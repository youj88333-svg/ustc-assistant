import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/public_query_contract.dart';
import 'package:ustc_assistant_m0/data/knowledge_markdown.dart';

void _expectFailure(String markdown, PublicFailureCode code) {
  expect(
    () => knowledgeSections(markdown),
    throwsA(
      isA<PublicFailure>().having((failure) => failure.code, 'code', code),
    ),
  );
}

void main() {
  group('knowledgeSections', () {
    test('keeps the preface and H1 in section zero, then splits headings', () {
      const markdown = '''
前置说明：本科生查询知识库材料。

# 本科选课流程

学生先阅读本段说明。

## 申请条件

- 条件：时间不冲突且人数未满。
- 否则：提交个性化选课申请。

> 学生应及时查询审核结果。

### 审核分支

- A：任课教师在系统中审核。
- B：任课教师在申请表上签字。
''';

      final sections = knowledgeSections(markdown);

      expect(sections, hasLength(3));
      expect(sections.map((section) => section.index), [0, 1, 2]);
      expect(sections[0].heading, '本科选课流程');
      expect(sections[0].markdown, contains('# 本科选课流程'));
      expect(sections[0].plainText, contains('前置说明'));
      expect(sections[0].plainText, contains('本科选课流程'));
      expect(sections[0].plainText, contains('学生先阅读本段说明'));
      expect(sections[1].heading, '申请条件');
      expect(sections[1].plainText, contains('时间不冲突且人数未满'));
      expect(sections[1].plainText, contains('否则：提交个性化选课申请'));
      expect(sections[1].plainText, contains('学生应及时查询审核结果'));
      expect(sections[2].heading, '审核分支');
      expect(sections[2].plainText, contains('任课教师在系统中审核'));
      expect(sections[2].plainText, contains('任课教师在申请表上签字'));
    });

    test('preserves table columns, header association, and link labels', () {
      const markdown = '''
| 事项 | 办理说明 | 来源 |
|---|---|---|
| 选课 | 先查时间，再提交申请 | [教务流程](https://www.teach.ustc.edu.cn/service/svc-student/12522.html) |

[财务指南](https://finance.ustc.edu.cn/main.htm) [教务课表](https://jw.ustc.edu.cn/for-std/course-table)
''';

      final section = knowledgeSections(markdown).single;

      expect(section.markdown, contains('| 事项 | 办理说明 | 来源 |'));
      expect(section.plainText, contains('事项：选课'));
      expect(section.plainText, contains('办理说明：先查时间，再提交申请'));
      expect(section.plainText, contains('来源：教务流程'));
      expect(section.plainText, contains('财务指南'));
      expect(section.plainText, contains('教务课表'));
      expect(section.plainText, isNot(contains('https://')));
    });

    test('rejects empty text, raw HTML, comments, and image syntax', () {
      _expectFailure('', PublicFailureCode.sourceSchema);
      _expectFailure('  \n\t ', PublicFailureCode.sourceSchema);
      _expectFailure(
        '<script>alert(1)</script>',
        PublicFailureCode.sourceSchema,
      );
      _expectFailure('普通文字 <!-- 注释 -->', PublicFailureCode.sourceSchema);
      _expectFailure(
        '![封面](https://www.teach.ustc.edu.cn/image.png)',
        PublicFailureCode.sourceSchema,
      );
    });

    test(
      'rejects file, non-HTTPS, credentialed, nonstandard-port, and other-host links',
      () {
        const invalidLinks = [
          '[附件](file:///C:/private/report.pdf)',
          '[页面](http://www.teach.ustc.edu.cn/service)',
          '[凭据](https://user@www.teach.ustc.edu.cn/service)',
          '[端口](https://www.teach.ustc.edu.cn:8443/service)',
          '[外站](https://example.org/policy)',
          '[脚本](javascript:alert(1))',
        ];

        for (final link in invalidLinks) {
          _expectFailure(link, PublicFailureCode.sourceSchema);
        }
      },
    );

    test('enforces UTF-8 byte and section limits', () {
      final oversized = List<String>.filled(90_000, '知').join();
      _expectFailure(oversized, PublicFailureCode.resourceLimit);

      final manySections = StringBuffer();
      for (var index = 0; index < 257; index++) {
        manySections
          ..write('## 第 $index 节\n')
          ..write('办理条件与知识内容 $index\n\n');
      }
      _expectFailure(manySections.toString(), PublicFailureCode.resourceLimit);
    });

    test(
      'normalizes line endings and keeps two-character Chinese searchable',
      () {
        final section = knowledgeSections('标题\r\n\r\n知识检索\r\n').single;

        expect(section.markdown, '标题\n\n知识检索');
        expect(section.plainText, contains('知识'));
        expect(section.heading, '正文');
      },
    );
  });
}
