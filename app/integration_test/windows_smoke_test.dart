import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ustc_assistant_app/app/app.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows app starts with local chat shell', (tester) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await tester.pumpWidget(UstcAssistantApp(database: database));
    await tester.pumpAndSettle();
    expect(find.text('聊天'), findsWidgets);
    expect(find.text('日程'), findsOneWidget);
  });
}
