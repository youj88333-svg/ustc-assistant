import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _platformChannel = MethodChannel('ustc_assistant/platform_v1');
const _diagnosticV1Schema = 'ios-i2-browser-diagnostics-v1';
const _diagnosticV2Schema = 'ios-i2-browser-diagnostics-v2';
const _diagnosticV1Keys = <String>{
  'kind',
  'source',
  'state',
  'lastEvent',
  'failureStage',
  'errorDomain',
  'errorCode',
  'cleanupStage',
  'cleanupFailure',
  'cleanupErrorDomain',
  'cleanupErrorCode',
};
const _diagnosticV2Keys = <String>{
  ..._diagnosticV1Keys,
  'policyAction',
  'policyTarget',
};
const _sourceValues = <String>{'none', 'jw', 'young'};
const _stateValues = <String>{
  'idle',
  'open',
  'closing',
  'cleanupPending',
  'closed',
};
const _lastEventValues = <String>{
  'none',
  'open',
  'navigating',
  'ready',
  'navigationFailed',
  'readerInstallFailed',
  'policyBlocked',
  'background',
  'processTerminated',
  'userClosed',
};
const _failureStageValues = <String>{
  'none',
  'provisionalNavigation',
  'navigation',
  'readerInstall',
  'presentation',
  'background',
  'process',
};
const _errorDomainValues = <String>{
  'none',
  'urlLoading',
  'webKit',
  'posix',
  'app',
  'other',
};
const _cleanupStageValues = <String>{
  'none',
  'waitingForView',
  'metadataDeletePending',
  'removeStore',
  'verifyStoreAbsent',
  'metadataRemoved',
  'complete',
};
const _cleanupFailureValues = <String>{
  'none',
  'viewRetained',
  'metadataWrite',
  'removeRejected',
  'storePresent',
  'metadataCompletion',
};
const _policyActionValues = <String>{
  'none',
  'topNavigationBlocked',
  'frameNavigationBlocked',
  'popupBlocked',
  'downloadBlocked',
  'permissionBlocked',
  'externalProtocolBlocked',
  'responseOriginBlocked',
  'dialogBlocked',
  'textPromptBlocked',
};
const _policyTargetValues = <String>{
  'none',
  'registered',
  'campus',
  'external',
  'localFixture',
  'otherScheme',
};

final class IOSSchoolDiagnosticsButton extends StatefulWidget {
  const IOSSchoolDiagnosticsButton({super.key});

  @override
  State<IOSSchoolDiagnosticsButton> createState() =>
      _IOSSchoolDiagnosticsButtonState();
}

final class _IOSSchoolDiagnosticsButtonState
    extends State<IOSSchoolDiagnosticsButton> {
  bool _requestInFlight = false;

  Future<void> _copyDiagnostics() async {
    if (_requestInFlight) return;
    setState(() => _requestInFlight = true);
    try {
      final response = await _platformChannel
          .invokeMethod<Object?>('i2BrowserDiagnostics')
          .timeout(const Duration(seconds: 5));
      final projection = _projectDiagnostics(response);
      if (!mounted) return;
      await Clipboard.setData(
        ClipboardData(text: jsonEncode(projection)),
      ).timeout(const Duration(seconds: 5));
      if (mounted) {
        _showMessage('已复制同步诊断，不含账号和网页内容。');
      }
    } on Object {
      if (mounted) _showMessage('未能复制诊断，请重试。');
    } finally {
      if (mounted) setState(() => _requestInFlight = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => TextButton.icon(
    key: const ValueKey('ios-i2-copy-diagnostics'),
    onPressed: _requestInFlight ? null : _copyDiagnostics,
    icon: const Icon(Icons.copy),
    label: const Text('复制诊断'),
  );
}

Map<String, Object?> _projectDiagnostics(Object? response) {
  if (response is! Map || response.keys.any((key) => key is! String)) {
    throw const _InvalidDiagnosticsResponse();
  }

  final kind = response['kind'];
  final Set<String> expectedKeys;
  if (kind == _diagnosticV1Schema) {
    expectedKeys = _diagnosticV1Keys;
  } else if (kind == _diagnosticV2Schema) {
    expectedKeys = _diagnosticV2Keys;
  } else {
    throw const _InvalidDiagnosticsResponse();
  }
  if (response.length != expectedKeys.length ||
      !expectedKeys.every(response.containsKey)) {
    throw const _InvalidDiagnosticsResponse();
  }

  final source = _enumValue(response['source'], _sourceValues);
  final state = _enumValue(response['state'], _stateValues);
  final lastEvent = _enumValue(response['lastEvent'], _lastEventValues);
  final failureStage = _enumValue(
    response['failureStage'],
    _failureStageValues,
  );
  final errorDomain = _enumValue(response['errorDomain'], _errorDomainValues);
  final errorCode = _errorCode(response['errorCode']);
  final cleanupStage = _enumValue(
    response['cleanupStage'],
    _cleanupStageValues,
  );
  final cleanupFailure = _enumValue(
    response['cleanupFailure'],
    _cleanupFailureValues,
  );
  final cleanupErrorDomain = _enumValue(
    response['cleanupErrorDomain'],
    _errorDomainValues,
  );
  final cleanupErrorCode = _errorCode(response['cleanupErrorCode']);

  final projection = <String, Object?>{
    'kind': kind,
    'source': source,
    'state': state,
    'lastEvent': lastEvent,
    'failureStage': failureStage,
    'errorDomain': errorDomain,
    'errorCode': errorCode,
    'cleanupStage': cleanupStage,
    'cleanupFailure': cleanupFailure,
    'cleanupErrorDomain': cleanupErrorDomain,
    'cleanupErrorCode': cleanupErrorCode,
  };
  if (kind == _diagnosticV2Schema) {
    projection['policyAction'] = _enumValue(
      response['policyAction'],
      _policyActionValues,
    );
    projection['policyTarget'] = _enumValue(
      response['policyTarget'],
      _policyTargetValues,
    );
  }
  return projection;
}

String _enumValue(Object? value, Set<String> allowed) {
  if (value is! String || !allowed.contains(value)) {
    throw const _InvalidDiagnosticsResponse();
  }
  return value;
}

int? _errorCode(Object? value) {
  if (value == null) return null;
  if (value is! int || value < -100000 || value > 100000) {
    throw const _InvalidDiagnosticsResponse();
  }
  return value;
}

final class _InvalidDiagnosticsResponse implements Exception {
  const _InvalidDiagnosticsResponse();
}
