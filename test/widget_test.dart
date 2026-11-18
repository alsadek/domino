import 'package:flutter_test/flutter_test.dart';
import 'package:domino_masri/main.dart';

void main() {
  testWidgets('DominoMasriApp smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const DominoMasriApp());
    expect(find.textContaining('دومينو'), findsWidgets);
  });
}
