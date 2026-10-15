import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/formatting.dart';
import 'package:smart_gossy_culture_app/ui/dashboard.dart';
import 'package:smart_gossy_culture_app/ui/device_claim_page.dart';
import 'package:smart_gossy_culture_app/ui/sign_in_page.dart';

import '../support/app_harness.dart';
import '../support/fake_backend.dart';

/// The literals the dashboard showed before Phase 3B. None may appear as data any more.
const formerSampleValues = ['1,250', '68%', '95%', 'Optimal', 'Estimated ripe bolls in sector A', 'SUNDAY, SEPTEMBER 7, 2025', 'Aphid infestation detected in Sector C.', 'Action Required'];

String textOf(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key(key))).data!;

TestApp farmerWithDevice({String deviceId = 'bb-0001', String? displayName, String? state, String? lastSeenAt}) {
  final app = TestApp()..signIn();
  app.backend.farms.add({'id': 'farm-1', 'name': 'North field', 'createdAt': '2026-10-01T00:00:00Z'});
  app.backend.devices.add(FakeBackend.device(deviceId, displayName: displayName, state: state, lastSeenAt: lastSeenAt));
  return app;
}

void expectNoSampleValues() {
  for (final value in formerSampleValues) {
    expect(find.text(value), findsNothing, reason: 'former hard-coded value "$value" is still displayed');
  }
}

