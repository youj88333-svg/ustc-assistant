import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const String _channelName = 'ustc_assistant/ios_i0_v1';
const String _aotSourceRevision = String.fromEnvironment(
  'I0_SOURCE_REVISION',
  defaultValue: '未设置',
);

const Set<String> _expectedSnapshotKeys = <String>{
  'kind',
  'sourceRevision',
  'bundleId',
  'groupAvailable',
  'groupDigest',
  'marker',
  'markerCreatedAt',
  'failure',
};

const Set<String> _knownFailureCodes = <String>{
  'shared_group_configuration_invalid',
  'shared_group_unavailable',
  'snapshot_missing',
  'snapshot_too_large',
  'snapshot_invalid',
  'snapshot_read_failed',
  'snapshot_write_failed',
  'snapshot_readback_mismatch',
};

abstract interface class ProbeGateway {
  Future<ProbeSnapshot> inspect();

  Future<ProbeSnapshot> writeSyntheticMarker();
}

class MethodChannelProbeGateway implements ProbeGateway {
  const MethodChannelProbeGateway({
    MethodChannel channel = const MethodChannel(_channelName),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<ProbeSnapshot> invoke(String method) async {
    if (method != 'inspect' && method != 'writeSyntheticMarker') {
      throw ArgumentError.value(method, 'method', 'Unsupported I0 method');
    }
    final Object? raw = await _channel.invokeMethod<Object?>(method);
    return ProbeSnapshot.fromPlatformObject(raw);
  }

  @override
  Future<ProbeSnapshot> inspect() => invoke('inspect');

  @override
  Future<ProbeSnapshot> writeSyntheticMarker() =>
      invoke('writeSyntheticMarker');
}

class ProbeSnapshot {
  const ProbeSnapshot({
    required this.sourceRevision,
    required this.bundleId,
    required this.groupAvailable,
    required this.groupDigest,
    required this.marker,
    required this.markerCreatedAt,
    required this.failure,
  });

  final String? sourceRevision;
  final String bundleId;
  final bool groupAvailable;
  final String? groupDigest;
  final String? marker;
  final String? markerCreatedAt;
  final String? failure;

  bool get hasReadableSharedMarker =>
      groupAvailable && failure == null && marker != null;

  factory ProbeSnapshot.fromPlatformObject(Object? object) {
    if (object is! Map) {
      throw const FormatException('I0 probe response is not a map');
    }
    final Map<Object?, Object?> map = Map<Object?, Object?>.from(object);
    if (map.keys.any((Object? key) => key is! String) ||
        map.length != _expectedSnapshotKeys.length ||
        !_expectedSnapshotKeys.every(map.containsKey)) {
      throw const FormatException('I0 probe response fields do not match');
    }

    String? optionalString(String key) {
      final Object? value = map[key];
      if (value == null) return null;
      if (value is! String) {
        throw FormatException('I0 probe field $key has an invalid type');
      }
      return value;
    }

    if (map['kind'] != 'ios-i0-probe-v1') {
      throw const FormatException('I0 probe response kind is unknown');
    }
    final String? sourceRevision = optionalString('sourceRevision');
    final Object? bundleIdValue = map['bundleId'];
    if (bundleIdValue is! String || bundleIdValue.isEmpty) {
      throw const FormatException('I0 probe bundle identity is missing');
    }
    final Object? groupAvailableValue = map['groupAvailable'];
    if (groupAvailableValue is! bool) {
      throw const FormatException('I0 probe group status is invalid');
    }

    final String? groupDigest = optionalString('groupDigest');
    final String? marker = optionalString('marker');
    final String? markerCreatedAt = optionalString('markerCreatedAt');
    final String? failure = optionalString('failure');

    if (failure != null && !_knownFailureCodes.contains(failure)) {
      throw const FormatException('I0 probe failure code is unknown');
    }
    if (groupDigest != null &&
        !RegExp(r'^[0-9a-f]{12}$').hasMatch(groupDigest)) {
      throw const FormatException('I0 probe group digest is invalid');
    }
    if (marker != null && !RegExp(r'^i0-[0-9a-fA-F]{8}$').hasMatch(marker)) {
      throw const FormatException('I0 probe marker is invalid');
    }
    if ((marker == null) != (markerCreatedAt == null)) {
      throw const FormatException('I0 probe marker fields are incomplete');
    }
    if (markerCreatedAt != null && !_isCanonicalUtcTimestamp(markerCreatedAt)) {
      throw const FormatException('I0 probe marker time is invalid');
    }
    if (groupAvailableValue) {
      if (groupDigest == null) {
        throw const FormatException('I0 probe group digest is missing');
      }
      if (failure == null && marker == null) {
        throw const FormatException('I0 probe success has no marker');
      }
      if (failure != null && (marker != null || markerCreatedAt != null)) {
        throw const FormatException('I0 probe reports a marker with failure');
      }
    } else {
      if (groupDigest != null || marker != null || markerCreatedAt != null) {
        throw const FormatException('I0 probe reports data without a group');
      }
      if (failure != 'shared_group_unavailable' &&
          failure != 'shared_group_configuration_invalid') {
        throw const FormatException('I0 probe group failure is missing');
      }
    }

    return ProbeSnapshot(
      sourceRevision: sourceRevision,
      bundleId: bundleIdValue,
      groupAvailable: groupAvailableValue,
      groupDigest: groupDigest,
      marker: marker,
      markerCreatedAt: markerCreatedAt,
      failure: failure,
    );
  }

  static bool _isCanonicalUtcTimestamp(String value) {
    if (!RegExp(
      r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$',
    ).hasMatch(value)) {
      return false;
    }
    try {
      final DateTime parsed = DateTime.parse(value).toUtc();
      return parsed.toIso8601String() == value;
    } on FormatException {
      return false;
    }
  }
}

void main() {
  runApp(const I0ProbeApp());
}

class I0ProbeApp extends StatelessWidget {
  const I0ProbeApp({
    super.key,
    this.gateway = const MethodChannelProbeGateway(),
  });

  final ProbeGateway gateway;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'iOS I0 合成共享探针',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
        useMaterial3: true,
      ),
      home: ProbeHomePage(gateway: gateway),
    );
  }
}

