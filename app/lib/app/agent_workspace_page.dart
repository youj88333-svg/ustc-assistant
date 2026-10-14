import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import 'agent_workspace_contract.dart';
import '../core/agent_contract.dart';
import '../core/diagnostics_contract.dart';
import '../core/speech_input_contract.dart';
import 'diagnostics_panel.dart';

const _agentGreen = Color(0xFF1F6B45);
const _agentMuted = Color(0xFF66736C);
const _agentLine = Color(0xFFE3E9E5);

/// The M5.1 chat surface. The workspace port is owned by its caller.
final class AgentWorkspacePage extends StatefulWidget {
  const AgentWorkspacePage({
    super.key,
    required this.controller,
    required this.onSettings,
    this.pickImages,
    this.onOpenLocalEvidence,
    this.diagnostics,
    this.speechInput,
  });

  final AgentWorkspacePort controller;
  final VoidCallback onSettings;
  final Future<List<AgentImage>> Function()? pickImages;
  final ValueChanged<AgentEvidence>? onOpenLocalEvidence;
  final DiagnosticsPort? diagnostics;

  /// Optional caller-owned local speech input. This page only cancels it.
  final SpeechInputPort? speechInput;

  @override
  State<AgentWorkspacePage> createState() => _AgentWorkspacePageState();
}

