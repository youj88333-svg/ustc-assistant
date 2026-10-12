import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../core/public_query_contract.dart';
import 'public_source_contract.dart';

/// A deliberately narrow parser for the public pages verified by M3.1.
///
/// This class only interprets the supplied HTML string. It has no HTTP, file,
/// database, browser, or reference-issuing capability.
final class FixedPublicHtmlParser implements PublicSourceParser {
  const FixedPublicHtmlParser();

  static const int _maxPageBytes = 2 * 1024 * 1024;
  static const int _maxNodes = 100000;
  // C1 retains a bounded source snapshot for C2 to expose in read pages.
  static const int _maxSnapshotCharacters = 512 * 1024;

  static const String _icourseHost = 'icourse.club';
  static const String _teachHost = 'www.teach.ustc.edu.cn';
  static const String _financeHost = 'finance.ustc.edu.cn';

  @override
  SourcePublicPage courses(String html, Uri uri) {
    _requireOrigin(uri, _icourseHost);
    final route = _IcourseListRoute.parse(uri);
    final document = _parse(html);
    final cards = <dom.Element>[];
    for (final card in document.querySelectorAll('div.ud-pd-md.dashed')) {
      if (!_isVisible(card)) continue;
      if (card.querySelector('a.px16[href]') != null) cards.add(card);
    }

    final items = <SourcePublicItem>[];
    final seen = <String>{};
    final teachersByCourseId = <String, String>{};
    var excluded = 0;
    for (final card in cards) {
      final anchor = card.querySelector('a.px16[href]');
      final target = anchor == null
          ? null
          : _resolve(uri, anchor.attributes['href']);
      final coursePath = target == null
          ? null
          : RegExp(r'^/course/(\d+)/$').firstMatch(target.path);
      final titleText = anchor == null ? '' : _plainText(anchor);
      final identity = _courseIdentity(titleText);
      if (target == null ||
          !_isOrigin(target, _icourseHost) ||
          target.query.isNotEmpty ||
          coursePath == null ||
          identity == null) {
        excluded++;
        continue;
      }

      final courseId = coursePath.group(1)!;
      final priorTeacher = teachersByCourseId[courseId];
      if (priorTeacher != null && priorTeacher != identity.teacher) {
        throw const PublicFailure(PublicFailureCode.sourceSchema);
      }
      teachersByCourseId[courseId] = identity.teacher;
      if (!seen.add('$courseId:${identity.teacher}')) {
        excluded++;
        continue;
      }
      final rating = _listRating(card);
      final course = PublicCourseInfo(
        courseKey: courseId,
        title: identity.title,
        teacher: identity.teacher,
        score: rating.score,
        ratingCount: rating.count,
      );
      items.add(
        SourcePublicItem(
          key: '$courseId:${identity.teacher}',
          title: identity.title,
          uri: target,
          provider: PublicProvider.icourse,
          course: course,
        ),
      );
    }

    final desktopNoResult = document.querySelectorAll('span.blue.h4.desktop');
    final mobileNoResult = document.querySelectorAll('span.blue.h5.mobile');
    final expectedNoResult = route.keyword == null
        ? null
        : '您的搜索「${route.keyword}」没有匹配到任何课程或老师';
    final noResults =
        route.isSearch &&
        expectedNoResult != null &&
        desktopNoResult.length == 1 &&
        mobileNoResult.length == 1 &&
        _isVisible(desktopNoResult.single) &&
        _isVisible(mobileNoResult.single) &&
        _plainText(desktopNoResult.single) == expectedNoResult &&
        _plainText(mobileNoResult.single) == expectedNoResult;
    if (items.isEmpty && !noResults) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    final nextPage = _icourseNextPage(document, uri, route);
    return SourcePublicPage(
      items: items,
      nextPage: nextPage,
      excluded: excluded,
    );
  }

  @override
  SourcePublicDocument course(String html, Uri uri) {
    _requireOrigin(uri, _icourseHost);
    final courseId = _courseIdFromDetailUri(uri);
    final document = _parse(html);
    final courseHeader = document.querySelector('div.col-md-8.inline-h3');
    final titleNode = courseHeader?.querySelector('span.blue.h3');
    final teacherNode = courseHeader?.querySelector('span.h3.blue.mobile');
    final title = titleNode == null || !_isVisible(titleNode)
        ? ''
        : _plainText(titleNode);
    final teacher = teacherNode == null || !_isVisible(teacherNode)
        ? null
        : _courseTeacher(_plainText(teacherNode));
    if (title.isEmpty || teacher == null) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    final identity = _CourseIdentity(title, teacher);

    final termOptions = _courseTerms(document, uri, courseId);
    if (termOptions.isEmpty) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    final selectedTerm = uri.queryParameters['term'];
    if (selectedTerm != null &&
        selectedTerm.isNotEmpty &&
        !termOptions.any((term) => term.code == selectedTerm)) {
      throw const PublicFailure(PublicFailureCode.unsafeTarget);
    }

    final ratingBlock = document.querySelector('div.desktop.ud-pd-sm.blue');
    final ratingCountNode = ratingBlock?.querySelector(
      'span.rl-pd-sm.text-muted',
    );
    final reviewCountNode = document.querySelector(
      'div.ud-pd-sm.review-header > span.rl-pd-sm.text-muted',
    );
    if (ratingBlock == null ||
        !_isVisible(ratingBlock) ||
        ratingCountNode == null ||
        reviewCountNode == null ||
        !_isVisible(reviewCountNode)) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    final ratingCount = _countFromLabel(_plainText(ratingCountNode));
    final reviewCount = _countFromLabel(_plainText(reviewCountNode));
    if (reviewCount == null) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    final score = _scoreFromLabel(_plainText(ratingBlock));

    final reviewRoots = <dom.Element>[];
    final reviewRootPattern = RegExp(r'^review-(\d+)$');
    for (final node in document.querySelectorAll(
      'div.review.ud-pd-md.dashed',
    )) {
      if (reviewRootPattern.hasMatch(node.id) &&
          node.classes.contains('ud-pd-md') &&
          node.classes.contains('dashed') &&
          _isVisible(node)) {
        reviewRoots.add(node);
      }
    }
    final reviews = <PublicReview>[];
    var excluded = 0;
    var deletedMarkers = 0;
    var reviewCharacters = 0;
    var reviewBudgetExceeded = false;
    final selectedTermLabel = selectedTerm == null || selectedTerm.isEmpty
        ? null
        : termOptions
              .where((option) => option.code == selectedTerm)
              .first
              .label;
    for (final root in reviewRoots) {
      final reviewId = reviewRootPattern.firstMatch(root.id)!.group(1)!;
      final deleted = root
          .querySelectorAll('div.alert.alert-warning > span')
          .any((node) => _isVisible(node) && _plainText(node).contains('删'));
      if (deleted) {
        deletedMarkers++;
        excluded++;
        continue;
      }
      final termNode = root.querySelector(
        'div.blue.ud-pd-sm > span.left-pd-md',
      );
      final term = termNode == null || !_isVisible(termNode)
          ? null
          : _plainText(termNode);
      if (selectedTermLabel != null && term != selectedTermLabel) {
        excluded++;
        continue;
      }
      final content = root.querySelector(
        '#review-content-$reviewId.review-content.ck-content',
      );
      if (content == null || !_isVisible(content)) {
        excluded++;
        continue;
      }
      var text = _plainText(content);
      if (text.isEmpty) {
        excluded++;
        continue;
      }
      final remaining = _maxSnapshotCharacters - reviewCharacters;
      if (remaining <= 0) {
        reviewBudgetExceeded = true;
        continue;
      }
      if (text.length > remaining) {
        text = text.substring(0, remaining);
        reviewBudgetExceeded = true;
      }
      reviewCharacters += text.length;
      reviews.add(
        PublicReview(text: text, locator: 'review-$reviewId', term: term),
      );
    }

    final completeReviews =
        reviewCount <= reviews.length + deletedMarkers &&
        !reviewBudgetExceeded &&
        excluded == deletedMarkers;
    final course = PublicCourseInfo(
      courseKey: courseId,
      title: identity.title,
      teacher: identity.teacher,
      score: score,
      ratingCount: ratingCount,
      reviewCount: reviewCount,
      terms: termOptions,
    );
    return SourcePublicDocument(
      provider: PublicProvider.icourse,
      title: identity.title,
      uri: uri,
      markdown: '',
      course: course,
      reviews: reviews,
      excluded: excluded,
      contentComplete: completeReviews,
    );
  }

