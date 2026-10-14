import 'dart:async';

const publicQueryVersion = 'public-query-v1';

enum PublicSource { icourse, campus }

enum PublicProvider { icourse, teach, finance }

extension PublicProviderSource on PublicProvider {
  PublicSource get source => this == PublicProvider.icourse
      ? PublicSource.icourse
      : PublicSource.campus;
}

enum CampusColumn {
  teachNotice,
  teachStudentService,
  financeNotice,
  financeBusiness,
  financeProcess,
  financeOperation,
  financeFaq,
}

extension CampusColumnProvider on CampusColumn {
  PublicProvider get provider => switch (this) {
    CampusColumn.teachNotice ||
    CampusColumn.teachStudentService => PublicProvider.teach,
    _ => PublicProvider.finance,
  };
}

enum CourseReviewSort {
  upvote,
  newest,
  oldest,
  scoreDescending,
  scoreAscending,
}

enum PublicFailureCode {
  invalidRequest,
  busy,
  consentRequired,
  cancelled,
  staleReference,
  unavailable,
  accessRestricted,
  campusOnly,
  networkFailed,
  sourceSchema,
  unsafeTarget,
  resourceLimit,
  storageFailed,
  cleanupPending,
  closed,
}

final class PublicFailure implements Exception {
  const PublicFailure(this.code);
  final PublicFailureCode code;
  @override
  String toString() => 'PublicFailure(${code.name})';
}

/// A lookup value, never a URL, database identity or a serialized job permit.
/// The issuer must reject unknown, expired and invalidated values.
final class PublicReference {
  const PublicReference(this.value);
  final String value;
  @override
  String toString() => 'PublicReference';
}

final class PublicCursor {
  const PublicCursor(this.value);
  final String value;
  @override
  String toString() => 'PublicCursor';
}

enum EvidenceOrigin { online, localKnowledge }

enum MaterialApplicability { unknown }

enum EvidenceQuality { parsedSource, reviewedContent }

final class PublicEvidence {
  const PublicEvidence({
    required this.provider,
    required this.title,
    required this.articleUrl,
    required this.observedAtUtc,
    required this.origin,
    this.materialUrl,
    this.publishedOn,
    this.updatedOn,
    this.revision,
    this.locator,
    this.sourceVersion,
    this.audience,
    this.coveredScope,
    this.quality = EvidenceQuality.parsedSource,
    this.applicability = MaterialApplicability.unknown,
  });
  final PublicProvider provider;
  final String title;
  final Uri articleUrl;
  final Uri? materialUrl;
  final DateTime observedAtUtc;
  final EvidenceOrigin origin;

  /// Source dates retain their precision, rather than inventing a UTC instant.
  final String? publishedOn;
  final String? updatedOn;
  final String? revision;
  final String? locator;
  final String? sourceVersion;
  final String? audience;
  final String? coveredScope;
  final EvidenceQuality quality;
  final MaterialApplicability applicability;
}

final class PublicCoverage {
  const PublicCoverage({
    required this.scope,
    required this.returned,
    this.observed,
    this.totalReported,
    this.excluded = 0,
    this.truncated = false,
    this.complete = false,
    this.cached = false,
  });
  final String scope;
  final int returned;
  final int? observed;
  final int? totalReported;
  final int excluded;
  final bool truncated;

  /// Complete only for the stated scope, never an inferred whole-site promise.
  final bool complete;
  final bool cached;
}

final class PublicTerm {
  const PublicTerm({required this.code, required this.label});
  final String code;
  final String label;
}

final class PublicCourseInfo {
  PublicCourseInfo({
    required this.courseKey,
    required this.title,
    required this.teacher,
    this.score,
    this.ratingCount,
    this.reviewCount,
    List<PublicTerm> terms = const [],
  }) : terms = List.unmodifiable(terms);
  final String courseKey;
  final String title;
  final String teacher;
  final double? score;
  final int? ratingCount;
  final int? reviewCount;
  final List<PublicTerm> terms;
}

final class PublicReview {
  const PublicReview({required this.text, required this.locator, this.term});
  final String text;
  final String locator;
  final String? term;
}

