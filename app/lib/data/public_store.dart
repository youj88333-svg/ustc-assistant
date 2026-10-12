part of 'jw_store.dart';

final class PublicAuthority {
  const PublicAuthority._(this.owner, this.epoch, this.generation, this.source);
  final String owner;
  final int epoch;
  final int generation;
  final PublicSource source;
  @override
  String toString() => 'PublicAuthority';
}

final class PublicJobTicket {
  PublicJobTicket._(this.authority, this.id);
  final PublicAuthority authority;
  final String id;
  bool cancelled = false;
  @override
  String toString() => 'PublicJobTicket';
}

final class KnowledgeLoadTicket {
  KnowledgeLoadTicket._(
    this.id,
    this.owner,
    this.reset,
    this.epoch,
    this.total,
    this.memoryGeneration,
  );
  final String id;
  final String owner;
  final int reset;
  final int epoch;
  final int total;
  final int memoryGeneration;
  int accepted = 0;
  int unchanged = 0;
  bool cancelled = false;
  @override
  String toString() => 'KnowledgeLoadTicket';
}

final class _KnowledgeStamp {
  const _KnowledgeStamp(
    this.owner,
    this.reset,
    this.epoch,
    this.sequence,
    this.memoryGeneration,
  );
  final String owner;
  final int reset;
  final int epoch;
  final int sequence;
  final int memoryGeneration;
}

final class _KnowledgePointer {
  const _KnowledgePointer(
    this.key,
    this.revision,
    this.section,
    this.stamp,
    this.expiry,
  );
  final String key;
  final String revision;
  final int section;
  final _KnowledgeStamp stamp;
  final DateTime expiry;
}

final class _KnowledgePage {
  _KnowledgePage(this.intent, this.rows, this.offset, this.stamp, this.expiry);
  final String intent;
  final List<(String, String, int)> rows;
  final int offset;
  final _KnowledgeStamp stamp;
  final DateTime expiry;
}

final class _KnowledgeRead {
  const _KnowledgeRead(this.intent, this.offset, this.expiry);
  final String intent;
  final int offset;
  final DateTime expiry;
}

/// C3 public operations share the canonical database, transaction queue and owner.
/// No school account is manufactured and no school record is read here.
final class PublicStore implements KnowledgeReadPort {
  PublicStore._(this._db);
  final JwStore _db;
  final Map<String, PublicJobTicket> _jobs = {};
  final Map<String, _KnowledgePointer> _references = {};
  final Map<String, _KnowledgePage> _pages = {};
  final Map<String, _KnowledgeRead> _reads = {};
  KnowledgeLoadTicket? _load;
  int _knowledgeGeneration = 0;
  bool _closed = false;

  static const schema = [
    '''CREATE TABLE public_sources (
      source TEXT PRIMARY KEY CHECK(source IN ('icourse','campus')),
      generation INTEGER NOT NULL, sequence INTEGER NOT NULL,
      active_job TEXT
    )''',
    "INSERT INTO public_sources VALUES ('icourse',0,0,NULL)",
    "INSERT INTO public_sources VALUES ('campus',0,0,NULL)",
    '''CREATE TABLE knowledge_state (
      singleton INTEGER PRIMARY KEY CHECK(singleton=1),
      epoch INTEGER NOT NULL, sequence INTEGER NOT NULL,
      edition TEXT, load_count INTEGER NOT NULL,
      icourse_consent INTEGER NOT NULL CHECK(icourse_consent IN (0,1))
    )''',
    'INSERT INTO knowledge_state VALUES (1,0,0,NULL,0,0)',
    '''CREATE TABLE knowledge_materials (
      material_key TEXT PRIMARY KEY, revision TEXT NOT NULL,
      metadata_json TEXT NOT NULL, markdown TEXT NOT NULL,
      title_search TEXT NOT NULL, provider TEXT NOT NULL,
      topic TEXT NOT NULL, audience TEXT NOT NULL, source_version TEXT NOT NULL,
      accepted_at INTEGER NOT NULL, byte_count INTEGER NOT NULL
    )''',
    '''CREATE TABLE knowledge_sections (
      material_key TEXT NOT NULL REFERENCES knowledge_materials(material_key),
      section_index INTEGER NOT NULL, heading TEXT NOT NULL,
      markdown TEXT NOT NULL, plain_text TEXT NOT NULL, search_text TEXT NOT NULL,
      PRIMARY KEY(material_key,section_index)
    )''',
    '''CREATE TABLE knowledge_loads (
      operation_id TEXT PRIMARY KEY, edition TEXT NOT NULL,
      epoch INTEGER NOT NULL, reset_epoch INTEGER NOT NULL,
      status TEXT NOT NULL, accepted INTEGER NOT NULL,
      unchanged INTEGER NOT NULL, total INTEGER NOT NULL
    )''',
    '''CREATE TABLE knowledge_audit (
      sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      action TEXT NOT NULL, material_count INTEGER NOT NULL,
      committed_at INTEGER NOT NULL
    )''',
    '''CREATE TABLE knowledge_load_items (
      operation_id TEXT NOT NULL REFERENCES knowledge_loads(operation_id),
      material_key TEXT NOT NULL, target_revision TEXT NOT NULL,
      result TEXT CHECK(result IN ('accepted','unchanged')),
      PRIMARY KEY(operation_id,material_key)
    )''',
  ];

