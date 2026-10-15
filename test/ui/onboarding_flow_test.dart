import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/ui/dashboard.dart';
import 'package:smart_gossy_culture_app/ui/device_claim_page.dart';
import 'package:smart_gossy_culture_app/ui/farm_onboarding_page.dart';
import 'package:smart_gossy_culture_app/ui/onboarding_gate_page.dart';
import 'package:smart_gossy_culture_app/ui/sign_in_page.dart';

import '../support/app_harness.dart';
import '../support/fake_backend.dart';

const _farm = {'id': 'farm-1', 'name': 'North field', 'createdAt': '2026-10-01T00:00:00Z'};
final _device = FakeBackend.device('bb-0001');

Future<void> claim(WidgetTester tester, String deviceId, String code) async {
  await tester.enterText(find.byKey(const Key('deviceIdField')), deviceId);
  await tester.enterText(find.byKey(const Key('claimCodeField')), code);
  await tester.tap(find.byKey(const Key('claimButton')));
  await tester.pumpAndSettle();
}

void main() {
  group('navigation after authentication', () {
    testWidgets('farmer with a farm and a device goes straight to the dashboard', (tester) async {
      final app = TestApp();
      app.backend.farms.add(Map.of(_farm));
      app.backend.devices.add(Map.of(_device));
      await startApp(tester, app);
      await signInThroughUi(tester, app);
      expect(find.byType(Dashboard), findsOneWidget);
      // The onboarding check, then (Phase 3B) the dashboard's own three read calls and
      // (Phase 5B) the two alert reads behind its bell.
      final afterSignIn = app.backend.calls.skip(2).map((c) => '$c').toList();
      expect(afterSignIn.take(2), ['GET /api/v1/farms', 'GET /api/v1/devices']);
      expect(afterSignIn.skip(2).toSet(), {'GET /api/v1/devices', 'GET /api/v1/devices/bb-0001/telemetry', 'GET /api/v1/detections', 'GET /api/v1/alerts'});    });

    testWidgets('farmer without a farm goes to farm onboarding', (tester) async {
      final app = TestApp();
      await startApp(tester, app);
      await signInThroughUi(tester, app);
      expect(find.byType(FarmOnboardingPage), findsOneWidget);
      expect(find.byType(Dashboard), findsNothing);
      expect(app.backend.count('GET', '/api/v1/devices'), 0);
    });

    testWidgets('farmer with a farm but no device goes to device claim', (tester) async {
      final app = TestApp();
      app.backend.farms.add(Map.of(_farm));
      await startApp(tester, app);
      await signInThroughUi(tester, app);
      expect(find.byType(DeviceClaimPage), findsOneWidget);
      expect(find.byKey(const Key('farmName')), findsOneWidget);
      expect(find.textContaining('North field'), findsOneWidget);
    });
  });

  group('farm onboarding', () {
    testWidgets('creating a farm leads to device claim', (tester) async {
      final app = TestApp();
      await startApp(tester, app);
      await signInThroughUi(tester, app);
      await tester.enterText(find.byKey(const Key('farmNameField')), '  North field ');
      await tester.tap(find.byKey(const Key('createFarmButton')));
      await tester.pumpAndSettle();
      expect(app.backend.farms.single['name'], 'North field');
      expect(app.backend.calls.firstWhere((c) => c.method == 'POST' && c.path == '/api/v1/farms').authorization, startsWith('Bearer '));
      expect(find.byType(DeviceClaimPage), findsOneWidget);
    });

    testWidgets('an empty name is rejected on the device; backend errors show a safe message', (tester) async {
      final app = TestApp();
      await startApp(tester, app);
      await signInThroughUi(tester, app);
      await tester.tap(find.byKey(const Key('createFarmButton')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Enter a farm name'), findsOneWidget);
      expect(app.backend.count('POST', '/api/v1/farms'), 0);

      app.backend.overrides['/api/v1/farms'] = FakeReply.error(503, 'service_unavailable');
      await tester.enterText(find.byKey(const Key('farmNameField')), 'North field');
      await tester.tap(find.byKey(const Key('createFarmButton')));
      await tester.pumpAndSettle();
      expect(find.textContaining('temporarily unavailable'), findsOneWidget);
      expect(find.byType(FarmOnboardingPage), findsOneWidget);
    });
  });

  group('device claim', () {
    Future<TestApp> atClaimPage(WidgetTester tester) async {
      final app = TestApp();
      app.backend.farms.add(Map.of(_farm));
      app.backend.claimable['bb-0001'] = 'CLAIM-CODE-1';
      await startApp(tester, app);
      await signInThroughUi(tester, app);
      expect(find.byType(DeviceClaimPage), findsOneWidget);
      return app;
    }

    testWidgets('a valid device id and claim code attach the device and open the dashboard', (tester) async {
      final app = await atClaimPage(tester);
      await claim(tester, ' BB-0001 ', 'CLAIM-CODE-1');
      final call = app.backend.calls.firstWhere((c) => c.path == '/api/v1/devices/claim');
      expect(call.body, {'deviceId': 'bb-0001', 'claimCode': 'CLAIM-CODE-1', 'farmId': 'farm-1'});
      expect(call.authorization, startsWith('Bearer '));
      expect(app.backend.devices.single['farmId'], 'farm-1');
      expect(find.byType(Dashboard), findsOneWidget);
    });

    testWidgets('missing or malformed input is rejected on the device', (tester) async {
      final app = await atClaimPage(tester);
      await claim(tester, 'x', '123');
      expect(find.text('Enter the device ID printed on the device label.'), findsOneWidget);
      expect(find.textContaining('6 to 32 characters'), findsOneWidget);
      expect(app.backend.count('POST', '/api/v1/devices/claim'), 0);
    });

    testWidgets('claim failure (wrong / used / expired code): message, code cleared, retry works', (tester) async {
      final app = await atClaimPage(tester);
      await claim(tester, 'bb-0001', 'WRONG-CODE');
      expect(find.byKey(const Key('claimError')), findsOneWidget);
      expect(find.textContaining('could not be added'), findsOneWidget);
      expect(find.textContaining('claim_failed'), findsNothing);
      expect(find.textContaining('backend message'), findsNothing);
      expect(tester.widget<TextField>(find.byKey(const Key('claimCodeField'))).controller!.text, isEmpty);
      expect(app.backend.devices, isEmpty);
      await claim(tester, 'bb-0001', 'CLAIM-CODE-1');
      expect(find.byType(Dashboard), findsOneWidget);
    });

    testWidgets('claim attempt limit reached (429 + Retry-After)', (tester) async {
      final app = await atClaimPage(tester);
      app.backend.overrides['/api/v1/devices/claim'] = FakeReply.error(429, 'rate_limited', headers: {'retry-after': '600'});
      await claim(tester, 'bb-0001', 'CLAIM-CODE-1');
      expect(find.textContaining('Too many attempts'), findsOneWidget);
      expect(find.textContaining('10 minutes'), findsOneWidget);
      expect(find.byType(DeviceClaimPage), findsOneWidget);
    });

    testWidgets('unauthorized claim: farm not owned by the caller (404) and forbidden (403)', (tester) async {
      final app = await atClaimPage(tester);
      app.backend.farms.clear(); // the backend no longer considers farm-1 the caller's
      await claim(tester, 'bb-0001', 'CLAIM-CODE-1');
      expect(find.textContaining('selected farm was not found'), findsOneWidget);
      expect(app.backend.devices, isEmpty);

      app.backend.overrides['/api/v1/devices/claim'] = FakeReply.error(403, 'forbidden');
      await claim(tester, 'bb-0001', 'CLAIM-CODE-1');
      expect(find.textContaining('not allowed'), findsOneWidget);
      expect(find.byType(DeviceClaimPage), findsOneWidget);
    });

    testWidgets('unauthorized claim: session no longer valid (401) returns to sign-in', (tester) async {
      final app = await atClaimPage(tester);
      app.backend
        ..expireAccessToken()
        ..sessionRevoked = true;
      await claim(tester, 'bb-0001', 'CLAIM-CODE-1');
      expect(find.byType(SignInPage), findsOneWidget);
      expect(app.tokens.session, isNull);
      expect(app.backend.devices, isEmpty);
    });

    testWidgets('a farmer with several farms chooses the farm', (tester) async {
      final app = TestApp();
      app.backend.farms
        ..add(Map.of(_farm))
        ..add({'id': 'farm-2', 'name': 'River plot', 'createdAt': '2026-10-01T00:00:00Z'});
      app.backend.claimable['bb-0002'] = 'CLAIM-CODE-2';
      await startApp(tester, app);
      await signInThroughUi(tester, app);
      await tester.tap(find.byKey(const Key('farmDropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('River plot').last);
      await tester.pumpAndSettle();
      await claim(tester, 'bb-0002', 'CLAIM-CODE-2');
      expect(app.backend.devices.single['farmId'], 'farm-2');
      expect(find.byType(Dashboard), findsOneWidget);
    });

    testWidgets('log out is available during onboarding', (tester) async {
      final app = await atClaimPage(tester);
      await tester.tap(find.text('Log out'));
      await tester.pumpAndSettle();
      expect(find.byType(SignInPage), findsOneWidget);
      expect(app.tokens.session, isNull);
    });
  });

  group('onboarding check failures', () {
    testWidgets('backend unavailable after sign-in: message with retry, then continues', (tester) async {
      final app = TestApp();
      app.backend.farms.add(Map.of(_farm));
      app.backend.devices.add(Map.of(_device));
      app.backend.overrides['/api/v1/farms'] = FakeReply.error(503, 'service_unavailable');
      await startApp(tester, app);
      await signInThroughUi(tester, app);
      expect(find.byType(OnboardingGatePage), findsOneWidget);
      expect(find.byKey(const Key('gateError')), findsOneWidget);
      expect(find.textContaining('temporarily unavailable'), findsOneWidget);
      app.backend.overrides.clear();
      await tester.tap(find.byKey(const Key('gateRetry')));
      await tester.pumpAndSettle();
      expect(find.byType(Dashboard), findsOneWidget);
    });

    testWidgets('network unavailable after sign-in: message with retry; the session is kept', (tester) async {
      final app = TestApp();
      await startApp(tester, app);
      await requestCode(tester, FakeBackend.allowedPhone);
      app.backend.overrides['/api/v1/farms'] = const FakeReply(200, 'not a list');
      await enterCode(tester, app.backend.currentCode);
      expect(find.byKey(const Key('gateError')), findsOneWidget);
      expect(find.textContaining('unexpected reply'), findsOneWidget);
      app.backend.overrides.clear();
      app.backend.outage = Outage.offline;
      await tester.tap(find.byKey(const Key('gateRetry')));
      await tester.pumpAndSettle();
      expect(find.textContaining('No connection'), findsOneWidget);
      expect(app.tokens.session, isNotNull);
      app.backend.outage = Outage.none;
      await tester.tap(find.byKey(const Key('gateRetry')));
      await tester.pumpAndSettle();
      expect(find.byType(FarmOnboardingPage), findsOneWidget);
    });
  });
}