  @override
  SourcePublicPage campus(String html, Uri uri, CampusColumn column) {
    final provider = column.provider;
    final host = provider == PublicProvider.teach ? _teachHost : _financeHost;
    _requireOrigin(uri, host);
    if (provider == PublicProvider.teach) {
      return _teachCampus(html, uri, column);
    }
    if (column == CampusColumn.financeFaq) {
      // The observed FAQ page is not the verified w6 news-list shape.
      throw const PublicFailure(PublicFailureCode.unavailable);
    }
    return _financeCampus(html, uri, column);
  }

  @override
  SourcePublicDocument article(String html, Uri uri, PublicProvider provider) {
    final host = switch (provider) {
      PublicProvider.icourse => _icourseHost,
      PublicProvider.teach => _teachHost,
      PublicProvider.finance => _financeHost,
    };
    _requireOrigin(uri, host);
    if (provider == PublicProvider.icourse) {
      throw const PublicFailure(PublicFailureCode.unavailable);
    }
    if (!_isExpectedArticleUri(uri, provider)) {
      throw const PublicFailure(PublicFailureCode.unsafeTarget);
    }
    final document = _parse(html);
    return provider == PublicProvider.teach
        ? _teachArticle(document, uri)
        : _financeArticle(document, uri);
  }

  SourcePublicDocument _teachArticle(dom.Document document, Uri uri) {
    dom.Element? article;
    for (final candidate in document.querySelectorAll('article.post[id]')) {
      if (RegExp(r'^post-\d+$').hasMatch(candidate.id)) {
        article = candidate;
        break;
      }
    }
    if (article == null ||
        !RegExp(r'^post-\d+$').hasMatch(article.id) ||
        !_isVisible(article)) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    final title = _articleTitle(document, article);
    final publishedOn = _dateValue(
      document.querySelector(
        'aside.sidebar-b > div.post-meta-side > ul > li.meta-date',
      ),
    );
    final updatedOn = _dateValue(
      document.querySelector(
        'aside.sidebar-b > div.post-meta-side > ul > li.meta-last-modified',
      ),
    );
    final renderer = _MarkdownRenderer(uri, PublicProvider.teach);
    final bodyNodes = <dom.Node>[];
    for (final child in article.nodes) {
      if (child is dom.Element && _skipTeachArticleChild(child, title)) {
        continue;
      }
      bodyNodes.add(child);
    }
    final rendered = renderer.renderNodes(bodyNodes);
    final markdown = _limitText(rendered.markdown);
    final isComplete =
        rendered.complete &&
        markdown.complete &&
        markdown.text.trim().isNotEmpty;
    if (markdown.text.trim().isEmpty && rendered.complete) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    return SourcePublicDocument(
      provider: PublicProvider.teach,
      title: title,
      uri: uri,
      markdown: markdown.text,
      publishedOn: publishedOn,
      updatedOn: updatedOn,
      attachmentLinks: rendered.attachments,
      contentComplete: isComplete,
    );
  }

  SourcePublicDocument _financeArticle(dom.Document document, Uri uri) {
    final body = document.querySelector(
      'div.infobox > div.article > div.entry > div.read > div.wp_articlecontent',
    );
    if (body == null || !_isVisible(body)) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    final title = _articleTitle(document, body);
    final publishedOn = _dateValue(
      document.querySelector('p.arti_metas > span.arti_update'),
    );
    final renderer = _MarkdownRenderer(uri, PublicProvider.finance);
    final rendered = renderer.renderElementChildren(body);
    final markdown = _limitText(rendered.markdown);
    final isComplete =
        rendered.complete &&
        markdown.complete &&
        markdown.text.trim().isNotEmpty;
    if (markdown.text.trim().isEmpty && rendered.complete) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    return SourcePublicDocument(
      provider: PublicProvider.finance,
      title: title,
      uri: uri,
      markdown: markdown.text,
      publishedOn: publishedOn,
      attachmentLinks: rendered.attachments,
      contentComplete: isComplete,
    );
  }

