import 'package:flutter/material.dart';
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
}