final class _AgentWorkspacePageState extends State<AgentWorkspacePage>
    with WidgetsBindingObserver {
  final TextEditingController _draft = TextEditingController();
  final FocusNode _composerFocus = FocusNode();
  final List<AgentImage> _draftImages = [];
  int _generation = 0;
  int _draftRevision = 0;
  int _speechStreamGeneration = 0;
  int _imagePickGeneration = 0;
  int? _observedHistoryEpoch;
  int? _observedMessageFingerprint;
  String? _observedConversationId;
  String? _observedDiscussionId;
  bool? _observedConsent;
  bool _draftEditedByUser = false;
  bool _loadingOlderMessages = false;
  bool _pickingImages = false;
  bool _pending = false;
  bool _sending = false;
  bool _stopping = false;
  bool _actionPending = false;
  bool _schoolContinuationPending = false;
  bool _schoolContinuationSubmitted = false;
  bool _messageIsError = false;
  String? _actionPendingId;
  String? _submittedActionId;
  String? _message;
  String? _speechFallbackError;
  SpeechInputPort? _speechPort;
  SpeechInputView _speechView = const SpeechInputView();
  StreamSubscription<SpeechInputView>? _speechSubscription;
  _SpeechDraftAnchor? _speechAnchor;
  TextEditingValue _lastDraftValue = TextEditingValue.empty;
  bool _speechCommandPending = false;
  final Set<String> _expandedQueryDetails = {};
  final Map<String, bool> _rememberActionChoices = {};
  String? _observedPendingActionId;
  bool _observedContextCompacted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastDraftValue = _draft.value;
    _draft.addListener(_onDraftValueChanged);
    widget.controller.addListener(_onControllerChanged);
    _bindSpeechInput(widget.speechInput);
    _rememberControllerView();
    _scheduleRefresh();
  }

  @override
  void didUpdateWidget(covariant AgentWorkspacePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final controllerChanged = !identical(
      oldWidget.controller,
      widget.controller,
    );
    final speechPortChanged = !identical(
      oldWidget.speechInput,
      widget.speechInput,
    );
    if (speechPortChanged) {
      _unbindSpeechInput(cancel: true);
      _bindSpeechInput(widget.speechInput);
    } else if (controllerChanged) {
      _invalidateSpeech(cancel: true);
    }
    if (controllerChanged) {
      oldWidget.controller.removeListener(_onControllerChanged);
      _generation++;
      _clearDraftImages(update: false);
      _pending = false;
      _sending = false;
      _stopping = false;
      _actionPending = false;
      _schoolContinuationPending = false;
      _schoolContinuationSubmitted = false;
      _loadingOlderMessages = false;
      _actionPendingId = null;
      _submittedActionId = null;
      _messageIsError = false;
      _message = null;
      _speechFallbackError = null;
      _expandedQueryDetails.clear();
      _rememberActionChoices.clear();
      _draft.clear();
      _draftEditedByUser = false;
      widget.controller.addListener(_onControllerChanged);
      _rememberControllerView();
      _scheduleRefresh();
    }
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _unbindSpeechInput(cancel: true);
    widget.controller.removeListener(_onControllerChanged);
    _clearDraftImages(update: false);
    _draft.removeListener(_onDraftValueChanged);
    _draft.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _invalidateSpeech(cancel: true);
    }
  }

  bool _isCurrent(AgentWorkspacePort port, int generation) =>
      mounted &&
      identical(widget.controller, port) &&
      _generation == generation;

  int _messageFingerprint(AgentWorkspaceView view) => Object.hashAll(
    view.messages.map(
      (message) => Object.hash(
        message.id,
        message.role,
        message.status,
        message.imageCount,
        message.text.hashCode,
      ),
    ),
  );

  void _rememberControllerView() {
    final view = widget.controller.view;
    _observedHistoryEpoch = view.settings?.authority.historyEpoch;
    _observedMessageFingerprint = _messageFingerprint(view);
    _observedConversationId = view.conversationId;
    _observedDiscussionId = view.discussionId;
    _observedPendingActionId = view.pendingAction?.id;
    _observedContextCompacted = view.contextCompacted;
    _observedConsent = view.settings?.consent;
    final draft = view.discussionDraft;
    if (view.discussionId != null && draft != null && !_draftEditedByUser) {
      _setDiscussionDraft(draft);
    }
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final view = widget.controller.view;
    final historyEpoch = view.settings?.authority.historyEpoch;
    final speechAnchor = _speechAnchor;
    if (speechAnchor != null &&
        (!identical(speechAnchor.controller, widget.controller) ||
            speechAnchor.generation != _generation ||
            view.phase != AgentPhase.idle ||
            view.conversationId != speechAnchor.conversationId ||
            historyEpoch != speechAnchor.historyEpoch)) {
      _invalidateSpeech(cancel: true);
    }
    final messageFingerprint = _messageFingerprint(view);
    final consent = view.settings?.consent;
    final discussionChanged = view.discussionId != _observedDiscussionId;
    final pendingActionId = view.pendingAction?.id;
    if (pendingActionId != _observedPendingActionId) {
      final previousActionId = _observedPendingActionId;
      if (previousActionId != null) {
        _rememberActionChoices.remove(previousActionId);
      }
      _observedPendingActionId = pendingActionId;
    }
    final historyChanged =
        historyEpoch != null &&
        _observedHistoryEpoch != null &&
        historyEpoch != _observedHistoryEpoch;
    final invalidated =
        view.phase == AgentPhase.closed ||
        view.busy ||
        !view.canSend ||
        (consent != null && _observedConsent == true && !consent) ||
        historyChanged ||
        view.conversationId != _observedConversationId ||
        messageFingerprint != _observedMessageFingerprint;
    if (historyChanged) _expandedQueryDetails.clear();
    if (view.contextCompacted && !_observedContextCompacted) {
      _message = '上下文已整理，完整聊天记录仍保留。';
      _messageIsError = false;
    }
    _observedContextCompacted = view.contextCompacted;
    if (view.phase != AgentPhase.waitingForSchool) {
      _schoolContinuationSubmitted = false;
    }
    _observedHistoryEpoch = historyEpoch;
    _observedMessageFingerprint = messageFingerprint;
    _observedConversationId = view.conversationId;
    _observedDiscussionId = view.discussionId;
    _observedConsent = consent;
    final discussionDraft = view.discussionDraft;
    if (discussionChanged &&
        !historyChanged &&
        view.discussionId != null &&
        discussionDraft != null &&
        !_draftEditedByUser) {
      _setDiscussionDraft(discussionDraft);
    }
    if (invalidated && (_draftImages.isNotEmpty || _pickingImages)) {
      _clearDraftImages();
    }
  }

  void _bindSpeechInput(SpeechInputPort? port) {
    _speechPort = port;
    _speechView = port?.view ?? const SpeechInputView();
    if (port == null) return;
    final streamGeneration = ++_speechStreamGeneration;
    _speechSubscription = port.changes.listen(
      (next) => _onSpeechViewChanged(port, streamGeneration, next),
      onError: (Object _) {
        if (!mounted ||
            streamGeneration != _speechStreamGeneration ||
            !identical(_speechPort, port)) {
          return;
        }
        _speechAnchor = null;
        _speechFallbackError = '语音输入暂时不可用，可继续键盘输入。';
        setState(() {});
      },
    );
  }

  void _unbindSpeechInput({required bool cancel}) {
    final port = _speechPort;
    final shouldCancel =
        _speechAnchor != null || (port != null && port.view.busy);
    _speechAnchor = null;
    _speechCommandPending = false;
    ++_speechStreamGeneration;
    _speechSubscription?.cancel();
    _speechSubscription = null;
    _speechPort = null;
    _speechView = const SpeechInputView();
    _speechFallbackError = null;
    if (cancel && shouldCancel && port != null) {
      unawaited(_safeCancelSpeech(port));
    }
  }

  void _onSpeechViewChanged(
    SpeechInputPort port,
    int streamGeneration,
    SpeechInputView next,
  ) {
    if (!mounted ||
        streamGeneration != _speechStreamGeneration ||
        !identical(_speechPort, port)) {
      return;
    }
    _speechView = next;
    final transcript = next.transcript;
    final anchor = _speechAnchor;
    if (transcript != null && anchor != null) {
      if (_speechResultIsCurrent(port, anchor, transcript)) {
        final text = transcript.text.trim();
        if (text.isNotEmpty && text.length <= speechMaximumTextCharacters) {
          final original = anchor.draftValue;
          final selection = original.selection;
          final start = selection.isValid
              ? selection.start.clamp(0, original.text.length)
              : original.text.length;
          final end = selection.isValid
              ? selection.end.clamp(start, original.text.length)
              : start;
          final inserted = original.text.replaceRange(start, end, text);
          _speechAnchor = null;
          _draft.value = TextEditingValue(
            text: inserted,
            selection: TextSelection.collapsed(offset: start + text.length),
          );
          _draftEditedByUser = true;
          _speechFallbackError = null;
        } else if (text.length > speechMaximumTextCharacters) {
          _speechAnchor = null;
          _speechFallbackError = '听写结果超过长度限制，可分段录入。';
        } else {
          _speechAnchor = null;
        }
      } else {
        _speechAnchor = null;
        if (next.busy) unawaited(_safeCancelSpeech(port));
      }
    } else if (next.phase == SpeechInputPhase.idle && next.failure != null) {
      _speechAnchor = null;
    }
    setState(() {});
  }

  bool _speechResultIsCurrent(
    SpeechInputPort port,
    _SpeechDraftAnchor anchor,
    SpeechTranscript transcript,
  ) {
    final view = widget.controller.view;
    return identical(_speechPort, port) &&
        identical(widget.controller, anchor.controller) &&
        anchor.generation == _generation &&
        anchor.speechRevision == transcript.revision &&
        port.view.revision == transcript.revision &&
        port.view.phase == SpeechInputPhase.idle &&
        anchor.draftRevision == _draftRevision &&
        _draft.value == anchor.draftValue &&
        _speechView.phase == SpeechInputPhase.idle &&
        view.phase == AgentPhase.idle &&
        view.conversationId == anchor.conversationId &&
        view.settings?.authority.historyEpoch == anchor.historyEpoch;
  }

  void _onDraftValueChanged() {
    final value = _draft.value;
    if (value == _lastDraftValue) return;
    _lastDraftValue = value;
    _draftRevision++;
    if (_speechAnchor != null) _invalidateSpeech(cancel: true);
  }

  void _invalidateSpeech({
    required bool cancel,
    bool update = true,
    SpeechInputPort? port,
  }) {
    final target = port ?? _speechPort;
    final hadAnchor = _speechAnchor != null;
    _speechAnchor = null;
    _speechCommandPending = false;
    if (cancel && target != null && (hadAnchor || target.view.busy)) {
      unawaited(_safeCancelSpeech(target));
    }
    if (update && mounted) setState(() {});
  }

  Future<void> _safeCancelSpeech(SpeechInputPort port) async {
    try {
      await port.cancel();
    } on Object {
      // The fixed UI status is sufficient; private audio/text is never shown.
    }
  }

  Future<void> _startSpeech() async {
    final port = _speechPort;
    if (port == null ||
        port.view.busy ||
        _pending ||
        _sending ||
        _pickingImages) {
      return;
    }
    final view = widget.controller.view;
    final conversationId = view.conversationId;
    if (view.phase != AgentPhase.idle || conversationId == null) return;
    final generation = _generation;
    final speechRevision = port.view.revision + 1;
    final anchor = _SpeechDraftAnchor(
      controller: widget.controller,
      generation: generation,
      conversationId: conversationId,
      historyEpoch: view.settings?.authority.historyEpoch,
      draftRevision: _draftRevision,
      draftValue: _draft.value,
      speechRevision: speechRevision,
    );
    _speechAnchor = anchor;
    _speechFallbackError = null;
    setState(() {});
    try {
      await port.start();
      if (mounted && identical(_speechPort, port)) {
        _onSpeechViewChanged(port, _speechStreamGeneration, port.view);
      }
    } on Object {
      if (_speechResultAnchorIsCurrent(port, anchor)) {
        _speechAnchor = null;
        _speechFallbackError = '无法开始语音输入，请检查麦克风权限后重试。';
        setState(() {});
      }
      await _safeCancelSpeech(port);
    }
  }

  bool _speechResultAnchorIsCurrent(
    SpeechInputPort port,
    _SpeechDraftAnchor anchor,
  ) =>
      identical(_speechPort, port) &&
      identical(_speechAnchor, anchor) &&
      identical(widget.controller, anchor.controller) &&
      anchor.generation == _generation;

  Future<void> _finishSpeech() async {
    final port = _speechPort;
    if (port == null ||
        port.view.phase != SpeechInputPhase.recording ||
        _speechCommandPending) {
      return;
    }
    _speechCommandPending = true;
    setState(() {});
    try {
      await port.finish();
    } on Object {
      if (identical(_speechPort, port) && mounted) {
        _speechFallbackError = '无法完成语音识别，可继续键盘输入。';
      }
    } finally {
      if (identical(_speechPort, port) && mounted) {
        _speechCommandPending = false;
        _onSpeechViewChanged(port, _speechStreamGeneration, port.view);
      }
    }
  }

  Future<void> _cancelSpeechFromButton() async {
    _speechFallbackError = null;
    _invalidateSpeech(cancel: true);
  }

  void _setDiscussionDraft(String value) {
    _draft.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  void _clearDraftImages({bool update = true}) {
    _imagePickGeneration++;
    _pickingImages = false;
    final images = List<AgentImage>.of(_draftImages);
    _draftImages.clear();
    _releaseImages(images);
    if (update && mounted) setState(() {});
  }

  void _releaseImages(List<AgentImage> images) {
    for (final image in images) {
      PaintingBinding.instance.imageCache.evict(
        MemoryImage(image.bytes),
        includeLive: true,
      );
      image.bytes.fillRange(0, image.bytes.length, 0);
    }
  }

  Future<void> _pickAgentImages() async {
    final picker = widget.pickImages;
    final port = widget.controller;
    final generation = _generation;
    final view = port.view;
    final conversationId = view.conversationId;
    final historyEpoch = view.settings?.authority.historyEpoch;
    if (picker == null ||
        !_isCurrent(port, generation) ||
        !view.canSend ||
        view.busy ||
        _speechView.busy ||
        conversationId == null ||
        _sending ||
        _pickingImages ||
        _draftImages.length >= AgentImage.maximumCount) {
      return;
    }
    final pickGeneration = ++_imagePickGeneration;
    setState(() {
      _pickingImages = true;
      _message = null;
      _messageIsError = false;
    });
    try {
      final selected = await picker();
      if (!_isImagePickCurrent(
        port,
        generation,
        pickGeneration,
        conversationId,
        historyEpoch,
      )) {
        _releaseImages(selected);
        return;
      }
      if (selected.isEmpty) return;
      final next = [..._draftImages, ...selected];
      final totalBytes = next.fold<int>(
        0,
        (sum, item) => sum + item.bytes.length,
      );
      if (next.length > AgentImage.maximumCount ||
          totalBytes > AgentImage.maximumTotalBytes) {
        _releaseImages(selected);
        setState(() {
          _message = '附图最多 3 张，规范图片合计不能超过 6 MiB。';
          _messageIsError = true;
        });
        return;
      }
      setState(() => _draftImages.addAll(selected));
    } on AgentFailure catch (failure) {
      if (_isImagePickCurrent(
        port,
        generation,
        pickGeneration,
        conversationId,
        historyEpoch,
      )) {
        setState(() {
          _message = _imageFailureText(failure.code);
          _messageIsError = true;
        });
      }
    } on Object {
      if (_isImagePickCurrent(
        port,
        generation,
        pickGeneration,
        conversationId,
        historyEpoch,
      )) {
        setState(() {
          _message = '无法读取所选图片，请检查文件后重试。';
          _messageIsError = true;
        });
      }
    } finally {
      if (_isCurrent(port, generation) &&
          _imagePickGeneration == pickGeneration) {
        setState(() => _pickingImages = false);
      }
    }
  }

  bool _isImagePickCurrent(
    AgentWorkspacePort port,
    int generation,
    int pickGeneration,
    String conversationId,
    int? historyEpoch,
  ) {
    final view = port.view;
    return _isCurrent(port, generation) &&
        _imagePickGeneration == pickGeneration &&
        !view.busy &&
        view.phase == AgentPhase.idle &&
        view.canSend &&
        view.settings?.consent == true &&
        view.conversationId == conversationId &&
        view.settings?.authority.historyEpoch == historyEpoch;
  }

  void _scheduleRefresh() {
    final port = widget.controller;
    final generation = _generation;
    scheduleMicrotask(() {
      if (_isCurrent(port, generation)) unawaited(_refresh(port, generation));
    });
  }

  Future<void> _refresh(AgentWorkspacePort port, int generation) async {
    try {
      await port.refresh();
    } on Object {
      if (_isCurrent(port, generation)) {
        setState(() {
          _message = '暂时无法读取 Agent 对话，请稍后重试。';
          _messageIsError = true;
        });
      }
    }
  }

  Future<void> _runConversationCommand({required bool compact}) async {
    final port = widget.controller;
    if (port is! AgentConversationCommandsWorkspacePort ||
        _pending ||
        _sending ||
        port.view.phase == AgentPhase.closed) {
      if (mounted) {
        setState(() {
          _message = '当前页面暂时无法执行本地对话命令。';
          _messageIsError = true;
        });
      }
      return;
    }
    if (compact && port.view.busy) return;
    final generation = _generation;
    final submittedText = _draft.text;
    if (!compact) {
      _invalidateSpeech(cancel: true);
      _draft.clear();
      _draftEditedByUser = false;
      _clearDraftImages(update: false);
    }
    setState(() {
      _pending = true;
      _message = null;
      _messageIsError = false;
    });
    try {
      if (compact) {
        await (port as AgentConversationCommandsWorkspacePort)
            .compactConversation();
      } else {
        await (port as AgentConversationCommandsWorkspacePort)
            .clearConversation();
      }
      if (_isCurrent(port, generation)) {
        final failure = port.view.failure;
        final compacted = port.view.contextCompacted;
        setState(() {
          _message = failure != null
              ? _failureText(failure)
              : compact
              ? compacted
                    ? '上下文已整理，完整聊天记录仍保留。'
                    : '上下文整理未确认完成；现有对话内容保持不变。'
              : '当前对话已清空，原历史记录仍保留。';
          _messageIsError = failure != null || (compact && !compacted);
          if (compact &&
              failure == null &&
              compacted &&
              _draft.text == submittedText) {
            _draft.clear();
            _draftEditedByUser = false;
          }
        });
      }
    } on Object {
      if (_isCurrent(port, generation)) {
        setState(() {
          _message = port.view.failure == null
              ? '本地对话命令暂未完成，请稍后重试。'
              : _failureText(port.view.failure!);
          _messageIsError = true;
        });
      }
    } finally {
      if (_isCurrent(port, generation)) setState(() => _pending = false);
    }
  }

  Future<void> _send() async {
    final draftText = _draft.text;
    final command = draftText.trim();
    final isCompact = command == '/compact';
    final isClear = command == '/clear';
    if (isCompact || isClear) {
      if (_draftImages.isNotEmpty) {
        setState(() {
          _message = '本地命令不能附带图片；请先移除附图再执行。';
          _messageIsError = true;
        });
        return;
      }
      await _runConversationCommand(compact: isCompact);
      return;
    }

    final view = widget.controller.view;
    final outgoingImages = List<AgentImage>.unmodifiable(
      _draftImages.map((image) => AgentImage(image.bytes)),
    );
    final text = draftText.trim().isEmpty && outgoingImages.isNotEmpty
        ? '请根据本次附图回答。'
        : draftText;
    final conversationId = view.conversationId;
    if (!view.canSend ||
        conversationId == null ||
        (text.trim().isEmpty && outgoingImages.isEmpty) ||
        _sending ||
        _speechView.busy) {
      _releaseImages(outgoingImages);
      return;
    }
    final port = widget.controller;
    final generation = _generation;
    _clearDraftImages(update: false);
    setState(() {
      _sending = true;
      _message = null;
      _messageIsError = false;
    });
    try {
      await port.send(text, images: outgoingImages);
      if (_isCurrent(port, generation)) {
        final failure = port.view.failure;
        if (failure != null) {
          setState(() {
            _message = _failureText(failure);
            _messageIsError = true;
          });
        } else if (_draft.text == draftText) {
          _draft.clear();
          _draftEditedByUser = false;
        }
      }
    } on Object {
      if (_isCurrent(port, generation)) {
        setState(() {
          _message = '消息未能发送，请稍后重试。';
          _messageIsError = true;
        });
      }
    } finally {
      _releaseImages(outgoingImages);
      if (_isCurrent(port, generation)) setState(() => _sending = false);
    }
  }

  Future<void> _stop() async {
    final port = widget.controller;
    final generation = _generation;
    if (!_isCurrent(port, generation) || _stopping) return;
    _clearDraftImages();
    setState(() {
      _stopping = true;
      _message = null;
      _messageIsError = false;
    });
    try {
      await port.stop();
    } on Object {
      if (_isCurrent(port, generation)) {
        setState(() {
          _message = '暂时无法停止本次生成，请稍后重试。';
          _messageIsError = true;
        });
      }
    } finally {
      if (_isCurrent(port, generation)) setState(() => _stopping = false);
    }
  }

  Future<void> _handleAction(String actionId, {required bool approve}) async {
    final port = widget.controller;
    if (port is! AgentActionWorkspacePort) return;
    final actionPort = port as AgentActionWorkspacePort;
    final current = port.view.pendingAction;
    if (_actionPending ||
        _submittedActionId == actionId ||
        port.view.phase != AgentPhase.waitingForApproval ||
        current == null ||
        current.id != actionId ||
        current.status != AgentActionStatus.proposed) {
      return;
    }
    final generation = _generation;
    setState(() {
      _actionPending = true;
      _actionPendingId = actionId;
      _message = null;
      _messageIsError = false;
    });
    try {
      if (approve) {
        final permissionPort = widget.controller;
        if (_rememberActionChoices[actionId] == true &&
            permissionPort is AgentPermissionWorkspacePort) {
          await (permissionPort as AgentPermissionWorkspacePort)
              .approveAndRememberAction(actionId);
        } else {
          await actionPort.approveAction(actionId);
        }
      } else {
        await actionPort.rejectAction(actionId);
      }
      if (_isCurrent(port, generation) &&
          _actionPendingId == actionId &&
          port.view.pendingAction?.id == actionId) {
        setState(() => _submittedActionId = actionId);
      }
    } on Object {
      if (_isCurrent(port, generation) && _actionPendingId == actionId) {
        setState(() {
          _message = approve
              ? '批准操作暂未完成，请检查当前方案状态后重试。'
              : '拒绝操作暂未完成，请检查当前方案状态后重试。';
          _messageIsError = true;
        });
      }
    } finally {
      if (_isCurrent(port, generation) && _actionPendingId == actionId) {
        setState(() {
          _actionPending = false;
          _actionPendingId = null;
        });
      }
    }
  }

  Future<void> _continueSchool() async {
    final port = widget.controller;
    if (port is! AgentActionWorkspacePort) return;
    final actionPort = port as AgentActionWorkspacePort;
    if (_schoolContinuationPending ||
        _schoolContinuationSubmitted ||
        port.view.phase != AgentPhase.waitingForSchool) {
      return;
    }
    final generation = _generation;
    setState(() {
      _schoolContinuationPending = true;
      _message = null;
      _messageIsError = false;
    });
    try {
      await actionPort.continueSchool();
      if (_isCurrent(port, generation) &&
          port.view.phase == AgentPhase.waitingForSchool) {
        setState(() => _schoolContinuationSubmitted = true);
      }
    } on Object {
      if (_isCurrent(port, generation)) {
        setState(() {
          _message = '继续学校流程暂未完成，请检查当前页面状态后重试。';
          _messageIsError = true;
        });
      }
    } finally {
      if (_isCurrent(port, generation)) {
        setState(() => _schoolContinuationPending = false);
      }
    }
  }

  Future<void> _loadOlderMessages() async {
    final port = widget.controller;
    if (port is! AgentHistoryWorkspacePort) return;
    final historyPort = port as AgentHistoryWorkspacePort;
    if (_loadingOlderMessages ||
        port.view.busy ||
        !port.view.historyTruncated) {
      return;
    }
    final generation = _generation;
    setState(() => _loadingOlderMessages = true);
    try {
      await historyPort.loadOlderMessages();
    } on Object {
      if (_isCurrent(port, generation)) {
        setState(() {
          _message = '暂时无法载入更早对话，请稍后重试。';
          _messageIsError = true;
        });
      }
    } finally {
      if (_isCurrent(port, generation)) {
        setState(() => _loadingOlderMessages = false);
      }
    }
  }

  Widget _actionCard(AgentActionView action, AgentWorkspaceView view) {
    final isCurrent = view.pendingAction?.id == action.id;
    final isWaitingForApproval =
        isCurrent &&
        view.phase == AgentPhase.waitingForApproval &&
        action.status == AgentActionStatus.proposed;
    final isCommitting = isCurrent && view.phase == AgentPhase.committing;
    final portAvailable = widget.controller is AgentActionWorkspacePort;
    final canAct =
        isWaitingForApproval &&
        portAvailable &&
        !_actionPending &&
        _submittedActionId != action.id;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: _AgentActionCard(
        action: action,
        isHistorical: !isCurrent,
        statusOverride: isCommitting ? '正在提交' : null,
        requestPending: _actionPending && _actionPendingId == action.id,
        requestSubmitted: isCurrent && _submittedActionId == action.id,
        rememberApproval:
            isCurrent &&
            _rememberActionChoices[action.id] == true &&
            widget.controller is AgentPermissionWorkspacePort,
        onRememberChanged:
            isCurrent &&
                canAct &&
                widget.controller is AgentPermissionWorkspacePort
            ? (remember) =>
                  setState(() => _rememberActionChoices[action.id] = remember)
            : null,
        onApprove: canAct
            ? () => unawaited(_handleAction(action.id, approve: true))
            : null,
        onReject: canAct
            ? () => unawaited(_handleAction(action.id, approve: false))
            : null,
      ),
    );
  }

  Widget _schoolContinuationControls(AgentWorkspaceView view) {
    final portAvailable = widget.controller is AgentActionWorkspacePort;
    final waiting = view.phase == AgentPhase.waitingForSchool;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        runSpacing: 6,
        children: [
          Text(
            portAvailable ? '学校页面需要你确认后才能继续。' : '正在等待学校页面操作。',
            style: const TextStyle(color: _agentMuted),
          ),
          FilledButton.tonalIcon(
            key: const ValueKey('agent-school-continue'),
            onPressed:
                waiting &&
                    portAvailable &&
                    !_schoolContinuationPending &&
                    !_schoolContinuationSubmitted
                ? _continueSchool
                : null,
            icon: _schoolContinuationPending
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow_rounded),
            label: Text(_schoolContinuationSubmitted ? '已请求继续' : '继续学校流程'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final view = widget.controller.view;
      final status = _statusLabel(view);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Agent',
                    key: const ValueKey('agent-page-title'),
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Text('你的校园事务助手', style: TextStyle(color: _agentMuted)),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (status != null)
                    Chip(
                      key: const ValueKey('agent-phase'),
                      avatar: const Icon(Icons.more_horiz_rounded, size: 18),
                      label: Text(status),
                    ),
                  Chip(
                    key: const ValueKey('agent-capability-read-tools'),
                    avatar: Icon(
                      view.businessToolsEnabled
                          ? Icons.manage_search_rounded
                          : Icons.chat_outlined,
                      size: 18,
                    ),
                    label: Text(
                      view.businessToolsEnabled ? '只读查询可用' : '只读查询未启用',
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('agent-settings-open'),
                    tooltip: 'Agent 设置',
                    onPressed: widget.onSettings,
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ],
              ),
            ],
          ),
          if (_message != null || view.failure != null) ...[
            const SizedBox(height: 8),
            _AgentNotice(
              message:
                  view.failure == AgentFailureCode.invalidInput &&
                      view.parameterIssue != null
                  ? '模型生成的操作参数未能通过检查：${view.parameterIssue!.userMessage}请重新发送要求；也可导出日志帮助排查。'
                  : _message ?? _failureText(view.failure!),
              isError:
                  _messageIsError || (_message == null && view.failure != null),
            ),
            if (widget.diagnostics != null && view.failure != null)
              Align(
                alignment: Alignment.centerRight,
                child: DiagnosticsExportButton(
                  diagnostics: widget.diagnostics!,
                ),
              ),
          ],
          const SizedBox(height: 12),
          Expanded(child: _conversation(view)),
        ],
      );
    },
  );

  bool _canSubmit(AgentWorkspaceView view) {
    if (_sending || _pending || _pickingImages || _speechView.busy) {
      return false;
    }
    if (view.phase != AgentPhase.idle) return false;
    final command = _draft.text.trim();
    if (command == '/clear' || command == '/compact') {
      return widget.controller is AgentConversationCommandsWorkspacePort;
    }
    return view.canSend &&
        view.conversationId != null &&
        (command.isNotEmpty || _draftImages.isNotEmpty);
  }

  Widget _conversation(AgentWorkspaceView view) {
    final configured =
        view.settings?.keySaved == true &&
        view.settings?.consent == true &&
        view.settings?.modelId != null &&
        view.settings?.report.capability != ModelCapability.unverified;
    final canSend = _canSubmit(view);
    final speechVisible =
        widget.speechInput != null && view.conversationId != null;
    final canStartSpeech =
        speechVisible &&
        view.phase == AgentPhase.idle &&
        !_pending &&
        !_sending &&
        !_pickingImages &&
        _speechView.phase == SpeechInputPhase.idle;
    final canStop =
        view.phase == AgentPhase.generating ||
        view.phase == AgentPhase.compacting ||
        view.phase == AgentPhase.executingRead ||
        view.phase == AgentPhase.waitingForApproval ||
        view.phase == AgentPhase.waitingForSchool ||
        view.phase == AgentPhase.committing ||
        view.phase == AgentPhase.settling;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Card(
            child: view.conversationId == null
                ? _emptyConversation(configured)
                : _messages(view),
          ),
        ),
        const SizedBox(height: 10),
        if (!configured)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _SetupPrompt(onSettings: widget.onSettings),
          ),
        if (view.phase == AgentPhase.waitingForSchool)
          _schoolContinuationControls(view),
        if (_showRunProgress(view)) ...[
          const SizedBox(height: 4),
          _AgentRunProgress(view: view),
          const SizedBox(height: 8),
        ],
        _composer(
          enabled: canSend,
          canPick:
              view.canSend &&
              view.conversationId != null &&
              !_sending &&
              !_pending &&
              !_pickingImages &&
              _draftImages.length < AgentImage.maximumCount &&
              !_speechView.busy &&
              _draftImages.fold<int>(
                    0,
                    (sum, image) => sum + image.bytes.length,
                  ) <
                  AgentImage.maximumTotalBytes,
          canStop: canStop,
          busy: view.busy,
          speechVisible: speechVisible,
          canStartSpeech: canStartSpeech,
          speechView: _speechView,
        ),
      ],
    );
  }

  Widget _emptyConversation(bool configured) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.forum_outlined, size: 42, color: _agentGreen),
            const SizedBox(height: 12),
            Text(
              configured ? '开始主对话' : '先完成模型设置',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              configured
                  ? '输入消息即可开始；可查询日程、任务、知识与公开资料，写入和同步功能后续开放。'
                  : '目前尚未配置可用模型。完成设置后即可开始对话。',
              style: const TextStyle(color: _agentMuted, height: 1.45),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            if (!configured) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: widget.onSettings,
                icon: const Icon(Icons.settings_outlined),
                label: const Text('打开 Agent 设置'),
              ),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _messages(AgentWorkspaceView view) => Column(
    children: [
      if (view.historyTruncated)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '当前只展示最近一部分对话内容。',
                  style: TextStyle(color: _agentMuted, fontSize: 12),
                ),
              ),
              if (widget.controller is AgentHistoryWorkspacePort) ...[
                const SizedBox(width: 8),
                TextButton.icon(
                  key: const ValueKey('agent-history-load-older'),
                  onPressed: view.busy || _loadingOlderMessages
                      ? null
                      : _loadOlderMessages,
                  icon: _loadingOlderMessages
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.history_rounded, size: 17),
                  label: Text(_loadingOlderMessages ? '正在载入' : '载入更早消息'),
                ),
              ],
            ],
          ),
        ),
      if (view.pendingAction != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: _actionCard(view.pendingAction!, view),
        ),
      Expanded(
        child: view.messages.isEmpty
            ? view.pendingAction != null
                  ? const SizedBox.shrink()
                  : const Center(
                      child: Text(
                        '发送一条消息，开始对话。',
                        style: TextStyle(color: _agentMuted),
                      ),
                    )
            : ListView.builder(
                key: const ValueKey('agent-message-list'),
                padding: const EdgeInsets.all(16),
                itemCount: view.messages.length,
                itemBuilder: (context, index) {
                  final message = view.messages[index];
                  final detailsKey =
                      '${view.conversationId ?? 'no-conversation'}:${message.id}';
                  final actionCards = [
                    for (final storedAction in message.actions)
                      if (view.pendingAction?.id != storedAction.id)
                        _actionCard(storedAction, view),
                  ];
                  final isCurrentAnswerEvidence =
                      index == view.messages.length - 1 &&
                      view.phase == AgentPhase.idle &&
                      message.role == AgentMessageRole.assistant &&
                      message.status == AgentMessageStatus.complete;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _MessageBubble(
                      message: message,
                      isCurrentAnswerEvidence: isCurrentAnswerEvidence,
                      queryDetailsKey: detailsKey,
                      queryDetailsExpanded: _expandedQueryDetails.contains(
                        detailsKey,
                      ),
                      actionCount: actionCards.length,
                      actionCards: actionCards,
                      onOpenLocalEvidence: widget.onOpenLocalEvidence,
                      onToggleQueryDetails: () {
                        setState(() {
                          if (!_expandedQueryDetails.add(detailsKey)) {
                            _expandedQueryDetails.remove(detailsKey);
                          }
                        });
                      },
                    ),
                  );
                },
              ),
      ),
    ],
  );

  Widget _composer({
    required bool enabled,
    required bool canPick,
    required bool canStop,
    required bool busy,
    required bool speechVisible,
    required bool canStartSpeech,
    required SpeechInputView speechView,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_draftImages.isNotEmpty) ...[
              _imageDraftPreview(),
              const SizedBox(height: 8),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  key: const ValueKey('agent-attach-image'),
                  tooltip: _pickingImages ? '正在读取图片' : '添加图片',
                  onPressed: canPick ? _pickAgentImages : null,
                  icon: _pickingImages
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add_photo_alternate_outlined),
                ),
                if (speechVisible)
                  IconButton(
                    key: const ValueKey('agent-speech-toggle'),
                    tooltip: speechView.phase == SpeechInputPhase.recording
                        ? '停止并识别'
                        : '本地语音输入',
                    onPressed: speechView.phase == SpeechInputPhase.recording
                        ? (_speechCommandPending ? null : _finishSpeech)
                        : canStartSpeech
                        ? _startSpeech
                        : null,
                    icon: speechView.phase == SpeechInputPhase.recording
                        ? const Icon(Icons.stop_circle_outlined)
                        : speechView.phase == SpeechInputPhase.preparing ||
                              speechView.phase == SpeechInputPhase.stopping ||
                              speechView.phase ==
                                  SpeechInputPhase.recognizing ||
                              speechView.phase == SpeechInputPhase.cancelling ||
                              speechView.phase == SpeechInputPhase.recovery
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.mic_none_rounded),
                  ),
                Expanded(
                  child: Focus(
                    onKeyEvent: (node, event) {
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.enter &&
                          !HardwareKeyboard.instance.isShiftPressed) {
                        if (enabled) {
                          unawaited(_send());
                          return KeyEventResult.handled;
                        }
                      }
                      return KeyEventResult.ignored;
                    },
                    child: TextField(
                      key: const ValueKey('agent-composer'),
                      controller: _draft,
                      focusNode: _composerFocus,
                      enabled: !busy && !_pending,
                      minLines: 1,
                      maxLines: 4,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.send,
                      onChanged: (_) {
                        _draftEditedByUser = true;
                        setState(() {});
                      },
                      onSubmitted: (_) {
                        if (enabled) unawaited(_send());
                      },
                      decoration: const InputDecoration(
                        hintText: '输入消息…（Enter 发送，Shift+Enter 换行）',
                        border: InputBorder.none,
                        filled: false,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                ),
                if (canStop)
                  IconButton.filledTonal(
                    key: const ValueKey('agent-stop'),
                    tooltip: '停止本次运行',
                    onPressed: _stopping ? null : _stop,
                    icon: _stopping
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.stop_rounded),
                  )
                else
                  IconButton.filled(
                    key: const ValueKey('agent-send'),
                    tooltip: '发送消息',
                    onPressed: enabled ? _send : null,
                    icon: _sending
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.arrow_upward_rounded),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '本地命令：/compact 整理上下文；/clear 清空当前聊天并保留历史。',
              key: ValueKey('agent-command-hint'),
              style: TextStyle(color: _agentMuted, fontSize: 12),
            ),
            if (_speechView.busy ||
                _speechView.failure != null ||
                _speechView.phase == SpeechInputPhase.closed ||
                _speechFallbackError != null) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _speechFallbackError ?? _speechStatusText(_speechView),
                      key: const ValueKey('agent-speech-status'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color:
                            _speechView.failure != null ||
                                _speechFallbackError != null
                            ? const Color(0xFF9B2C2C)
                            : _agentMuted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  if (_speechView.busy)
                    TextButton(
                      key: const ValueKey('agent-speech-cancel'),
                      onPressed: _cancelSpeechFromButton,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('取消'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _imageDraftPreview() {
    final total = _draftImages.fold<int>(
      0,
      (sum, image) => sum + image.bytes.length,
    );
    final remainingCount = AgentImage.maximumCount - _draftImages.length;
    final remainingBytes = AgentImage.maximumTotalBytes - total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var index = 0; index < _draftImages.length; index++)
              Stack(
                key: ValueKey('agent-image-preview-$index'),
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(
                      _draftImages[index].bytes,
                      width: 68,
                      height: 68,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stack) => Container(
                        width: 68,
                        height: 68,
                        color: const Color(0xFFF5F7F6),
                        alignment: Alignment.center,
                        child: const Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.broken_image_outlined, size: 20),
                            Text('预览失败', style: TextStyle(fontSize: 10)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    top: 0,
                    child: IconButton.filledTonal(
                      key: ValueKey('agent-image-remove-$index'),
                      tooltip: '移除附图',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _removeDraftImage(index),
                      icon: const Icon(Icons.close_rounded, size: 16),
                    ),
                  ),
                ],
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '附图 ${_draftImages.length} 张 · 还可选 $remainingCount 张 · '
          '剩余 ${(remainingBytes / (1024 * 1024)).toStringAsFixed(1)} MiB',
          key: const ValueKey('agent-image-counts'),
          style: const TextStyle(color: _agentMuted, fontSize: 12),
        ),
      ],
    );
  }

  void _removeDraftImage(int index) {
    if (index < 0 || index >= _draftImages.length) return;
    final image = _draftImages.removeAt(index);
    _releaseImages([image]);
    setState(() {});
  }
}