  SourcePublicPage _teachCampus(String html, Uri uri, CampusColumn column) {
    final route = _TeachRoute.parse(uri, column);
    final document = _parse(html);
    if (column == CampusColumn.teachNotice || route.keyword != null) {
      final rows = document
          .querySelectorAll(
            column == CampusColumn.teachStudentService
                ? 'main.main > section > div.list > ul.article-list > li.post.type-post.status-publish'
                : 'ul.article-list.with-tag > li.post.type-post.status-publish',
          )
          .where(
            (row) => RegExp(
              r'(^|\s)post-\d+(?:\s|$)',
            ).hasMatch(row.attributes['class'] ?? ''),
          );
      final items = <SourcePublicItem>[];
      var excluded = 0;
      final seen = <String>{};
      for (final row in rows) {
        if (!_isVisible(row)) continue;
        if (row.classes.contains('sticky') ||
            row.classes.contains('post-sticky')) {
          excluded++;
          continue;
        }
        if (column == CampusColumn.teachStudentService &&
            !row.classes.contains('category-svc-student')) {
          excluded++;
          continue;
        }
        final anchor = row.querySelector('span.post > a[href]');
        final target = anchor == null
            ? null
            : _resolve(uri, anchor.attributes['href']);
        if (target == null ||
            !_isOrigin(target, _teachHost) ||
            !_isExpectedArticleUri(target, PublicProvider.teach)) {
          excluded++;
          continue;
        }
        final title = _plainText(anchor!);
        if (title.isEmpty || !seen.add(target.toString())) {
          excluded++;
          continue;
        }
        items.add(
          SourcePublicItem(
            key: target.path,
            title: title,
            uri: target,
            provider: PublicProvider.teach,
            publishedOn: _dateValue(row.querySelector('span.date')),
          ),
        );
      }
      final noResults =
          _hasClass(document.body, 'search-no-results') &&
          route.keyword != null;
      if (items.isEmpty && !noResults) {
        throw const PublicFailure(PublicFailureCode.sourceSchema);
      }
      return SourcePublicPage(
        items: items,
        nextPage: _teachNextPage(document, uri, route),
        excluded: excluded,
      );
    }

    if (column != CampusColumn.teachStudentService) {
      throw const PublicFailure(PublicFailureCode.unavailable);
    }
    final main = document.querySelector('main.main');
    if (main == null || !_isVisible(main)) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    final anchors = <dom.Element>[];
    for (final flow in main.querySelectorAll(
      'div.flow.flow1, div.flow.flow2, '
      'div.flow.flow3, div.flow.flow4, div.flow.flow5, div.flow.flow6',
    )) {
      if (!_isVisible(flow)) continue;
      anchors.addAll(flow.querySelectorAll('span.post > a[href]'));
    }
    for (final list in main.querySelectorAll(
      'div.faq > ul.article-list > li, div.more > ul.article-list > li',
    )) {
      if (_isVisible(list)) {
        anchors.addAll(list.querySelectorAll('span.post > a[href]'));
      }
    }

    final items = <SourcePublicItem>[];
    final seen = <String>{};
    var excluded = 0;
    for (final anchor in anchors) {
      if (!_isVisible(anchor)) continue;
      final target = _resolve(uri, anchor.attributes['href']);
      if (target == null ||
          !_isOrigin(target, _teachHost) ||
          !_isExpectedArticleUri(target, PublicProvider.teach)) {
        excluded++;
        continue;
      }
      final title = _plainText(anchor);
      if (title.isEmpty || !seen.add(target.toString())) {
        excluded++;
        continue;
      }
      final itemRoot = _closestListItem(anchor) ?? anchor.parent;
      items.add(
        SourcePublicItem(
          key: target.path,
          title: title,
          uri: target,
          provider: PublicProvider.teach,
          publishedOn: itemRoot == null
              ? null
              : _dateValue(itemRoot.querySelector('span.date, .date')),
        ),
      );
    }
    final noResults =
        _hasClass(document.body, 'search-no-results') && route.keyword != null;
    if (items.isEmpty && !noResults) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    return SourcePublicPage(items: items, excluded: excluded);
  }

  SourcePublicPage _financeCampus(String html, Uri uri, CampusColumn column) {
    final route = _FinanceRoute.parse(uri, column);
    final document = _parse(html);
    final list = document.querySelector('div#wp_news_w6 > ul.news_list.list2');
    if (list == null || !_isVisible(list)) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    final rows = list.querySelectorAll('li.news.clearfix');
    final items = <SourcePublicItem>[];
    final seen = <String>{};
    var excluded = 0;
    for (final row in rows) {
      if (!_isVisible(row)) continue;
      final anchor = row.querySelector('span.news_title > a[href]');
      final target = anchor == null
          ? null
          : _resolve(uri, anchor.attributes['href']);
      if (target == null ||
          !_isOrigin(target, _financeHost) ||
          !_isExpectedArticleUri(target, PublicProvider.finance)) {
        excluded++;
        continue;
      }
      final title = _plainText(anchor!);
      if (title.isEmpty || !seen.add(target.toString())) {
        excluded++;
        continue;
      }
      items.add(
        SourcePublicItem(
          key: target.path,
          title: title,
          uri: target,
          provider: PublicProvider.finance,
          publishedOn: _dateValue(row.querySelector('span.news_meta')),
        ),
      );
    }
    if (items.isEmpty) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    final nextPage = _financeNextPage(document, uri, route);
    return SourcePublicPage(
      items: items,
      nextPage: nextPage,
      totalReported: _financeReportedCount(document),
      excluded: excluded,
    );
  }

  static dom.Document _parse(String html) {
    if (utf8.encode(html).length > _maxPageBytes) {
      throw const PublicFailure(PublicFailureCode.resourceLimit);
    }
    if (html.trim().isEmpty) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    final document = html_parser.parse(html);
    if (document.querySelectorAll('*').length > _maxNodes) {
      throw const PublicFailure(PublicFailureCode.resourceLimit);
    }
    return document;
  }

  static void _requireOrigin(Uri uri, String host) {
    if (!_isOrigin(uri, host) || uri.fragment.isNotEmpty) {
      throw const PublicFailure(PublicFailureCode.unsafeTarget);
    }
  }

  static bool _isOrigin(Uri uri, String host) =>
      uri.scheme == 'https' &&
      uri.host.toLowerCase() == host &&
      (uri.port == 443 || uri.port == 0) &&
      uri.userInfo.isEmpty;

