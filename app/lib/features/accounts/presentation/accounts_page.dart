import 'package:flutter/material.dart';

import '../application/account_service.dart';
import '../../settings/application/settings_service.dart';
import '../../settings/presentation/settings_page.dart';

class AccountsPage extends StatefulWidget {
  const AccountsPage({
    required this.service,
    this.onLoginAgain,
    this.onFirstLogin,
    this.onOpenOfficialPage,
    this.coordinatedReset,
    this.onCompleteReset,
    super.key,
  });

  final AccountService service;
  final ValueChanged<String>? onLoginAgain;
  final VoidCallback? onFirstLogin;
  final VoidCallback? onOpenOfficialPage;
  final Future<void> Function()? coordinatedReset;
  final VoidCallback? onCompleteReset;

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  late Future<List<AccountSummary>> summaries;
  bool resetting = false;

  @override
  void initState() {
    super.initState();
    summaries = widget.service.summaries();
  }

  void reload() {
    setState(() {
      summaries = widget.service.summaries();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('学校账号')),
      body: FutureBuilder<List<AccountSummary>>(
        future: summaries,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final accounts = snapshot.data ?? const [];
          if (accounts.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('尚未绑定学校账号'),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const Key('first-login-entry'),
                    onPressed: widget.onFirstLogin,
                    icon: const Icon(Icons.login),
                    label: const Text('登录教务'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const Key('complete-reset'),
                    onPressed: resetting ? null : _completeReset,
                    icon: const Icon(Icons.delete_forever_outlined),
                    label: const Text('清除全部数据'),
                  ),
                ],
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: accounts.length,
            separatorBuilder: (_, _) => const Divider(),
            itemBuilder: (context, index) => _AccountPanel(
              account: accounts[index],
              onLoginAgain: widget.onLoginAgain == null
                  ? null
                  : () => widget.onLoginAgain!(accounts[index].id),
              onDeleteCredentials: () => _deleteCredentials(accounts[index]),
              onOpenOfficialPage: widget.onOpenOfficialPage,
            ),
          );
        },
      ),
    );
  }

  Future<void> _deleteCredentials(AccountSummary account) async {
    final confirmed = await _confirm(
      title: '删除已保存凭据？',
      body: '只删除加密保存的账号与密码，不清除浏览器登录会话。',
      confirmLabel: '删除凭据',
    );
    if (!confirmed) return;
    await widget.service.deleteCredentials(account.id);
    if (mounted) reload();
  }

  Future<void> _completeReset() async {
    if (resetting) return;
    final confirmed = await confirmCompleteReset(context);
    if (!mounted) return;
    if (!confirmed) {
      showResetCancelledMessage(context);
      return;
    }
    setState(() => resetting = true);
    var completed = false;
    try {
      final coordinatedReset = widget.coordinatedReset;
      if (coordinatedReset != null) {
        await coordinatedReset();
      } else {
        await SettingsService(
          database: widget.service.database,
          accounts: widget.service,
          accountId: null,
        ).completeReset(firstConfirmation: true, secondConfirmation: true);
      }
      completed = true;
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('本地数据重置失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => resetting = false);
    }
    if (completed && mounted) widget.onCompleteReset?.call();
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(confirmLabel),
            ),
          ],
        ),
      ) ??
      false;
}

class _AccountPanel extends StatelessWidget {
  const _AccountPanel({
    required this.account,
    required this.onLoginAgain,
    required this.onDeleteCredentials,
    required this.onOpenOfficialPage,
  });

  final AccountSummary account;
  final VoidCallback? onLoginAgain;
  final VoidCallback onDeleteCredentials;
  final VoidCallback? onOpenOfficialPage;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(account.active ? Icons.badge : Icons.badge_outlined),
          title: Text(account.maskedHint),
          subtitle: Text(account.active ? '当前账号' : '本地账号分区'),
          trailing: account.active
              ? const Icon(Icons.check_circle, semanticLabel: '当前活动账号')
              : null,
        ),
        Text(account.hasCredentials ? '凭据已保存' : '需要重新登录'),
        Text('已保存密码：${account.hasSavedPassword ? '是' : '否'}'),
        Text('教务系统：${_syncStatus(account.jwLastSuccessAt)}'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: Key('reauthenticate-${account.id}'),
              onPressed: onLoginAgain,
              icon: const Icon(Icons.login),
              label: const Text('重新登录'),
            ),
            OutlinedButton.icon(
              onPressed: onOpenOfficialPage,
              icon: const Icon(Icons.open_in_browser),
              label: const Text('学校官方页面'),
            ),
            TextButton.icon(
              key: Key('delete-credentials-${account.id}'),
              onPressed: account.hasCredentials ? onDeleteCredentials : null,
              icon: const Icon(Icons.key_off_outlined),
              label: const Text('删除凭据'),
            ),
          ],
        ),
      ],
    );
  }

  String _syncStatus(int? timestamp) {
    if (timestamp == null) return '等待同步';
    final shifted = DateTime.fromMillisecondsSinceEpoch(
      timestamp,
      isUtc: true,
    ).add(const Duration(hours: 8));
    String two(int value) => value.toString().padLeft(2, '0');
    return '上次同步成功：${shifted.year}-${two(shifted.month)}-'
        '${two(shifted.day)} ${two(shifted.hour)}:${two(shifted.minute)}';
  }
}