  Future<T> _serial<T>(Future<T> Function() action) async {
    if (_closed) throw const PublicFailure(PublicFailureCode.closed);
    try {
      return await _db._serialized(action);
    } on AppFailure catch (error) {
      throw PublicFailure(
        error.code == FailureCode.closed
            ? PublicFailureCode.closed
            : PublicFailureCode.storageFailed,
      );
    }
  }

  Future<void> _initialize() async {
    await _db.customStatement(
      'UPDATE public_sources SET generation=generation+1,active_job=NULL',
    );
    await _db.customStatement(
      "UPDATE knowledge_loads SET status='abandoned' WHERE status='active'",
    );
    _jobs.clear();
    _references.clear();
    _pages.clear();
    _reads.clear();
    _load = null;
  }

  void _invalidateMemory() {
    _closed = true;
    for (final ticket in _jobs.values) {
      ticket.cancelled = true;
    }
    _load?.cancelled = true;
    _references.clear();
    _pages.clear();
    _reads.clear();
  }

  Future<QueryRow> _knowledgeState() => _db
      .customSelect('SELECT * FROM knowledge_state WHERE singleton=1')
      .getSingle();

  Future<QueryRow> _sourceState(PublicSource source) => _db
      .customSelect(
        'SELECT * FROM public_sources WHERE source=?',
        variables: [Variable.withString(source.name)],
      )
      .getSingle();

  Future<PublicAuthority> _authority(PublicSource source) async {
    final canonical = await _db._state();
    final state = await _sourceState(source);
    final owner = canonical.read<String>('owner_id');
    _db._validateOwner(owner);
    return PublicAuthority._(
      owner,
      canonical.read<int>('reset_epoch'),
      state.read<int>('generation'),
      source,
    );
  }

  Future<PublicAuthority> publicAuthority(PublicSource source) =>
      _serial(() => _authority(source));

  Future<void> ensureAuthority(PublicAuthority expected) => _serial(() async {
    final current = await _authority(expected.source);
    if (current.owner != expected.owner ||
        current.epoch != expected.epoch ||
        current.generation != expected.generation) {
      throw const PublicFailure(PublicFailureCode.staleReference);
    }
  });

  Future<bool> hasIcourseConsent() => _serial(
    () async => (await _knowledgeState()).read<int>('icourse_consent') == 1,
  );

  Future<void> setIcourseConsent(bool allowed) {
    for (final ticket in _jobs.values.where(
      (t) => t.authority.source == PublicSource.icourse,
    )) {
      ticket.cancelled = true;
    }
    return _serial(
      () => _db.transaction(() async {
        await _db.customStatement(
          'UPDATE knowledge_state SET icourse_consent=? WHERE singleton=1',
          [allowed ? 1 : 0],
        );
        await _db.customStatement(
          "UPDATE public_sources SET generation=generation+1,active_job=NULL WHERE source='icourse'",
        );
        await _db._guard();
      }),
    );
  }

  Future<PublicJobTicket> beginPublicJob(PublicSource source) =>
      _serial(() async {
        final ticket = await _db.transaction(() async {
          if (source == PublicSource.icourse &&
              (await _knowledgeState()).read<int>('icourse_consent') != 1) {
            throw const PublicFailure(PublicFailureCode.consentRequired);
          }
          final state = await _sourceState(source);
          if (state.read<String?>('active_job') != null) {
            throw const PublicFailure(PublicFailureCode.busy);
          }
          final authority = await _authority(source);
          final sequence = state.read<int>('sequence') + 1;
          final id = JwStore._randomHexId('public-');
          await _db.customStatement(
            'UPDATE public_sources SET sequence=?,active_job=? WHERE source=?',
            [sequence, id, source.name],
          );
          await _db._guard();
          return PublicJobTicket._(authority, id);
        });
        _jobs[ticket.id] = ticket;
        return ticket;
      });

