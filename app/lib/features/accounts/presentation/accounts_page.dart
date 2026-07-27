import 'package:flutter/material.dart';

import '../application/account_service.dart';

class AccountsPage extends StatefulWidget {
  const AccountsPage({
    required this.service,
    this.onLoginAgain,
    this.onOpenOfficialPage,
    super.key,
  });

  final AccountService service;
  final ValueChanged<String>? onLoginAgain;
  final VoidCallback? onOpenOfficialPage;

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  late Future<List<AccountSummary>> summaries;

  @override
  void initState() {
    super.initState();
    summaries = widget.service.summaries();
  }

  void reload() {
    setState(() => summaries = widget.service.summaries());
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
            return const Center(child: Text('尚未绑定学校账号'));
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: accounts.length,
            separatorBuilder: (_, _) => const Divider(),
            itemBuilder: (context, index) => _AccountPanel(
              account: accounts[index],
              onSwitch: () async {
                await widget.service.switchAccount(accounts[index].id);
                reload();
              },
              onLoginAgain: widget.onLoginAgain == null
                  ? null
                  : () => widget.onLoginAgain!(accounts[index].id),
              onDeleteCredentials: () => _deleteCredentials(accounts[index]),
              onClearBrowser: () => _clearBrowserSession(accounts[index]),
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
    reload();
  }

  Future<void> _clearBrowserSession(AccountSummary account) async {
    final confirmed = await _confirm(
      title: '清除浏览器会话？',
      body: '只清除专用 Edge 登录会话，不删除已保存凭据。',
      confirmLabel: '清除会话',
    );
    if (!confirmed) return;
    await widget.service.clearDedicatedBrowserSession();
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
    required this.onSwitch,
    required this.onLoginAgain,
    required this.onDeleteCredentials,
    required this.onClearBrowser,
    required this.onOpenOfficialPage,
  });

  final AccountSummary account;
  final VoidCallback onSwitch;
  final VoidCallback? onLoginAgain;
  final VoidCallback onDeleteCredentials;
  final VoidCallback onClearBrowser;
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
              : TextButton(onPressed: onSwitch, child: const Text('切换')),
        ),
        Text('已保存密码：${account.hasSavedPassword ? '是' : '否'}'),
        Text('教务系统：${_syncStatus(account.jwLastSuccessAt)}'),
        Text('二课平台：${_syncStatus(account.youngLastSuccessAt)}'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
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
              onPressed: onDeleteCredentials,
              icon: const Icon(Icons.key_off_outlined),
              label: const Text('删除凭据'),
            ),
            TextButton.icon(
              key: Key('clear-browser-${account.id}'),
              onPressed: onClearBrowser,
              icon: const Icon(Icons.delete_sweep_outlined),
              label: const Text('清除浏览器会话'),
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