  static Uri? _resolve(Uri base, String? href) {
    final value = href?.trim();
    if (value == null || value.isEmpty) return null;
    final candidate = Uri.tryParse(value);
    if (candidate == null) return null;
    late final Uri resolved;
    try {
      resolved = base.resolveUri(candidate);
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
    if (resolved.userInfo.isNotEmpty || resolved.fragment.isNotEmpty) {
      return null;
    }
    if (resolved.queryParameters.keys.any(_sensitiveQueryName)) return null;
    return resolved;
  }

  static bool _sensitiveQueryName(String name) => RegExp(
    r'(?:token|ticket|auth|session|password|cookie|secret)',
    caseSensitive: false,
  ).hasMatch(name);

  static bool _isVisible(dom.Element element) {
    dom.Node? current = element;
    while (current is dom.Element) {
      final classes = current.classes;
      final style = current.attributes['style'] ?? '';
      final identifiers = <String>{current.id, ...classes}.map(
        (name) => name.toLowerCase().replaceAll(
          RegExp(r'[^a-z0-9\u0080-\uffff]'),
          '',
        ),
      );
      if (current.attributes.containsKey('hidden') ||
          current.attributes['aria-hidden']?.toLowerCase() == 'true' ||
          current.attributes['type']?.toLowerCase() == 'hidden' ||
          classes.any(
            const <String>{'hidden', 'hide', 'd-none', 'is-hidden'}.contains,
          ) ||
          identifiers.any(
            (name) =>
                name.contains('curriculum') ||
                name.contains('trainingplan') ||
                name.contains('peiyangfangan') ||
                name.contains('培养方案') ||
                name.contains('courseplan') ||
                name == 'modal',
          ) ||
          RegExp(
            r'(?:display\s*:\s*none|visibility\s*:\s*hidden)',
            caseSensitive: false,
          ).hasMatch(style)) {
        return false;
      }
      current = current.parent;
    }
    return true;
  }

  static bool _hasAiAncestor(dom.Element element) {
    dom.Node? current = element;
    while (current is dom.Element) {
      final names = <String>{
        current.id,
        ...current.classes,
      }.map((name) => name.toLowerCase());
      if (names.any(
            (name) =>
                name == 'ai-summary' ||
                name == 'ai_summary' ||
                name == 'generated-summary' ||
                name == 'course-ai-summary' ||
                name == 'ai-generated-summary' ||
                RegExp(
                  r'ai.*summary|summary.*ai|generated.*summary',
                  caseSensitive: false,
                ).hasMatch(name),
          ) ||
          current.attributes.containsKey('data-ai-summary')) {
        return true;
      }
      current = current.parent;
    }
    return false;
  }

  static bool _isSkippedNode(dom.Element element) {
    final name = element.localName;
    if (const <String>{
      'script',
      'style',
      'noscript',
      'template',
      'nav',
      'form',
      'input',
      'button',
      'select',
      'option',
      'textarea',
    }.contains(name)) {
      return true;
    }
    if (!_isVisible(element) || _hasAiAncestor(element)) return true;
    if (element.classes.any(
      const <String>{
        'attachments',
        'attachment-list',
        'signature',
        'site-ai-summary',
      }.contains,
    )) {
      return true;
    }
    return false;
  }

  static String _plainText(dom.Element element) {
    final buffer = StringBuffer();
    void visit(dom.Node node) {
      if (node is dom.Text) {
        buffer.write(node.data);
        return;
      }
      if (node is! dom.Element || _isSkippedNode(node)) return;
      if (node.localName == 'br') {
        buffer.write(' ');
        return;
      }
      for (final child in node.nodes) {
        visit(child);
        if (const <String>{'p', 'div', 'li', 'tr'}.contains(node.localName)) {
          buffer.write(' ');
        }
      }
    }

    visit(element);
    return _normalizeSpace(buffer.toString());
  }

  static String _normalizeSpace(String value) =>
      value.replaceAll(RegExp(r'[\s\u00a0]+'), ' ').trim();

  static bool _hasClass(dom.Element? element, String className) =>
      element?.classes.contains(className) ?? false;

  static _CourseIdentity? _courseIdentity(String value) {
    final normalized = _normalizeSpace(value);
    final match = RegExp(
      r'^(.*?)[（(]([^（）()]{1,60})[）)]$',
    ).firstMatch(normalized);
    if (match == null) return null;
    final title = _normalizeSpace(match.group(1) ?? '');
    final teacher = _normalizeSpace(match.group(2) ?? '');
    if (title.isEmpty || teacher.isEmpty) return null;
    return _CourseIdentity(title, teacher);
  }

  static String? _courseTeacher(String value) {
    final normalized = _normalizeSpace(value);
    final match = RegExp(
      r'^[（(]\s*([^（）()]{1,60}?)\s*[）)]$',
    ).firstMatch(normalized);
    final teacher = _normalizeSpace(match?.group(1) ?? '');
    return teacher.isEmpty ? null : teacher;
  }

  static _CourseRating _listRating(dom.Element card) {
    final node = card.querySelector('div.ud-pd-sm.blue');
    if (node == null || !_isVisible(node)) return const _CourseRating();
    final text = _plainText(node);
    return _CourseRating(
      score: _scoreFromLabel(text),
      count: _countFromRatingLabel(text),
    );
  }

  static int? _countFromRatingLabel(String label) {
    if (RegExp(r'(?:暂无评分|未评分)').hasMatch(label)) return null;
    final match = RegExp(
      r'(\d[\d,]*)\s*(?:人|位)\s*(?:评分|评价)|(?:评分|评价)\s*(\d[\d,]*)\s*(?:人|位)',
    ).firstMatch(label);
    final digits = match?.group(1) ?? match?.group(2);
    if (digits == null) return null;
    final value = int.tryParse(digits.replaceAll(',', ''));
    if (value == null || value < 0 || value > 1000000000) return null;
    return value;
  }

  static int? _countFromLabel(String label) {
    final match = RegExp(r'(?<![\d.])(\d[\d,]*)').firstMatch(label);
    if (match == null) return null;
    final value = int.tryParse(match.group(1)!.replaceAll(',', ''));
    if (value == null || value < 0 || value > 1000000000) return null;
    return value;
  }

  static double? _scoreFromLabel(String label) {
    if (RegExp(r'(?:暂无评分|未评分)').hasMatch(label)) return null;
    final match = RegExp(r'(?<![\d.])(\d{1,2}(?:\.\d+)?)').firstMatch(label);
    if (match == null) return null;
    final value = double.tryParse(match.group(1)!);
    if (value == null || value < 0 || value > 10) return null;
    return value;
  }

  static String _courseIdFromDetailUri(Uri uri) {
    final match = RegExp(r'^/course/(\d+)/$').firstMatch(uri.path);
    if (match == null) {
      throw const PublicFailure(PublicFailureCode.unsafeTarget);
    }
    final query = _strictQuery(uri, const <String>{'term', 'sort_by'});
    final sort = query['sort_by']?.single;
    if (sort != null &&
        !const <String>{
          'upvote',
          'pubtime_desc',
          'pubtime',
          'score_desc',
          'score',
        }.contains(sort)) {
      throw const PublicFailure(PublicFailureCode.unsafeTarget);
    }
    final term = query['term']?.single;
    if (term != null &&
        term.isNotEmpty &&
        !RegExp(r'^\d{4,6}$').hasMatch(term)) {
      throw const PublicFailure(PublicFailureCode.unsafeTarget);
    }
    return match.group(1)!;
  }

  static List<PublicTerm> _courseTerms(
    dom.Document document,
    Uri base,
    String courseId,
  ) {
    final terms = <PublicTerm>[];
    final seen = <String>{};
    for (final option in document.querySelectorAll('select option')) {
      if (!_isVisible(option)) continue;
      final declared = Uri.tryParse(option.attributes['value'] ?? '');
      final termTarget = declared?.fragment == 'review-anchor'
          ? declared!.replace(fragment: '').toString()
          : option.attributes['value'];
      final target = _resolve(base, termTarget);
      if (target == null ||
          !_isOrigin(target, _icourseHost) ||
          target.path != '/course/$courseId/' ||
          target.fragment.isNotEmpty) {
        continue;
      }
      // Sort/rating controls share the same location-select shape. Only the
      // verified term shape contributes to the semester directory.
      if (!target.queryParameters.containsKey('term') ||
          target.queryParameters.keys.any(
            (k) => !{'term', 'sort_by'}.contains(k),
          )) {
        continue;
      }
      final query = _strictQuery(target, const <String>{'term', 'sort_by'});
      final code = query['term']?.single;
      if (code == null || !RegExp(r'^\d{4,6}$').hasMatch(code)) continue;
      final sort = query['sort_by']?.single;
      if (sort != null &&
          !const <String>{
            'upvote',
            'pubtime_desc',
            'pubtime',
            'score_desc',
            'score',
          }.contains(sort)) {
        continue;
      }
      var label = _normalizeSpace(option.text);
      label = label.replaceFirst(RegExp(r'\s*[（(]\d+[）)]$'), '').trim();
      // Other selects retain the chosen term in their own sort/rating URLs.
      // Validate the observed semester label before reserving that term code.
      if (!RegExp(r'^[12][0-9]{3}[春夏秋冬]$').hasMatch(label) || !seen.add(code)) {
        continue;
      }
      terms.add(PublicTerm(code: code, label: label));
    }
    return List<PublicTerm>.unmodifiable(terms);
  }

  static Uri? _icourseNextPage(
    dom.Document document,
    Uri current,
    _IcourseListRoute route,
  ) {
    final currentPage = route.page;
    final candidates = <Uri>{};
    for (final anchor in document.querySelectorAll('a[href]')) {
      if (!_isVisible(anchor) || !_insidePager(anchor)) continue;
      final isMarkedNext = _markedNext(anchor);
      final target = _resolve(current, anchor.attributes['href']);
      if (target == null || !_isOrigin(target, _icourseHost)) {
        if (isMarkedNext) {
          throw const PublicFailure(PublicFailureCode.unsafeTarget);
        }
        continue;
      }
      final candidateRoute = _IcourseListRoute.tryParse(
        target,
        allowMissingNoRedirect: true,
      );
      if (candidateRoute == null) {
        if (isMarkedNext) {
          throw const PublicFailure(PublicFailureCode.unsafeTarget);
        }
        continue;
      }
      if (candidateRoute.page != currentPage + 1) {
        if (isMarkedNext) {
          throw const PublicFailure(PublicFailureCode.unsafeTarget);
        }
        continue;
      }
      if (candidateRoute.path != route.path ||
          !route.sameQueryExceptPage(candidateRoute)) {
        throw const PublicFailure(PublicFailureCode.unsafeTarget);
      }
      candidates.add(
        route.isSearch
            ? target.replace(
                queryParameters: <String, String>{
                  ...target.queryParameters,
                  'noredirect': 'True',
                },
              )
            : target,
      );
    }
    if (candidates.length > 1) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    return candidates.isEmpty ? null : candidates.single;
  }

  static Uri? _teachNextPage(
    dom.Document document,
    Uri current,
    _TeachRoute route,
  ) {
    final candidates = <Uri>{};
    for (final anchor in document.querySelectorAll(
      'main.main > section > div.pagination > a.page-numbers[href]',
    )) {
      if (!_isVisible(anchor)) continue;
      final isMarkedNext = _markedNext(anchor);
      final target = _resolve(current, anchor.attributes['href']);
      if (target == null || !_isOrigin(target, _teachHost)) {
        if (isMarkedNext) {
          throw const PublicFailure(PublicFailureCode.unsafeTarget);
        }
        continue;
      }
      final candidate = _TeachRoute.tryParse(target, route.column);
      if (candidate == null) {
        if (isMarkedNext) {
          throw const PublicFailure(PublicFailureCode.unsafeTarget);
        }
        continue;
      }
      if (candidate.page != route.page + 1) {
        if (isMarkedNext) {
          throw const PublicFailure(PublicFailureCode.unsafeTarget);
        }
        continue;
      }
      if (!route.sameQuery(candidate)) {
        throw const PublicFailure(PublicFailureCode.unsafeTarget);
      }
      candidates.add(target);
    }
    if (candidates.length > 1) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    return candidates.isEmpty ? null : candidates.single;
  }

  static Uri? _financeNextPage(
    dom.Document document,
    Uri current,
    _FinanceRoute route,
  ) {
    final links = document.querySelectorAll(
      'div#wp_paging_w6 > ul.wp_paging.clearfix > li.page_nav > a.next',
    );
    if (links.isEmpty) return null;
    if (links.length != 1 || !_isVisible(links.single)) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    final href = links.single.attributes['href'];
    if (href == null || href.trim().isEmpty) {
      if (links.single.attributes['aria-disabled']?.toLowerCase() == 'true' ||
          links.single.classes.contains('disabled')) {
        return null;
      }
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    if (href == 'javascript:void(0);') {
      final pages = _financeCurrentPages(document, route);
      if (pages == null || pages.$1 != route.page || pages.$1 != pages.$2) {
        throw const PublicFailure(PublicFailureCode.unsafeTarget);
      }
      return null;
    }
    final target = _resolve(current, href);
    if (target == null || !_isOrigin(target, _financeHost)) {
      throw const PublicFailure(PublicFailureCode.unsafeTarget);
    }
    final candidate = _FinanceRoute.tryParse(target, route.column);
    if (candidate == null || candidate.page != route.page + 1) {
      throw const PublicFailure(PublicFailureCode.unsafeTarget);
    }
    return target;
  }

  static (int, int)? _financeCurrentPages(
    dom.Document document,
    _FinanceRoute route,
  ) {
    final nodes = document.querySelectorAll('div#wp_paging_w6 span.pages');
    if (nodes.length != 1 || !_isVisible(nodes.single)) return null;
    final match = RegExp(
      r'^页码\s*(\d+)\s*/\s*(\d+)$',
    ).firstMatch(_plainText(nodes.single));
    if (match == null) return null;
    final currentPage = int.tryParse(match.group(1)!);
    final totalPages = int.tryParse(match.group(2)!);
    if (currentPage == null ||
        totalPages == null ||
        currentPage < 1 ||
        currentPage > totalPages ||
        currentPage != route.page) {
      return null;
    }
    return (currentPage, totalPages);
  }

  static int? _financeReportedCount(dom.Document document) {
    final nodes = document.querySelectorAll('div#wp_paging_w6 span.all_count');
    if (nodes.length != 1 || !_isVisible(nodes.single)) return null;
    final match = RegExp(
      r'^总共\s*([\d,]+)\s*记录$',
    ).firstMatch(_plainText(nodes.single));
    final value = int.tryParse(match?.group(1)?.replaceAll(',', '') ?? '');
    if (value == null || value < 0 || value > 1000000000) return null;
    return value;
  }

  static bool _insidePager(dom.Element element) {
    dom.Node? parent = element;
    while (parent is dom.Element) {
      if (parent.classes.any(
            (name) => const <String>{
              'pagination',
              'pager',
              'paging',
              'page-numbers',
              'page-links',
            }.contains(name),
          ) ||
          parent.id == 'pagination' ||
          parent.id == 'pager') {
        return true;
      }
      parent = parent.parent;
    }
    return element.attributes['rel']?.toLowerCase() == 'next' ||
        element.classes.contains('next');
  }

  static bool _markedNext(dom.Element element) {
    final relations = element.attributes['rel']?.toLowerCase().split(
      RegExp(r'\s+'),
    );
    if (relations?.contains('next') == true ||
        element.classes.contains('next')) {
      return true;
    }
    return RegExp(
      r'^(?:next|下一页|下页|后页|›|»)$',
      caseSensitive: false,
    ).hasMatch(_normalizeSpace(element.text));
  }

  static Map<String, List<String>> _strictQuery(Uri uri, Set<String> allowed) {
    final all = uri.queryParametersAll;
    if (all.keys.any((key) => !allowed.contains(key)) ||
        all.values.any((values) => values.length != 1)) {
      throw const PublicFailure(PublicFailureCode.unsafeTarget);
    }
    return all;
  }

  static String? _dateValue(dom.Element? node) {
    if (node == null || !_isVisible(node)) return null;
    final value = _plainText(node);
    if (value.isEmpty) return null;
    return value.replaceFirst(
      RegExp(r'^(?:发布时间|发布日期|发布|更新时间|最后修改时间|更新日期)\s*[:：]?\s*'),
      '',
    );
  }

  static bool _isExpectedArticleUri(Uri uri, PublicProvider provider) {
    return provider != PublicProvider.icourse &&
        uri.query.isEmpty &&
        isRegisteredPublicArticlePath(uri.path, provider);
  }

  static String _articleTitle(dom.Document document, dom.Element scope) {
    final local = scope.querySelector('h1');
    final titleNode = local != null && _isVisible(local)
        ? local
        : document.querySelector('h1');
    final title = titleNode == null ? '' : _plainText(titleNode);
    if (title.isEmpty) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    return title;
  }

  static bool _skipTeachArticleChild(dom.Element element, String title) {
    if (_isSkippedNode(element) ||
        const <String>{
          'aside',
          'address',
          'nav',
          'form',
          'header',
          'footer',
        }.contains(element.localName)) {
      return true;
    }
    if (element.classes.any(
      const <String>{
        'attachments',
        'post-meta',
        'post-meta-print',
        'post-title',
      }.contains,
    )) {
      return true;
    }
    if (element.localName == 'h1' && _plainText(element) == title) return true;
    return false;
  }

  static dom.Element? _closestListItem(dom.Element element) {
    dom.Node? current = element.parent;
    while (current is dom.Element) {
      if (current.localName == 'li') return current;
      if (current.localName == 'main') break;
      current = current.parent;
    }
    return null;
  }

  static _LimitedText _limitText(String value) {
    final normalized = value.trim();
    if (normalized.length <= _maxSnapshotCharacters) {
      return _LimitedText(normalized, true);
    }
    return _LimitedText(normalized.substring(0, _maxSnapshotCharacters), false);
  }
}

final class _IcourseListRoute {
  const _IcourseListRoute({
    required this.path,
    required this.page,
    required this.query,
    required this.isSearch,
    this.keyword,
  });

  final String path;
  final int page;
  final Map<String, List<String>> query;
  final bool isSearch;
  final String? keyword;

  static _IcourseListRoute parse(Uri uri) {
    final value = tryParse(uri);
    if (value == null) {
      throw const PublicFailure(PublicFailureCode.unsafeTarget);
    }
    return value;
  }

  static _IcourseListRoute? tryParse(
    Uri uri, {
    bool allowMissingNoRedirect = false,
  }) {
    if (!FixedPublicHtmlParser._isOrigin(
          uri,
          FixedPublicHtmlParser._icourseHost,
        ) ||
        uri.fragment.isNotEmpty) {
      return null;
    }
    final isCourseIndex = uri.path == '/course/';
    final isSearch = uri.path == '/search/';
    if (!isCourseIndex && !isSearch) return null;
    final allowed = isCourseIndex
        ? const <String>{'course_type', 'sort_by', 'page'}
        : const <String>{'q', 'page', 'term', 'noredirect'};
    final query = _safeQuery(uri, allowed);
    if (query == null) return null;
    final pageText = query['page']?.single ?? '1';
    final page = int.tryParse(pageText);
    if (page == null || page < 1 || page > 10000) return null;
    if (isCourseIndex) {
      final type = query['course_type']?.single;
      final sort = query['sort_by']?.single;
      if (type != null &&
          !const <String>{
            'liberal',
            'physical',
            'english',
            'mooc',
            'dual-degree',
            'graduate',
          }.contains(type)) {
        return null;
      }
      if (sort != null && !const <String>{'rating', 'popular'}.contains(sort)) {
        return null;
      }
    } else {
      final keyword = query['q']?.single;
      final term = query['term']?.single;
      final noRedirect = query['noredirect']?.single;
      if (keyword == null ||
          keyword.trim().isEmpty ||
          keyword.runes.length > 80 ||
          (noRedirect != 'True' &&
              !(allowMissingNoRedirect && noRedirect == null))) {
        return null;
      }
      if (term != null &&
          term.isNotEmpty &&
          !RegExp(r'^\d{4,6}$').hasMatch(term)) {
        return null;
      }
    }
    return _IcourseListRoute(
      path: uri.path,
      page: page,
      query: query,
      isSearch: isSearch,
      keyword: query['q']?.single,
    );
  }

  bool sameQueryExceptPage(_IcourseListRoute other) {
    final left = Map<String, List<String>>.from(query)..remove('page');
    final right = Map<String, List<String>>.from(other.query)..remove('page');
    left.remove('noredirect');
    right.remove('noredirect');
    if (left['term']?.single.isEmpty == true) left.remove('term');
    if (right['term']?.single.isEmpty == true) right.remove('term');
    return _sameMap(left, right);
  }
}

final class _TeachRoute {
  const _TeachRoute({
    required this.column,
    required this.path,
    required this.page,
    required this.keyword,
  });

  final CampusColumn column;
  final String path;
  final int page;
  final String? keyword;

  static _TeachRoute parse(Uri uri, CampusColumn column) {
    final route = tryParse(uri, column);
    if (route == null) {
      throw const PublicFailure(PublicFailureCode.unsafeTarget);
    }
    return route;
  }

  static _TeachRoute? tryParse(Uri uri, CampusColumn column) {
    if (!FixedPublicHtmlParser._isOrigin(
      uri,
      FixedPublicHtmlParser._teachHost,
    )) {
      return null;
    }
    final query = _safeQuery(uri, const <String>{'s'});
    if (query == null) return null;
    final keyword = query['s']?.single;
    if (keyword != null &&
        (keyword.trim().isEmpty || keyword.runes.length > 80)) {
      return null;
    }
    final path = switch (column) {
      CampusColumn.teachNotice => '/category/notice',
      CampusColumn.teachStudentService => '/category/service/svc-student',
      _ => null,
    };
    if (path == null) return null;
    final match = RegExp(
      '^${RegExp.escape(path)}'
      r'(?:/page/(\d+))?/?$',
    ).firstMatch(uri.path);
    if (match == null) return null;
    final page = int.tryParse(match.group(1) ?? '1');
    if (page == null || page < 1 || page > 10000) return null;
    if (column == CampusColumn.teachStudentService &&
        page > 1 &&
        keyword == null) {
      return null;
    }
    return _TeachRoute(
      column: column,
      path: path,
      page: page,
      keyword: keyword,
    );
  }

  bool sameQuery(_TeachRoute other) =>
      column == other.column && keyword == other.keyword;
}

final class _FinanceRoute {
  const _FinanceRoute({
    required this.column,
    required this.prefix,
    required this.extension,
    required this.page,
  });

  final CampusColumn column;
  final String prefix;
  final String extension;
  final int page;

  static const Map<CampusColumn, (String, String)> _paths =
      <CampusColumn, (String, String)>{
        CampusColumn.financeNotice: ('/tzgg/', 'htm'),
        CampusColumn.financeBusiness: ('/ywzn/', 'psp'),
        CampusColumn.financeProcess: ('/22118/', 'psp'),
        CampusColumn.financeOperation: ('/22119/', 'psp'),
        CampusColumn.financeFaq: ('/22120/', 'psp'),
      };

  static _FinanceRoute parse(Uri uri, CampusColumn column) {
    final route = tryParse(uri, column);
    if (route == null) {
      throw const PublicFailure(PublicFailureCode.unsafeTarget);
    }
    return route;
  }

  static _FinanceRoute? tryParse(Uri uri, CampusColumn column) {
    if (!FixedPublicHtmlParser._isOrigin(
          uri,
          FixedPublicHtmlParser._financeHost,
        ) ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      return null;
    }
    final expected = _paths[column];
    if (expected == null) return null;
    final prefix = expected.$1;
    final extension = expected.$2;
    final stem = prefix.substring(0, prefix.length - 1);
    final match = RegExp(
      '^${RegExp.escape(stem)}/list(\\d*)\\.(htm|psp)\$',
    ).firstMatch(uri.path);
    if (match == null) return null;
    final page = match.group(1)!.isEmpty ? 1 : int.tryParse(match.group(1)!);
    if (page == null || page < 1 || page > 10000) return null;
    // Page one is tied to the fixed extension from the source reference.
    if (page == 1 && !uri.path.endsWith('.$extension')) return null;
    // These two .psp columns are observed to redirect listN.htm to listN.psp.
    // Keep the alias on the same fixed route and page number only.
    final acceptsPspAlias =
        column == CampusColumn.financeBusiness ||
        column == CampusColumn.financeProcess;
    if (page > 1 &&
        match.group(2) != 'htm' &&
        !(acceptsPspAlias && match.group(2) == 'psp')) {
      return null;
    }
    return _FinanceRoute(
      column: column,
      prefix: prefix,
      extension: extension,
      page: page,
    );
  }
}

Map<String, List<String>>? _safeQuery(Uri uri, Set<String> allowed) {
  final all = uri.queryParametersAll;
  if (all.keys.any((key) => !allowed.contains(key)) ||
      all.values.any((values) => values.length != 1)) {
    return null;
  }
  return all;
}

bool _sameMap(Map<String, List<String>> left, Map<String, List<String>> right) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    final other = right[entry.key];
    if (other == null || other.length != entry.value.length) return false;
    for (var index = 0; index < other.length; index++) {
      if (other[index] != entry.value[index]) return false;
    }
  }
  return true;
}

