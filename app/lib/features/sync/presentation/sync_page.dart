import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/database/app_database.dart';
import '../../../core/security/windows_dpapi_protector.dart';
import '../../accounts/application/account_service.dart';
import '../../import/application/import_service.dart';
import '../../import/data/source_bundle_decoder.dart';
import '../../import/presentation/file_import_action.dart';
import '../application/sync_coordinator.dart';
import '../data/bridge_client.dart';
import '../data/python_locator.dart';
import '../domain/sync_state.dart';

Future<void> runStartupAutomaticSync(AppDatabase database) async {
  BridgeGateway? bridge;
  try {
    final accounts = AccountService(
      database: database,
      protector: WindowsDpapiProtector(),
    );
    final account = await accounts.activeAccount();
    if (account == null) return;
    final schemaText = await rootBundle.loadString(
      'assets/schemas/source-bundle-1.0.draft7.schema.json',
    );
    final importer = ImportService(
      database: database,
      decoder: SourceBundleDecoder(
        jsonDecode(schemaText) as Map<String, dynamic>,
      ),
    );
    final coordinator = SyncCoordinator(
      database: database,
      accounts: accounts,
      bridgeFactory: () async {
        final current = bridge;
        if (current != null) return current;
        final executable = await PythonLocator().locate();
        return bridge = await BridgeClient.start(pythonExecutable: executable);
      },
      importBundle: importer.importBytes,
    );
    await coordinator.recoverInterruptedRuns();
    final outcomes = await coordinator.syncAll(
      trigger: SyncTrigger.automatic,
      accountId: account.id,
    );
    for (final outcome in outcomes.whereType<SyncNeedsUserAction>()) {
      await coordinator.resumeInteractive(outcome.jobId, userConfirmed: false);
    }
  } on Object {
    // Startup synchronization is best-effort and must not block local data.
  } finally {
    await bridge?.shutdown();
  }
}

class SyncPageLoader extends StatefulWidget {
  const SyncPageLoader({required this.database, super.key});

  final AppDatabase database;

  @override
  State<SyncPageLoader> createState() => _SyncPageLoaderState();
}

class _SyncPageLoaderState extends State<SyncPageLoader> {
  late final Future<_SyncDependencies> dependencies = _build();
  BridgeGateway? bridge;

  Future<_SyncDependencies> _build() async {
    final schemaText = await rootBundle.loadString(
      'assets/schemas/source-bundle-1.0.draft7.schema.json',
    );
    final accounts = AccountService(
      database: widget.database,
      protector: WindowsDpapiProtector(),
    );
    final importer = ImportService(
      database: widget.database,
      decoder: SourceBundleDecoder(
        jsonDecode(schemaText) as Map<String, dynamic>,
      ),
    );
    final coordinator = SyncCoordinator(
      database: widget.database,
      accounts: accounts,
      bridgeFactory: () async {
        final current = bridge;
        if (current != null) return current;
        final executable = await PythonLocator().locate();
        final started = await BridgeClient.start(pythonExecutable: executable);
        bridge = started;
        return started;
      },
      importBundle: importer.importBytes,
    );
    await coordinator.recoverInterruptedRuns();
    return _SyncDependencies(accounts: accounts, coordinator: coordinator);
  }

  @override
  void dispose() {
    bridge?.shutdown();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_SyncDependencies>(
      future: dependencies,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Scaffold(body: Center(child: Text('同步组件初始化失败')));
        }
        final value = snapshot.data;
        if (value == null) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return SyncPage(
          accounts: value.accounts,
          coordinator: value.coordinator,
        );
      },
    );
  }
}

class _SyncDependencies {
  const _SyncDependencies({required this.accounts, required this.coordinator});

  final AccountService accounts;
  final SyncCoordinator coordinator;
}

class SyncPage extends StatefulWidget {
  const SyncPage({
    required this.accounts,
    required this.coordinator,
    this.filePicker = const SystemImportFilePicker(),
    super.key,
  });

  final AccountService accounts;
  final SyncCoordinator coordinator;
  final ImportFilePicker filePicker;

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  String? accountId;
  bool busy = false;
  Map<SyncSource, SyncSourceState> states = const {};

  @override
  void initState() {
    super.initState();
    _loadAndAutoSync();
  }

