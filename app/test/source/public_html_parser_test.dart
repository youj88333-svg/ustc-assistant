import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/public_query_contract.dart';
import 'package:ustc_assistant_m0/source/public_html_parser.dart';

const FixedPublicHtmlParser _parser = FixedPublicHtmlParser();

String _courseDetailHtml(int reviewCount, String reviewBlocks) =>
    '''
  <html><body>
    <div class="col-md-8 inline-h3">
      <span class="blue h3">合成课程</span>
      <span class="h3 blue mobile">（合成教师）</span>
    </div>
    <div class="desktop ud-pd-sm blue">
      9.0 <span class="rl-pd-sm text-muted">3人评分</span>
    </div>
    <div class="ud-pd-sm review-header">
      <span class="rl-pd-sm text-muted">$reviewCount条点评</span>
    </div>
    <select>
      <option value="/course/13486/?term=20251">2025秋（9）</option>
      <option value="/course/13486/?term=20242">2024秋（4）</option>
    </select>
    $reviewBlocks
  </body></html>
''';

String _reviewHtml(String id, String term, String content) =>
    '''
  <div id="review-$id" class="ud-pd-md dashed review">
    <div class="blue ud-pd-sm"><span class="left-pd-md">$term</span></div>
    <div id="review-content-$id" class="review-content ck-content"><p>$content</p></div>
  </div>
''';

String _financePageHtml(String pages, String nextHref) =>
    '''
  <html><body>
    <div id="wp_news_w6"><ul class="news_list list2">
      <li class="news n14 clearfix">
        <span class="news_title"><a href="/2025/1128/c21817a712082/page.psp">合成财政指南</a></span>
        <span class="news_meta">2025-11-28</span>
      </li>
    </ul></div>
    <div id="wp_paging_w6"><ul class="wp_paging clearfix">
      <span class="all_count">总共 10 记录</span>
      <span class="pages">页码 $pages</span>
      <li class="page_nav"><a class="next" href="$nextHref">下一页</a></li>
    </ul></div>
  </body></html>
''';

String _teachNoticeHtml(List<String?> dates, {String? stickyDate}) {
  final rows = <String>[
    if (stickyDate != null)
      '''<li class="post-999 post type-post status-publish sticky">
        <span class="post"><a href="/notice/notice-teaching/999.html">置顶通知</a></span>
        <span class="date">$stickyDate</span>
      </li>''',
    for (var index = 0; index < dates.length; index++)
      '''<li class="post-${index + 1} post type-post status-publish">
        <span class="post"><a href="/notice/notice-teaching/${index + 1}.html">通知${index + 1}</a></span>
        ${dates[index] == null ? '' : '<span class="date">${dates[index]}</span>'}
      </li>''',
  ];
  return '''<html><body><main class="main"><section>
    <ul class="article-list with-tag">${rows.join()}</ul>
  </section></main></body></html>''';
}

String _financeNoticeHtml(List<String?> dates, {String? stickyDate}) {
  final rows = <String>[
    if (stickyDate != null)
      '''<li class="news sticky clearfix">
        <span class="news_title"><a href="/2026/1014/c21813a748899/page.psp">置顶通知</a></span>
        <span class="news_meta">$stickyDate</span>
      </li>''',
    for (var index = 0; index < dates.length; index++)
      '''<li class="news n$index clearfix">
        <span class="news_title"><a href="/2026/1015/c21813a${748900 + index}/page.psp">通知${index + 1}</a></span>
        ${dates[index] == null ? '' : '<span class="news_meta">${dates[index]}</span>'}
      </li>''',
  ];
  return '''<html><body><div id="wp_news_w6"><ul class="news_list list2">
    ${rows.join()}
  </ul></div></body></html>''';
}

String _financeArticleHtml(String content) =>
    '''
  <html><body>
    <h1>合成财务表格</h1>
    <div class="infobox"><div class="article"><div class="entry"><div class="read">
      <div class="wp_articlecontent">$content</div>
    </div></div></div></div>
  </body></html>
''';

void _expectFailure(PublicFailureCode code, void Function() action) {
  expect(
    action,
    throwsA(
      isA<PublicFailure>().having((failure) => failure.code, 'code', code),
    ),
  );
}

