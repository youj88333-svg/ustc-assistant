part of 'jw_store.dart';

final class _PermissionProof {
  _PermissionProof(
    this.ticket,
    this.scope,
    this.categories,
    this.mode,
    this.remember,
    this.revisions,
  );
  final AgentRunTicket ticket;
  final String scope;
  final List<AgentPermissionCategory> categories;
  final AgentAuthorizationMode mode;
  final bool remember;
  final Map<AgentPermissionCategory, int> revisions;
}

/// Local human decisions. Neither these proofs nor account scope are JSON tools.
final class _AgentPermissionState {
  _AgentPermissionState(this.owner);
  final AgentStore owner;
  JwStore get db => owner._db;
  final actions = Expando<_PermissionProof>();
  final local = Expando<_PermissionProof>();
  final _references = Expando<String>();
  final _revoked = <String>{};
  static const schema = <String>[
    "ALTER TABLE agent_actions ADD COLUMN authorization TEXT NOT NULL DEFAULT 'legacy' CHECK(authorization IN ('legacy','confirmed','remembered'))",
    '''CREATE TABLE agent_permissions (
      scope TEXT NOT NULL, tool TEXT NOT NULL, category TEXT NOT NULL,
      revision INTEGER NOT NULL CHECK(revision>0),
      enabled INTEGER NOT NULL CHECK(enabled IN (0,1)), changed_at INTEGER NOT NULL,
      PRIMARY KEY(scope,tool,category))''',
  ];

  Future<String> scope() async {
    final authority = await owner._authority();
    final account = await db._account();
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              authority.owner,
              authority.resetEpoch,
              account?.read<String>('expected_account_code'),
            ]),
          ),
        )
        .toString();
  }

  String _key(String scope, AgentPermissionCategory c, int revision) =>
      '$scope/${c.name}/$revision';

  Future<_PermissionProof?> issue(
    AgentRunTicket ticket,
    List<AgentPermissionCategory> categories,
    AgentAuthorizationMode mode,
    bool remember,
  ) async {
    await owner._ensureAgentWritesAllowed(ticket);
    if (categories.isEmpty ||
        remember && mode != AgentAuthorizationMode.confirmed) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    final currentScope = await scope();
    final revisions = <AgentPermissionCategory, int>{};
    if (mode == AgentAuthorizationMode.remembered) {
      for (final category in categories.toSet()) {
        final row = await _row(currentScope, category);
        if (row == null ||
            row.read<int>('enabled') != 1 ||
            _revoked.contains(
              _key(currentScope, category, row.read<int>('revision')),
            )) {
          return null;
        }
        revisions[category] = row.read<int>('revision');
      }
    }
    return _PermissionProof(
      ticket,
      currentScope,
      List.unmodifiable(categories.toSet()),
      mode,
      remember,
      Map.unmodifiable(revisions),
    );
  }

  Future<QueryRow?> _row(String scope, AgentPermissionCategory c) => db
      .customSelect(
        'SELECT * FROM agent_permissions WHERE scope=? AND tool=? AND category=?',
        variables: [
          Variable.withString(scope),
          Variable.withString(c.tool),
          Variable.withString(c.name),
        ],
      )
      .getSingleOrNull();

  Future<void> validate(_PermissionProof proof) async {
    await owner._ensureAgentWritesAllowed(proof.ticket);
    if (proof.scope != await scope() ||
        owner._revokedActionRuns.contains(proof.ticket.runId)) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    if (proof.mode == AgentAuthorizationMode.remembered) {
      for (final category in proof.categories) {
        final revision = proof.revisions[category];
        final row = await _row(proof.scope, category);
        if (revision == null ||
            row?.read<int>('revision') != revision ||
            row?.read<int>('enabled') != 1 ||
            _revoked.contains(_key(proof.scope, category, revision))) {
          throw const AgentFailure(AgentFailureCode.consentRequired);
        }
      }
    }
  }

  Future<void> validateAction(AgentActionView action) async {
    final ticket =
        owner._actionPermits[action] ?? owner._preferencePermits[action]?.$1;
    if (ticket != null) await owner._ensureAgentWritesAllowed(ticket);
    final proof = actions[action];
    if (proof != null) await validate(proof);
  }

  /// Called in the same mutation/approval transaction after final checks.
  Future<void> persist(_PermissionProof proof) async {
    await validate(proof);
    if (!proof.remember) return;
    for (final category in proof.categories) {
      await db.customStatement(
        'INSERT INTO agent_permissions VALUES (?,?,?,1,1,?) '
        'ON CONFLICT(scope,tool,category) DO UPDATE SET '
        'revision=revision+1,enabled=1,changed_at=excluded.changed_at',
        [
          proof.scope,
          category.tool,
          category.name,
          db._clock.nowUtc.microsecondsSinceEpoch,
        ],
      );
    }
  }

  Future<List<AgentPermissionReference>> read() => owner._serial(() async {
    await db._guard();
    final currentScope = await scope();
    final rows = await db
        .customSelect(
          'SELECT category,revision FROM agent_permissions WHERE scope=? AND enabled=1 ORDER BY category',
          variables: [Variable.withString(currentScope)],
        )
        .get();
    return List.unmodifiable(
      rows.map((row) {
        final c = AgentPermissionCategory.values.byName(
          row.read<String>('category'),
        );
        final reference = AgentPermissionReference(
          c,
          row.read<int>('revision'),
        );
        _references[reference] = currentScope;
        return reference;
      }),
    );
  });

  Future<void> revoke(AgentPermissionReference reference) {
    final issuedScope = _references[reference];
    if (issuedScope == null) {
      return Future.error(const AgentFailure(AgentFailureCode.staleContext));
    }
    // Immediate revocation also reaches a transaction paused at a checkpoint.
    _revoked.add(_key(issuedScope, reference.category, reference.revision));
    return owner._serial(() async {
      await db.transaction(() async {
        await db._guard();
        final row = await _row(issuedScope, reference.category);
        if (issuedScope != await scope() ||
            row?.read<int>('revision') != reference.revision ||
            row?.read<int>('enabled') != 1) {
          throw const AgentFailure(AgentFailureCode.staleContext);
        }
        await db.customStatement(
          'UPDATE agent_permissions SET enabled=0,revision=revision+1,changed_at=? '
          'WHERE scope=? AND tool=? AND category=? AND revision=?',
          [
            db._clock.nowUtc.microsecondsSinceEpoch,
            issuedScope,
            reference.category.tool,
            reference.category.name,
            reference.revision,
          ],
        );
        db._ownership.ensureHeld();
      });
      owner._signal();
    });
  }

  Future<void> reset() async {
    await db.customStatement('DELETE FROM agent_permissions');
    _revoked.clear();
  }
}

