// Basic smoke test for DimaGo app
import 'package:flutter_test/flutter_test.dart';
import 'package:lango/main.dart';

void main() {
  testWidgets('App builds without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const LangoApp());
  });
}