  Future<void> _requireJob(PublicJobTicket ticket, {bool active = true}) async {
    if (!identical(_jobs[ticket.id], ticket) || ticket.cancelled) {
      throw const PublicFailure(PublicFailureCode.cancelled);
    }
    final authority = await _authority(ticket.authority.source);
    final state = await _sourceState(ticket.authority.source);
    if (authority.owner != ticket.authority.owner ||
        authority.epoch != ticket.authority.epoch ||
        authority.generation != ticket.authority.generation ||
        active && state.read<String?>('active_job') != ticket.id) {
      throw const PublicFailure(PublicFailureCode.staleReference);
    }
  }

  Future<void> ensurePublicJob(PublicJobTicket ticket) =>
      _serial(() => _requireJob(ticket));

  Future<void> finishPublicJob(PublicJobTicket ticket) => _serial(
    () => _db.transaction(() async {
      await _requireJob(ticket);
      await _db.customStatement(
        'UPDATE public_sources SET active_job=NULL WHERE source=? AND active_job=?',
        [ticket.authority.source.name, ticket.id],
      );
      await _db._guard();
    }),
  );

  Future<void> cancelPublicJob(PublicJobTicket ticket) async {
    ticket.cancelled = true;
    await _serial(
      () => _db.transaction(() async {
        if (!identical(_jobs[ticket.id], ticket)) return;
        final current = await _authority(ticket.authority.source);
        if (current.owner == ticket.authority.owner &&
            current.epoch == ticket.authority.epoch &&
            current.generation == ticket.authority.generation) {
          await _db.customStatement(
            'UPDATE public_sources SET generation=generation+1,active_job=NULL WHERE source=?',
            [ticket.authority.source.name],
          );
        }
        await _db._guard();
      }),
    );
  }

  void releasePublicJob(PublicJobTicket ticket) {
    if (identical(_jobs[ticket.id], ticket)) _jobs.remove(ticket.id);
  }

  Future<_KnowledgeStamp> _stamp() async {
    final canonical = await _db._state();
    final state = await _knowledgeState();
    return _KnowledgeStamp(
      canonical.read<String>('owner_id'),
      canonical.read<int>('reset_epoch'),
      state.read<int>('epoch'),
      state.read<int>('sequence'),
      _knowledgeGeneration,
    );
  }

  Future<void> _requireStamp(_KnowledgeStamp expected) async {
    final current = await _stamp();
    if (current.owner != expected.owner ||
        current.reset != expected.reset ||
        current.epoch != expected.epoch ||
        current.sequence != expected.sequence ||
        current.memoryGeneration != expected.memoryGeneration) {
      throw const PublicFailure(PublicFailureCode.staleReference);
    }
  }

  @override
  Future<KnowledgeSummary> inspectKnowledge() => _serial(() async {
    final state = await _knowledgeState();
    return KnowledgeSummary(
      materialCount: await _db._count(
        'SELECT COUNT(*) AS count FROM knowledge_materials',
      ),
      sectionCount: await _db._count(
        'SELECT COUNT(*) AS count FROM knowledge_sections',
      ),
      loadCount: state.read<int>('load_count'),
      loading: _load != null,
      edition: state.read<String?>('edition'),
    );
  });

  Future<KnowledgeLoadTicket> beginKnowledgeLoad() {
    final admission = _knowledgeGeneration;
    return _serial(() async {
      if (admission != _knowledgeGeneration) {
        throw const PublicFailure(PublicFailureCode.cancelled);
      }
      if (_load != null) throw const PublicFailure(PublicFailureCode.busy);
      final identity = _db.knowledgeIdentity;
      if (identity.catalogDigest.length != 64 ||
          identity.materialKeys.isEmpty ||
          identity.materialKeys.length > 256) {
        throw const PublicFailure(PublicFailureCode.unavailable);
      }
      final ticket = await _db.transaction(() async {
        final stamp = await _stamp();
        final ticket = KnowledgeLoadTicket._(
          JwStore._randomHexId('knowledge-'),
          stamp.owner,
          stamp.reset,
          stamp.epoch,
          identity.materialKeys.length,
          admission,
        );
        await _db.customStatement(
          "INSERT INTO knowledge_loads VALUES (?,?,?,?,'active',0,0,?)",
          [ticket.id, identity.key, ticket.epoch, ticket.reset, ticket.total],
        );
        await _db._guard();
        return ticket;
      });
      _load = ticket;
      return ticket;
    });
  }