final class _CourseIdentity {
  const _CourseIdentity(this.title, this.teacher);
  final String title;
  final String teacher;
}

final class _CourseRating {
  const _CourseRating({this.score, this.count});
  final double? score;
  final int? count;
}

final class _LimitedText {
  const _LimitedText(this.text, this.complete);
  final String text;
  final bool complete;
}

final class _RenderedContent {
  const _RenderedContent(this.markdown, this.attachments, this.complete);
  final String markdown;
  final List<Uri> attachments;
  final bool complete;
}

final class _MarkdownRenderer {
  _MarkdownRenderer(this.baseUri, this.provider);

  final Uri baseUri;
  final PublicProvider provider;
  final List<Uri> _attachments = <Uri>[];
  final Set<String> _attachmentKeys = <String>{};
  bool _complete = true;

  _RenderedContent renderNodes(Iterable<dom.Node> nodes) {
    final markdown = _renderBlocks(nodes).trim();
    return _RenderedContent(
      markdown,
      List<Uri>.unmodifiable(_attachments),
      _complete,
    );
  }

  _RenderedContent renderElementChildren(dom.Element element) =>
      renderNodes(element.nodes);

  String _renderBlocks(Iterable<dom.Node> nodes) {
    final chunks = <String>[];
    for (final node in nodes) {
      final rendered = _renderBlock(node);
      if (rendered.trim().isNotEmpty) chunks.add(rendered.trim());
    }
    return chunks.join('\n\n');
  }

