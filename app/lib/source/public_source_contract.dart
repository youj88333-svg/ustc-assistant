import '../core/public_query_contract.dart';

/// Shared path registry for parsed article candidates and outbound requests.
/// A link in a registered column does not expand the allowed article scope.
bool isRegisteredPublicArticlePath(String path, PublicProvider provider) =>
    switch (provider) {
      PublicProvider.icourse => RegExp(r'^/course/[0-9]+/$').hasMatch(path),
      PublicProvider.teach => RegExp(
        r'^/(?:service/svc-student|notice/[a-z0-9-]+)/[0-9]+\.html$',
      ).hasMatch(path),
      PublicProvider.finance => RegExp(
        r'^/[0-9]{4}/[0-9]{4}/c[0-9]+a[0-9]+/page\.(?:htm|psp)$',
      ).hasMatch(path),
    };

/// C1 values. URLs remain internal to the controlled coordinator and source.
final class SourcePublicItem {
  const SourcePublicItem({
    required this.key,
    required this.title,
    required this.uri,
    required this.provider,
    this.publishedOn,
    this.snippet = '',
    this.course,
  });
  final String key;
  final String title;
  final Uri uri;
  final PublicProvider provider;
  final String? publishedOn;
  final String snippet;
  final PublicCourseInfo? course;
}

final class SourcePublicPage {
  SourcePublicPage({
    required List<SourcePublicItem> items,
    this.nextPage,
    this.totalReported,
    this.excluded = 0,
    this.listingOrder = PublicListingOrder.unknown,
  }) : items = List.unmodifiable(items);
  final List<SourcePublicItem> items;
  final Uri? nextPage;
  final int? totalReported;
  final int excluded;
  final PublicListingOrder listingOrder;
}

final class SourcePublicDocument {
  SourcePublicDocument({
    required this.provider,
    required this.title,
    required this.uri,
    required this.markdown,
    this.publishedOn,
    this.updatedOn,
    this.course,
    List<PublicReview> reviews = const [],
    List<Uri> attachmentLinks = const [],
    this.excluded = 0,
    this.contentComplete = true,
  }) : reviews = List.unmodifiable(reviews),
       attachmentLinks = List.unmodifiable(attachmentLinks);
  final PublicProvider provider;
  final String title;
  final Uri uri;
  final String markdown;
  final String? publishedOn;
  final String? updatedOn;
  final PublicCourseInfo? course;
  final List<PublicReview> reviews;
  final List<Uri> attachmentLinks;
  final int excluded;
  final bool contentComplete;
}

abstract interface class PublicSourceParser {
  SourcePublicPage courses(String html, Uri uri);
  SourcePublicDocument course(String html, Uri uri);
  SourcePublicPage campus(String html, Uri uri, CampusColumn column);
  SourcePublicDocument article(String html, Uri uri, PublicProvider provider);
}
