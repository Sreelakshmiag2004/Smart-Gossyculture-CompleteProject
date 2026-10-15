import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/auth/session_controller.dart';
import 'package:smart_gossy_culture_app/ui/dashboard.dart';
import 'package:smart_gossy_culture_app/ui/farm_onboarding_page.dart';
import 'package:smart_gossy_culture_app/ui/otp_verify_page.dart';
import 'package:smart_gossy_culture_app/ui/settings_profile_page.dart';
import 'package:smart_gossy_culture_app/ui/sign_in_page.dart';

import '../support/app_harness.dart';
import '../support/fake_backend.dart';

void main() {
  testWidgets('app start without a stored session shows the sign-in page and sends nothing', (tester) async {
    final app = TestApp();
    await startApp(tester, app);
    expect(find.byType(SignInPage), findsOneWidget);
    expect(app.backend.calls, isEmpty);
  });

  group('phone entry', () {
    testWidgets('an incomplete number is rejected on the device; no request is sent', (tester) async {
      final app = TestApp();
      await startApp(tester, app);
      await requestCode(tester, '98765 43210'); // no country code
      expect(find.textContaining('country code'), findsWidgets);
      expect(find.byType(OtpVerifyPage), findsNothing);
      expect(app.backend.calls, isEmpty);
    });

    testWidgets('the email tab does not sign in', (tester) async {
      final app = TestApp();
      await startApp(tester, app);
      await tester.tap(find.text('Email'));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('phoneField')), 'farmer@example.com');
      await tester.tap(find.byKey(const Key('continueButton')));
      await tester.pumpAndSettle();
      expect(find.textContaining('email is not available'), findsOneWidget);
      expect(app.backend.calls, isEmpty);
    });

    testWidgets('requesting a code: busy state, then the code-entry page; the backend got the E.164 number', (tester) async {
      final app = TestApp();
      await startApp(tester, app);
      await tester.enterText(find.byKey(const Key('phoneField')), '+999 0000 0001');
      await tester.tap(find.byKey(const Key('continueButton')));
      await tester.pump(); // request in flight
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.widget<ElevatedButton>(find.byKey(const Key('continueButton'))).onPressed, isNull);
      await tester.pumpAndSettle();
      expect(find.byType(OtpVerifyPage), findsOneWidget);
      expect(app.backend.calls.single.path, '/api/v1/auth/otp/request');
      expect(app.backend.calls.single.body, {'phone': '+99900000001'});
      expect(find.textContaining('+99 '), findsOneWidget); // masked number
      expect(find.textContaining('00000001'), findsNothing);
    });
  });

  group('code entry', () {
    testWidgets('a code that is not six digits is rejected on the device', (tester) async {
      final app = TestApp();
      await startApp(tester, app);
      await requestCode(tester, FakeBackend.allowedPhone);
      await enterCode(tester, '123');
      expect(find.text('Enter the 6-digit code.'), findsOneWidget);
      expect(app.backend.count('POST', '/api/v1/auth/otp/verify'), 0);
      // letters cannot be typed, and at most six digits are kept
      await tester.enterText(find.byKey(const Key('codeField')), '12ab3456789');
      expect(tester.widget<TextField>(find.byKey(const Key('codeField'))).controller!.text, '123456');
    });

    testWidgets('successful verification stores the tokens and leaves the sign-in pages', (tester) async {
      final app = TestApp();
      await startApp(tester, app);
      await signInThroughUi(tester, app);
      expect(app.tokens.session, isNotNull);
      expect(app.services.session.status, SessionStatus.signedIn);
      expect(find.byType(OtpVerifyPage), findsNothing);
      expect(find.byType(SignInPage), findsNothing);
      expect(find.byType(FarmOnboardingPage), findsOneWidget); // new farmer: no farm yet
      // No token is ever rendered.
      expect(find.textContaining('access-'), findsNothing);
      expect(find.textContaining('refresh-token'), findsNothing);
    });

    testWidgets('invalid code: friendly message, field cleared, nothing stored, retry works', (tester) async {
      final app = TestApp();
      await startApp(tester, app);
      await requestCode(tester, FakeBackend.allowedPhone);
      await enterCode(tester, '000000');
      expect(find.textContaining('incorrect or has expired'), findsOneWidget);
      expect(find.textContaining('backend message'), findsNothing);
      expect(find.textContaining('invalid_credentials'), findsNothing);
      expect(app.tokens.session, isNull);
      expect(tester.widget<TextField>(find.byKey(const Key('codeField'))).controller!.text, isEmpty);
      await enterCode(tester, app.backend.currentCode);
      expect(app.tokens.session, isNotNull);
    });

    testWidgets('expired code: same backend answer; a new code can be requested and then works', (tester) async {
      final app = TestApp();
      await startApp(tester, app);
      await requestCode(tester, FakeBackend.allowedPhone);
      app.backend.challengeIssued = false; // the challenge has expired on the backend
      await enterCode(tester, app.backend.currentCode);
      expect(find.textContaining('incorrect or has expired'), findsOneWidget);
      expect(app.tokens.session, isNull);
      await tester.tap(find.byKey(const Key('resendButton')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('codeInfo')), findsOneWidget);
      expect(app.backend.count('POST', '/api/v1/auth/otp/request'), 2);
      await enterCode(tester, app.backend.currentCode);
      expect(app.tokens.session, isNotNull);
    });

    testWidgets('a number that is not eligible gets the same screens and can never sign in', (tester) async {
      final app = TestApp();
      await startApp(tester, app);
      await requestCode(tester, '+99900000777');
      expect(find.byType(OtpVerifyPage), findsOneWidget); // uniform answer: no enumeration
      await enterCode(tester, app.backend.currentCode);
      expect(find.textContaining('incorrect or has expired'), findsOneWidget);
      expect(app.tokens.session, isNull);
    });
  });

  group('failures during sign-in', () {
    testWidgets('rate limited when requesting a code (429 + Retry-After)', (tester) async {
      final app = TestApp();
      app.backend.overrides['/api/v1/auth/otp/request'] = FakeReply.error(429, 'rate_limited', headers: {'retry-after': '300'});
      await startApp(tester, app);
      await requestCode(tester, FakeBackend.allowedPhone);
      expect(find.textContaining('Too many attempts'), findsOneWidget);
      expect(find.textContaining('5 minutes'), findsOneWidget);
      expect(find.byType(OtpVerifyPage), findsNothing);
    });

    testWidgets('rate limited when verifying a code', (tester) async {
      final app = TestApp();
      await startApp(tester, app);
      await requestCode(tester, FakeBackend.allowedPhone);
      app.backend.overrides['/api/v1/auth/otp/verify'] = FakeReply.error(429, 'rate_limited', headers: {'retry-after': '45'});
      await enterCode(tester, app.backend.currentCode);
      expect(find.textContaining('45 seconds'), findsOneWidget);
      expect(app.tokens.session, isNull);
    });

    testWidgets('code delivery unavailable (503, production without an SMS provider)', (tester) async {
      final app = TestApp();
      app.backend.overrides['/api/v1/auth/otp/request'] = FakeReply.error(503, 'otp_delivery_unavailable');
      await startApp(tester, app);
      await requestCode(tester, FakeBackend.allowedPhone);
      expect(find.textContaining('cannot be sent at the moment'), findsOneWidget);
      expect(find.byType(OtpVerifyPage), findsNothing);
    });

    testWidgets('backend unavailable (500 / 503) shows a safe message and allows a retry', (tester) async {
      final app = TestApp();
      app.backend.overrides['/api/v1/auth/otp/request'] = FakeReply.error(500, 'internal_error');
      await startApp(tester, app);
      await requestCode(tester, FakeBackend.allowedPhone);
      expect(find.textContaining('Something went wrong on our side'), findsOneWidget);
      expect(find.textContaining('internal_error'), findsNothing);
      app.backend.overrides['/api/v1/auth/otp/request'] = FakeReply.error(503, 'service_unavailable');
      await tester.tap(find.byKey(const Key('continueButton')));
      await tester.pumpAndSettle();
      expect(find.textContaining('temporarily unavailable'), findsOneWidget);
      app.backend.overrides.clear();
      await tester.tap(find.byKey(const Key('continueButton')));
      await tester.pumpAndSettle();
      expect(find.byType(OtpVerifyPage), findsOneWidget);
    });

    testWidgets('network unavailable / timeout when requesting and when verifying', (tester) async {
      final app = TestApp();
      app.backend.outage = Outage.offline;
      await startApp(tester, app);
      await requestCode(tester, FakeBackend.allowedPhone);
      expect(find.textContaining('No connection'), findsOneWidget);
      app.backend.outage = Outage.timeout;
      await tester.tap(find.byKey(const Key('continueButton')));
      await tester.pumpAndSettle();
      expect(find.textContaining('taking too long'), findsOneWidget);
      app.backend.outage = Outage.none;
      await tester.tap(find.byKey(const Key('continueButton')));
      await tester.pumpAndSettle();
      app.backend.outage = Outage.offline;
      await enterCode(tester, app.backend.currentCode);
      expect(find.textContaining('No connection'), findsOneWidget);
      expect(app.tokens.session, isNull);
    });
  });

  group('session', () {
    testWidgets('a stored session is restored at start-up without signing in again', (tester) async {
      final app = TestApp()..signIn();
      app.backend.farms.add({'id': 'farm-1', 'name': 'North field', 'createdAt': '2026-10-01T00:00:00Z'});
      app.backend.devices.add(FakeBackend.device('bb-0001'));
      await startApp(tester, app);
      expect(find.byType(Dashboard), findsOneWidget);
      expect(app.backend.count('POST', '/api/v1/auth/otp/request'), 0);
    });

    testWidgets('a stored session that the backend rejects leads to sign-in with a notice', (tester) async {
      final app = TestApp()..signIn();
      app.backend
        ..expireAccessToken()
        ..sessionRevoked = true;
      await startApp(tester, app);
      expect(find.byType(SignInPage), findsOneWidget);
      expect(find.byKey(const Key('signInNotice')), findsOneWidget);
      expect(find.textContaining('session has ended'), findsOneWidget);
      expect(app.tokens.session, isNull);
    });

    testWidgets('backend unreachable at start-up with a stored session: retry on the launch page, tokens kept', (tester) async {
      final app = TestApp()..signIn();
      app.backend.farms.add({'id': 'farm-1', 'name': 'North field', 'createdAt': '2026-10-01T00:00:00Z'});
      app.backend.devices.add(FakeBackend.device('bb-0001'));
      app.backend.outage = Outage.offline;
      await startApp(tester, app);
      expect(find.byKey(const Key('launchUnreachable')), findsOneWidget);
      expect(app.tokens.session, isNotNull);
      app.backend.outage = Outage.none;
      await tester.tap(find.byKey(const Key('launchRetry')));
      await tester.pumpAndSettle();
      expect(find.byType(Dashboard), findsOneWidget);
    });

    testWidgets('session ends while the user is inside the app: back to sign-in with a notice', (tester) async {
      final app = TestApp();
      await startApp(tester, app);
      await signInThroughUi(tester, app);
      expect(find.byType(FarmOnboardingPage), findsOneWidget);
      app.backend
        ..expireAccessToken()
        ..sessionRevoked = true; // e.g. refresh-token reuse detected, or signed out elsewhere
      await tester.enterText(find.byKey(const Key('farmNameField')), 'North field');
      await tester.tap(find.byKey(const Key('createFarmButton')));
      await tester.pumpAndSettle();
      expect(find.byType(SignInPage), findsOneWidget);
      expect(find.textContaining('session has ended'), findsOneWidget);
      expect(app.tokens.session, isNull);
      expect(app.backend.farms, isEmpty);
    });

    testWidgets('logout from Settings revokes the session, deletes the tokens and returns to sign-in', (tester) async {
      final app = TestApp()..signIn();
      app.backend.farms.add({'id': 'farm-1', 'name': 'North field', 'createdAt': '2026-10-01T00:00:00Z'});
      app.backend.devices.add(FakeBackend.device('bb-0001'));
      await startApp(tester, app);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsProfilePage), findsOneWidget);
      await tester.scrollUntilVisible(find.widgetWithText(ElevatedButton, 'Log Out'), 300);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Log Out'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Log Out'));
      await tester.pumpAndSettle();
      expect(find.byType(SignInPage), findsOneWidget);
      expect(find.byKey(const Key('signInNotice')), findsNothing);
      expect(app.backend.count('POST', '/api/v1/auth/logout'), 1);
      expect(app.backend.sessionRevoked, isTrue);
      expect(app.tokens.session, isNull);
    });
  });
}