Future<void> refresh(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('dashboardRefresh')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('success: backend values are rendered in the cards, banner and device row', (tester) async {
    final app = farmerWithDevice(displayName: 'Field unit', state: 'online', lastSeenAt: '2026-10-01T15:59:58Z');
    app.backend.telemetry['bb-0001'] = [FakeBackend.telemetryRow(time: '2026-10-01T15:59:55Z', batteryPct: 91.4, moistureRhPct: 54.3, airTempC: 31.5, bollsHarvestedTotal: 1287, solarActive: true)];
    app.backend.detections['bb-0001'] = [FakeBackend.detectionRow(deviceId: 'bb-0001', detectedAt: '2026-10-01T15:40:00Z', label: 'leaf_curl_virus', confidence: 0.87)];
    await startApp(tester, app);

    expect(find.byType(Dashboard), findsOneWidget);
    expect(textOf(tester, 'bollValue'), '1,287');
    expect(textOf(tester, 'bollCaption'), 'Bolls harvested (device total)');
    expect(textOf(tester, 'moistureValue'), '54.3%');
    expect(textOf(tester, 'moistureCaption'), 'Sensor reading (%RH)');
    expect(textOf(tester, 'powerValue'), '91.4%');
    expect(textOf(tester, 'powerCaption'), 'Solar Active');
    expect(textOf(tester, 'telemetryTime'), 'Reading taken by the device: ${formatDateTime(DateTime.utc(2026, 10, 1, 15, 59, 55))}');
    expect(textOf(tester, 'deviceName'), 'Field unit (bb-0001)');
    expect(find.descendant(of: find.byKey(const Key('deviceStatus')), matching: find.text('Online')), findsOneWidget);
    expect(textOf(tester, 'deviceLastSeen'), 'Last heard from: ${formatDateTime(DateTime.utc(2026, 10, 1, 15, 59, 58))}');
    expect(textOf(tester, 'detectionText'), contains('Leaf curl virus · confidence 87%'));
    expect(textOf(tester, 'detectionText'), contains(formatDateTime(DateTime.utc(2026, 10, 1, 15, 40))));
    expect(textOf(tester, 'dateLine'), formatDateHeader(DateTime.now()));
    expect(find.byKey(const Key('dashboardLoading')), findsNothing);
    expect(find.byKey(const Key('dashboardError')), findsNothing);
    expectNoSampleValues();
    // unchanged parts of the page
    expect(find.text('Quick Actions'), findsOneWidget);
    expect(find.text('Monitor'), findsOneWidget);
  });

  testWidgets('no hard-coded backend values are displayed as live data in any state', (tester) async {
    final app = farmerWithDevice();
    app.backend.telemetry['bb-0001'] = [FakeBackend.telemetryRow(time: '2026-10-01T10:00:00Z', batteryPct: 7, moistureRhPct: 12, bollsHarvestedTotal: 3, solarActive: false)];
    await startApp(tester, app);
    expect(textOf(tester, 'bollValue'), '3');
    expect(textOf(tester, 'moistureValue'), '12%');
    expect(textOf(tester, 'powerValue'), '7%');
    expect(textOf(tester, 'powerCaption'), 'Solar inactive');
    expectNoSampleValues();
    // no verdict, alert or recommendation is derived, even from low values
    for (final text in ['Optimal', 'Low Battery', 'Low', 'Ready', 'Action Required', 'Critical', 'Moisture Alert']) {
      expect(find.text(text), findsNothing, reason: text);
    }
    expect(find.byKey(const Key('detectionBanner')), findsNothing);

    // empty state
    app.backend.telemetry.clear();
    await refresh(tester);
    expect(find.byKey(const Key('dashboardNoTelemetry')), findsOneWidget);
    expectNoSampleValues();

    // error state
    app.services.dashboard.reset();
    app.backend.outage = Outage.offline;
    await refresh(tester);
    expect(find.byKey(const Key('dashboardError')), findsOneWidget);
    expectNoSampleValues();
  });

  testWidgets('greeting uses the profile name from the backend, or a neutral word when none is set', (tester) async {
    final app = farmerWithDevice();
    await startApp(tester, app);
    expect(textOf(tester, 'greeting'), 'Welcome back, Farmer!');
  });

  testWidgets('greeting shows the display name stored on the backend', (tester) async {
    final named = farmerWithDevice();
    named.backend.overrides['/api/v1/me'] = const FakeReply(200, {'id': 'u-1', 'phone': '+99900000001', 'displayName': 'Lakshmi', 'role': 'farmer', 'createdAt': '2026-10-01T00:00:00Z', 'lastLoginAt': null});
    await startApp(tester, named);
    expect(textOf(tester, 'greeting'), 'Welcome back, Lakshmi!');
  });

  testWidgets('loading state is shown while the request is in flight; refresh is disabled meanwhile', (tester) async {
    final app = farmerWithDevice();
    app.backend.telemetry['bb-0001'] = [FakeBackend.telemetryRow(time: '2026-10-01T15:59:55Z', batteryPct: 50)];
    await startApp(tester, app);
    app.services.dashboard.reset(); // nothing cached
    app.backend.latency = const Duration(seconds: 2);
    await tester.tap(find.byKey(const Key('dashboardRefresh')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('dashboardLoading')), findsOneWidget);
    expect(find.text('Loading your farm data...'), findsOneWidget);
    expect(find.byKey(const Key('powerValue')), findsNothing);
    expect(tester.widget<IconButton>(find.byKey(const Key('dashboardRefresh'))).onPressed, isNull);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dashboardLoading')), findsNothing);
    expect(textOf(tester, 'powerValue'), '50%');
    // Phase 3C: once the live stream has started the snapshot is read once more in the
    // background (no loading state); let that slow reply arrive before the test ends.
    await tester.pump(const Duration(seconds: 3));
    expect(find.byKey(const Key('dashboardLoading')), findsNothing);
  });

  testWidgets('empty: a device that has sent nothing shows "no readings", dashes and no banner', (tester) async {
    final app = farmerWithDevice();
    await startApp(tester, app);
    expect(find.byKey(const Key('dashboardNoTelemetry')), findsOneWidget);
    expect(find.text('No readings yet'), findsOneWidget);
    expect(textOf(tester, 'bollValue'), '—');
    expect(textOf(tester, 'moistureValue'), '—');
    expect(textOf(tester, 'powerValue'), '—');
    expect(textOf(tester, 'bollCaption'), 'No reading');
    expect(find.byKey(const Key('telemetryTime')), findsNothing);
    expect(find.byKey(const Key('detectionBanner')), findsNothing);
    expect(find.descendant(of: find.byKey(const Key('deviceStatus')), matching: find.text('Status not reported')), findsOneWidget);
    expect(textOf(tester, 'deviceLastSeen'), 'Not heard from yet');
    expect(find.text('0'), findsNothing);
    expect(find.text('0%'), findsNothing);
  });

  testWidgets('partial reading: fields the device did not send show "no reading", the rest are shown', (tester) async {
    final app = farmerWithDevice(state: 'offline', lastSeenAt: '2026-10-01T09:00:00Z');
    app.backend.telemetry['bb-0001'] = [FakeBackend.telemetryRow(time: '2026-10-01T09:00:00Z', batteryPct: 40)];
    await startApp(tester, app);
    expect(textOf(tester, 'powerValue'), '40%');
    expect(textOf(tester, 'powerCaption'), 'Battery level');
    expect(textOf(tester, 'bollValue'), '—');
    expect(textOf(tester, 'moistureValue'), '—');
    expect(textOf(tester, 'moistureCaption'), 'No reading');
    expect(find.byKey(const Key('dashboardNoTelemetry')), findsNothing);
    expect(find.descendant(of: find.byKey(const Key('deviceStatus')), matching: find.text('Offline')), findsOneWidget);
  });

  testWidgets('no device (defensive): message and a way back to device onboarding', (tester) async {
    final app = farmerWithDevice();
    await startApp(tester, app);
    app.backend.devices.clear(); // detached on the backend after onboarding
    await refresh(tester);
    expect(find.byKey(const Key('dashboardNoDevice')), findsOneWidget);
    expect(find.byKey(const Key('powerValue')), findsNothing);
    await tester.tap(find.byKey(const Key('dashboardAddDevice')));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceClaimPage), findsOneWidget);
  });

  testWidgets('HTTP error on first load: error state with a safe message; retry loads the data', (tester) async {
    final app = farmerWithDevice();
    app.backend.telemetry['bb-0001'] = [FakeBackend.telemetryRow(time: '2026-10-01T15:59:55Z', batteryPct: 66)];
    await startApp(tester, app);
    app.services.dashboard.reset();
    app.backend.overrides['/api/v1/devices/bb-0001/telemetry'] = FakeReply.error(500, 'internal_error');
    await refresh(tester);
    expect(find.byKey(const Key('dashboardError')), findsOneWidget);
    expect(find.textContaining('Something went wrong on our side'), findsOneWidget);
    expect(find.textContaining('internal_error'), findsNothing);
    expect(find.textContaining('backend message'), findsNothing);
    expect(find.byKey(const Key('powerValue')), findsNothing);

    app.backend.overrides['/api/v1/devices/bb-0001/telemetry'] = FakeReply.error(503, 'service_unavailable');
    await tester.tap(find.byKey(const Key('dashboardRetry')));
    await tester.pumpAndSettle();
    expect(find.textContaining('temporarily unavailable'), findsOneWidget);

    app.backend.overrides.clear();
    await tester.tap(find.byKey(const Key('dashboardRetry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dashboardError')), findsNothing);
    expect(textOf(tester, 'powerValue'), '66%');
  });

  testWidgets('network failure and timeout on first load, then retry', (tester) async {
    final app = farmerWithDevice();
    app.backend.telemetry['bb-0001'] = [FakeBackend.telemetryRow(time: '2026-10-01T15:59:55Z', batteryPct: 66)];
    await startApp(tester, app);
    app.services.dashboard.reset();
    app.backend.outage = Outage.offline;
    await refresh(tester);
    expect(find.byKey(const Key('dashboardError')), findsOneWidget);
    expect(find.textContaining('No connection'), findsOneWidget);
    app.backend.outage = Outage.timeout;
    await tester.tap(find.byKey(const Key('dashboardRetry')));
    await tester.pumpAndSettle();
    expect(find.textContaining('taking too long'), findsOneWidget);
    app.backend.outage = Outage.none;
    await tester.tap(find.byKey(const Key('dashboardRetry')));
    await tester.pumpAndSettle();
    expect(textOf(tester, 'powerValue'), '66%');
  });

  testWidgets('refresh: new backend values replace the old ones; nothing is requested without a refresh', (tester) async {
    final app = farmerWithDevice();
    app.backend.telemetry['bb-0001'] = [FakeBackend.telemetryRow(time: '2026-10-01T15:00:00Z', batteryPct: 66, bollsHarvestedTotal: 10)];
    await startApp(tester, app);
    expect(textOf(tester, 'powerValue'), '66%');
    final sent = app.backend.calls.length;
    await tester.pump(const Duration(minutes: 10)); // no polling, no timers
    expect(app.backend.calls.length, sent);

    app.backend.telemetry['bb-0001']!.insert(0, FakeBackend.telemetryRow(time: '2026-10-01T15:05:00Z', batteryPct: 65, bollsHarvestedTotal: 14));
    await refresh(tester);
    expect(textOf(tester, 'powerValue'), '65%');
    expect(textOf(tester, 'bollValue'), '14');
    // the dashboard's three reads and, since Phase 5B, the two alert reads behind the bell
    final refreshCalls = app.backend.calls.skip(sent).map((c) => '$c').toList();
    expect(refreshCalls.where((c) => c != 'GET /api/v1/alerts').toSet(), {'GET /api/v1/devices', 'GET /api/v1/devices/bb-0001/telemetry', 'GET /api/v1/detections'});
    expect(refreshCalls.where((c) => c == 'GET /api/v1/alerts'), hasLength(2));
    expect(app.backend.calls.length, sent + 5);

    // pull-to-refresh does the same
    app.backend.telemetry['bb-0001']!.insert(0, FakeBackend.telemetryRow(time: '2026-10-01T15:10:00Z', batteryPct: 64, bollsHarvestedTotal: 15));
    await tester.fling(find.byKey(const Key('greeting')), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();
    expect(textOf(tester, 'powerValue'), '64%');
  });

  testWidgets('failed refresh: the last loaded values stay, marked with when they were loaded; retry clears the notice', (tester) async {
    final app = farmerWithDevice();
    app.backend.telemetry['bb-0001'] = [FakeBackend.telemetryRow(time: '2026-10-01T15:00:00Z', batteryPct: 66)];
    await startApp(tester, app);
    app.backend.outage = Outage.offline;
    await refresh(tester);
    expect(find.byKey(const Key('dashboardRefreshError')), findsOneWidget);
    expect(find.textContaining('Showing data loaded'), findsOneWidget);
    expect(textOf(tester, 'powerValue'), '66%');
    app.backend.outage = Outage.none;
    await tester.tap(find.byKey(const Key('dashboardRefreshRetry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dashboardRefreshError')), findsNothing);
  });

  testWidgets('malformed response: safe message, no partial or invented values', (tester) async {
    final app = farmerWithDevice();
    await startApp(tester, app);
    app.services.dashboard.reset();
    app.backend.overrides['/api/v1/devices/bb-0001/telemetry'] = const FakeReply(200, {'items': [{'time': '2026-10-01T15:59:55Z', 'msgId': 'm', 'batteryPct': 'ninety'}]});
    await refresh(tester);
    expect(find.byKey(const Key('dashboardError')), findsOneWidget);
    expect(find.textContaining('unexpected reply'), findsOneWidget);
    expect(find.textContaining('ninety'), findsNothing);
    expect(find.textContaining('FormatException'), findsNothing);
    expect(find.byKey(const Key('powerValue')), findsNothing);
  });

  testWidgets('session expiration on the dashboard: session cleared, back to sign-in with a notice', (tester) async {
    final app = farmerWithDevice();
    app.backend.telemetry['bb-0001'] = [FakeBackend.telemetryRow(time: '2026-10-01T15:00:00Z', batteryPct: 66)];
    await startApp(tester, app);
    expect(find.byType(Dashboard), findsOneWidget);
    app.backend
      ..expireAccessToken()
      ..sessionRevoked = true;
    await refresh(tester);
    expect(find.byType(SignInPage), findsOneWidget);
    expect(find.textContaining('session has ended'), findsOneWidget);
    expect(app.tokens.session, isNull);
    expect(app.services.dashboard.data, isNull);
    expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
  });

  testWidgets('expired access token on the dashboard: one refresh, data loads, user stays signed in', (tester) async {
    final app = farmerWithDevice();
    app.backend.telemetry['bb-0001'] = [FakeBackend.telemetryRow(time: '2026-10-01T15:00:00Z', batteryPct: 66)];
    await startApp(tester, app);
    app.backend.expireAccessToken();
    app.backend.telemetry['bb-0001']!.insert(0, FakeBackend.telemetryRow(time: '2026-10-01T15:05:00Z', batteryPct: 61));
    await refresh(tester);
    expect(textOf(tester, 'powerValue'), '61%');
    expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
    expect(find.byType(Dashboard), findsOneWidget);
  });

  testWidgets('several devices: the selector switches device and shows only that device\'s data', (tester) async {
    final app = TestApp()..signIn();
    app.backend.farms.add({'id': 'farm-1', 'name': 'North field', 'createdAt': '2026-10-01T00:00:00Z'});
    app.backend.devices
      ..add(FakeBackend.device('bb-0001', claimedAt: '2026-10-01T00:00:00Z'))
      ..add(FakeBackend.device('bb-0002', claimedAt: '2026-09-01T00:00:00Z'));
    app.backend.telemetry['bb-0001'] = [FakeBackend.telemetryRow(time: '2026-10-01T15:00:00Z', batteryPct: 81, bollsHarvestedTotal: 100)];
    app.backend.telemetry['bb-0002'] = [FakeBackend.telemetryRow(time: '2026-10-01T14:00:00Z', batteryPct: 22)];
    app.backend.detections['bb-0001'] = [FakeBackend.detectionRow(deviceId: 'bb-0001', detectedAt: '2026-10-01T15:40:00Z', label: 'bollworm', confidence: 0.9)];
    await startApp(tester, app);
    expect(textOf(tester, 'powerValue'), '81%');
    expect(find.byKey(const Key('detectionBanner')), findsOneWidget);
    await tester.tap(find.byKey(const Key('deviceSelector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('bb-0002').last);
    await tester.pumpAndSettle();
    expect(textOf(tester, 'powerValue'), '22%');
    expect(textOf(tester, 'bollValue'), '—');
    expect(find.byKey(const Key('detectionBanner')), findsNothing);
    expect(app.backend.calls.where((c) => c.path == '/api/v1/detections').last.query['deviceId'], 'bb-0002');
  });
}