List<AgentPermissionCategory> _planPermissionCategories(AgentLocalPlan plan) {
  if (plan.view.kind == AgentActionKind.undo) {
    return const [AgentPermissionCategory.undo];
  }
  final categories = <AgentPermissionCategory>{};
  for (final change in plan.changes) {
    if (change is AgentCreateTask) {
      categories.add(AgentPermissionCategory.createTask);
    } else if (change is AgentDependentBlock) {
      categories.add(AgentPermissionCategory.createBlock);
    } else if (change is AgentPersonalPatch) {
      categories.add(AgentPermissionCategory.updatePersonal);
    } else if (change is AgentTaskPatch) {
      categories.add(AgentPermissionCategory.updateTask);
    } else if (change is AgentBlockPatch) {
      categories.add(AgentPermissionCategory.updateBlock);
    } else if (change is AgentCalendarChange) {
      final intent = change.intent;
      if (intent is UpdateSchoolAnnotation) {
        if (intent.attendance != null) {
          categories.add(AgentPermissionCategory.attendance);
        }
        if (intent.listening != null) {
          categories.add(AgentPermissionCategory.listening);
        }
        if (intent.note != null) {
          categories.add(AgentPermissionCategory.note);
        }
        if (intent.hidden != null) {
          categories.add(AgentPermissionCategory.visibility);
        }
      } else {
        categories.add(switch (intent) {
          CreatePersonalEvent() => AgentPermissionCategory.createPersonal,
          UpdatePersonalSeries() ||
          UpdatePersonalOccurrence() => AgentPermissionCategory.updatePersonal,
          SetPersonalOccurrenceState() => AgentPermissionCategory.statePersonal,
          DeletePersonalSeries() => AgentPermissionCategory.deletePersonal,
          CreateTask() => AgentPermissionCategory.createTask,
          UpdateTask() => AgentPermissionCategory.updateTask,
          SetTaskStatus() => AgentPermissionCategory.stateTask,
          DeleteTask() => AgentPermissionCategory.deleteTask,
          CreatePlanBlock() => AgentPermissionCategory.createBlock,
          UpdatePlanBlock() => AgentPermissionCategory.updateBlock,
          SetPlanBlockStatus() => AgentPermissionCategory.stateBlock,
          DeletePlanBlock() => AgentPermissionCategory.deleteBlock,
          SaveCalendarRelation() => AgentPermissionCategory.saveRelation,
          DeleteCalendarRelation() => AgentPermissionCategory.deleteRelation,
          _ => throw const AgentFailure(AgentFailureCode.invalidInput),
        });
      }
    } else {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
  }
  return categories.toList();
}
