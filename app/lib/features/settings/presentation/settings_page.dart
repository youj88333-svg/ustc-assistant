import 'package:flutter/material.dart';

import '../application/settings_service.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({required this.service, super.key});

  final SettingsService service;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final pythonController = TextEditingController();
  bool jwEnabled = true;
  bool youngEnabled = true;

  @override
  void initState() {
    super.initState();
    widget.service.pythonPath().then((value) {
      if (mounted) pythonController.text = value ?? '';
    });
    Future.wait([
      widget.service.sourceEnabled('ustc_jw'),
      widget.service.sourceEnabled('ustc_young_schedule'),
    ]).then((values) {
      if (mounted) {
        setState(() {
          jwEnabled = values[0];
          youngEnabled = values[1];
        });
      }
    });
  }

  @override
  void dispose() {
    pythonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
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
          SwitchListTile(
            secondary: const Icon(Icons.event),
            title: const Text('已报名二课'),
            value: youngEnabled,
            onChanged: (value) async {
              await widget.service.setSourceEnabled(
                'ustc_young_schedule',
                value,
              );
              if (mounted) setState(() => youngEnabled = value);
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
            subtitle: const Text('461 / 2026fall / 2026 秋季学期'),
            onTap: widget.service.resetJwSemester,
          ),
          const ListTile(
            leading: Icon(Icons.notifications_outlined),
            title: Text('提醒默认值'),
            subtitle: Text('考试 24 小时和 2 小时；课程 15 分钟；二课 2 小时'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.cleaning_services),
            title: const Text('清理缓存'),
            onTap: widget.service.clearCache,
          ),
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
          ListTile(
            leading: const Icon(Icons.warning_amber),
            title: const Text('完全重置'),
            onTap: _completeReset,
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
    var first = false;
    await _confirm('完全重置本地数据？', () async => first = true);
    if (!first || !mounted) return;
    await _confirm(
      '再次确认：此操作不可撤回',
      () => widget.service.completeReset(
        firstConfirmation: true,
        secondConfirmation: true,
      ),
    );
  }
}