void main() {
  group('FixedPublicHtmlParser', () {
    test('parses an icourse candidate tuple and a real next-page link', () {
      const html = '''
        <html><body>
          <div class="ud-pd-md dashed">
            <a class="px16" href="/course/13486/">数学分析(B1)（程艺）</a>
            <div class="ud-pd-sm blue">9.9 <span>48人评分</span></div>
          </div>
          <div class="pagination">
            <a class="page-numbers" href="?q=数学分析&amp;page=2&amp;term=">2</a>
          </div>
        </body></html>
      ''';

      final page = _parser.courses(
        html,
        Uri.parse(
          'https://icourse.club/search/?q=%E6%95%B0%E5%AD%A6%E5%88%86%E6%9E%90&term=&noredirect=True',
        ),
      );

      expect(page.items, hasLength(1));
      expect(page.items.single.key, '13486:程艺');
      expect(page.items.single.course?.courseKey, '13486');
      expect(page.items.single.course?.title, '数学分析(B1)');
      expect(page.items.single.course?.teacher, '程艺');
      expect(page.items.single.course?.score, 9.9);
      expect(page.items.single.course?.ratingCount, 48);
      expect(page.items.single.course?.reviewCount, isNull);
      expect(page.nextPage?.queryParameters['q'], '数学分析');
      expect(page.nextPage?.queryParameters['page'], '2');
      expect(page.nextPage?.queryParameters['term'], '');
      expect(page.nextPage?.queryParameters['noredirect'], 'True');
    });

    test('accepts only the observed icourse no-course result state', () {
      const empty = '''<html><body>
        <span class="blue h4 desktop">您的搜索「synthetic-no-match」没有匹配到任何课程或老师</span>
        <span class="blue h5 mobile">您的搜索「synthetic-no-match」没有匹配到任何课程或老师</span>
      </body></html>''';
      final page = _parser.courses(
        empty,
        Uri.parse(
          'https://icourse.club/search/?q=synthetic-no-match&noredirect=True',
        ),
      );
      expect(page.items, isEmpty);
      _expectFailure(
        PublicFailureCode.unsafeTarget,
        () => _parser.courses(
          empty,
          Uri.parse('https://icourse.club/search/?q=synthetic-no-match'),
        ),
      );
      _expectFailure(
        PublicFailureCode.unsafeTarget,
        () => _parser.courses(
          empty,
          Uri.parse(
            'https://icourse.club/search/?q=synthetic-no-match&noredirect=False',
          ),
        ),
      );

      _expectFailure(
        PublicFailureCode.sourceSchema,
        () => _parser.courses(
          '<html><body><main></main></body></html>',
          Uri.parse(
            'https://icourse.club/search/?q=synthetic-no-match&noredirect=True',
          ),
        ),
      );
      _expectFailure(
        PublicFailureCode.sourceSchema,
        () => _parser.courses(
          '''<html><body>
            <span class="blue h4 desktop">您的搜索「synthetic-no-match」没有匹配到任何点评</span>
            <span class="blue h5 mobile">您的搜索「synthetic-no-match」没有匹配到任何点评</span>
          </body></html>''',
          Uri.parse(
            'https://icourse.club/search/?q=synthetic-no-match&noredirect=True',
          ),
        ),
      );
    });

    test(
      'keeps course rating count separate from comments and excludes replies',
      () {
        const html = '''
        <html><body>
          <div class="col-md-8 inline-h3">
            <span class="blue h3">数学分析(B1)</span>
            <span class="h3 blue mobile">（程艺）</span>
          </div>
          <div class="desktop ud-pd-sm blue">
            9.9 <span class="rl-pd-sm text-muted">48人评分</span>
          </div>
          <div class="ud-pd-sm review-header">
            <span class="rl-pd-sm text-muted">2条点评</span>
          </div>
          <select>
            <option value="/course/13486/?term=20251&amp;sort_by=upvote">2025秋（9）</option>
            <option value="/course/13486/?term=20242&amp;sort_by=upvote">2024秋（4）</option>
          </select>
          <div id="review-101" class="ud-pd-md dashed review">
            <div class="blue ud-pd-sm"><span class="left-pd-md">2025秋</span></div>
            <div id="review-content-101" class="review-content ck-content">
              <p>公开点评正文。</p>
              <div class="ai-summary">站点生成的隐藏总结。</div>
              <span hidden>隐藏内容。</span>
            </div>
            <a class="author" href="/user/123/">作者档案</a>
            <div id="review-101-comments" class="review-comments panel panel-default">
              <div class="panel-body"><div class="ud-pd-sm solid">回复文字不属于点评。</div></div>
            </div>
          </div>
          <div id="review-102" class="ud-pd-md dashed review">
            <div class="alert alert-warning"><span>该点评已删除</span></div>
          </div>
        </body></html>
      ''';

        final document = _parser.course(
          html,
          Uri.parse(
            'https://icourse.club/course/13486/?term=20251&sort_by=upvote',
          ),
        );

        expect(document.course?.courseKey, '13486');
        expect(document.course?.teacher, '程艺');
        expect(document.course?.score, 9.9);
        expect(document.course?.ratingCount, 48);
        expect(document.course?.reviewCount, 2);
        expect(document.course?.terms, hasLength(2));
        expect(document.course?.terms.first.code, '20251');
        expect(document.course?.terms.first.label, '2025秋');
        expect(document.reviews, hasLength(1));
        expect(document.reviews.single.term, '2025秋');
        expect(document.reviews.single.locator, 'review-101');
        expect(document.reviews.single.text, contains('公开点评正文'));
        expect(document.reviews.single.text, isNot(contains('隐藏总结')));
        expect(document.reviews.single.text, isNot(contains('隐藏内容')));
        expect(document.reviews.single.text, isNot(contains('回复文字')));
        expect(document.reviews.single.text, isNot(contains('作者档案')));
        expect(document.excluded, 1);
        expect(document.contentComplete, isTrue);
        expect(document.markdown, isEmpty);
      },
    );

    test('accepts a valid course page with no public reviews', () {
      final document = _parser.course(
        _courseDetailHtml(0, ''),
        Uri.parse('https://icourse.club/course/13486/'),
      );

      expect(document.course?.reviewCount, 0);
      expect(document.reviews, isEmpty);
      expect(document.contentComplete, isTrue);
    });

    test('keeps semester options with the observed review fragment only', () {
      final document = _parser.course('''<html><body>
          <div class="col-md-8 inline-h3">
            <span class="blue h3">合成课程</span>
            <span class="h3 blue mobile">（合成教师）</span>
          </div>
          <div class="desktop ud-pd-sm blue">
            9.0 <span class="rl-pd-sm text-muted">3人评分</span>
          </div>
          <div class="ud-pd-sm review-header">
            <span class="rl-pd-sm text-muted">0条点评</span>
          </div>
          <select class="terms">
            <option value="/course/13486/?term=20251&amp;sort_by=upvote#review-anchor">2025秋（9）</option>
            <option value="/course/13486/?term=20242&amp;sort_by=upvote#review-anchor">2024秋（4）</option>
          </select>
          <select class="sort">
            <option value="/course/13486/?sort_by=upvote">优先推荐</option>
            <option value="/course/13486/?sort_by=pubtime_desc">最新点评</option>
          </select>
        </body></html>''', Uri.parse('https://icourse.club/course/13486/'));

      expect(document.course?.terms, hasLength(2));
      expect(document.course?.terms.map((term) => term.code), <String>[
        '20251',
        '20242',
      ]);
      expect(document.course?.terms.map((term) => term.label), <String>[
        '2025秋',
        '2024秋',
      ]);
      expect(document.contentComplete, isTrue);
    });

    test(
      'sort controls retaining term do not hide selected semester reviews',
      () {
        final html =
            _courseDetailHtml(
              1,
              _reviewHtml('209', '2025秋', '选中学期的公开点评'),
            ).replaceFirst('<select>', '''
        <select class="sort">
          <option value="/course/13486/?term=20251&amp;sort_by=upvote#review-anchor">点赞最多</option>
          <option value="/course/13486/?term=20251&amp;sort_by=pubtime_desc#review-anchor">最新点评</option>
        </select>
        <select class="rating">
          <option value="/course/13486/?term=20251#review-anchor">全部</option>
        </select>
        <select>''');
        final document = _parser.course(
          html,
          Uri.parse(
            'https://icourse.club/course/13486/?term=20251&sort_by=pubtime_desc',
          ),
        );
        expect(document.course!.terms.map((term) => term.label), [
          '2025秋',
          '2024秋',
        ]);
        expect(document.reviews.single.text, '选中学期的公开点评');
        expect(document.reviews.single.term, '2025秋');
        expect(document.excluded, 0);
        expect(document.contentComplete, isTrue);
      },
    );

    test('retains long single and multiple reviews for paged C2 reads', () {
      final singleTail = '单篇尾部定位标记';
      final singleText = '单篇开头${'甲' * 13000}$singleTail';
      final single = _parser.course(
        _courseDetailHtml(1, _reviewHtml('201', '2025秋', singleText)),
        Uri.parse('https://icourse.club/course/13486/'),
      );

      expect(single.reviews, hasLength(1));
      expect(single.reviews.single.text, singleText);
      expect(single.reviews.single.text.length, greaterThan(12000));
      expect(single.contentComplete, isTrue);

      final secondTail = '第二条尾部定位标记';
      final firstText = '第一条${'乙' * 7000}';
      final secondText = '第二条${'丙' * 7000}$secondTail';
      final multiple = _parser.course(
        _courseDetailHtml(
          2,
          _reviewHtml('202', '2025秋', firstText) +
              _reviewHtml('203', '2025秋', secondText),
        ),
        Uri.parse('https://icourse.club/course/13486/'),
      );

      expect(multiple.reviews, hasLength(2));
      expect(multiple.reviews.first.text, firstText);
      expect(multiple.reviews.last.text, secondText);
      expect(multiple.reviews.last.text, contains(secondTail));
      expect(multiple.contentComplete, isTrue);
    });

    test('filters reviews by term before spending the snapshot budget', () {
      final unmatchedText = '${'x' * (512 * 1024)}未选学期正文';
      final selectedText = '已选学期${'y' * 13000}选中学期尾部';
      final document = _parser.course(
        _courseDetailHtml(
          1,
          _reviewHtml('204', '2024秋', unmatchedText) +
              _reviewHtml('205', '2025秋', selectedText),
        ),
        Uri.parse('https://icourse.club/course/13486/?term=20251'),
      );

      expect(document.reviews, hasLength(1));
      expect(document.reviews.single.text, selectedText);
      expect(document.reviews.single.text, contains('选中学期尾部'));
      expect(document.excluded, 1);
    });

    test(
      'caps a course snapshot at the final review and reports incomplete coverage',
      () {
        final firstText = 'a' * (300 * 1024);
        final secondText = 'b' * (300 * 1024);
        final thirdText = '不可达的后续点评';
        final document = _parser.course(
          _courseDetailHtml(
            3,
            _reviewHtml('206', '2025秋', firstText) +
                _reviewHtml('207', '2025秋', secondText) +
                _reviewHtml('208', '2025秋', thirdText),
          ),
          Uri.parse('https://icourse.club/course/13486/'),
        );

        expect(document.reviews, hasLength(2));
        expect(document.reviews.first.text, firstText);
        expect(document.reviews.last.text, startsWith('b'));
        expect(document.reviews.last.text.length, lessThan(secondText.length));
        expect(
          document.reviews.last.text,
          hasLength(512 * 1024 - firstText.length),
        );
        expect(
          document.reviews.any((review) => review.text.contains(thirdText)),
          isFalse,
        );
        expect(document.contentComplete, isFalse);
      },
    );

    test(
      'rejects malformed course structures and unapproved source targets',
      () {
        _expectFailure(
          PublicFailureCode.sourceSchema,
          () => _parser.course(
            '<html><body><h1>课程（教师）</h1></body></html>',
            Uri.parse('https://icourse.club/course/13486/'),
          ),
        );
        _expectFailure(
          PublicFailureCode.unsafeTarget,
          () => _parser.courses(
            '<html><body></body></html>',
            Uri.parse('https://other.example/search/?q=term'),
          ),
        );
        _expectFailure(
          PublicFailureCode.resourceLimit,
          () => _parser.courses(
            '<html><body>${'x' * (2 * 1024 * 1024 + 1)}</body></html>',
            Uri.parse('https://icourse.club/search/?q=term&noredirect=True'),
          ),
        );
        _expectFailure(
          PublicFailureCode.unsafeTarget,
          () => _parser.courses(
            '''<html><body>
              <div class="ud-pd-md dashed">
                <a class="px16" href="/course/13486/">数学分析(B1)（程艺）</a>
              </div>
              <div class="pagination">
                <a class="next" href="https://outside.example/search/?q=x&amp;page=2">下一页</a>
              </div>
            </body></html>''',
            Uri.parse('https://icourse.club/search/?q=x&noredirect=True'),
          ),
        );
      },
    );

    test(
      'strips sticky teach posts and follows the next local page control',
      () {
        const html = '''
        <html><body>
          <main class="main"><section>
            <ul class="article-list with-tag">
              <li class="post-1 post type-post status-publish sticky">
                <span class="post"><a href="/notice/notice-teaching/100.html">置顶项</a></span>
              </li>
              <li class="post-2 post type-post status-publish">
                <span class="post"><a href="/notice/notice-teaching/101.html">通知标题</a></span>
                <span class="date">2026-10-01</span>
              </li>
            </ul>
            <div class="pagination">
              <a class="page-numbers" href="/category/notice/page/2/?s=缓考">2</a>
            </div>
          </section></main>
        </body></html>
      ''';

        final page = _parser.campus(
          html,
          Uri.parse(
            'https://www.teach.ustc.edu.cn/category/notice?s=%E7%BC%93%E8%80%83',
          ),
          CampusColumn.teachNotice,
        );

        expect(page.items, hasLength(1));
        expect(page.items.single.title, '通知标题');
        expect(page.items.single.publishedOn, '2026-10-01');
        expect(page.excluded, 1);
        expect(page.nextPage?.path, '/category/notice/page/2/');
        expect(page.nextPage?.queryParameters['s'], '缓考');
        expect(page.listingOrder, PublicListingOrder.unknown);
      },
    );

    test('recognizes only valid non-increasing teach notice dates', () {
      final uri = Uri.parse('https://www.teach.ustc.edu.cn/category/notice');
      final ordered = _parser.campus(
        _teachNoticeHtml([
          '2026-10-15',
          '2026-10-15',
          '2026-10-14',
        ], stickyDate: '2020-01-01'),
        uri,
        CampusColumn.teachNotice,
      );
      expect(ordered.items, hasLength(3));
      expect(ordered.excluded, 1);
      expect(ordered.listingOrder, PublicListingOrder.newestFirst);

      final completeDateForms = _parser.campus(
        _teachNoticeHtml(['2026/10/15 12:30:00', '2026年10月15日']),
        uri,
        CampusColumn.teachNotice,
      );
      expect(completeDateForms.listingOrder, PublicListingOrder.newestFirst);

      for (final dates in <List<String?>>[
        ['2026-10-14', '2026-10-15'],
        ['2026-10-15', null],
        ['2026-02-30'],
        ['2026-10-15 25:00'],
      ]) {
        final page = _parser.campus(
          _teachNoticeHtml(dates),
          uri,
          CampusColumn.teachNotice,
        );
        expect(page.listingOrder, PublicListingOrder.unknown);
      }

      final search = _parser.campus(
        _teachNoticeHtml(['2026-10-15', '2026-10-14']),
        uri.replace(queryParameters: {'s': '通知'}),
        CampusColumn.teachNotice,
      );
      expect(search.listingOrder, PublicListingOrder.unknown);
    });

    test(
      'uses teach no-results state and limits student links to main sections',
      () {
        final empty = _parser.campus(
          '''<html><body class="search search-no-results">
            <main class="main"><section><ul class="article-list with-tag">
              <li class="post-9 post type-post status-publish sticky">
                <span class="post"><a href="/notice/notice-teaching/999.html">跨栏目置顶公告</a></span>
              </li>
            </ul></section></main>
          </body></html>''',
          Uri.parse(
            'https://www.teach.ustc.edu.cn/category/notice?s=not-found',
          ),
          CampusColumn.teachNotice,
        );
        expect(empty.items, isEmpty);
        expect(empty.excluded, 1);

        const student = '''
        <html><body>
          <main class="main"><section>
            <div class="flow flow3"><ul><li>
              <span class="post"><a href="/service/svc-student/2690.html">办理流程</a></span>
              <span class="date">2015-07-03</span>
            </li></ul></div>
            <div class="faq"><ul class="article-list">
              <li><span class="post"><a href="/service/svc-student/13824.html">常见问题</a></span>
                <span class="date">2026-06-01</span></li>
            </ul></div>
            <div class="more"><ul class="article-list">
              <li><span class="post"><a href="/service/svc-student/20496.html">指南</a></span></li>
              <li><span class="post"><a href="/service/svc-teacher/11719.html">教师事务</a></span></li>
              <li><span class="post"><a href="/service/svc-resource/12388.html">教学资源</a></span></li>
              <li><span class="post"><a href="/service/svc-student/nested/999.html">未知路径</a></span></li>
            </ul></div>
          </section></main>
          <footer><a href="/service/svc-student/999.html">页脚链接</a></footer>
        </body></html>
      ''';
        final page = _parser.campus(
          student,
          Uri.parse(
            'https://www.teach.ustc.edu.cn/category/service/svc-student',
          ),
          CampusColumn.teachStudentService,
        );
        expect(page.items.map((item) => item.title), <String>[
          '办理流程',
          '常见问题',
          '指南',
        ]);
        expect(page.items.first.publishedOn, '2015-07-03');
        expect(page.items.last.publishedOn, isNull);
        expect(page.excluded, 3);
        expect(page.listingOrder, PublicListingOrder.unknown);
      },
    );

    test(
      'student keyword query uses scoped search rows, paging and legal empty',
      () {
        final page = _parser.campus(
          '''<html><body class="search search-results">
          <main class="main"><section><div class="list"><ul class="article-list">
          <li class="post-201 post type-post status-publish category-svc-student">
            <span class="post"><a href="/service/svc-student/201.html">课程办理</a></span>
          </li>
          <li class="post-202 post type-post status-publish category-svc-student category-notice-info">
            <span class="post"><a href="/notice/notice-info/202.html">双分类通知</a></span>
          </li>
          <li class="post-203 post type-post status-publish category-svc-teacher">
            <span class="post"><a href="/notice/notice-info/203.html">非学生事务</a></span>
          </li>
        </ul></div><div class="pagination">
          <a class="next page-numbers" href="/category/service/svc-student/page/2?s=课程">下一页</a>
        </div></section></main></body></html>''',
          Uri.parse(
            'https://www.teach.ustc.edu.cn/category/service/svc-student?s=课程',
          ),
          CampusColumn.teachStudentService,
        );
        expect(page.items.map((item) => item.title), ['课程办理', '双分类通知']);
        expect(page.excluded, 1);
        expect(page.listingOrder, PublicListingOrder.unknown);
        expect(page.nextPage!.path, '/category/service/svc-student/page/2');
        expect(page.nextPage!.queryParameters['s'], '课程');
        final empty = _parser.campus(
          '''<html><body class="search search-no-results">
          <main class="main"><section><div class="list"><ul class="article-list"></ul></div></section></main>
        </body></html>''',
          Uri.parse(
            'https://www.teach.ustc.edu.cn/category/service/svc-student?s=未命中',
          ),
          CampusColumn.teachStudentService,
        );
        expect(empty.items, isEmpty);
        expect(empty.nextPage, isNull);
        final next = _parser.campus(
          '''<html><body class="search search-results">
          <main class="main"><section><div class="list"><ul class="article-list">
          <li class="post-204 post type-post status-publish category-svc-student">
            <span class="post"><a href="/service/svc-student/204.html">第二页</a></span>
          </li>
        </ul></div></section></main></body></html>''',
          page.nextPage!,
          CampusColumn.teachStudentService,
        );
        expect(next.items.single.title, '第二页');
        expect(next.nextPage, isNull);
      },
    );

    test(
      'parses only finance w6 list rows, actual next, and visible dates',
      () {
        const html = '''
        <html><body>
          <div id="wp_news_w6"><ul class="news_list list2">
            <li class="news n1 clearfix">
              <span class="news_title"><a href="/2025/1128/c21817a712082/page.psp">业务指南</a></span>
              <span class="news_meta">2025-11-28</span>
            </li>
            <li class="news n2 clearfix">
              <span class="news_title"><a href="/2025/1129/c21817a712083/page.psp">报销说明</a></span>
              <span class="news_meta">2025-11-29</span>
            </li>
            <li class="news n14 clearfix">
              <span class="news_title"><a href="/2025/1130/c21817a712084/page.psp">票据要求</a></span>
              <span class="news_meta">2025-11-30</span>
            </li>
          </ul></div>
          <div id="wp_paging_w6"><ul class="wp_paging clearfix">
            <li class="page_nav"><a class="next" href="/ywzn/list2.htm">下一页</a></li>
          </ul></div>
        </body></html>
      ''';
        final page = _parser.campus(
          html,
          Uri.parse('https://finance.ustc.edu.cn/ywzn/list.psp'),
          CampusColumn.financeBusiness,
        );
        expect(page.items, hasLength(3));
        expect(page.items.map((item) => item.title), <String>[
          '业务指南',
          '报销说明',
          '票据要求',
        ]);
        expect(page.items.first.publishedOn, '2025-11-28');
        expect(page.nextPage?.path, '/ywzn/list2.htm');
        expect(page.listingOrder, PublicListingOrder.unknown);

        _expectFailure(
          PublicFailureCode.unsafeTarget,
          () => _parser.campus(
            '''<html><body>
            <div id="wp_news_w6"><ul class="news_list list2">
              <li class="news n1 clearfix">
                <span class="news_title"><a href="/2025/1128/c21817a712082/page.psp">指南</a></span>
                <span class="news_meta">2025-11-28</span>
              </li>
            </ul></div>
            <div id="wp_paging_w6"><ul class="wp_paging clearfix">
              <li class="page_nav"><a class="next" href="https://outside.example/ywzn/list2.htm">下一页</a></li>
            </ul></div>
          </body></html>''',
            Uri.parse('https://finance.ustc.edu.cn/ywzn/list.psp'),
            CampusColumn.financeBusiness,
          ),
        );

        _expectFailure(
          PublicFailureCode.unsafeTarget,
          () => _parser.campus(
            '''<html><body>
            <div id="wp_news_w6"><ul class="news_list list2">
              <li class="news n1 clearfix">
                <span class="news_title"><a href="/2025/1128/c21817a712082/page.psp">指南</a></span>
                <span class="news_meta">2025-11-28</span>
              </li>
            </ul></div>
            <div id="wp_paging_w6"><ul class="wp_paging clearfix">
              <li class="page_nav"><a class="next" href="/tzgg/list2.htm">下一页</a></li>
            </ul></div>
          </body></html>''',
            Uri.parse('https://finance.ustc.edu.cn/ywzn/list.psp'),
            CampusColumn.financeBusiness,
          ),
        );

        _expectFailure(
          PublicFailureCode.unavailable,
          () => _parser.campus(
            '<html><body></body></html>',
            Uri.parse('https://finance.ustc.edu.cn/22120/list.psp'),
            CampusColumn.financeFaq,
          ),
        );
      },
    );

    test('recognizes only valid non-increasing finance notice dates', () {
      final uri = Uri.parse('https://finance.ustc.edu.cn/tzgg/list.htm');
      final ordered = _parser.campus(
        _financeNoticeHtml([
          '2026-10-15',
          '2026-10-15',
          '2026-10-14',
        ], stickyDate: '2020-01-01'),
        uri,
        CampusColumn.financeNotice,
      );
      expect(ordered.items, hasLength(3));
      expect(ordered.excluded, 1);
      expect(ordered.listingOrder, PublicListingOrder.newestFirst);

      for (final dates in <List<String?>>[
        ['2026-10-14', '2026-10-15'],
        ['2026-10-15', null],
        ['2026-02-30'],
      ]) {
        final page = _parser.campus(
          _financeNoticeHtml(dates),
          uri,
          CampusColumn.financeNotice,
        );
        expect(page.listingOrder, PublicListingOrder.unknown);
      }
    });

    test(
      'follows observed finance page suffixes and validates terminal placeholders',
      () {
        final first = _parser.campus(
          _financePageHtml('1/3', '/ywzn/list2.htm'),
          Uri.parse('https://finance.ustc.edu.cn/ywzn/list.psp'),
          CampusColumn.financeBusiness,
        );
        expect(first.nextPage?.path, '/ywzn/list2.htm');
        expect(first.totalReported, 10);

        final second = _parser.campus(
          _financePageHtml('2/3', '/ywzn/list3.htm'),
          Uri.parse('https://finance.ustc.edu.cn/ywzn/list2.psp'),
          CampusColumn.financeBusiness,
        );
        expect(second.nextPage?.path, '/ywzn/list3.htm');

        final third = _parser.campus(
          _financePageHtml('3/3', 'javascript:void(0);'),
          Uri.parse('https://finance.ustc.edu.cn/ywzn/list3.psp'),
          CampusColumn.financeBusiness,
        );
        expect(third.nextPage, isNull);
        expect(third.totalReported, 10);

        final operation = _parser.campus(
          _financePageHtml('1/1', 'javascript:void(0);'),
          Uri.parse('https://finance.ustc.edu.cn/22119/list.psp'),
          CampusColumn.financeOperation,
        );
        expect(operation.nextPage, isNull);
        expect(operation.totalReported, 10);

        _expectFailure(
          PublicFailureCode.unsafeTarget,
          () => _parser.campus(
            _financePageHtml('2/3', 'javascript:void(0);'),
            Uri.parse('https://finance.ustc.edu.cn/ywzn/list2.psp'),
            CampusColumn.financeBusiness,
          ),
        );
        _expectFailure(
          PublicFailureCode.unsafeTarget,
          () => _parser.campus(
            _financePageHtml(
              '1/1',
              'javascript:void(0);',
            ).replaceAll('<span class="pages">页码 1/1</span>', ''),
            Uri.parse('https://finance.ustc.edu.cn/22119/list.psp'),
            CampusColumn.financeOperation,
          ),
        );
        _expectFailure(
          PublicFailureCode.unsafeTarget,
          () => _parser.campus(
            _financePageHtml('3/3', 'javascript:run()'),
            Uri.parse('https://finance.ustc.edu.cn/ywzn/list3.psp'),
            CampusColumn.financeBusiness,
          ),
        );
        _expectFailure(
          PublicFailureCode.unsafeTarget,
          () => _parser.campus(
            _financePageHtml('3/3', '/tzgg/list4.psp'),
            Uri.parse('https://finance.ustc.edu.cn/tzgg/list3.htm'),
            CampusColumn.financeNotice,
          ),
        );
      },
    );

    test(
      'expands table row and column spans while preserving cell associations',
      () {
        final document = _parser.article(
          _financeArticleHtml('''
            <table>
              <tbody>
                <tr><th rowspan="2">项目</th><th colspan="2">条件</th></tr>
                <tr><th>金额</th><th>单位</th></tr>
                <tr><td>报销</td><td rowspan="2">100</td><td>元</td></tr>
                <tr><td>采购</td><td>件</td></tr>
              </tbody>
              <tbody>
                <tr><th colspan="3">附加条件</th></tr>
                <tr><td>邮寄</td><td>5</td><td>元</td></tr>
              </tbody>
            </table>
          '''),
          Uri.parse(
            'https://finance.ustc.edu.cn/2025/1128/c21817a712082/page.psp',
          ),
          PublicProvider.finance,
        );

        expect(
          document.markdown,
          contains('''| 项目 | 条件 | 条件 |
| --- | --- | --- |
| 项目 | 金额 | 单位 |
| 报销 | 100 | 元 |
| 采购 | 100 | 件 |
| 附加条件 | 附加条件 | 附加条件 |
| 邮寄 | 5 | 元 |'''),
        );
        expect(document.contentComplete, isTrue);
      },
    );

    test('rejects invalid, overlapping, and over-budget table spans', () {
      final uri = Uri.parse(
        'https://finance.ustc.edu.cn/2025/1128/c21817a712082/page.psp',
      );
      _expectFailure(
        PublicFailureCode.sourceSchema,
        () => _parser.article(
          _financeArticleHtml(
            '<table><tr><td colspan="invalid">事项</td></tr></table>',
          ),
          uri,
          PublicProvider.finance,
        ),
      );
      _expectFailure(
        PublicFailureCode.sourceSchema,
        () => _parser.article(
          _financeArticleHtml('''<table><tbody>
            <tr><td rowspan="2">项目</td><td>金额</td><td rowspan="2">单位</td></tr>
            <tr><td colspan="2">错误重叠</td></tr>
          </tbody></table>'''),
          uri,
          PublicProvider.finance,
        ),
      );
      _expectFailure(
        PublicFailureCode.resourceLimit,
        () => _parser.article(
          _financeArticleHtml(
            '<table><tr><td colspan="1001">过大列跨度</td></tr></table>',
          ),
          uri,
          PublicProvider.finance,
        ),
      );
      _expectFailure(
        PublicFailureCode.resourceLimit,
        () => _parser.article(
          _financeArticleHtml(
            '<table><tr><td colspan="41">超过列预算</td></tr></table>',
          ),
          uri,
          PublicProvider.finance,
        ),
      );
    });

    test(
      'preserves finance table columns and marks unread media incomplete',
      () {
        const html = '''
        <html><body>
          <h1>合成财务指南</h1>
          <p class="arti_metas"><span class="arti_update">发布时间：2025-11-28</span></p>
          <div class="infobox"><div class="article"><div class="entry"><div class="read">
            <div class="wp_articlecontent">
              <p>适用事项</p>
              <table><tbody>
                <tr><th>事项</th><th>入口</th></tr>
                <tr><td>报销</td><td>线上系统<br>公开说明</td></tr>
              </tbody></table>
              <p><a href="https://finance.ustc.edu.cn/_upload/guide.pdf">PDF指南</a></p>
              <p><a href="https://outside.example/file.pdf">外站附件</a></p>
              <p><a href="http://finance.ustc.edu.cn/_upload/legacy.pdf">HTTP附件</a></p>
              <img src="/_upload/figure.png" alt="流程图">
              <div hidden>隐藏文本</div>
              <aside class="attachments">附件列表不属于正文</aside>
              <address class="signature">署名不属于正文</address>
              <script>忽略脚本</script>
            </div>
          </div></div></div></div>
        </body></html>
      ''';
        final document = _parser.article(
          html,
          Uri.parse(
            'https://finance.ustc.edu.cn/2025/1128/c21817a712082/page.psp',
          ),
          PublicProvider.finance,
        );

        expect(document.title, '合成财务指南');
        expect(document.publishedOn, '2025-11-28');
        expect(document.markdown, contains('| 事项 | 入口 |'));
        expect(document.markdown, contains('| 报销 | 线上系统 / 公开说明 |'));
        expect(document.markdown, isNot(contains('隐藏文本')));
        expect(document.markdown, isNot(contains('附件列表')));
        expect(document.markdown, isNot(contains('署名')));
        expect(document.markdown, isNot(contains('忽略脚本')));
        expect(document.attachmentLinks, hasLength(2));
        expect(
          document.attachmentLinks.map((uri) => uri.path),
          contains('/_upload/guide.pdf'),
        );
        expect(
          document.attachmentLinks.map((uri) => uri.path),
          contains('/_upload/figure.png'),
        );
        expect(
          document.attachmentLinks.any((uri) => uri.host == 'outside.example'),
          isFalse,
        );
        expect(document.contentComplete, isFalse);
      },
    );

    test(
      'treats a teach flowchart as incomplete and excludes attachment/sidebar text',
      () {
        const html = '''
        <html><body>
          <h1>办理流程</h1>
          <aside class="sidebar-b"><div class="post-meta-side"><ul>
            <li class="meta-date">发布时间：2015-07-03 14:27</li>
            <li class="meta-last-modified">最后修改时间：2026-07-22 17:00</li>
          </ul></div></aside>
          <article id="post-2690" class="post type-post status-publish">
            <figure class="photo photo-large align-none"><img src="/wp-content/uploads/flow.png" alt="流程图"></figure>
            <aside class="attachments"><a href="/login/download.pdf">登录附件</a></aside>
            <address class="signature">署名</address>
          </article>
        </body></html>
      ''';
        final document = _parser.article(
          html,
          Uri.parse(
            'https://www.teach.ustc.edu.cn/service/svc-student/2690.html',
          ),
          PublicProvider.teach,
        );
        expect(document.publishedOn, '2015-07-03 14:27');
        expect(document.updatedOn, '2026-07-22 17:00');
        expect(document.contentComplete, isFalse);
        expect(document.markdown, contains('图示内容未读取'));
        expect(document.markdown, isNot(contains('登录附件')));
        expect(document.markdown, isNot(contains('署名')));
        expect(document.attachmentLinks, hasLength(1));
        expect(
          document.attachmentLinks.single.path,
          '/wp-content/uploads/flow.png',
        );
      },
    );

    test(
      'rejects article URL scope outside the registered providers and paths',
      () {
        _expectFailure(
          PublicFailureCode.unsafeTarget,
          () => _parser.article(
            '<html><body></body></html>',
            Uri.parse('https://outside.example/news/1.html'),
            PublicProvider.teach,
          ),
        );
      },
    );
  });
}
