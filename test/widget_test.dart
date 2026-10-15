// App smoke test: the app starts, shows the splash and then the sign-in page.
// (Replaces the Flutter template counter test, which did not match this app.)

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/ui/launch_page.dart';
import 'package:smart_gossy_culture_app/ui/sign_in_page.dart';

import 'support/app_harness.dart';
import 'support/fake_backend.dart';

void main() {
  testWidgets('app starts on the splash and continues to sign-in', (WidgetTester tester) async {
    final app = TestApp();
    await startApp(tester, app);
    expect(find.byType(LaunchPage), findsNothing);
    expect(find.byType(SignInPage), findsOneWidget);
    expect(find.text('Sign In or Sign Up'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
  });
}
