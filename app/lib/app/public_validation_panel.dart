import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../core/knowledge_contract.dart';
import '../core/public_query_contract.dart';

/// Temporary validation UI over the same internal ports used by the app.
final class PublicValidationPanel extends StatefulWidget {
  const PublicValidationPanel({
    super.key,
    required this.queries,
    required this.knowledge,
  });

  final PublicQueryPort queries;
  final KnowledgePort knowledge;

  @override
  State<PublicValidationPanel> createState() => _PublicValidationPanelState();
}

final class _PublicValidationPanelState extends State<PublicValidationPanel> {
  static const int _documentStart = 0;
  static const int _maxDocumentCharacters = 12000;

  final _courseKeyword = TextEditingController();
  final _campusKeyword = TextEditingController();
  final _knowledgeKeyword = TextEditingController();
  final _knowledgeTopic = TextEditingController();
  final _knowledgeAudience = TextEditingController();
  final _knowledgeVersion = TextEditingController();

  StreamSubscription<PublicJobView>? _querySubscription;
  late PublicJobView _job;
  KnowledgeSummary _knowledgeSummary = const KnowledgeSummary(
    materialCount: 0,
    sectionCount: 0,
    loadCount: 0,
    loading: false,
  );
  CampusColumn _campusColumn = CampusColumn.teachNotice;
  PublicProvider? _knowledgeProvider;
  PublicCandidate? _selectedCourse;
  String? _courseTerm;
  CourseReviewSort _courseSort = CourseReviewSort.upvote;
  String? _courseQuery;
  CampusColumn? _campusQueryColumn;
  String? _campusQuery;
  String? _knowledgeQuery;
  PublicProvider? _knowledgeQueryProvider;
  String? _knowledgeQueryTopic;
  String? _knowledgeQueryAudience;
  String? _knowledgeQueryVersion;
  PublicQueryPort? _campusReadPort;
  PublicReference? _campusReadReference;
  int? _campusReadSectionStart;
  int? _campusReadMaxCharacters;
  PublicCursor? _campusReadNext;
  int _campusReadEpoch = 0;
  bool _campusReadInFlight = false;
  KnowledgeReadPort? _knowledgeReadPort;
  PublicReference? _knowledgeReadReference;
  int? _knowledgeReadSectionStart;
  int? _knowledgeReadMaxCharacters;
  PublicCursor? _knowledgeReadNext;
  int _knowledgeReadEpoch = 0;
  PublicQueryResult? _courseResults;
  PublicQueryResult? _courseDocument;
  PublicQueryResult? _campusResults;
  PublicQueryResult? _campusDocument;
  PublicQueryResult? _knowledgeResults;
  PublicQueryResult? _knowledgeDocument;
  PublicCoverage? _lastCoverage;
  PublicFailureCode? _courseFailure;
  PublicFailureCode? _campusFailure;
  PublicFailureCode? _knowledgeFailure;
  PublicFailureCode? _sourceActionFailure;
  String? _courseNotice;
  String? _campusNotice;
  String? _knowledgeNotice;
  String? _citationNotice;
  bool _sourcePending = false;
  bool _sourceCancelPending = false;
  bool _knowledgeInspectPending = false;
  bool _loadInFlight = false;
  bool _loadOutcomeReceived = false;
  bool _cancelLoadPending = false;
  bool _clearPromptPending = false;
  bool _clearPending = false;
  bool _copyPending = false;
  int _viewEpoch = 0;
  int _knowledgeQueryEpoch = 0;

  @override
  void initState() {
    super.initState();
    _job = widget.queries.view;
    _subscribe();
    unawaited(_inspectKnowledge());
  }

