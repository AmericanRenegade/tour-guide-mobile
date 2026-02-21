import 'package:flutter_test/flutter_test.dart';
import 'package:tour_guide/main.dart';

void main() {
  testWidgets('App renders splash screen on launch', (WidgetTester tester) async {
    await tester.pumpWidget(const TourGuideApp());
    expect(find.byType(SplashScreen), findsOneWidget);
  });
}
