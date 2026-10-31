import 'dart:math';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/demo_runtime.dart';
import 'core/contracts.dart';
import 'platform/ios_credential_protector.dart';

const _revision = String.fromEnvironment(
  'USTC_BUILD_REVISION',
  defaultValue: 'unknown',
);
const _platform = MethodChannel('ustc_assistant/platform_v1');
const _purpose = 'ustc-model-key/v1/jw-owner-11111111111111111111111111111111';
const _synthetic = [105, 49, 45, 115, 121, 110, 116, 104, 101, 116, 105, 99];

/// I1 device acceptance uses synthetic state in the demo store only. No account,
/// model request, source sync, microphone or user-entered secrets are exposed.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(home: _I1Screen(), debugShowCheckedModeBanner: false),
  );
}

class _I1Screen extends StatefulWidget {
  const _I1Screen();
  @override
  State<_I1Screen> createState() => _I1State();
}

class _I1State extends State<_I1Screen> with WidgetsBindingObserver {
  RuntimeBootstrap? _bootstrap;
  String? _marker, _failure, _bundleId;
  bool _busy = true,
      _cipherValid = false,
      _revisionValid = false,
      _filesProtected = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _open();
  }

  Future<void> _open() async {
    try {
      final bootstrap = await RuntimeBootstrap.open();
      if (!mounted) {
        await bootstrap.close();
        return;
      }
      if (bootstrap.runtime == null) {
        await bootstrap.close();
        throw const AppFailure(FailureCode.cleanupPending);
      }
      _bootstrap = bootstrap;
      await bootstrap.store.customStatement(
        'CREATE TABLE IF NOT EXISTS ios_i1_probe '
        '(id INTEGER PRIMARY KEY CHECK(id=1), marker TEXT NOT NULL, cipher BLOB NOT NULL)',
      );
      final info = await _platform.invokeMapMethod<String, Object?>(
        'i1BuildInfo',
      );
      _bundleId = info?['bundleId'] as String?;
      _revisionValid = _revision != 'unknown' && info?['revision'] == _revision;
      await _read();
    } catch (error) {
      _recordFailure(error);
    }
  }

  Future<void> _read() async {
    final bootstrap = _bootstrap;
    if (bootstrap == null) return;
    try {
      bootstrap.directory.ensureHeld();
      bootstrap.jwDirectory.ensureHeld();
      final rows = await bootstrap.store
          .customSelect('SELECT marker, cipher FROM ios_i1_probe WHERE id=1')
          .get();
      String? marker;
      var cipherValid = false;
      if (rows.isNotEmpty) {
        marker = rows.single.read<String>('marker');
        final cipher = Uint8List.fromList(
          rows.single.read<Uint8List>('cipher'),
        );
        final plain = await const IOSModelCredentialProtector().unprotect(
          cipher,
          purpose: _purpose,
        );
        cipherValid = plain.length == _synthetic.length;
        for (var i = 0; i < plain.length && cipherValid; i++) {
          cipherValid = plain[i] == _synthetic[i];
        }
        plain.fillRange(0, plain.length, 0);
      }
      final status = await _platform.invokeMapMethod<String, Object?>(
        'storageProtectionStatus',
      );
      if (!mounted) return;
      setState(() {
        _marker = marker;
        _cipherValid = cipherValid;
        _filesProtected =
            status?['isSimulator'] == false &&
            status?['excludedFromBackup'] == true &&
            status?['filesProtected'] == true;
        _busy = false;
        _failure = null;
      });
    } catch (error) {
      _recordFailure(error);
    }
  }

  Future<void> _write() async {
    final bootstrap = _bootstrap;
    if (bootstrap == null || _busy) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final plain = Uint8List.fromList(_synthetic);
      final cipher = await const IOSModelCredentialProtector().protect(
        plain,
        purpose: _purpose,
      );
      plain.fillRange(0, plain.length, 0);
      final marker =
          'i1-${Random.secure().nextInt(0x100000000).toRadixString(16).padLeft(8, '0')}';
      await bootstrap.store.transaction(
        () => bootstrap.store.customStatement(
          'INSERT OR REPLACE INTO ios_i1_probe (id, marker, cipher) VALUES (1, ?, ?)',
          [marker, Variable.withBlob(cipher).value],
        ),
      );
      cipher.fillRange(0, cipher.length, 0);
      await _read();
    } catch (error) {
      _recordFailure(error);
    }
  }

  void _recordFailure(Object error) {
    if (!mounted) return;
    setState(() {
      _failure = error is AppFailure
          ? error.code.name
          : 'platform_or_storage_failed';
      _busy = false;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _bootstrap != null && !_busy) {
      // Re-read under the same owner; resuming never acquires a second lease.
      _busy = true;
      _read();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _bootstrap?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('iOS I1 本机存储验证')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            '只使用合成数据',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          const Text('这个页面检查私有数据库和密钥保护。写入一个测试值后，关闭重开、切后台返回或覆盖安装，核对同一个值是否保留。'),
          const Divider(height: 32),
          Text(
            '构建：${_revision.length > 12 ? _revision.substring(0, 12) : _revision}',
          ),
          Text('修订一致：${_revisionValid ? '是' : '待确认'}'),
          Text('应用身份：${_bundleId ?? '读取中'}'),
          const SizedBox(height: 20),
          SelectableText(
            _marker ?? '尚未写入测试值',
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
          ),
          Text(
            '测试密文回读：${_marker == null
                ? '待写入'
                : _cipherValid
                ? '通过'
                : '未通过'}',
          ),
          Text('私有文件保护属性及备份排除：${_filesProtected ? '通过' : '待真机确认'}'),
          if (_failure != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text('检查失败：$_failure'),
            ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: LinearProgressIndicator(),
            ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy || _bootstrap == null ? null : _write,
            child: const Text('写入新测试值'),
          ),
          TextButton(
            onPressed: _busy || _bootstrap == null
                ? null
                : () {
                    setState(() => _busy = true);
                    _read();
                  },
            child: const Text('重新读取'),
          ),
          const Divider(height: 32),
          const Text('本阶段只验启动与存储，课程同步、提醒和图片等随后接入。此 iOS 版本不提供小组件和语音输入。'),
        ],
      ),
    ),
  );
}