  Future<void> _loadAndAutoSync() async {
    final account = await widget.accounts.activeAccount();
    if (!mounted) return;
    accountId = account?.id;
    await _refresh();
    if (account != null) await _runAll(SyncTrigger.automatic);
  }

  Future<void> _refresh() async {
    final id = accountId;
    if (id == null) {
      if (mounted) setState(() {});
      return;
    }
    final loaded = <SyncSource, SyncSourceState>{};
    for (final source in SyncSource.values) {
      loaded[source] = await widget.coordinator.stateFor(source, id);
    }
    if (mounted) setState(() => states = loaded);
  }

  Future<void> _run(SyncSource source, SyncTrigger trigger) async {
    final id = accountId;
    if (id == null || busy) return;
    setState(() => busy = true);
    final outcome = await widget.coordinator.sync(
      source,
      trigger: trigger,
      accountId: id,
    );
    await _handle(outcome);
    if (mounted) setState(() => busy = false);
    await _refresh();
  }

  Future<void> _runAll(SyncTrigger trigger) async {
    final id = accountId;
    if (id == null || busy) return;
    setState(() => busy = true);
    final outcomes = await widget.coordinator.syncAll(
      trigger: trigger,
      accountId: id,
    );
    for (final outcome in outcomes) {
      await _handle(outcome);
    }
    if (mounted) setState(() => busy = false);
    await _refresh();
  }

  Future<void> _handle(SyncOutcome outcome) async {
    if (outcome is! SyncNeedsUserAction || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('需要登录学校网站'),
        content: const Text('继续后将打开可见浏览器；仅在你确认后才会读取已保存密码。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    await widget.coordinator.resumeInteractive(
      outcome.jobId,
      userConfirmed: confirmed == true,
    );
  }

  Future<void> _importFile() async {
    final action = FileImportAction(
      accounts: widget.accounts,
      picker: widget.filePicker,
      confirmTarget: _confirmTarget,
      importBundle: widget.coordinator.importBundle,
    );
    try {
      final outcome = await action.run();
      if (!mounted) return;
      final message = switch (outcome) {
        FileImportCompleted() => '导入完成',
        FileImportCancelled() => '已取消导入',
        FileImportRejected(:final code) => '无法导入：$code',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('文件校验或导入失败')));
      }
    }
  }

  Future<String?> _confirmTarget(
    List<AccountSummary> accounts,
    String? preselected,
  ) async {
    var selected = preselected;
    return showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('确认导入账号'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final account in accounts)
                ListTile(
                  leading: Icon(
                    selected == account.id
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  selected: selected == account.id,
                  title: Text(account.maskedHint),
                  onTap: () => setDialogState(() => selected = account.id),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: selected == null
                  ? null
                  : () => Navigator.pop(context, selected),
              child: const Text('确认导入'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('同步')),
      body: accountId == null
          ? const Center(child: Text('请先配置学校账号'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: busy
                          ? null
                          : () => _runAll(SyncTrigger.manual),
                      icon: const Icon(Icons.sync),
                      label: const Text('同步全部'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: busy ? null : _importFile,
                      icon: const Icon(Icons.file_open),
                      label: const Text('导入文件'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                for (final source in SyncSource.values)
                  ListTile(
                    leading: Icon(
                      source == SyncSource.jw ? Icons.school : Icons.event,
                    ),
                    title: Text(source == SyncSource.jw ? '教务系统' : '已报名二课'),
                    subtitle: Text(_stateLabel(states[source])),
                    trailing: IconButton(
                      tooltip: '同步',
                      onPressed: busy
                          ? null
                          : () => _run(source, SyncTrigger.manual),
                      icon: const Icon(Icons.refresh),
                    ),
                  ),
              ],
            ),
    );
  }

  String _stateLabel(SyncSourceState? state) {
    if (state == null) return '尚未同步';
    final label = switch (state.phase) {
      SyncPhase.idle => '已是最新',
      SyncPhase.due => '等待同步',
      SyncPhase.running => '同步中',
      SyncPhase.needsUserAction => '等待登录',
      SyncPhase.succeeded => '上次同步成功',
      SyncPhase.failed => '上次同步失败',
      SyncPhase.cancelled => '已取消',
    };
    return state.lastSuccessfulAt == null
        ? label
        : '$label · ${state.lastSuccessfulAt!.toLocal()}';
  }
}