final class _SetupPrompt extends StatelessWidget {
  const _SetupPrompt({required this.onSettings});

  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('agent-model-setup-prompt'),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF5E8),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFF0E0C7)),
    ),
    child: Row(
      children: [
        const Icon(Icons.info_outline_rounded, color: Color(0xFF8A5A14)),
        const SizedBox(width: 10),
        const Expanded(child: Text('配置学校模型并完成发送说明确认后，才能发送消息。')),
        TextButton(onPressed: onSettings, child: const Text('去设置')),
      ],
    ),
  );
}

final class _AgentNotice extends StatelessWidget {
  const _AgentNotice({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('agent-page-notice'),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: isError ? const Color(0xFFFFF0F0) : const Color(0xFFEAF3ED),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(message, style: const TextStyle(height: 1.4)),
  );
}

bool _showRunProgress(AgentWorkspaceView view) =>
    view.phase == AgentPhase.generating ||
    view.phase == AgentPhase.compacting ||
    view.phase == AgentPhase.executingRead ||
    view.phase == AgentPhase.committing ||
    view.phase == AgentPhase.settling;

final class _AgentRunProgress extends StatelessWidget {
  const _AgentRunProgress({required this.view});

  final AgentWorkspaceView view;

  @override
  Widget build(BuildContext context) {
    final active = view.phase == AgentPhase.executingRead
        ? _toolLabel(view.activeTool)
        : null;
    return Container(
      key: const ValueKey('agent-run-progress'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F7F6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _agentLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  active == null ? _statusLabel(view) ?? '处理中' : '正在查询$active',
                  key: const ValueKey('agent-run-progress-status'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            '模型请求 ${view.modelCalls} 次 · 工具调用 ${view.toolCalls} 次',
            key: const ValueKey('agent-run-progress-counts'),
            style: const TextStyle(color: _agentMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

final class _ToolStepList extends StatelessWidget {
  const _ToolStepList({required this.steps});

  final List<AgentToolStep> steps;

  @override
  Widget build(BuildContext context) => Column(
    key: const ValueKey('agent-tool-steps'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('查询步骤', style: TextStyle(color: _agentMuted, fontSize: 12)),
      const SizedBox(height: 4),
      Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (var index = 0; index < steps.length; index++)
            Chip(
              key: ValueKey('agent-tool-step-$index'),
              visualDensity: VisualDensity.compact,
              label: Text(
                '${_toolLabel(steps[index].tool) ?? '只读查询'} · '
                '${_toolStatusLabel(steps[index].status)}',
              ),
            ),
        ],
      ),
    ],
  );
}

final class _EvidenceCard extends StatefulWidget {
  const _EvidenceCard({
    required this.evidence,
    required this.historical,
    required this.number,
    this.onOpenLocalEvidence,
  });

  final AgentEvidence evidence;
  final int number;
  final bool historical;
  final ValueChanged<AgentEvidence>? onOpenLocalEvidence;

  @override
  State<_EvidenceCard> createState() => _EvidenceCardState();
}

final class _AgentActionCard extends StatelessWidget {
  const _AgentActionCard({
    required this.action,
    required this.isHistorical,
    required this.requestPending,
    required this.requestSubmitted,
    required this.rememberApproval,
    this.onRememberChanged,
    this.statusOverride,
    this.onApprove,
    this.onReject,
  });

  final AgentActionView action;
  final bool isHistorical;
  final bool requestPending;
  final bool requestSubmitted;
  final bool rememberApproval;
  final ValueChanged<bool>? onRememberChanged;
  final String? statusOverride;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;

  @override
  Widget build(BuildContext context) {
    final canRespond = onApprove != null || onReject != null;
    final authorizationLabel =
        isHistorical && action.status == AgentActionStatus.committed
        ? switch (action.authorization) {
            AgentActionAuthorization.legacy => null,
            AgentActionAuthorization.confirmed => '本次确认',
            AgentActionAuthorization.remembered => '已保存授权',
          }
        : null;
    return Card(
      key: ValueKey('agent-action-${action.id}'),
      margin: EdgeInsets.zero,
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.fact_check_outlined,
                  size: 19,
                  color: _agentGreen,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        action.title,
                        key: ValueKey('agent-action-title-${action.id}'),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${_actionKindLabel(action.kind)} · '
                        '${statusOverride ?? _actionStatusLabel(action.status)}'
                        '${isHistorical ? ' · 历史记录' : ''}'
                        '${authorizationLabel == null ? '' : ' · $authorizationLabel'}',
                        key: ValueKey('agent-action-status-${action.id}'),
                        style: const TextStyle(
                          color: _agentMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (action.details.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final detail in action.details)
                if (detail.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text('• $detail'),
                  ),
            ],
            if (action.warning.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                key: ValueKey('agent-action-warning-${action.id}'),
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF5E8),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  action.warning,
                  style: const TextStyle(color: Color(0xFF805500)),
                ),
              ),
            ],
            if (action.status == AgentActionStatus.committed ||
                action.committedCount > 0) ...[
              const SizedBox(height: 6),
              Text(
                '本地实际提交 ${action.committedCount} 项',
                key: ValueKey('agent-action-committed-${action.id}'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
            if (isHistorical) ...[
              const SizedBox(height: 6),
              const Text(
                '这是历史记录，不提供再次批准操作。',
                style: TextStyle(color: _agentMuted, fontSize: 12),
              ),
            ],
            if (requestPending || requestSubmitted) ...[
              const SizedBox(height: 6),
              Text(
                requestPending ? '正在提交你的决定…' : '操作已送出，等待本地状态更新。',
                key: ValueKey('agent-action-request-state-${action.id}'),
                style: const TextStyle(color: _agentMuted, fontSize: 12),
              ),
            ],
            if (onRememberChanged != null) ...[
              const SizedBox(height: 8),
              CheckboxListTile(
                key: ValueKey('agent-action-remember-${action.id}'),
                value: rememberApproval,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('以后不再确认此类操作'),
                subtitle: const Text('只适用于本卡涉及的固定工具和操作类别；模型不能新增或扩大权限，可在设置中撤销。'),
                onChanged: (value) {
                  if (value != null) onRememberChanged?.call(value);
                },
              ),
            ],
            if (canRespond) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  FilledButton.icon(
                    key: ValueKey('agent-action-approve-${action.id}'),
                    onPressed: onApprove,
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: const Text('批准并提交'),
                  ),
                  OutlinedButton.icon(
                    key: ValueKey('agent-action-reject-${action.id}'),
                    onPressed: onReject,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    label: const Text('拒绝'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _actionKindLabel(AgentActionKind kind) => switch (kind) {
  AgentActionKind.localPlan => '本地修改方案',
  AgentActionKind.undo => '撤销本地修改',
  AgentActionKind.sourceRefresh => '学校来源刷新',
  AgentActionKind.planningPreferences => '时间规划偏好',
};

String _actionStatusLabel(AgentActionStatus status) => switch (status) {
  AgentActionStatus.proposed => '待批准',
  AgentActionStatus.rejected => '已拒绝',
  AgentActionStatus.committed => '已提交',
  AgentActionStatus.interrupted => '已中断',
  AgentActionStatus.failed => '未完成',
};

final class _EvidenceCardState extends State<_EvidenceCard> {
  bool _expanded = false;

  Future<void> _copySource(Uri uri) async {
    try {
      await Clipboard.setData(ClipboardData(text: uri.toString()));
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已复制已核验出处链接。')));
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂时无法复制出处链接。')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final evidence = widget.evidence;
    final source = _verifiedEvidenceUri(evidence);
    final dates = [
      if (evidence.publishedOn != null) '发布 ${evidence.publishedOn}',
      if (evidence.updatedOn != null) '更新 ${evidence.updatedOn}',
    ].join(' · ');
    return Card(
      key: ValueKey('agent-evidence-${evidence.id}'),
      margin: EdgeInsets.zero,
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.verified_outlined,
                  size: 18,
                  color: _agentGreen,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${_providerLabel(evidence.provider)} · '
                    '${widget.historical ? '历史材料，下轮须重新查询' : '本次回答读取，下轮须重新查询'}',
                    style: const TextStyle(
                      color: _agentMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '出处 ${widget.number}',
                  key: ValueKey('agent-evidence-id-${evidence.id}'),
                  style: const TextStyle(color: _agentMuted, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              evidence.title,
              key: ValueKey('agent-evidence-title-${evidence.id}'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 3),
            Text(
              '读取于北京时间 ${_beijingTime(evidence.observedAtUtc)} · '
              '${evidence.complete ? '覆盖完整' : '覆盖不完整'} · 适用性未核验',
              style: const TextStyle(color: _agentMuted, fontSize: 12),
            ),
            if (dates.isNotEmpty ||
                evidence.revision != null ||
                evidence.sourceVersion != null ||
                evidence.locator != null) ...[
              const SizedBox(height: 3),
              Text(
                [
                  if (dates.isNotEmpty) dates,
                  if (evidence.revision != null) '修订 ${evidence.revision}',
                  if (evidence.sourceVersion != null)
                    '来源版本 ${evidence.sourceVersion}',
                  if (evidence.locator != null) '位置 ${evidence.locator}',
                ].join(' · '),
                style: const TextStyle(color: _agentMuted, fontSize: 12),
              ),
            ],
            const SizedBox(height: 3),
            Text(
              '范围：${evidence.scope}',
              style: const TextStyle(color: _agentMuted, fontSize: 12),
            ),
            if (evidence.snippet.isNotEmpty) ...[
              const SizedBox(height: 5),
              TextButton.icon(
                key: ValueKey('agent-evidence-expand-${evidence.id}'),
                onPressed: () => setState(() => _expanded = !_expanded),
                icon: Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 18,
                ),
                label: Text(_expanded ? '收起已读取片段' : '展开已读取片段'),
              ),
              if (_expanded)
                Container(
                  key: ValueKey('agent-evidence-snippet-${evidence.id}'),
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F7F6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(evidence.snippet),
                ),
            ],
            if (widget.onOpenLocalEvidence != null &&
                evidence.provider == 'local' &&
                ((evidence.eventReference != null) !=
                    (evidence.taskReference != null)))
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: ValueKey('agent-evidence-open-local-${evidence.id}'),
                  onPressed: () => widget.onOpenLocalEvidence?.call(evidence),
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: Text(
                    evidence.eventReference != null ? '在日程中查看' : '在任务中查看',
                  ),
                ),
              ),
            if (source != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: ValueKey('agent-evidence-copy-${evidence.id}'),
                  onPressed: () => unawaited(_copySource(source)),
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: const Text('复制已核验出处链接'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _providerLabel(String provider) => switch (provider) {
  'local' => '本地资料',
  'icourse' => '评课公开资料',
  'teach' => '教务公开资料',
  'finance' => '财务公开资料',
  _ => '已核验资料',
};

Uri? _verifiedEvidenceUri(AgentEvidence evidence) {
  final value = evidence.articleUrl ?? evidence.materialUrl;
  if (value == null) return null;
  final host = switch (evidence.provider) {
    'icourse' => 'icourse.club',
    'teach' => 'www.teach.ustc.edu.cn',
    'finance' => 'finance.ustc.edu.cn',
    _ => '',
  };
  final uri = Uri.tryParse(value);
  if (host.isEmpty ||
      uri == null ||
      uri.host != host ||
      uri.userInfo.isNotEmpty ||
      !const {'http', 'https'}.contains(uri.scheme) ||
      uri.port != (uri.scheme == 'https' ? 443 : 80)) {
    return null;
  }
  return uri;
}

String _beijingTime(DateTime utc) {
  final value = utc.toUtc().add(const Duration(hours: 8));
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
}

String? _toolLabel(String? tool) {
  if (tool == null) return null;
  return switch (tool) {
    'query_agenda' => '日程',
    'read_event' => '日程详情',
    'query_tasks' => '任务',
    'read_task' => '任务详情',
    'inspect_conflicts' => '时间冲突',
    'search_knowledge' => '知识库',
    'read_knowledge' => '知识片段',
    'search_courses' => '课程',
    'read_course' => '课程详情',
    'read_reviews' => '评课资料',
    'browse_campus' => '校园公开资料',
    'read_campus_article' => '校园文章',
    'propose_local_changes' => '准备本地修改方案',
    'propose_undo' => '准备撤销方案',
    'find_free_slots' => '查找空闲时段',
    'query_source_options' => '查看来源刷新范围',
    'request_source_refresh' => '请求学校来源刷新',
    'query_young_activities' => '查询二课活动',
    'propose_planning_preferences' => '准备时间偏好方案',
    _ => null,
  };
}

String _toolStatusLabel(String status) => switch (status) {
  'success' => '已完成',
  'empty' => '完整空结果',
  'partial' => '部分结果',
  'busy' => '来源正忙',
  'consentRequired' => '需要授权',
  'unavailable' => '暂不可用',
  'accessRestricted' => '无法访问',
  'stale' => '资料已变化',
  'cancelled' => '已取消',
  'resourceLimit' => '达到上限',
  'failure' => '查询失败',
  'executing' => '查询中',
  'invalidRequest' => '输入无效',
  'secretDetected' => '检测到受保护内容',
  'waitingForApproval' => '等待批准',
  'waitingForSchool' => '等待学校操作',
  'committed' => '已提交',
  'rejected' => '已拒绝',
  _ => '状态未知',
};

String _markEvidenceReferences(String text, List<AgentEvidence> evidence) {
  final known = {
    for (var i = 0; i < evidence.length; i++) evidence[i].id: i + 1,
  };
  return text.replaceAllMapped(RegExp(r'\[\[([^\]\r\n]*)\]\]'), (match) {
    final id = match.group(1) ?? '';
    return known.containsKey(id) ? '【出处 ${known[id]}】' : '【引用未验证】';
  });
}

final class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.isCurrentAnswerEvidence,
    required this.queryDetailsKey,
    required this.queryDetailsExpanded,
    required this.onToggleQueryDetails,
    required this.actionCount,
    required this.actionCards,
    this.onOpenLocalEvidence,
  });

  final AgentMessage message;
  final bool isCurrentAnswerEvidence;
  final String queryDetailsKey;
  final bool queryDetailsExpanded;
  final VoidCallback onToggleQueryDetails;
  final int actionCount;
  final List<Widget> actionCards;
  final ValueChanged<AgentEvidence>? onOpenLocalEvidence;

  @override
  Widget build(BuildContext context) {
    final user = message.role == AgentMessageRole.user;
    final text = _boundedMarkdown(
      _markEvidenceReferences(message.text, message.evidence),
    );
    final status = _messageStatus(message.status);
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Container(
          key: ValueKey('agent-message-${message.id}'),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: user ? const Color(0xFFE7F1EA) : const Color(0xFFF5F7F6),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _agentLine),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!user)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Agent',
                      style: TextStyle(
                        color: _agentMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (status != null) ...[
                      const SizedBox(width: 8),
                      _MessageStatus(
                        label: status,
                        failed: message.status == AgentMessageStatus.failed,
                      ),
                    ],
                  ],
                ),
              if (text.isNotEmpty) ...[
                if (!user) const SizedBox(height: 5),
                MarkdownBody(
                  data: text,
                  softLineBreak: true,
                  fitContent: true,
                  builders: {'a': _PlainAnchorBuilder()},
                  imageBuilder: (uri, title, alt) => Text(
                    alt == null || alt.isEmpty ? '（图片已隐藏）' : '（图片已隐藏：$alt）',
                    style: const TextStyle(color: _agentMuted),
                  ),
                ),
              ] else if (message.status != AgentMessageStatus.complete) ...[
                const SizedBox(height: 4),
                Text(
                  message.status == AgentMessageStatus.failed
                      ? '本次回复未完成。操作结果以方案卡为准，可导出最近日志排查。'
                      : '回复已停止。',
                  style: const TextStyle(color: _agentMuted),
                ),
              ],
              if (user && message.imageCount > 0) ...[
                const SizedBox(height: 6),
                Text(
                  '附图 ${message.imageCount} 张 · 原图未保留',
                  key: ValueKey('agent-message-images-${message.id}'),
                  style: const TextStyle(color: _agentMuted, fontSize: 12),
                ),
              ],
              if (!user &&
                  (message.steps.isNotEmpty ||
                      message.evidence.isNotEmpty ||
                      actionCards.isNotEmpty)) ...[
                if (text.isNotEmpty) const SizedBox(height: 6),
                TextButton.icon(
                  key: ValueKey('agent-query-details-toggle-$queryDetailsKey'),
                  onPressed: onToggleQueryDetails,
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: Icon(
                    queryDetailsExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                  ),
                  label: Text(
                    '处理详情 · ${message.steps.length} 个步骤 · '
                    '${message.evidence.length} 处出处 · $actionCount 项操作',
                  ),
                ),
                if (queryDetailsExpanded) ...[
                  if (message.steps.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    _ToolStepList(steps: message.steps),
                  ],
                  for (var index = 0; index < message.evidence.length; index++)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: _EvidenceCard(
                        evidence: message.evidence[index],
                        number: index + 1,
                        historical: !isCurrentAnswerEvidence,
                        onOpenLocalEvidence: onOpenLocalEvidence,
                      ),
                    ),
                  ...actionCards,
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

final class _PlainAnchorBuilder extends MarkdownElementBuilder {
  _PlainAnchorBuilder();

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => Text(element.textContent, style: parentStyle);
}

final class _MessageStatus extends StatelessWidget {
  const _MessageStatus({required this.label, required this.failed});

  final String label;
  final bool failed;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: failed ? const Color(0xFFFBEAEA) : const Color(0xFFE9EDEA),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: failed ? const Color(0xFF9B2C2C) : _agentMuted,
        fontSize: 11,
      ),
    ),
  );
}

String _boundedMarkdown(String input) {
  const maxLength = 12000;
  final bounded = input.length <= maxLength
      ? input
      : '${input.substring(0, maxLength)}\n\n…内容过长，已截断显示';
  // Raw HTML is displayed as ordinary text. Markdown links stay visible but
  // are rendered by _PlainAnchorBuilder without tap handlers; images are
  // replaced with an inert label in imageBuilder.
  return bounded.replaceAll('<', r'\<');
}

String? _messageStatus(AgentMessageStatus status) => switch (status) {
  AgentMessageStatus.streaming => '生成中',
  AgentMessageStatus.complete => null,
  AgentMessageStatus.interrupted => '部分回复 · 已中断',
  AgentMessageStatus.cancelled => '已取消',
  AgentMessageStatus.failed => '回复失败',
};

String? _statusLabel(AgentWorkspaceView view) => switch (view.phase) {
  AgentPhase.idle => null,
  AgentPhase.loadingModels => '正在获取模型',
  AgentPhase.verifying => '正在验证模型',
  AgentPhase.generating => '正在生成回复',
  AgentPhase.compacting => '正在整理上下文',
  AgentPhase.executingRead =>
    view.activeTool == null
        ? '正在查询资料'
        : '正在查询${_toolLabel(view.activeTool) ?? '只读资料'}',
  AgentPhase.waitingForApproval => '等待你批准方案',
  AgentPhase.waitingForSchool => '等待你在学校页面继续',
  AgentPhase.committing => '正在提交本地修改',
  AgentPhase.settling => '正在保存回复',
  AgentPhase.recovery => '正在恢复状态',
  AgentPhase.maintenance => '本地维护中',
  AgentPhase.closed => '服务已关闭',
};

String _failureText(AgentFailureCode code) => switch (code) {
  AgentFailureCode.invalidInput => '输入不符合要求，请检查后重试。',
  AgentFailureCode.imageRejected => '模型拒绝了附图；请换用支持图片输入的模型后重试。',
  AgentFailureCode.secretDetected => '输入包含受保护内容，请移除后重试。',
  AgentFailureCode.consentRequired => '请先在设置中阅读说明并明确勾选同意。',
  AgentFailureCode.keyRequired => '请先在设置中配置模型 Key。',
  AgentFailureCode.modelRequired => '请先在设置中获取并选择有效模型。',
  AgentFailureCode.busy => 'Agent 正在处理其他操作，请稍后重试。',
  AgentFailureCode.staleContext => '对话状态已变化，请刷新后重试。',
  AgentFailureCode.maintenance => '本地维护正在进行，请稍后重试。',
  AgentFailureCode.ownershipLost => '本机数据状态已变化，请重新打开 Agent。',
  AgentFailureCode.storageFailed => '本机对话暂时无法保存，请稍后重试。',
  AgentFailureCode.protectionFailed => '本机密钥保护未完成，操作没有保存。',
  AgentFailureCode.unauthorized ||
  AgentFailureCode.forbidden => '模型服务未授权此请求，请检查设置。',
  AgentFailureCode.rateLimited => '模型服务暂时繁忙，请稍后重试。',
  AgentFailureCode.networkFailed ||
  AgentFailureCode.timeout => '暂时无法连接模型服务，请检查网络后重试。',
  AgentFailureCode.protocol ||
  AgentFailureCode.redirectRejected => '模型服务返回内容无法安全验证。',
  AgentFailureCode.resourceLimit => '回复超出当前处理上限。',
  AgentFailureCode.cancelled => '本次生成已取消。',
  AgentFailureCode.closed => 'Agent 服务已关闭，请重新打开页面。',
  AgentFailureCode.toolUnavailable => '请求的工具不在本次可用范围内，已停止本次处理。',
};

String _imageFailureText(AgentFailureCode code) => switch (code) {
  AgentFailureCode.resourceLimit => '图片数量、尺寸或文件大小超过限制。',
  AgentFailureCode.invalidInput => '所选图片无法读取，请选择 PNG、JPEG 或 WebP 图片。',
  AgentFailureCode.imageRejected => '模型拒绝了附图；请换用支持图片输入的模型后重试。',
  _ => '无法读取所选图片，请检查文件后重试。',
};

String _speechStatusText(SpeechInputView view) {
  final failure = view.failure;
  if (failure != null) {
    return switch (failure) {
      SpeechInputFailureCode.unsupportedPlatform => '此设备暂不支持语音输入。',
      SpeechInputFailureCode.permissionDenied => '未获得麦克风权限，可继续键盘输入。',
      SpeechInputFailureCode.microphoneUnavailable => '麦克风不可用，请检查设备后重试。',
      SpeechInputFailureCode.modelUnavailable => '本地语音模型未准备好，可继续键盘输入。',
      SpeechInputFailureCode.invalidAudio => '录音数据无效，请重试。',
      SpeechInputFailureCode.noSpeech => '没有听到可识别的语音。',
      SpeechInputFailureCode.tooShort => '录音过短，请再说一会儿。',
      SpeechInputFailureCode.resourceLimit => '录音超过上限，请缩短后重试。',
      SpeechInputFailureCode.recognitionFailed => '识别失败，可重试或继续键盘输入。',
      SpeechInputFailureCode.cleanupFailed => '语音资源正在恢复，请稍后重试。',
      SpeechInputFailureCode.busy => '语音输入正在处理中，请稍后。',
      SpeechInputFailureCode.closed => '语音输入已关闭。',
    };
  }
  return switch (view.phase) {
    SpeechInputPhase.idle => '',
    SpeechInputPhase.preparing => '正在准备语音输入…',
    SpeechInputPhase.recording =>
      '正在录音 · ${_formatSpeechElapsed(view.elapsedMilliseconds)} / 00:30',
    SpeechInputPhase.stopping =>
      view.elapsedMilliseconds > 0
          ? '正在结束录音 · ${_formatSpeechElapsed(view.elapsedMilliseconds)}'
          : '正在结束录音…',
    SpeechInputPhase.recognizing => '正在识别…',
    SpeechInputPhase.cancelling => '正在取消语音输入…',
    SpeechInputPhase.recovery => '语音资源正在收口，请稍后重试。',
    SpeechInputPhase.closed => '语音输入已关闭。',
  };
}

String _formatSpeechElapsed(int milliseconds) {
  final seconds = milliseconds.clamp(0, speechMaximumSeconds * 1000) ~/ 1000;
  final minutesPart = (seconds ~/ 60).toString().padLeft(2, '0');
  final secondsPart = (seconds % 60).toString().padLeft(2, '0');
  return '$minutesPart:$secondsPart';
}

final class _SpeechDraftAnchor {
  const _SpeechDraftAnchor({
    required this.controller,
    required this.generation,
    required this.conversationId,
    required this.historyEpoch,
    required this.draftRevision,
    required this.draftValue,
    required this.speechRevision,
  });

  final AgentWorkspacePort controller;
  final int generation;
  final String conversationId;
  final int? historyEpoch;
  final int draftRevision;
  final TextEditingValue draftValue;
  final int speechRevision;
}