  String _renderBlock(dom.Node node) {
    if (node is dom.Text) return _escapeText(node.data.trim());
    if (node is! dom.Element || _skip(node)) return '';
    final tag = node.localName ?? '';
    if (tag == 'table') return _renderTable(node);
    if (tag == 'ul' || tag == 'ol') return _renderList(node, 0);
    if (RegExp(r'^h[1-6]$').hasMatch(tag)) {
      final level = int.parse(tag.substring(1));
      return '${'#' * level} ${_renderInlineChildren(node).trim()}';
    }
    if (tag == 'p' || tag == 'blockquote') {
      final value = _renderInlineChildren(node).trim();
      return tag == 'blockquote' ? '> $value' : value;
    }
    if (tag == 'br') return '\n';
    if (tag == 'img') return _renderImage(node);
    if (tag == 'iframe' || tag == 'object' || tag == 'embed') {
      return _renderEmbedded(node);
    }
    if (tag == 'hr') return '---';
    return _renderBlocks(node.nodes);
  }

  String _renderInline(dom.Node node) {
    if (node is dom.Text) return _escapeText(node.data);
    if (node is! dom.Element || _skip(node)) return '';
    final tag = node.localName;
    if (tag == 'br') return ' ';
    if (tag == 'img') return _renderImage(node);
    if (tag == 'iframe' || tag == 'object' || tag == 'embed') {
      return _renderEmbedded(node);
    }
    if (tag == 'a') {
      final label = _renderInlineChildren(node).trim();
      final target = _safeSourceLink(node.attributes['href']);
      if (target == null || label.isEmpty) return label;
      if (_isAttachment(target)) {
        _addAttachment(target);
        if (_isPdf(target)) _complete = false;
      }
      return '[$label](${_markdownUrl(target)})';
    }
    if (tag == 'strong' || tag == 'b') {
      return '**${_renderInlineChildren(node).trim()}**';
    }
    if (tag == 'em' || tag == 'i') {
      return '*${_renderInlineChildren(node).trim()}*';
    }
    return _renderInlineChildren(node);
  }