  Future<void> _requireLoad(KnowledgeLoadTicket ticket) async {
    if (!identical(_load, ticket) ||
        ticket.cancelled ||
        ticket.memoryGeneration != _knowledgeGeneration) {
      throw const PublicFailure(PublicFailureCode.cancelled);
    }
    final stamp = await _stamp();
    if (stamp.owner != ticket.owner ||
        stamp.reset != ticket.reset ||
        stamp.epoch != ticket.epoch) {
      throw const PublicFailure(PublicFailureCode.staleReference);
    }
    await _db._guard();
  }

  void validateEdition(KnowledgeEdition edition) {
    final identity = _db.knowledgeIdentity;
    final keys = edition.materials.map((m) => m.key).toSet();
    if (edition.key != identity.key ||
        edition.catalogDigest != identity.catalogDigest ||
        edition.materials.length != identity.materialKeys.length ||
        keys.length != edition.materials.length ||
        !keys.containsAll(identity.materialKeys)) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
  }

  /// Bind the immutable batch intent before accepting any material.
  Future<void> bindKnowledgeEdition(
    KnowledgeLoadTicket ticket,
    KnowledgeEdition edition,
  ) => _serial(
    () => _db.transaction(() async {
      await _requireLoad(ticket);
      validateEdition(edition);
      final targets = {
        for (final material in edition.materials)
          material.key: fingerprint([_metadata(material), material.markdown]),
      };
      final bound = await _db
          .customSelect(
            'SELECT material_key,target_revision FROM knowledge_load_items WHERE operation_id=?',
            variables: [Variable.withString(ticket.id)],
          )
          .get();
      if (bound.isNotEmpty) {
        if (bound.length != targets.length ||
            bound.any(
              (row) =>
                  targets[row.read<String>('material_key')] !=
                  row.read<String>('target_revision'),
            )) {
          throw const PublicFailure(PublicFailureCode.sourceSchema);
        }
        return;
      }
      for (final entry in targets.entries) {
        await _db.customStatement(
          'INSERT INTO knowledge_load_items VALUES (?,?,?,NULL)',
          [ticket.id, entry.key, entry.value],
        );
      }
      await _requireLoad(ticket);
    }),
  );