class ProbeHomePage extends StatefulWidget {
  const ProbeHomePage({super.key, required this.gateway});

  final ProbeGateway gateway;

  @override
  State<ProbeHomePage> createState() => _ProbeHomePageState();
}

class _ProbeHomePageState extends State<ProbeHomePage> {
  ProbeSnapshot? _snapshot;
  bool _busy = false;
  bool _lastActionWasWrite = false;
  String? _readError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool write = false}) async {
    setState(() {
      _busy = true;
      _readError = null;
    });
    try {
      final ProbeSnapshot snapshot = write
          ? await widget.gateway.writeSyntheticMarker()
          : await widget.gateway.inspect();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _lastActionWasWrite = write && snapshot.hasReadableSharedMarker;
      });
    } on FormatException {
      if (!mounted) return;
      setState(() {
        _snapshot = null;
        _lastActionWasWrite = false;
        _readError = '探针响应无效';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _snapshot = null;
        _lastActionWasWrite = false;
        _readError = '原生探针暂不可用';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ProbeSnapshot? snapshot = _snapshot;
    final bool sharedValueReady = snapshot?.hasReadableSharedMarker ?? false;
    final bool canWrite = snapshot?.groupAvailable ?? true;

    return Scaffold(
      appBar: AppBar(title: const Text('iOS I0 合成共享探针')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            _IdentityCard(snapshot: snapshot),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'App Group 状态',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    if (_busy && snapshot == null)
                      const LinearProgressIndicator()
                    else if (_readError != null)
                      Text(_readError!, key: const Key('probe-error'))
                    else if (snapshot == null)
                      const Text('正在读取共享状态…')
                    else if (!snapshot.groupAvailable)
                      const Text('共享不可用', key: Key('group-status'))
                    else
                      Text('共享容器可访问', key: const Key('group-status')),
                    if (snapshot?.groupDigest
                        case final String digest) ...<Widget>[
                      const SizedBox(height: 6),
                      Text('共享组摘要：$digest'),
                    ],
                    const Divider(height: 28),
                    Text(
                      '当前合成标记',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    if (_readError != null)
                      const Text('没有可确认的共享值')
                    else if (sharedValueReady)
                      Text(
                        snapshot!.marker!,
                        key: const Key('shared-marker'),
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontFamily: 'monospace'),
                      )
                    else
                      const Text(
                        '尚未读到有效合成值',
                        key: Key('shared-marker-missing'),
                      ),
                    if (sharedValueReady) ...<Widget>[
                      const SizedBox(height: 4),
                      Text('生成时间（UTC）：${snapshot!.markerCreatedAt!}'),
                      const SizedBox(height: 8),
                      Text(
                        _lastActionWasWrite ? '新值已写入并读回' : '已从共享文件读到该值',
                        key: const Key('shared-value-status'),
                      ),
                    ],
                    if (snapshot?.failure
                        case final String failure) ...<Widget>[
                      const SizedBox(height: 8),
                      Text('失败码：$failure', key: const Key('failure-code')),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                FilledButton.icon(
                  key: const Key('write-marker-button'),
                  onPressed: _busy || !canWrite
                      ? null
                      : () => _load(write: true),
                  icon: const Icon(Icons.edit_note),
                  label: const Text('写入新合成值'),
                ),
                OutlinedButton.icon(
                  key: const Key('refresh-button'),
                  onPressed: _busy ? null : () => _load(),
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.snapshot});

  final ProbeSnapshot? snapshot;

  static final RegExp _revisionPattern = RegExp(r'^[0-9a-fA-F]{40}$');

  @override
  Widget build(BuildContext context) {
    final String? nativeRevision = snapshot?.sourceRevision;
    final bool aotRevisionValid = _revisionPattern.hasMatch(_aotSourceRevision);
    final bool nativeRevisionValid =
        nativeRevision != null && _revisionPattern.hasMatch(nativeRevision);
    final bool revisionsMatch =
        aotRevisionValid &&
        nativeRevisionValid &&
        nativeRevision == _aotSourceRevision;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('探针身份', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            _IdentityRow(
              label: 'Bundle ID',
              value: snapshot?.bundleId ?? '读取中',
            ),
            const SizedBox(height: 8),
            _IdentityRow(label: 'Dart AOT 修订', value: _aotSourceRevision),
            const SizedBox(height: 8),
            _IdentityRow(
              label: 'Info.plist 修订',
              value: nativeRevision ?? '未读取',
            ),
            const SizedBox(height: 8),
            Text(
              revisionsMatch ? '修订一致' : '修订未设置、格式无效或两端不一致',
              key: const Key('revision-status'),
            ),
          ],
        ),
      ),
    );
  }
}

class _IdentityRow extends StatelessWidget {
  const _IdentityRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        SelectableText(value, key: Key('identity-$label')),
      ],
    );
  }
}