  @override
  void didUpdateWidget(covariant PublicValidationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.queries == widget.queries &&
        oldWidget.knowledge == widget.knowledge) {
      return;
    }
    _viewEpoch++;
    final subscription = _querySubscription;
    _querySubscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    _job = widget.queries.view;
    _sourcePending = false;
    _sourceCancelPending = false;
    _loadInFlight = false;
    _clearResults();
    _subscribe();
    unawaited(_inspectKnowledge());
  }

  void _subscribe() {
    final epoch = _viewEpoch;
    _querySubscription = widget.queries.changes.listen(
      (view) {
        if (mounted && epoch == _viewEpoch) {
          setState(() {
            _job = view;
            if (view.busy &&
                !_campusReadInFlight &&
                _campusReadReference != null) {
              _discardCampusRead();
            }
          });
        }
      },
      onError: (Object _) {
        if (mounted && epoch == _viewEpoch) {
          setState(() => _sourceActionFailure = PublicFailureCode.sourceSchema);
        }
      },
    );
  }

  @override
  void dispose() {
    _viewEpoch++;
    final subscription = _querySubscription;
    if (subscription != null) unawaited(subscription.cancel());
    _courseKeyword.dispose();
    _campusKeyword.dispose();
    _knowledgeKeyword.dispose();
    _knowledgeTopic.dispose();
    _knowledgeAudience.dispose();
    _knowledgeVersion.dispose();
    super.dispose();
  }

  bool get _sourceBusy => _job.busy || _sourcePending;

  void _clearResults() {
    _courseResults = null;
    _courseDocument = null;
    _campusResults = null;
    _knowledgeResults = null;
    _selectedCourse = null;
    _lastCoverage = null;
    _discardCampusRead();
    _discardKnowledgeRead();
    _knowledgeQueryEpoch++;
  }

  void _discardCampusRead() {
    _campusReadEpoch++;
    _campusReadPort = null;
    _campusReadReference = null;
    _campusReadSectionStart = null;
    _campusReadMaxCharacters = null;
    _campusReadNext = null;
    _campusReadInFlight = false;
    _campusDocument = null;
  }

  void _discardKnowledgeRead() {
    _knowledgeReadEpoch++;
    _knowledgeReadPort = null;
    _knowledgeReadReference = null;
    _knowledgeReadSectionStart = null;
    _knowledgeReadMaxCharacters = null;
    _knowledgeReadNext = null;
    _knowledgeDocument = null;
  }

  void _invalidateCourseQuery(String value) {
    if (_courseQuery == null || value.trim() == _courseQuery) return;
    setState(() {
      _courseQuery = null;
      _courseResults = null;
      _courseDocument = null;
      _selectedCourse = null;
    });
  }

  void _invalidateCampusQuery() {
    if (_campusQueryColumn == null &&
        _campusQuery == null &&
        _campusResults == null &&
        _campusReadReference == null) {
      return;
    }
    setState(() {
      _campusQueryColumn = null;
      _campusQuery = null;
      _campusResults = null;
      _discardCampusRead();
    });
  }

  void _invalidateKnowledgeQuery() {
    if (_knowledgeQuery == null &&
        _knowledgeResults == null &&
        _knowledgeReadReference == null) {
      return;
    }
    _knowledgeQueryEpoch++;
    setState(() {
      _knowledgeQuery = null;
      _knowledgeResults = null;
      _discardKnowledgeRead();
    });
  }

  PublicFailureCode _failureCode(Object error, PublicFailureCode fallback) =>
      error is PublicFailure ? error.code : fallback;

  Future<void> _searchCourses() async {
    if (_sourceBusy) return;
    late final String keyword;
    try {
      keyword = publicKeywords(_courseKeyword.text);
    } on PublicFailure catch (failure) {
      setState(() {
        _courseFailure = failure.code;
        _courseNotice = null;
      });
      return;
    }
    setState(() {
      _sourcePending = true;
      _courseFailure = null;
      _courseNotice = null;
      _courseResults = null;
      _courseDocument = null;
      _selectedCourse = null;
      _courseQuery = keyword;
      _discardCampusRead();
    });
    try {
      var allowed = await widget.queries.hasIcourseConsent();
      if (!mounted) return;
      if (!allowed) {
        allowed =
            await showDialog<bool>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: const Text('首次评课公开查询授权'),
                content: const Text(
                  '继续后，当前输入的课程或教师关键词会发送给评课公开来源。无需输入学号、密码或 Key。',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('暂不授权'),
                  ),
                  FilledButton(
                    key: const ValueKey('public-validation-course-consent'),
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: const Text('授权并继续'),
                  ),
                ],
              ),
            ) ??
            false;
        if (!allowed) {
          if (mounted) {
            setState(() => _courseNotice = '本次未授权，未发送评课查询。');
          }
          return;
        }
        if (!mounted) return;
        await widget.queries.setIcourseConsent(true);
        if (!mounted) return;
      }
      final result = await widget.queries.searchCourses(keyword);
      if (mounted) {
        setState(() {
          _courseResults = result;
          _lastCoverage = result.coverage;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _courseFailure = _failureCode(error, PublicFailureCode.networkFailed);
        });
      }
    } finally {
      if (mounted) setState(() => _sourcePending = false);
    }
  }

  Future<void> _nextCoursePage() async {
    final result = _courseResults;
    final cursor = result?.next;
    final keyword = _courseQuery;
    if (_sourceBusy || cursor == null || keyword == null) return;
    await _sourceQuery(
      action: () => widget.queries.searchCourses(keyword, cursor: cursor),
      onFailure: (code) => _courseFailure = code,
      onSuccess: (value) {
        _courseResults = value;
        _lastCoverage = value.coverage;
      },
    );
  }

  Future<void> _readCourse(
    PublicCandidate candidate, {
    PublicCursor? cursor,
  }) async {
    if (_sourceBusy) return;
    setState(() {
      if (!identical(_selectedCourse, candidate)) {
        _selectedCourse = candidate;
        _courseTerm = null;
        _courseSort = CourseReviewSort.upvote;
      }
      _courseDocument = null;
      _courseFailure = null;
    });
    await _sourceQuery(
      action: () => widget.queries.readCourse(
        candidate.reference,
        term: _courseTerm,
        sort: _courseSort,
        cursor: cursor,
      ),
      onFailure: (code) => _courseFailure = code,
      onSuccess: (value) {
        _courseDocument = value;
        _lastCoverage = value.coverage;
      },
    );
  }

  Future<void> _browseCampus({PublicCursor? cursor}) async {
    if (_sourceBusy) return;
    final column = cursor == null
        ? _campusColumn
        : (_campusQueryColumn ?? _campusColumn);
    final typedKeyword = cursor == null
        ? _campusKeyword.text.trim()
        : (_campusQuery ?? '');
    final teachingColumn =
        column == CampusColumn.teachNotice ||
        column == CampusColumn.teachStudentService;
    if (!teachingColumn && typedKeyword.isNotEmpty) {
      setState(() {
        _campusFailure = PublicFailureCode.unavailable;
        _campusNotice = '财务栏目来源关键词检索当前不可用（unavailable）。请清空关键词后浏览固定栏目。';
        _campusResults = null;
        _discardCampusRead();
      });
      return;
    }
    if (teachingColumn && typedKeyword.isNotEmpty) {
      try {
        publicKeywords(typedKeyword);
      } on PublicFailure catch (failure) {
        setState(() {
          _campusFailure = failure.code;
          _campusNotice = null;
          _campusResults = null;
          _discardCampusRead();
        });
        return;
      }
    }
    final keyword = teachingColumn && typedKeyword.isNotEmpty
        ? typedKeyword
        : null;
    setState(() {
      _campusFailure = null;
      _campusNotice = null;
      if (cursor == null) {
        _campusQueryColumn = column;
        _campusQuery = keyword;
        _campusResults = null;
        _discardCampusRead();
      }
    });
    await _sourceQuery(
      action: () => widget.queries.browseCampus(
        column,
        keywords: keyword,
        cursor: cursor,
      ),
      onFailure: (code) => _campusFailure = code,
      onSuccess: (value) {
        _campusResults = value;
        _lastCoverage = value.coverage;
      },
    );
  }

  Future<void> _readCampusArticle(PublicCandidate candidate) async {
    await _readCampusArticleRange(
      port: widget.queries,
      reference: candidate.reference,
      sectionStart: _documentStart,
      maxCharacters: _maxDocumentCharacters,
    );
  }

  Future<void> _continueCampusArticle() async {
    final port = _campusReadPort;
    final reference = _campusReadReference;
    final sectionStart = _campusReadSectionStart;
    final maxCharacters = _campusReadMaxCharacters;
    final cursor = _campusReadNext;
    if (_sourceBusy ||
        port == null ||
        reference == null ||
        sectionStart == null ||
        maxCharacters == null ||
        cursor == null) {
      return;
    }
    if (!identical(port, widget.queries)) {
      setState(_discardCampusRead);
      return;
    }
    await _readCampusArticleRange(
      port: port,
      reference: reference,
      sectionStart: sectionStart,
      maxCharacters: maxCharacters,
      cursor: cursor,
    );
  }

  Future<void> _readCampusArticleRange({
    required PublicQueryPort port,
    required PublicReference reference,
    required int sectionStart,
    required int maxCharacters,
    PublicCursor? cursor,
  }) async {
    if (_sourceBusy) return;
    final readEpoch = ++_campusReadEpoch;
    setState(() {
      _campusReadPort = port;
      _campusReadReference = reference;
      _campusReadSectionStart = sectionStart;
      _campusReadMaxCharacters = maxCharacters;
      _campusReadNext = null;
      _campusReadInFlight = true;
      _campusFailure = null;
      _campusNotice = null;
      _campusDocument = null;
    });
    await _sourceQuery(
      preserveCampusRead: true,
      action: () => port.readCampusArticle(
        reference,
        sectionStart: sectionStart,
        maxCharacters: maxCharacters,
        cursor: cursor,
      ),
      onFailure: (code) {
        if (readEpoch != _campusReadEpoch) return;
        _campusFailure = code;
        _campusReadPort = null;
        _campusReadReference = null;
        _campusReadSectionStart = null;
        _campusReadMaxCharacters = null;
        _campusReadNext = null;
        _campusReadInFlight = false;
      },
      onSuccess: (value) {
        if (readEpoch != _campusReadEpoch) return;
        _campusDocument = value;
        _campusReadNext = value.next;
        _campusReadInFlight = false;
        _lastCoverage = value.coverage;
      },
    );
  }

  Future<void> _searchKnowledge({PublicCursor? cursor}) async {
    late final String keyword;
    try {
      keyword = cursor == null
          ? publicKeywords(_knowledgeKeyword.text)
          : (_knowledgeQuery ?? publicKeywords(_knowledgeKeyword.text));
    } on PublicFailure catch (failure) {
      setState(() {
        _knowledgeFailure = failure.code;
        _knowledgeNotice = null;
      });
      return;
    }
    final provider = cursor == null
        ? _knowledgeProvider
        : _knowledgeQueryProvider;
    final topic = cursor == null
        ? _optionalFilter(_knowledgeTopic.text)
        : _knowledgeQueryTopic;
    final audience = cursor == null
        ? _optionalFilter(_knowledgeAudience.text)
        : _knowledgeQueryAudience;
    final version = cursor == null
        ? _optionalFilter(_knowledgeVersion.text)
        : _knowledgeQueryVersion;
    final queryEpoch = ++_knowledgeQueryEpoch;
    setState(() {
      _knowledgeFailure = null;
      _knowledgeNotice = null;
      _discardKnowledgeRead();
      if (cursor == null) {
        _knowledgeQuery = keyword;
        _knowledgeQueryProvider = provider;
        _knowledgeQueryTopic = topic;
        _knowledgeQueryAudience = audience;
        _knowledgeQueryVersion = version;
        _knowledgeResults = null;
      }
    });
    try {
      final result = await widget.knowledge.searchKnowledge(
        keyword,
        provider: provider,
        topic: topic,
        audience: audience,
        version: version,
        cursor: cursor,
      );
      if (mounted && queryEpoch == _knowledgeQueryEpoch) {
        setState(() {
          _knowledgeResults = result;
          _lastCoverage = result.coverage;
        });
      }
    } catch (error) {
      if (mounted && queryEpoch == _knowledgeQueryEpoch) {
        setState(() {
          _knowledgeFailure = _failureCode(
            error,
            PublicFailureCode.storageFailed,
          );
          _knowledgeResults = null;
        });
      }
    }
  }

  Future<void> _nextKnowledgePage() async {
    final next = _knowledgeResults?.next;
    if (next != null && _knowledgeQuery != null) {
      await _searchKnowledge(cursor: next);
    }
  }

  String? _optionalFilter(String value) {
    final normalized = value.trim();
    return normalized.isEmpty ? null : normalized;
  }

  Future<void> _readKnowledgeMaterial(PublicCandidate candidate) async {
    await _readKnowledgeMaterialRange(
      port: widget.knowledge,
      reference: candidate.reference,
      sectionStart: _documentStart,
      maxCharacters: _maxDocumentCharacters,
    );
  }

  Future<void> _continueKnowledgeMaterial() async {
    final port = _knowledgeReadPort;
    final reference = _knowledgeReadReference;
    final sectionStart = _knowledgeReadSectionStart;
    final maxCharacters = _knowledgeReadMaxCharacters;
    final cursor = _knowledgeReadNext;
    if (port == null ||
        reference == null ||
        sectionStart == null ||
        maxCharacters == null ||
        cursor == null) {
      return;
    }
    if (!identical(port, widget.knowledge)) {
      setState(_discardKnowledgeRead);
      return;
    }
    await _readKnowledgeMaterialRange(
      port: port,
      reference: reference,
      sectionStart: sectionStart,
      maxCharacters: maxCharacters,
      cursor: cursor,
    );
  }

  Future<void> _readKnowledgeMaterialRange({
    required KnowledgeReadPort port,
    required PublicReference reference,
    required int sectionStart,
    required int maxCharacters,
    PublicCursor? cursor,
  }) async {
    final readEpoch = ++_knowledgeReadEpoch;
    final queryEpoch = ++_knowledgeQueryEpoch;
    setState(() {
      _knowledgeReadPort = port;
      _knowledgeReadReference = reference;
      _knowledgeReadSectionStart = sectionStart;
      _knowledgeReadMaxCharacters = maxCharacters;
      _knowledgeReadNext = null;
      _knowledgeFailure = null;
      _knowledgeNotice = null;
      _knowledgeDocument = null;
    });
    try {
      final result = await port.readKnowledgeMaterial(
        reference,
        sectionStart: sectionStart,
        maxCharacters: maxCharacters,
        cursor: cursor,
      );
      if (mounted &&
          readEpoch == _knowledgeReadEpoch &&
          queryEpoch == _knowledgeQueryEpoch &&
          identical(port, widget.knowledge)) {
        setState(() {
          _knowledgeDocument = result;
          _knowledgeReadNext = result.next;
          _lastCoverage = result.coverage;
        });
      }
    } catch (error) {
      if (mounted &&
          readEpoch == _knowledgeReadEpoch &&
          queryEpoch == _knowledgeQueryEpoch) {
        setState(() {
          _knowledgeFailure = _failureCode(
            error,
            PublicFailureCode.storageFailed,
          );
          _knowledgeReadPort = null;
          _knowledgeReadReference = null;
          _knowledgeReadSectionStart = null;
          _knowledgeReadMaxCharacters = null;
          _knowledgeReadNext = null;
        });
      }
    }
  }

  Future<void> _sourceQuery({
    required Future<PublicQueryResult> Function() action,
    required void Function(PublicQueryResult) onSuccess,
    required void Function(PublicFailureCode) onFailure,
    bool preserveCampusRead = false,
  }) async {
    if (_sourceBusy) return;
    setState(() {
      if (!preserveCampusRead) _discardCampusRead();
      _sourcePending = true;
      _sourceActionFailure = null;
    });
    try {
      final result = await action();
      if (mounted) setState(() => onSuccess(result));
    } catch (error) {
      if (mounted) {
        setState(
          () => onFailure(_failureCode(error, PublicFailureCode.networkFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => _sourcePending = false);
    }
  }

  Future<void> _sourceCommand(Future<void> Function() action) async {
    setState(() {
      _sourcePending = true;
      _sourceActionFailure = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() {
          _sourceActionFailure = _failureCode(
            error,
            PublicFailureCode.cleanupPending,
          );
        });
      }
    } finally {
      if (mounted) setState(() => _sourcePending = false);
    }
  }

  Future<void> _cancelSource() async {
    if (!_job.busy ||
        _job.phase == PublicJobPhase.recovery ||
        _job.phase == PublicJobPhase.closed ||
        _sourceCancelPending) {
      return;
    }
    setState(() {
      _sourceCancelPending = true;
      if (_campusReadInFlight) _discardCampusRead();
    });
    try {
      await _sourceCommand(widget.queries.cancel);
    } finally {
      if (mounted) setState(() => _sourceCancelPending = false);
    }
  }

  Future<void> _retryRecovery() async {
    if (_job.phase != PublicJobPhase.recovery || _sourcePending) return;
    await _sourceCommand(widget.queries.retryRecovery);
  }

  Future<void> _inspectKnowledge() async {
    final epoch = _viewEpoch;
    setState(() => _knowledgeInspectPending = true);
    try {
      final summary = await widget.knowledge.inspectKnowledge();
      if (mounted && epoch == _viewEpoch) {
        setState(() {
          _knowledgeSummary = summary;
          _knowledgeFailure = null;
        });
      }
    } catch (error) {
      if (mounted && epoch == _viewEpoch) {
        setState(() {
          _knowledgeFailure = _failureCode(
            error,
            PublicFailureCode.storageFailed,
          );
        });
      }
    } finally {
      if (mounted && epoch == _viewEpoch) {
        setState(() => _knowledgeInspectPending = false);
      }
    }
  }

  Future<void> _loadKnowledge() async {
    if (_loadInFlight) return;
    setState(() {
      _loadInFlight = true;
      _loadOutcomeReceived = false;
      _knowledgeFailure = null;
      _knowledgeNotice = null;
    });
    try {
      final outcome = await widget.knowledge.loadBundledEdition();
      if (!mounted) return;
      setState(() {
        _loadOutcomeReceived = true;
        _knowledgeNotice = switch (outcome.state) {
          KnowledgeLoadState.done =>
            '首批清单载入结束：接受 ${outcome.accepted} 项，未变化 ${outcome.unchanged} 项，共 ${outcome.total} 项。',
          KnowledgeLoadState.cancelled => '首批清单载入已取消；已接受与未提交项目以端口回执为准。',
          KnowledgeLoadState.failed => null,
        };
        if (outcome.state == KnowledgeLoadState.failed) {
          _knowledgeFailure =
              outcome.failure ?? PublicFailureCode.storageFailed;
        }
      });
      await _inspectKnowledge();
    } catch (error) {
      if (mounted) {
        setState(() {
          _knowledgeFailure = _failureCode(
            error,
            PublicFailureCode.storageFailed,
          );
        });
      }
    } finally {
      if (mounted) setState(() => _loadInFlight = false);
    }
  }

  Future<void> _cancelKnowledgeLoad() async {
    if (!_loadInFlight || _cancelLoadPending) return;
    setState(() {
      _cancelLoadPending = true;
      _knowledgeFailure = null;
      _knowledgeNotice = null;
    });
    try {
      await widget.knowledge.cancelKnowledgeLoad();
      if (mounted && _loadInFlight && !_loadOutcomeReceived) {
        setState(() => _knowledgeNotice = '已请求取消首批清单载入。');
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _knowledgeFailure = _failureCode(
            error,
            PublicFailureCode.storageFailed,
          );
        });
      }
    } finally {
      if (mounted) setState(() => _cancelLoadPending = false);
    }
  }

  Future<void> _clearKnowledge() async {
    if (_clearPromptPending || _clearPending) return;
    setState(() => _clearPromptPending = true);
    final first =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('清除本地知识库？'),
            content: const Text('这会清除已载入的精选公开文本与索引，不会清除学校日程、密码或来源目录。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('继续'),
              ),
            ],
          ),
        ) ??
        false;
    if (!first || !mounted) {
      if (mounted) setState(() => _clearPromptPending = false);
      return;
    }
    final second =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('再次确认清除知识库'),
            content: const Text('再次确认清除。清理后不会自动从随包清单重建。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('保留知识库'),
              ),
              FilledButton(
                key: const ValueKey('public-validation-clear-confirm'),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('确认清除'),
              ),
            ],
          ),
        ) ??
        false;
    if (!second || !mounted || _clearPending) {
      if (mounted) setState(() => _clearPromptPending = false);
      return;
    }
    setState(() {
      _clearPending = true;
      _knowledgeFailure = null;
      _knowledgeNotice = null;
      _knowledgeQueryEpoch++;
      _discardKnowledgeRead();
      _knowledgeResults = null;
    });
    try {
      await widget.knowledge.clearKnowledge(confirmed: true);
      if (!mounted) return;
      setState(() {
        _knowledgeNotice = '知识库清理请求已完成。';
        _knowledgeResults = null;
        _knowledgeDocument = null;
      });
      await _inspectKnowledge();
    } catch (error) {
      if (mounted) {
        setState(() {
          _knowledgeFailure = _failureCode(
            error,
            PublicFailureCode.storageFailed,
          );
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _clearPending = false;
          _clearPromptPending = false;
        });
      }
    }
  }

  Future<void> _copySummary() async {
    if (_copyPending) return;
    final coverage = _lastCoverage;
    final summary = <String, Object?>{
      'kind': 'public-query-validation-v1',
      'stage': _job.phase.name,
      'fixedFailure':
          (_job.failure ??
                  _sourceActionFailure ??
                  _courseFailure ??
                  _campusFailure ??
                  _knowledgeFailure)
              ?.name,
      'source': <String, Object?>{
        'returned': _job.returned,
        'coverageReturned': coverage?.returned ?? 0,
        'observed': coverage?.observed,
        'totalReported': coverage?.totalReported,
        'excluded': coverage?.excluded ?? 0,
        'truncated': coverage?.truncated ?? false,
        'complete': coverage?.complete ?? false,
      },
      'knowledge': <String, Object?>{
        'materials': _knowledgeSummary.materialCount,
        'sections': _knowledgeSummary.sectionCount,
        'loads': _knowledgeSummary.loadCount,
        'loading': _loadInFlight || _knowledgeSummary.loading,
      },
    };
    setState(() => _copyPending = true);
    try {
      await Clipboard.setData(ClipboardData(text: jsonEncode(summary)));
      if (mounted) setState(() => _citationNotice = '已复制安全验收摘要。');
    } catch (_) {
      if (mounted) setState(() => _citationNotice = '复制安全验收摘要失败。');
    } finally {
      if (mounted) setState(() => _copyPending = false);
    }
  }

  bool _safeHttps(Uri uri) =>
      uri.scheme.toLowerCase() == 'https' &&
      uri.hasAuthority &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(uri.toString());

  Future<void> _showCitation(Uri uri) async {
    if (!_safeHttps(uri)) {
      if (mounted) setState(() => _citationNotice = '该链接不是可复制的 HTTPS 出处。');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('公开出处链接'),
        content: SelectableText(uri.toString()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () async {
              try {
                await Clipboard.setData(ClipboardData(text: uri.toString()));
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                if (mounted) {
                  setState(() => _citationNotice = '已复制 HTTPS 出处链接。');
                }
              } catch (_) {
                if (mounted) setState(() => _citationNotice = '复制出处链接失败。');
              }
            },
            child: const Text('复制链接'),
          ),
        ],
      ),
    );
  }

  void _onMarkdownLink(String text, String? href, String title) {
    final uri = href == null ? null : Uri.tryParse(href);
    if (uri == null) {
      setState(() => _citationNotice = '该链接不是可复制的 HTTPS 出处。');
      return;
    }
    unawaited(_showCitation(uri));
  }

  Widget _blockedImage(Uri uri, String? title, String? alt) => Container(
    key: const ValueKey('public-validation-blocked-image'),
    margin: const EdgeInsets.symmetric(vertical: 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(alt == null || alt.isEmpty ? '图片已阻止自动加载' : '图片已阻止自动加载：$alt'),
  );

  String _providerLabel(PublicProvider provider) => switch (provider) {
    PublicProvider.icourse => '评课',
    PublicProvider.teach => '教务',
    PublicProvider.finance => '财务',
  };

  String _qualityLabel(EvidenceQuality quality) => switch (quality) {
    EvidenceQuality.parsedSource => '来源解析稿',
    EvidenceQuality.reviewedContent => '已校核内容',
  };

  String _columnLabel(CampusColumn column) => switch (column) {
    CampusColumn.teachNotice => '教务通知',
    CampusColumn.teachStudentService => '教务学生事务',
    CampusColumn.financeNotice => '财务通知',
    CampusColumn.financeBusiness => '财务业务指南',
    CampusColumn.financeProcess => '财务流程指南',
    CampusColumn.financeOperation => '财务操作指南',
    CampusColumn.financeFaq => '财务常见问题',
  };

  String _sortLabel(CourseReviewSort sort) => switch (sort) {
    CourseReviewSort.upvote => '来源排序：赞同数',
    CourseReviewSort.newest => '来源排序：最新',
    CourseReviewSort.oldest => '来源排序：最早',
    CourseReviewSort.scoreDescending => '来源排序：评分降序',
    CourseReviewSort.scoreAscending => '来源排序：评分升序',
  };

  String _failureDescription(PublicFailureCode code) => switch (code) {
    PublicFailureCode.invalidRequest => '输入范围无效。',
    PublicFailureCode.busy => '当前来源忙碌，请等待收口。',
    PublicFailureCode.consentRequired => '需要先完成公开查询授权。',
    PublicFailureCode.cancelled => '本次操作已取消。',
    PublicFailureCode.staleReference => '引用已失效，请重新检索。',
    PublicFailureCode.unavailable => '该能力当前不可用。',
    PublicFailureCode.accessRestricted => '来源访问受限。',
    PublicFailureCode.campusOnly => '该来源要求校园网络。',
    PublicFailureCode.networkFailed => '网络请求失败。',
    PublicFailureCode.sourceSchema => '来源结构未能核对。',
    PublicFailureCode.unsafeTarget => '来源目标未通过安全校验。',
    PublicFailureCode.resourceLimit => '达到本次资源范围上限。',
    PublicFailureCode.storageFailed => '本地知识操作失败。',
    PublicFailureCode.cleanupPending => '公开查询资源收口待恢复。',
    PublicFailureCode.closed => '端口已关闭。',
  };

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      padding: EdgeInsets.symmetric(
        horizontal: constraints.maxWidth < 560 ? 12 : 20,
        vertical: 12,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(constraints.maxWidth < 560 ? 16 : 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '临时验收：公开查询与精选文本',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text('只用于核对内部端口、出处、覆盖和本地材料；不是正式搜索入口，不调用 Agent 或模型。'),
                  const SizedBox(height: 12),
                  _sourceStatus(),
                  const SizedBox(height: 18),
                  _courseSection(),
                  const Divider(height: 28),
                  _campusSection(),
                  const Divider(height: 28),
                  _knowledgeSection(),
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    key: const ValueKey('public-validation-copy-summary'),
                    onPressed: _copyPending ? null : _copySummary,
                    icon: const Icon(Icons.copy_outlined),
                    label: const Text('复制安全验收摘要'),
                  ),
                  if (_citationNotice != null) Text(_citationNotice!),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _sourceStatus() {
    final phase = switch (_job.phase) {
      PublicJobPhase.idle => '公开来源空闲',
      PublicJobPhase.requesting => '公开来源查询中',
      PublicJobPhase.settling => '公开来源正在收口',
      PublicJobPhase.recovery => '公开来源正在恢复；新在线查询保持忙碌',
      PublicJobPhase.closed => '公开查询端口已关闭',
    };
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(phase, key: const ValueKey('public-validation-source-state')),
            if (_job.failure != null) Text('公开查询失败码：${_job.failure!.name}'),
            if (_sourceActionFailure != null)
              Text('收口操作失败码：${_sourceActionFailure!.name}'),
            if (_job.phase == PublicJobPhase.recovery)
              FilledButton(
                key: const ValueKey('public-validation-retry-recovery'),
                onPressed: _sourcePending ? null : _retryRecovery,
                child: const Text('重试公开查询收口'),
              )
            else if (_job.busy && _job.phase != PublicJobPhase.closed)
              OutlinedButton(
                key: const ValueKey('public-validation-cancel-source'),
                onPressed: _sourceCancelPending ? null : _cancelSource,
                child: Text(_sourceCancelPending ? '正在取消公开查询' : '取消当前公开查询'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _failure(PublicFailureCode code) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Text(
      '请求失败码：${code.name}。 ${_failureDescription(code)}',
      key: ValueKey('public-validation-failure-${code.name}'),
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  );

  Widget _courseSection() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('评课公开查询', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      const Text('首次联网前会单独询问授权；这里只输入课程或教师关键词。'),
      const SizedBox(height: 8),
      TextField(
        key: const ValueKey('public-validation-course-keyword'),
        controller: _courseKeyword,
        enabled: !_sourceBusy,
        onChanged: _invalidateCourseQuery,
        decoration: const InputDecoration(
          labelText: '课程或教师关键词',
          border: OutlineInputBorder(),
        ),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton(
          key: const ValueKey('public-validation-course-search'),
          onPressed: _sourceBusy ? null : _searchCourses,
          child: const Text('查询评课'),
        ),
      ),
      if (_courseFailure != null) _failure(_courseFailure!),
      if (_courseNotice != null) Text(_courseNotice!),
      if (_courseResults != null)
        _candidateList(
          title: '评课候选',
          result: _courseResults!,
          prefix: 'course',
          onRead: (candidate) => _readCourse(candidate),
        ),
      if (_courseResults?.next != null)
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            key: const ValueKey('public-validation-course-next'),
            onPressed: _sourceBusy ? null : _nextCoursePage,
            child: const Text('读取评课候选下一页'),
          ),
        ),
      if (_courseResults != null && _courseResults!.candidates.isEmpty)
        const Text('本次查询返回合法空结果。'),
      if (_selectedCourse != null) ...[
        _courseFilters(),
        if (_courseDocument != null)
          _documentResult(_courseDocument!, label: '课程信息与公开点评'),
      ],
    ],
  );

  Widget _courseFilters() {
    final terms = _selectedCourse?.course?.terms ?? const <PublicTerm>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('已选候选：${_selectedCourse!.title}'),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            DropdownButton<String>(
              key: const ValueKey('public-validation-course-term'),
              value: _courseTerm ?? '',
              items: [
                const DropdownMenuItem(value: '', child: Text('全部来源学期')),
                ...terms.map(
                  (term) => DropdownMenuItem(
                    value: term.code,
                    child: Text(term.label),
                  ),
                ),
              ],
              onChanged: _sourceBusy
                  ? null
                  : (value) {
                      setState(
                        () => _courseTerm = value == null || value.isEmpty
                            ? null
                            : value,
                      );
                      unawaited(_readCourse(_selectedCourse!));
                    },
            ),
            DropdownButton<CourseReviewSort>(
              key: const ValueKey('public-validation-course-sort'),
              value: _courseSort,
              items: CourseReviewSort.values
                  .map(
                    (sort) => DropdownMenuItem(
                      value: sort,
                      child: Text(_sortLabel(sort)),
                    ),
                  )
                  .toList(growable: false),
              onChanged: _sourceBusy
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() => _courseSort = value);
                      unawaited(_readCourse(_selectedCourse!));
                    },
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            key: const ValueKey('public-validation-course-read'),
            onPressed: _sourceBusy ? null : () => _readCourse(_selectedCourse!),
            child: const Text('读取课程与点评'),
          ),
        ),
        if (_courseDocument?.next != null)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              key: const ValueKey('public-validation-course-review-next'),
              onPressed: _sourceBusy
                  ? null
                  : () => _readCourse(
                      _selectedCourse!,
                      cursor: _courseDocument!.next,
                    ),
              child: const Text('读取点评下一页'),
            ),
          ),
      ],
    );
  }

  Widget _campusSection() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('校园固定栏目', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      DropdownButtonFormField<CampusColumn>(
        key: const ValueKey('public-validation-campus-column'),
        initialValue: _campusColumn,
        items: CampusColumn.values
            .map(
              (column) => DropdownMenuItem(
                value: column,
                child: Text(_columnLabel(column)),
              ),
            )
            .toList(growable: false),
        onChanged: _sourceBusy
            ? null
            : (value) {
                if (value != null && value != _campusColumn) {
                  setState(() {
                    _campusColumn = value;
                    _campusQueryColumn = null;
                    _campusQuery = null;
                    _campusResults = null;
                    _discardCampusRead();
                  });
                }
              },
      ),
      TextField(
        key: const ValueKey('public-validation-campus-keyword'),
        controller: _campusKeyword,
        enabled: !_sourceBusy,
        onChanged: (_) => _invalidateCampusQuery(),
        decoration: const InputDecoration(
          labelText: '教务栏目关键词（财务栏目不支持）',
          border: OutlineInputBorder(),
        ),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton(
          key: const ValueKey('public-validation-campus-browse'),
          onPressed: _sourceBusy ? null : _browseCampus,
          child: const Text('浏览固定栏目'),
        ),
      ),
      if (_campusFailure != null) _failure(_campusFailure!),
      if (_campusNotice != null) Text(_campusNotice!),
      if (_campusResults != null)
        _candidateList(
          title: '栏目条目',
          result: _campusResults!,
          prefix: 'campus',
          onRead: (candidate) => _readCampusArticle(candidate),
        ),
      if (_campusResults?.next != null)
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            key: const ValueKey('public-validation-campus-next'),
            onPressed: _sourceBusy
                ? null
                : () => _browseCampus(cursor: _campusResults!.next),
            child: const Text('读取栏目下一页'),
          ),
        ),
      if (_campusResults != null && _campusResults!.candidates.isEmpty)
        const Text('本次栏目读取返回合法空结果。'),
      if (_campusDocument != null)
        _documentResult(_campusDocument!, label: '校园文章正文'),
      if (_campusReadNext != null &&
          _campusReadReference != null &&
          identical(_campusReadPort, widget.queries))
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            key: const ValueKey('public-validation-campus-document-next'),
            onPressed: _sourceBusy ? null : _continueCampusArticle,
            child: const Text('继续读取正文'),
          ),
        ),
    ],
  );

  Widget _knowledgeSection() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('本地精选知识材料', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      Text(
        _knowledgeInspectPending
            ? '正在读取知识库状态。'
            : '材料 ${_knowledgeSummary.materialCount} 项；片段 ${_knowledgeSummary.sectionCount} 项；载入 ${_knowledgeSummary.loadCount} 次。',
      ),
      Wrap(
        spacing: 10,
        runSpacing: 8,
        children: [
          FilledButton(
            key: const ValueKey('public-validation-knowledge-load'),
            onPressed: _loadInFlight ? null : _loadKnowledge,
            child: Text(_loadInFlight ? '首批清单载入中' : '载入首批清单'),
          ),
          if (_loadInFlight)
            OutlinedButton(
              key: const ValueKey('public-validation-knowledge-cancel-load'),
              onPressed: _cancelLoadPending ? null : _cancelKnowledgeLoad,
              child: Text(_cancelLoadPending ? '正在请求取消' : '取消载入'),
            ),
          OutlinedButton(
            key: const ValueKey('public-validation-knowledge-clear'),
            onPressed: _clearPending || _clearPromptPending
                ? null
                : _clearKnowledge,
            child: const Text('清除知识库'),
          ),
        ],
      ),
      TextField(
        key: const ValueKey('public-validation-knowledge-keyword'),
        controller: _knowledgeKeyword,
        onChanged: (_) => _invalidateKnowledgeQuery(),
        decoration: const InputDecoration(
          labelText: '本地关键词',
          border: OutlineInputBorder(),
        ),
      ),
      Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          DropdownButton<PublicProvider?>(
            key: const ValueKey('public-validation-knowledge-provider'),
            value: _knowledgeProvider,
            hint: const Text('全部提供方'),
            items: [
              const DropdownMenuItem<PublicProvider?>(
                value: null,
                child: Text('全部提供方'),
              ),
              ...PublicProvider.values.map(
                (provider) => DropdownMenuItem<PublicProvider?>(
                  value: provider,
                  child: Text(_providerLabel(provider)),
                ),
              ),
            ],
            onChanged: (value) {
              setState(() => _knowledgeProvider = value);
              _invalidateKnowledgeQuery();
            },
          ),
          SizedBox(
            width: 150,
            child: TextField(
              key: const ValueKey('public-validation-knowledge-topic'),
              controller: _knowledgeTopic,
              onChanged: (_) => _invalidateKnowledgeQuery(),
              decoration: const InputDecoration(labelText: '主题筛选'),
            ),
          ),
          SizedBox(
            width: 150,
            child: TextField(
              key: const ValueKey('public-validation-knowledge-audience'),
              controller: _knowledgeAudience,
              onChanged: (_) => _invalidateKnowledgeQuery(),
              decoration: const InputDecoration(labelText: '人群筛选'),
            ),
          ),
          SizedBox(
            width: 150,
            child: TextField(
              key: const ValueKey('public-validation-knowledge-version'),
              controller: _knowledgeVersion,
              onChanged: (_) => _invalidateKnowledgeQuery(),
              decoration: const InputDecoration(labelText: '版本筛选'),
            ),
          ),
        ],
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton(
          key: const ValueKey('public-validation-knowledge-search'),
          onPressed: _searchKnowledge,
          child: const Text('检索本地片段'),
        ),
      ),
      if (_knowledgeFailure != null) _failure(_knowledgeFailure!),
      if (_knowledgeNotice != null) Text(_knowledgeNotice!),
      if (_knowledgeResults != null)
        _candidateList(
          title: '本地匹配片段',
          result: _knowledgeResults!,
          prefix: 'knowledge',
          onRead: (candidate) => _readKnowledgeMaterial(candidate),
        ),
      if (_knowledgeResults?.next != null)
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            key: const ValueKey('public-validation-knowledge-next'),
            onPressed: _nextKnowledgePage,
            child: const Text('读取本地结果下一页'),
          ),
        ),
      if (_knowledgeResults != null && _knowledgeResults!.candidates.isEmpty)
        const Text('本次本地检索返回合法空结果。'),
      if (_knowledgeDocument != null)
        _documentResult(_knowledgeDocument!, label: '有界材料正文'),
      if (_knowledgeReadNext != null &&
          _knowledgeReadReference != null &&
          identical(_knowledgeReadPort, widget.knowledge))
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            key: const ValueKey('public-validation-knowledge-document-next'),
            onPressed: _continueKnowledgeMaterial,
            child: const Text('继续读取正文'),
          ),
        ),
    ],
  );

  Widget _candidateList({
    required String title,
    required PublicQueryResult result,
    required String prefix,
    required Future<void> Function(PublicCandidate) onRead,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleMedium),
      _coverage(result.coverage),
      for (var index = 0; index < result.candidates.length; index++)
        Card(
          key: ValueKey('public-validation-$prefix-candidate-$index'),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  result.candidates[index].title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                if (result.candidates[index].snippet.isNotEmpty)
                  Text(result.candidates[index].snippet),
                _evidence(result.candidates[index].evidence),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    onPressed: _sourceBusy && prefix != 'knowledge'
                        ? null
                        : () => onRead(result.candidates[index]),
                    child: const Text('按受控引用读取'),
                  ),
                ),
              ],
            ),
          ),
        ),
    ],
  );

  Widget _documentResult(PublicQueryResult result, {required String label}) {
    final document = result.document;
    if (document == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label),
          const Text('端口未返回正文。'),
          _coverage(result.coverage),
        ],
      );
    }
    final course = document.course;
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(label, style: Theme.of(context).textTheme.titleMedium),
            if (course != null) ...[
              Text('课程：${course.title}'),
              Text('教师：${course.teacher}'),
              Text('评分：${course.score?.toString() ?? '未提供'}'),
              Text('评分人数：${course.ratingCount ?? '未提供'}'),
              Text('点评数：${course.reviewCount ?? '未提供'}'),
              if (course.terms.isNotEmpty)
                Text(
                  '来源学期：${course.terms.map((term) => term.label).join('、')}',
                ),
            ],
            _evidence(document.evidence),
            if (document.markdown.isNotEmpty)
              MarkdownBody(
                data: document.markdown,
                imageBuilder: _blockedImage,
                onTapLink: _onMarkdownLink,
              )
            else
              const Text('端口返回正文为空。'),
            for (final review in document.reviews)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(review.text),
                      if (review.term != null) Text('来源学期：${review.term}'),
                      Text('定位：${review.locator}'),
                    ],
                  ),
                ),
              ),
            if (document.attachmentLinks.isNotEmpty) ...[
              const Text('相关附件出处'),
              for (final link in document.attachmentLinks)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => unawaited(_showCitation(link)),
                    child: const Text('查看/复制 HTTPS 附件出处'),
                  ),
                ),
            ],
            _coverage(result.coverage),
          ],
        ),
      ),
    );
  }

  Widget _evidence(PublicEvidence evidence) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '来源：${_providerLabel(evidence.provider)}；'
        '${evidence.origin == EvidenceOrigin.localKnowledge ? '本地版本' : '在线观察'}',
      ),
      if (evidence.revision != null) Text('版本：${evidence.revision}'),
      if (evidence.sourceVersion != null)
        Text('来源版本：${evidence.sourceVersion}'),
      if (evidence.audience != null) Text('适用人群：${evidence.audience}'),
      if (evidence.coveredScope != null) Text('覆盖范围：${evidence.coveredScope}'),
      Text('内容质量：${_qualityLabel(evidence.quality)}'),
      if (evidence.publishedOn != null) Text('可证发布日期：${evidence.publishedOn}'),
      if (evidence.updatedOn != null) Text('来源标注更新时间：${evidence.updatedOn}'),
      Text('观察时间（UTC）：${evidence.observedAtUtc.toIso8601String()}'),
      if (evidence.locator != null) Text('正文定位：${evidence.locator}'),
      Text(
        '适用性：${evidence.applicability == MaterialApplicability.unknown ? '未知，未核实现行性' : evidence.applicability.name}',
      ),
      Wrap(
        spacing: 8,
        children: [
          TextButton(
            onPressed: () => unawaited(_showCitation(evidence.articleUrl)),
            child: const Text('查看/复制文章出处'),
          ),
          if (evidence.materialUrl != null)
            TextButton(
              onPressed: () => unawaited(_showCitation(evidence.materialUrl!)),
              child: const Text('查看/复制材料出处'),
            ),
        ],
      ),
    ],
  );

  Widget _coverage(PublicCoverage coverage) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Text(
      '覆盖：${coverage.scope}；本次 ${coverage.returned} 项'
      '${coverage.observed == null ? '' : '，观察 ${coverage.observed} 项'}'
      '${coverage.totalReported == null ? '' : '，来源报告总数 ${coverage.totalReported}'}'
      '；排除 ${coverage.excluded} 项'
      '${coverage.truncated ? '；结果已截断' : ''}'
      '；${coverage.complete ? '此范围完整' : '此范围完整性未确认'}'
      '${coverage.cached ? '；来自缓存' : ''}',
    ),
  );
}