  Map<String, Object?> _metadata(KnowledgeMaterial material) {
    final fields = [
      material.key,
      material.title,
      material.topic,
      material.audience,
      material.sourceVersion,
      material.coveredScope,
      material.reviewVersion,
    ];
    if (fields.any(
          (s) =>
              s.trim().isEmpty ||
              s.length > 2000 ||
              RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]').hasMatch(s),
        ) ||
        material.provider == PublicProvider.icourse ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(material.sourceDigest) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(material.markdownDigest) ||
        fingerprintBytes(material.markdown) != material.markdownDigest) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    final allowedHost = material.provider == PublicProvider.teach
        ? 'www.teach.ustc.edu.cn'
        : 'finance.ustc.edu.cn';
    for (final uri in [
      material.articleUrl,
      if (material.materialUrl != null) material.materialUrl!,
    ]) {
      if (uri.scheme != 'https' ||
          uri.host != allowedHost ||
          uri.port != 443 ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment ||
          uri.hasQuery) {
        throw const PublicFailure(PublicFailureCode.unsafeTarget);
      }
    }
    return {
      'key': material.key,
      'title': material.title,
      'provider': material.provider.name,
      'topic': material.topic,
      'audience': material.audience,
      'sourceVersion': material.sourceVersion,
      'articleUrl': material.articleUrl.toString(),
      'materialUrl': material.materialUrl?.toString(),
      'sourceDigest': material.sourceDigest,
      'scope': material.coveredScope,
      'reviewVersion': material.reviewVersion,
      'publishedOn': material.publishedOn,
      'updatedOn': material.updatedOn,
    };
  }

  Future<bool> acceptKnowledgeMaterial(
    KnowledgeLoadTicket ticket,
    KnowledgeMaterial material,
  ) => _serial(() async {
    final receipt = await _db.transaction(() async {
      await _requireLoad(ticket);
      if (!_db.knowledgeIdentity.materialKeys.contains(material.key)) {
        throw const PublicFailure(PublicFailureCode.sourceSchema);
      }
      final metadata = _metadata(material);
      final revision = fingerprint([metadata, material.markdown]);
      final bound = await _db
          .customSelect(
            'SELECT target_revision,result FROM knowledge_load_items WHERE operation_id=? AND material_key=?',
            variables: [
              Variable.withString(ticket.id),
              Variable.withString(material.key),
            ],
          )
          .getSingleOrNull();
      if (bound == null || bound.read<String>('target_revision') != revision) {
        throw const PublicFailure(PublicFailureCode.sourceSchema);
      }
      if (bound.read<String?>('result') != null) {
        // Replaying one material never advances the batch or writes it again.
        final counts = await _loadCounts(ticket);
        return (
          bound.read<String>('result') == 'accepted',
          false,
          counts.$1,
          counts.$2,
        );
      }
      final sections = knowledgeSections(material.markdown);
      final previous = await _db
          .customSelect(
            'SELECT revision,byte_count FROM knowledge_materials WHERE material_key=?',
            variables: [Variable.withString(material.key)],
          )
          .getSingleOrNull();
      if (previous?.read<String>('revision') == revision) {
        await _db.customStatement(
          'UPDATE knowledge_loads SET unchanged=unchanged+1 WHERE operation_id=?',
          [ticket.id],
        );
        await _db.customStatement(
          "UPDATE knowledge_load_items SET result='unchanged' WHERE operation_id=? AND material_key=?",
          [ticket.id, material.key],
        );
        await _requireLoad(ticket);
        final counts = await _loadCounts(ticket);
        return (false, false, counts.$1, counts.$2);
      }
      final bytes =
          utf8.encode(material.markdown).length +
          sections.fold<int>(
            0,
            (sum, s) =>
                sum +
                utf8.encode(s.plainText).length +
                utf8.encode(s.markdown).length,
          );
      final currentBytes =
          (await _db
                  .customSelect(
                    'SELECT COALESCE(SUM(byte_count),0) AS bytes FROM knowledge_materials',
                  )
                  .getSingle())
              .read<int>('bytes');
      final count = await _db._count(
        'SELECT COUNT(*) AS count FROM knowledge_materials',
      );
      if (currentBytes - (previous?.read<int>('byte_count') ?? 0) + bytes >
              128 * 1024 * 1024 ||
          previous == null && count >= 256) {
        throw const PublicFailure(PublicFailureCode.resourceLimit);
      }
      await _db.customStatement(
        'DELETE FROM knowledge_sections WHERE material_key=?',
        [material.key],
      );
      await _db.customStatement(
        'INSERT INTO knowledge_materials VALUES (?,?,?,?,?,?,?,?,?,?,?) '
        'ON CONFLICT(material_key) DO UPDATE SET revision=excluded.revision,metadata_json=excluded.metadata_json,'
        'markdown=excluded.markdown,title_search=excluded.title_search,provider=excluded.provider,'
        'topic=excluded.topic,audience=excluded.audience,source_version=excluded.source_version,'
        'accepted_at=excluded.accepted_at,byte_count=excluded.byte_count',
        [
          material.key,
          revision,
          jsonEncode(metadata),
          material.markdown,
          '${material.title} ${material.topic}'.toLowerCase(),
          material.provider.name,
          material.topic,
          material.audience,
          material.sourceVersion,
          _db._clock.nowUtc.microsecondsSinceEpoch,
          bytes,
        ],
      );
      for (final section in sections) {
        await _db.customStatement(
          'INSERT INTO knowledge_sections VALUES (?,?,?,?,?,?)',
          [
            material.key,
            section.index,
            section.heading,
            section.markdown,
            section.plainText,
            section.plainText.toLowerCase(),
          ],
        );
      }
      await _db.onKnowledgeCheckpoint?.call();
      await _requireLoad(ticket);
      await _db.customStatement(
        'UPDATE knowledge_state SET sequence=sequence+1,edition=NULL WHERE singleton=1',
      );
      await _db.customStatement(
        'UPDATE knowledge_loads SET accepted=accepted+1 WHERE operation_id=?',
        [ticket.id],
      );
      await _db.customStatement(
        "UPDATE knowledge_load_items SET result='accepted' WHERE operation_id=? AND material_key=?",
        [ticket.id, material.key],
      );
      await _db.customStatement(
        'INSERT INTO knowledge_audit(action,material_count,committed_at) VALUES (?,?,?)',
        ['loaded', 1, _db._clock.nowUtc.microsecondsSinceEpoch],
      );
      await _db._guard();
      final counts = await _loadCounts(ticket);
      return (true, true, counts.$1, counts.$2);
    });
    ticket.accepted = receipt.$3;
    ticket.unchanged = receipt.$4;
    if (receipt.$2) {
      _references.clear();
      _pages.clear();
      _reads.clear();
    }
    return receipt.$1;
  });

  Future<(int, int)> _loadCounts(KnowledgeLoadTicket ticket) async {
    final row = await _db
        .customSelect(
          "SELECT SUM(CASE WHEN result='accepted' THEN 1 ELSE 0 END) AS accepted,"
          "SUM(CASE WHEN result='unchanged' THEN 1 ELSE 0 END) AS unchanged "
          'FROM knowledge_load_items WHERE operation_id=?',
          variables: [Variable.withString(ticket.id)],
        )
        .getSingle();
    return (row.read<int?>('accepted') ?? 0, row.read<int?>('unchanged') ?? 0);
  }

  Future<KnowledgeLoadOutcome> finishKnowledgeLoad(
    KnowledgeLoadTicket ticket,
    KnowledgeLoadState state, {
    PublicFailureCode? failure,
  }) => _serial(() async {
    if (!identical(_load, ticket) && ticket.cancelled) {
      return KnowledgeLoadOutcome(
        state: KnowledgeLoadState.cancelled,
        accepted: ticket.accepted,
        unchanged: ticket.unchanged,
        total: ticket.total,
        failure: PublicFailureCode.cancelled,
      );
    }
    final outcome = await _db.transaction(() async {
      if (!identical(_load, ticket)) {
        throw const PublicFailure(PublicFailureCode.staleReference);
      }
      if (state == KnowledgeLoadState.done) await _requireLoad(ticket);
      final counts = await _loadCounts(ticket);
      if (state == KnowledgeLoadState.done) {
        final items = await _db
            .customSelect(
              'SELECT i.material_key,i.target_revision,i.result,m.revision FROM knowledge_load_items i '
              'LEFT JOIN knowledge_materials m ON i.material_key=m.material_key WHERE i.operation_id=?',
              variables: [Variable.withString(ticket.id)],
            )
            .get();
        if (items.length != ticket.total ||
            counts.$1 + counts.$2 != ticket.total ||
            !items
                .map((i) => i.read<String>('material_key'))
                .toSet()
                .containsAll(_db.knowledgeIdentity.materialKeys) ||
            items.any(
              (i) =>
                  i.read<String?>('result') == null ||
                  i.read<String>('target_revision') !=
                      i.read<String?>('revision'),
            )) {
          throw const PublicFailure(PublicFailureCode.sourceSchema);
        }
      }
      await _db.customStatement(
        'UPDATE knowledge_loads SET status=? WHERE operation_id=?',
        [state.name, ticket.id],
      );
      if (state == KnowledgeLoadState.done) {
        await _db.customStatement(
          'UPDATE knowledge_state SET edition=?,load_count=load_count+1 WHERE singleton=1',
          [_db.knowledgeIdentity.key],
        );
      }
      await _db._guard();
      return KnowledgeLoadOutcome(
        state: state,
        accepted: counts.$1,
        unchanged: counts.$2,
        total: ticket.total,
        failure: failure,
      );
    });
    if (identical(_load, ticket)) _load = null;
    ticket.accepted = outcome.accepted;
    ticket.unchanged = outcome.unchanged;
    return outcome;
  });

  Future<void> cancelKnowledgeLoad() async {
    final ticket = _load;
    if (ticket == null) return;
    ticket.cancelled = true;
    await _serial(() async {
      await _db.customStatement(
        "UPDATE knowledge_loads SET status='cancelled' WHERE operation_id=? AND status='active'",
        [ticket.id],
      );
    });
  }

  Future<void> clearKnowledge({required bool confirmed}) async {
    if (!confirmed) throw const PublicFailure(PublicFailureCode.invalidRequest);
    _load?.cancelled = true;
    _knowledgeGeneration++;
    await _serial(() async {
      _load?.cancelled = true;
      await _db.transaction(() async {
        final count = await _db._count(
          'SELECT COUNT(*) AS count FROM knowledge_materials',
        );
        await _db.customStatement(
          'UPDATE knowledge_state SET epoch=epoch+1,sequence=sequence+1,edition=NULL,load_count=0 WHERE singleton=1',
        );
        await _db.customStatement('DELETE FROM knowledge_sections');
        await _db.customStatement('DELETE FROM knowledge_materials');
        await _db.customStatement('DELETE FROM knowledge_load_items');
        await _db.customStatement('DELETE FROM knowledge_loads');
        await _db.customStatement(
          'INSERT INTO knowledge_audit(action,material_count,committed_at) VALUES (?,?,?)',
          ['cleared', count, _db._clock.nowUtc.microsecondsSinceEpoch],
        );
        await _db._guard();
      });
      _references.clear();
      _pages.clear();
      _reads.clear();
      _load = null;
    });
  }

  void _prune() {
    final now = _db._clock.nowUtc;
    _references.removeWhere((_, p) => !now.isBefore(p.expiry));
    _pages.removeWhere((_, p) => !now.isBefore(p.expiry));
    _reads.removeWhere((_, p) => !now.isBefore(p.expiry));
    while (_references.length >= 256) {
      _references.remove(_references.keys.first);
    }
    while (_pages.length >= 256) {
      _pages.remove(_pages.keys.first);
    }
    while (_reads.length >= 256) {
      _reads.remove(_reads.keys.first);
    }
  }

  @override
  Future<PublicQueryResult> searchKnowledge(
    String keywords, {
    PublicProvider? provider,
    String? topic,
    String? audience,
    String? version,
    int pageSize = 20,
    PublicCursor? cursor,
  }) {
    final query = publicKeywords(keywords).toLowerCase();
    requirePublicPageSize(pageSize);
    if (provider == PublicProvider.icourse) {
      throw const PublicFailure(PublicFailureCode.invalidRequest);
    }
    for (final filter in [topic, audience, version]) {
      if (filter != null) publicKeywords(filter);
    }
    final intent = fingerprint([
      query,
      provider?.name,
      topic,
      audience,
      version,
      pageSize,
    ]);
    return _serial(() async {
      _prune();
      final stamp = await _stamp();
      List<(String, String, int)> matches;
      var offset = 0;
      if (cursor != null) {
        final page = _pages[cursor.value];
        if (page == null || page.intent != intent) {
          throw const PublicFailure(PublicFailureCode.staleReference);
        }
        await _requireStamp(page.stamp);
        matches = page.rows;
        offset = page.offset;
      } else {
        final conditions = <String>[];
        final parameters = <Variable>[];
        for (final word in query.split(' ')) {
          conditions.add(
            '(instr(s.search_text,?)>0 OR instr(m.title_search,?)>0)',
          );
          parameters.addAll([
            Variable.withString(word),
            Variable.withString(word),
          ]);
        }
        final filters = {
          'provider': provider?.name,
          'topic': topic,
          'audience': audience,
          'source_version': version,
        };
        for (final entry in filters.entries.where((e) => e.value != null)) {
          conditions.add('m.${entry.key}=?');
          parameters.add(Variable.withString(entry.value!));
        }
        parameters.add(Variable.withString(query));
        final rows = await _db
            .customSelect(
              'SELECT m.material_key,m.revision,MIN(s.section_index) AS first_section '
              'FROM knowledge_materials m JOIN knowledge_sections s ON m.material_key=s.material_key '
              'WHERE ${conditions.join(' AND ')} GROUP BY m.material_key '
              'ORDER BY CASE WHEN instr(m.title_search,?)>0 THEN 0 ELSE 1 END,m.material_key LIMIT 257',
              variables: parameters,
            )
            .get();
        if (rows.length > 256) {
          throw const PublicFailure(PublicFailureCode.resourceLimit);
        }
        matches = rows
            .map(
              (r) => (
                r.read<String>('material_key'),
                r.read<String>('revision'),
                r.read<int>('first_section'),
              ),
            )
            .toList();
      }
      final candidates = <PublicCandidate>[];
      for (final row in matches.skip(offset).take(pageSize)) {
        final record = await _material(row.$1);
        if (record == null || record.read<String>('revision') != row.$2) {
          throw const PublicFailure(PublicFailureCode.staleReference);
        }
        final section = await _section(row.$1, row.$3);
        final id = JwStore._randomHexId('kr-');
        _prune();
        _references[id] = _KnowledgePointer(
          row.$1,
          row.$2,
          row.$3,
          stamp,
          _db._clock.nowUtc.add(const Duration(minutes: 10)),
        );
        final text = section.read<String>('plain_text');
        final firstWord = query.split(' ').first;
        final position = text.toLowerCase().indexOf(firstWord);
        final snippet = position > 40 ? text.substring(position - 40) : text;
        candidates.add(
          PublicCandidate(
            reference: PublicReference(id),
            title: _meta(record)['title'] as String,
            snippet: clipPublicText(snippet, 400),
            evidence: _evidence(record, section.read<String>('heading')),
          ),
        );
      }
      PublicCursor? next;
      if (offset + candidates.length < matches.length) {
        final id = JwStore._randomHexId('kp-');
        _prune();
        _pages[id] = _KnowledgePage(
          intent,
          matches,
          offset + candidates.length,
          stamp,
          _db._clock.nowUtc.add(const Duration(minutes: 10)),
        );
        next = PublicCursor(id);
      }
      await _requireStamp(stamp);
      await _db._guard();
      return PublicQueryResult(
        candidates: candidates,
        next: next,
        coverage: PublicCoverage(
          scope: 'acceptedKnowledge',
          returned: candidates.length,
          observed: matches.length,
          totalReported: matches.length,
          complete: next == null,
        ),
      );
    });
  }

  Future<QueryRow?> _material(String key) => _db
      .customSelect(
        'SELECT * FROM knowledge_materials WHERE material_key=?',
        variables: [Variable.withString(key)],
      )
      .getSingleOrNull();
  Future<QueryRow> _section(String key, int index) => _db
      .customSelect(
        'SELECT * FROM knowledge_sections WHERE material_key=? AND section_index=?',
        variables: [Variable.withString(key), Variable.withInt(index)],
      )
      .getSingle();
  Map<String, dynamic> _meta(QueryRow row) =>
      jsonDecode(row.read<String>('metadata_json')) as Map<String, dynamic>;
  PublicEvidence _evidence(QueryRow row, String locator) {
    final meta = _meta(row);
    return PublicEvidence(
      provider: PublicProvider.values.byName(meta['provider'] as String),
      title: meta['title'] as String,
      articleUrl: Uri.parse(meta['articleUrl'] as String),
      materialUrl: meta['materialUrl'] == null
          ? null
          : Uri.parse(meta['materialUrl'] as String),
      observedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
        row.read<int>('accepted_at'),
        isUtc: true,
      ),
      origin: EvidenceOrigin.localKnowledge,
      publishedOn: meta['publishedOn'] as String?,
      updatedOn: meta['updatedOn'] as String?,
      revision: row.read<String>('revision'),
      locator: locator,
      sourceVersion: meta['sourceVersion'] as String,
      audience: meta['audience'] as String,
      coveredScope: meta['scope'] as String,
      quality: EvidenceQuality.reviewedContent,
    );
  }

  @override
  Future<PublicQueryResult> readKnowledgeMaterial(
    PublicReference reference, {
    int sectionStart = 0,
    int maxCharacters = 12000,
    PublicCursor? cursor,
  }) {
    requirePublicTextRange(sectionStart, maxCharacters);
    return _serial(() async {
      _prune();
      final pointer = _references[reference.value];
      if (pointer == null) {
        throw const PublicFailure(PublicFailureCode.staleReference);
      }
      await _requireStamp(pointer.stamp);
      final row = await _material(pointer.key);
      if (row == null || row.read<String>('revision') != pointer.revision) {
        throw const PublicFailure(PublicFailureCode.staleReference);
      }
      final sections = await _db
          .customSelect(
            'SELECT * FROM knowledge_sections WHERE material_key=? AND section_index>=? ORDER BY section_index',
            variables: [
              Variable.withString(pointer.key),
              Variable.withInt(sectionStart),
            ],
          )
          .get();
      if (sections.isEmpty) {
        throw const PublicFailure(PublicFailureCode.invalidRequest);
      }
      final all = sections.map((s) => s.read<String>('markdown')).join('\n\n');
      final intent = fingerprint([
        reference.value,
        sectionStart,
        maxCharacters,
      ]);
      var offset = 0;
      if (cursor != null) {
        final read = _reads[cursor.value];
        if (read == null || read.intent != intent) {
          throw const PublicFailure(PublicFailureCode.staleReference);
        }
        offset = read.offset;
      }
      final runes = all.runes.toList();
      final markdown = String.fromCharCodes(
        runes.skip(offset).take(maxCharacters),
      );
      final end = offset + markdown.runes.length;
      PublicCursor? next;
      if (end < runes.length) {
        final id = JwStore._randomHexId('kb-');
        _prune();
        _reads[id] = _KnowledgeRead(intent, end, pointer.expiry);
        next = PublicCursor(id);
      }
      await _requireStamp(pointer.stamp);
      final evidence = _evidence(
        row,
        '${sections.first.read<String>('heading')} · 字符 $offset–$end',
      );
      return PublicQueryResult(
        document: PublicDocument(evidence: evidence, markdown: markdown),
        next: next,
        coverage: PublicCoverage(
          scope: 'selectedMaterialSections',
          returned: markdown.runes.length,
          observed: runes.length,
          truncated: offset > 0 || next != null,
          complete: offset == 0 && next == null,
        ),
      );
    });
  }
}

String fingerprintBytes(String value) =>
    sha256.convert(utf8.encode(value)).toString();
String clipPublicText(String text, int maximum) =>
    String.fromCharCodes(text.runes.take(maximum));