final class PublicCandidate {
  const PublicCandidate({
    required this.reference,
    required this.title,
    required this.evidence,
    this.snippet = '',
    this.course,
  });
  final PublicReference reference;
  final String title;
  final String snippet;
  final PublicEvidence evidence;
  final PublicCourseInfo? course;
}

final class PublicDocument {
  PublicDocument({
    required this.evidence,
    required this.markdown,
    this.course,
    List<PublicReview> reviews = const [],
    List<Uri> attachmentLinks = const [],
  }) : reviews = List.unmodifiable(reviews),
       attachmentLinks = List.unmodifiable(attachmentLinks);
  final PublicEvidence evidence;
  final String markdown;
  final PublicCourseInfo? course;
  final List<PublicReview> reviews;
  final List<Uri> attachmentLinks;
}

final class PublicQueryResult {
  PublicQueryResult({
    required this.coverage,
    List<PublicCandidate> candidates = const [],
    this.document,
    this.next,
  }) : candidates = List.unmodifiable(candidates);
  String get version => publicQueryVersion;
  final List<PublicCandidate> candidates;
  final PublicDocument? document;
  final PublicCursor? next;
  final PublicCoverage coverage;
}

enum PublicJobPhase { idle, requesting, settling, recovery, closed }

final class PublicJobView {
  const PublicJobView({
    required this.phase,
    this.source,
    this.failure,
    this.returned = 0,
  });
  final PublicJobPhase phase;
  final PublicSource? source;
  final PublicFailureCode? failure;
  final int returned;
  bool get busy =>
      phase != PublicJobPhase.idle && phase != PublicJobPhase.closed;
}

/// Internal application ports. These are not registered model tools.
abstract interface class PublicQueryPort {
  PublicJobView get view;
  Stream<PublicJobView> get changes;
  Future<bool> hasIcourseConsent();
  Future<void> setIcourseConsent(bool allowed);
  Future<PublicQueryResult> searchCourses(
    String keywords, {
    int pageSize = 20,
    PublicCursor? cursor,
  });
  Future<PublicQueryResult> readCourse(
    PublicReference reference, {
    String? term,
    CourseReviewSort sort = CourseReviewSort.upvote,
    int pageSize = 10,
    PublicCursor? cursor,
  });
  Future<PublicQueryResult> browseCampus(
    CampusColumn column, {
    String? keywords,
    int pageSize = 20,
    PublicCursor? cursor,
  });
  Future<PublicQueryResult> readCampusArticle(
    PublicReference reference, {
    int sectionStart = 0,
    int maxCharacters = 12000,
    PublicCursor? cursor,
  });
  Future<void> cancel();
  Future<void> retryRecovery();
  Future<void> close();
}

/// Validates the exact issued result against current source/knowledge epochs.
/// Implementations cannot accept a reconstructed result as live authority.
abstract interface class PublicResultGuardPort {
  Future<void> ensurePublicResult(PublicQueryResult result);
}

/// Historical observations keep their text after a normal catalogue revision.
/// Ownership, reset, clearing and consent still have to be current. References
/// and cursors continue to use the stricter live-result guard above.
abstract interface class PublicResultLifecycleGuardPort {
  Future<void> ensurePublicResultContext(PublicQueryResult result);
}

/// A bounded review slice retains the C2 cursor's exact character position.
/// The ordinary application read API keeps its existing 12000-character cap.
abstract interface class PublicReviewReadPort {
  Future<PublicQueryResult> readCourseSlice(
    PublicReference reference, {
    String? term,
    CourseReviewSort sort = CourseReviewSort.upvote,
    int pageSize = 5,
    int maxCharacters = 2400,
    PublicCursor? cursor,
  });
}

String publicKeywords(String value) {
  final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.isEmpty ||
      normalized.runes.length > 80 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(normalized)) {
    throw const PublicFailure(PublicFailureCode.invalidRequest);
  }
  return normalized;
}

void requirePublicPageSize(int value) {
  if (value < 1 || value > 20) {
    throw const PublicFailure(PublicFailureCode.invalidRequest);
  }
}

void requirePublicTextRange(int start, int maxCharacters) {
  if (start < 0 ||
      start > 10000 ||
      maxCharacters < 1 ||
      maxCharacters > 12000) {
    throw const PublicFailure(PublicFailureCode.invalidRequest);
  }
}
