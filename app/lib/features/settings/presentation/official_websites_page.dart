import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

abstract interface class OfficialWebsiteLauncher {
  Future<bool> launch(Uri uri);
}

class UrlLauncherOfficialWebsiteLauncher implements OfficialWebsiteLauncher {
  const UrlLauncherOfficialWebsiteLauncher();

  @override
  Future<bool> launch(Uri uri) => launchUrl(uri);
}

class OfficialWebsitesPage extends StatelessWidget {
  const OfficialWebsitesPage({required this.launcher, super.key});

  final OfficialWebsiteLauncher launcher;

  static final websites = [
    (
      label: '教务系统',
      uri: Uri.https('jw.ustc.edu.cn', '/home'),
      icon: Icons.school_outlined,
    ),
    (
      label: '二课平台',
      uri: Uri.https('young.ustc.edu.cn', '/'),
      icon: Icons.groups_outlined,
    ),
    (
      label: '教务处',
      uri: Uri.https('www.teach.ustc.edu.cn', '/'),
      icon: Icons.account_balance_outlined,
    ),
    (
      label: '财务处',
      uri: Uri.https('finance.ustc.edu.cn', '/'),
      icon: Icons.receipt_long_outlined,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('学校官方网站')),
      body: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: websites.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final website = websites[index];
          return ListTile(
            leading: Icon(website.icon),
            title: Text(website.label),
            trailing: const Icon(Icons.open_in_new),
            onTap: () async {
              final launched = await launcher.launch(website.uri);
              if (!launched && context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('无法打开官方网站')));
              }
            },
          );
        },
      ),
    );
  }
}