  String _renderInlineChildren(dom.Element element) =>
      element.nodes.map(_renderInline).join();

  String _renderImage(dom.Element image) {
    _complete = false;
    final target = _safeSourceLink(image.attributes['src']);
    if (target != null && _isImage(target)) {
      _addAttachment(target);
      final label = image.attributes['alt']?.trim();
      return label == null || label.isEmpty
          ? '[图示内容未读取](${_markdownUrl(target)})'
          : '[图示内容未读取：${_escapeText(label)}](${_markdownUrl(target)})';
    }
    return '[图示内容未读取]';
  }

  String _renderEmbedded(dom.Element element) {
    _complete = false;
    final raw = element.attributes['src'] ?? element.attributes['data'];
    final target = _safeSourceLink(raw);
    if (target != null && _isAttachment(target)) {
      _addAttachment(target);
      return '[嵌入材料正文未读取](${_markdownUrl(target)})';
    }
    return '[嵌入材料正文未读取]';
  }

  String _renderList(dom.Element list, int depth) {
    final items = <String>[];
    final ordered = list.localName == 'ol';
    var number = 1;
    for (final child in list.children.where((item) => item.localName == 'li')) {
      if (_skip(child)) continue;
      final body = <String>[];
      for (final node in child.nodes) {
        if (node is dom.Element &&
            (node.localName == 'ul' || node.localName == 'ol')) {
          continue;
        }
        final rendered = _renderInline(node).trim();
        if (rendered.isNotEmpty) body.add(rendered);
      }
      final prefix = ordered ? '${number++}. ' : '- ';
      final indent = '  ' * depth;
      var line = '$indent$prefix${body.join(' ')}';
      for (final nested in child.children.where(
        (item) => item.localName == 'ul' || item.localName == 'ol',
      )) {
        line += '\n${_renderList(nested, depth + 1)}';
      }
      items.add(line);
    }
    return items.join('\n');
  }

