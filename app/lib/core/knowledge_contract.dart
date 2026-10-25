import 'public_query_contract.dart';

const knowledgeEditionVersion = 'knowledge-edition-v1';

final class KnowledgeEditionIdentity {
  const KnowledgeEditionIdentity({
    required this.key,
    required this.catalogDigest,
    required this.materialKeys,
  });
  final String key;
  final String catalogDigest;
  final List<String> materialKeys;
}

final class KnowledgeMaterial {
  const KnowledgeMaterial({
    required this.key,
    required this.title,
    required this.provider,
    required this.topic,
    required this.audience,
    required this.sourceVersion,
    required this.articleUrl,
    required this.sourceDigest,
    required this.coveredScope,
    required this.markdown,
    required this.markdownDigest,
    required this.reviewVersion,
    this.materialUrl,
    this.publishedOn,
    this.updatedOn,
  });
  final String key;
  final String title;
  final PublicProvider provider;
  final String topic;
  final String audience;
  final String sourceVersion;
  final Uri articleUrl;
  final Uri? materialUrl;

  /// Original image bytes or explicitly identified normalized HTML digest.
  final String sourceDigest;
  final String coveredScope;
  final String markdown;
  final String markdownDigest;
  final String reviewVersion;
  final String? publishedOn;
  final String? updatedOn;
}

final class KnowledgeEdition {
  KnowledgeEdition({
    required this.key,
    required this.catalogDigest,
    required List<KnowledgeMaterial> materials,
  }) : materials = List.unmodifiable(materials);
  final String key;

  /// Bound by the trusted package loader, not a caller-selected path or URL.
  final String catalogDigest;
  final List<KnowledgeMaterial> materials;
}

final class KnowledgeSummary {
  const KnowledgeSummary({
    required this.materialCount,
    required this.sectionCount,
    required this.loadCount,
    required this.loading,
    this.edition,
  });
  final int materialCount;
  final int sectionCount;
  final int loadCount;
  final bool loading;
  final String? edition;
}

enum KnowledgeLoadState { done, cancelled, failed }

final class KnowledgeLoadOutcome {
  const KnowledgeLoadOutcome({
    required this.state,
    required this.accepted,
    required this.unchanged,
    required this.total,
    this.failure,
  });
  final KnowledgeLoadState state;
  final int accepted;
  final int unchanged;
  final int total;
  final PublicFailureCode? failure;
  bool get hasCommittedChanges => accepted > 0;
}

abstract interface class KnowledgeReadPort {
  Future<KnowledgeSummary> inspectKnowledge();
  Future<PublicQueryResult> searchKnowledge(
    String keywords, {
    PublicProvider? provider,
    String? topic,
    String? audience,
    String? version,
    int pageSize = 20,
    PublicCursor? cursor,
  });
  Future<PublicQueryResult> readKnowledgeMaterial(
    PublicReference reference, {
    int sectionStart = 0,
    int maxCharacters = 12000,
    PublicCursor? cursor,
  });
}

/// Separate from the read port; future read-only tools receive no load/clear.
abstract interface class KnowledgeMaintenancePort {
  Future<KnowledgeLoadOutcome> loadBundledEdition();
  Future<void> cancelKnowledgeLoad();
  Future<void> clearKnowledge({required bool confirmed});
}

abstract interface class KnowledgePort
    implements KnowledgeReadPort, KnowledgeMaintenancePort {}
