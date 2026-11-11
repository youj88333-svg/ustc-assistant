import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/assistant_markdown.dart';
import 'package:ustc_assistant_m0/app/product_app.dart';

void main() {
  testWidgets('prose hierarchy remains readable in a narrow enlarged view', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: productTheme,
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: const SizedBox(
              width: 320,
              child: SingleChildScrollView(
                child: AssistantMarkdown(
                  data:
                      '### 这节课\n\n**合成课程A**，14:00–15:35，GT-B211。\n\n'
                      '你把它设成了“不参加，自学”。\n\n'
                      '- 第一项需要留意的事\n- 第二项需要留意的事',
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('合成课程A', findRichText: true), findsOneWidget);
    expect(find.textContaining('第一项需要留意', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'HTML, links and images stay inert while their text remains visible',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: productTheme,
          home: const Scaffold(
            body: AssistantMarkdown(
              data:
                  '<script>synthetic-script</script>\n\n'
                  '[公开链接](https://example.invalid/read)\n\n'
                  '![合成图片](https://example.invalid/image.png)',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('synthetic-script', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('公开链接'), findsOneWidget);
      expect(find.text('（图片已隐藏：合成图片）'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      await tester.tap(find.text('公开链接'));
      await tester.pumpAndSettle();
      expect(find.byType(AssistantMarkdown), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('streaming prose is bounded plain text, not reparsed Markdown', (
    tester,
  ) async {
    final streamed = '${'正文。' * 3000}**仍在生成**\n\n流式末尾';
    await tester.pumpWidget(
      MaterialApp(
        theme: productTheme,
        home: Scaffold(
          body: AssistantMarkdown(data: streamed, streaming: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final visible = tester.widget<Text>(
      find.byKey(const ValueKey('assistant-streaming-text')),
    );
    expect(visible.data!.length, lessThan(4200));
    expect(visible.data, contains('流式末尾'));
    expect(visible.data, contains('**仍在生成**'));
    expect(find.byType(MarkdownBody), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long completed prose keeps the whole reply available', (
    tester,
  ) async {
    const ending = '完整答案尾部仍可查看。';
    final content = '${'正文。' * 4001}\n\n$ending';
    await tester.pumpWidget(
      MaterialApp(
        theme: productTheme,
        home: Scaffold(
          body: SingleChildScrollView(child: AssistantMarkdown(data: content)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.text('显示完整回复'), findsOneWidget);
    expect(find.textContaining(ending, findRichText: true), findsNothing);
    final expand = find.byKey(const ValueKey('assistant-markdown-expand'));
    await tester.ensureVisible(expand);
    await tester.tap(expand);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.textContaining(ending, findRichText: true));

    expect(find.textContaining(ending, findRichText: true), findsOneWidget);
    expect(find.text('收起长回复'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