  String _renderTable(dom.Element table) {
    const maxRows = 1000;
    const maxColumns = 40;
    const maxSpan = 1000;
    final rowGroups = <int, List<dom.Element>>{};
    var nextGroup = 0;
    void collect(dom.Element node, int group) {
      for (final child in node.children) {
        if (child.localName == 'table') continue;
        if (const <String>{
          'thead',
          'tbody',
          'tfoot',
        }.contains(child.localName)) {
          final childGroup = ++nextGroup;
          rowGroups[childGroup] = <dom.Element>[];
          collect(child, childGroup);
          continue;
        }
        if (child.localName == 'tr') {
          rowGroups.putIfAbsent(group, () => <dom.Element>[]).add(child);
        } else {
          collect(child, group);
        }
      }
    }

    collect(table, 0);
    final groups = rowGroups.values.where((rows) => rows.isNotEmpty).toList();
    final rowCount = groups.fold<int>(0, (count, rows) => count + rows.length);
    if (rowCount > maxRows) {
      throw const PublicFailure(PublicFailureCode.resourceLimit);
    }
    if (rowCount == 0) return '';

    var currentGroupRowCount = 0;
    int parseSpan(dom.Element cell, String name, int rowIndex) {
      final raw = cell.attributes[name];
      if (raw == null) return 1;
      final valueText = raw.trim();
      if (!RegExp(r'^\d+$').hasMatch(valueText)) {
        throw const PublicFailure(PublicFailureCode.sourceSchema);
      }
      final value = int.tryParse(valueText);
      if (value == null || value > maxSpan) {
        throw const PublicFailure(PublicFailureCode.resourceLimit);
      }
      if (value == 0 && name == 'rowspan') {
        return currentGroupRowCount - rowIndex;
      }
      if (value < 1) {
        throw const PublicFailure(PublicFailureCode.sourceSchema);
      }
      return value;
    }

    final gridRows = <List<String?>>[];
    var width = 0;
    for (final rows in groups) {
      currentGroupRowCount = rows.length;
      final grid = List<List<String?>>.generate(
        rows.length,
        (_) => List<String?>.filled(maxColumns, null),
      );
      for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
        final cells = rows[rowIndex].children.where(
          (cell) => cell.localName == 'th' || cell.localName == 'td',
        );
        var column = 0;
        for (final cell in cells) {
          while (column < maxColumns && grid[rowIndex][column] != null) {
            column++;
          }
          final columnSpan = parseSpan(cell, 'colspan', rowIndex);
          final rowSpan = parseSpan(cell, 'rowspan', rowIndex);
          if (column >= maxColumns || column + columnSpan > maxColumns) {
            throw const PublicFailure(PublicFailureCode.resourceLimit);
          }
          if (rowIndex + rowSpan > rows.length) {
            throw const PublicFailure(PublicFailureCode.sourceSchema);
          }
          for (
            var spanRow = rowIndex;
            spanRow < rowIndex + rowSpan;
            spanRow++
          ) {
            for (
              var spanColumn = column;
              spanColumn < column + columnSpan;
              spanColumn++
            ) {
              if (grid[spanRow][spanColumn] != null) {
                throw const PublicFailure(PublicFailureCode.sourceSchema);
              }
            }
          }
          final text = _renderCell(cell);
          for (
            var spanRow = rowIndex;
            spanRow < rowIndex + rowSpan;
            spanRow++
          ) {
            for (
              var spanColumn = column;
              spanColumn < column + columnSpan;
              spanColumn++
            ) {
              grid[spanRow][spanColumn] = text;
            }
          }
          column += columnSpan;
          if (column > width) width = column;
        }
      }
      gridRows.addAll(grid);
    }
    if (width == 0) return '';

    final output = StringBuffer();
    var outputCharacters = 0;
    var outputTruncated = false;
    void append(String text) {
      if (text.isEmpty || outputTruncated) return;
      final remaining =
          FixedPublicHtmlParser._maxSnapshotCharacters - outputCharacters;
      if (text.length <= remaining) {
        output.write(text);
        outputCharacters += text.length;
      } else {
        if (remaining > 0) {
          output.write(text.substring(0, remaining));
          outputCharacters += remaining;
        }
        outputTruncated = true;
        _complete = false;
      }
    }

    void renderRow(List<String?> row) {
      append('| ');
      for (var column = 0; column < width; column++) {
        if (column > 0) append(' | ');
        append(row[column] ?? '');
      }
      append(' |');
    }

    renderRow(gridRows.first);
    append('\n| ${List<String>.filled(width, '---').join(' | ')} |');
    for (final row in gridRows.skip(1)) {
      append('\n');
      renderRow(row);
    }
    return output.toString();
  }

  String _renderCell(dom.Element cell) {
    final buffer = StringBuffer();
    void visit(dom.Node node) {
      if (node is dom.Text) {
        buffer.write(_escapeText(node.data));
      } else if (node is dom.Element && !_skip(node)) {
        if (node.localName == 'br') {
          buffer.write(' / ');
        } else if (node.localName == 'a' ||
            node.localName == 'img' ||
            node.localName == 'iframe' ||
            node.localName == 'object' ||
            node.localName == 'embed') {
          buffer.write(_renderInline(node));
        } else {
          for (final child in node.nodes) {
            visit(child);
          }
        }
      }
    }

    visit(cell);
    return buffer.toString().replaceAll(RegExp(r'[\s\u00a0]+'), ' ').trim();
  }

  Uri? _safeSourceLink(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final parsed = Uri.tryParse(raw.trim());
    if (parsed == null) return null;
    late final Uri resolved;
    try {
      resolved = baseUri.resolveUri(parsed);
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
    final host = switch (provider) {
      PublicProvider.icourse => FixedPublicHtmlParser._icourseHost,
      PublicProvider.teach => FixedPublicHtmlParser._teachHost,
      PublicProvider.finance => FixedPublicHtmlParser._financeHost,
    };
    if (!FixedPublicHtmlParser._isOrigin(resolved, host) ||
        resolved.fragment.isNotEmpty ||
        resolved.queryParameters.keys.any(
          FixedPublicHtmlParser._sensitiveQueryName,
        ) ||
        RegExp(
          r'/(?:login|sso|auth)(?:/|$)',
          caseSensitive: false,
        ).hasMatch(resolved.path)) {
      return null;
    }
    return resolved;
  }

  bool _isAttachment(Uri uri) => RegExp(
    r'\.(?:pdf|png|jpe?g|gif|webp|bmp|docx?|xlsx?|pptx?|zip)$',
    caseSensitive: false,
  ).hasMatch(uri.path);

  bool _isImage(Uri uri) => RegExp(
    r'\.(?:png|jpe?g|gif|webp|bmp)$',
    caseSensitive: false,
  ).hasMatch(uri.path);

  bool _isPdf(Uri uri) => uri.path.toLowerCase().endsWith('.pdf');

  void _addAttachment(Uri uri) {
    final key = uri.toString();
    if (_attachmentKeys.add(key) && _attachments.length < 100) {
      _attachments.add(uri);
    }
    if (_attachments.length >= 100) _complete = false;
  }

  bool _skip(dom.Element element) {
    if (FixedPublicHtmlParser._isSkippedNode(element)) return true;
    if (const <String>{'aside', 'address'}.contains(element.localName)) {
      return true;
    }
    return false;
  }

  static String _escapeText(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('|', r'\|')
      .replaceAll('[', r'\[')
      .replaceAll(']', r'\]');

  static String _markdownUrl(Uri uri) => uri.toString().replaceAll(')', r'\)');
}
