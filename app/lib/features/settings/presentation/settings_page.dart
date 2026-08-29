import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/config/generated_source_defaults.dart';
import '../application/settings_service.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    required this.service,
    this.onFirstLogin,
    this.onCompleteReset,
    super.key,
  });

  final SettingsService service;
  final VoidCallback? onFirstLogin;
  final VoidCallback? onCompleteReset;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final pythonController = TextEditingController();
  bool jwEnabled = true;
  bool resetting = false;

  @override
  void initState() {
    super.initState();
    if (widget.service.hasAccount) {
      widget.service.pythonPath().then((value) {
        if (mounted) pythonController.text = value ?? '';
      });
      widget.service.sourceEnabled('ustc_jw').then((value) {
        if (mounted) {
          setState(() {
            jwEnabled = value;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    pythonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasAccount = widget.service.hasAccount;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (!hasAccount) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('当前没有已登录的学校账号。'),
            ),
            if (widget.onFirstLogin != null)
              ListTile(
                key: const Key('settings-first-login-entry'),
                leading: const Icon(Icons.login),
                title: const Text('绑定学校账号'),
                onTap: widget.onFirstLogin,
              ),
            const Divider(),
          ],
          if (hasAccount) ...[
            ListTile(
              leading: const Icon(Icons.smart_toy_outlined),
              title: const Text('模型服务'),
              subtitle: const Text('配置学校模型服务 API Key 与模型'),
              onTap: () => context.push('/settings/agent'),
            ),
            const Divider(),
            const ListTile(
              leading: Icon(Icons.schedule),
              title: Text('自动同步'),
              subtitle: Text('打开 App 且距上次成功同步满 12 小时时执行'),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.school),
              title: const Text('教务系统'),
              value: jwEnabled,
              onChanged: (value) async {
                await widget.service.setSourceEnabled('ustc_jw', value);
                if (mounted) setState(() => jwEnabled = value);
              },
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: pythonController,
                decoration: InputDecoration(
                  labelText: 'Python 解释器路径',
                  suffixIcon: IconButton(
                    tooltip: '保存路径',
                    icon: const Icon(Icons.save),
                    onPressed: () =>
                        widget.service.setPythonPath(pythonController.text),
                  ),
                ),
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.restore),
              title: const Text('恢复默认教务学期'),
              subtitle: const Text(
                '$kDefaultJwSemesterId / $kDefaultJwSemesterKey / '
                '$kDefaultJwSemesterDisplayName',
              ),
              onTap: widget.service.resetJwSemester,
            ),
            const ListTile(
              leading: Icon(Icons.notifications_outlined),
              title: Text('提醒默认值'),
              subtitle: Text('考试 24 小时和 2 小时；课程 15 分钟；二课 2 小时'),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.key_off),
              title: const Text('删除安全凭据'),
              onTap: () => _confirm(
                '删除安全凭据？',
                () => widget.service.clearCredentials(confirmed: true),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.web_asset_off),
              title: const Text('清除专用浏览器会话'),
              onTap: () => _confirm(
                '清除浏览器会话？',
                () => widget.service.clearBrowserSession(confirmed: true),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('清除业务数据'),
              onTap: () => _confirm(
                '清除日程、任务和本地修改？',
                () => widget.service.clearBusinessData(confirmed: true),
              ),
            ),
          ],
          ListTile(
            leading: const Icon(Icons.cleaning_services),
            title: const Text('清理缓存'),
            onTap: widget.service.clearCache,
          ),
          ListTile(
            key: const Key('complete-reset'),
            leading: const Icon(Icons.warning_amber),
            title: const Text('完全重置'),
            subtitle: hasAccount ? null : const Text('清除全部残留本地数据和浏览器会话'),
            enabled: !resetting,
            onTap: resetting ? null : _completeReset,
          ),
        ],
      ),
    );
  }

  Future<void> _confirm(String title, Future<void> Function() action) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (confirmed == true) await action();
  }

  Future<void> _completeReset() async {
    if (resetting) return;
    if (!await _ask('完全重置本地数据？') || !mounted) return;
    if (!await _ask('再次确认：此操作不可撤回') || !mounted) return;
    setState(() => resetting = true);
    var accountCleared = false;
    try {
      await widget.service.completeReset(
        firstConfirmation: true,
        secondConfirmation: true,
      );
      accountCleared = true;
    } on BrowserSessionClearAfterResetError {
      accountCleared = true;
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('本地数据已清除，但浏览器会话清理失败')));
      }
    } finally {
      if (mounted) setState(() => resetting = false);
    }
    if (accountCleared && mounted) widget.onCompleteReset?.call();
  }

  Future<bool> _ask(String title) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ??
      false;
}
