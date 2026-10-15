// Phase 4: the Dashboard page's behaviour around the app lifecycle, reading freshness, the air
// temperature reading and the states of the live channel - the real app (launch page included)
// with the fake REST backend and the fake live channel that follow the backend contracts.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/dashboard/dashboard_controller.dart';
import 'package:smart_gossy_culture_app/core/realtime/live_connection.dart';
import 'package:smart_gossy_culture_app/ui/dashboard.dart';
import 'package:smart_gossy_culture_app/ui/settings_profile_page.dart';
import 'package:smart_gossy_culture_app/ui/sign_in_page.dart';

import '../support/app_harness.dart';
import '../support/fake_backend.dart';
import '../support/fake_live.dart';

const device = 'unit-a';
const otherDevice = 'unit-b';

const liveText = 'Live - newest reading from the device';
const notConnectedText = 'Last known reading - live updates are not connected';
const offlineText = 'Last known reading - the device is offline';
const unknownStatusText = 'Last known reading - the device has not reported its status';

String textOf(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key(key))).data!;

Color colorOf(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key(key))).style!.color!;

TestApp farmer({List<String> devices = const [device], String? state = 'online', num? airTempC = 31.5}) {
  final app = TestApp(random: FixedRandom(1.0))..signIn();
  app.backend.farms.add({'id': 'farm-1', 'name': 'North field', 'createdAt': '2026-10-01T00:00:00Z'});
  for (final (index, id) in devices.indexed) {
    app.backend.devices.add(FakeBackend.device(id, displayName: index == 0 ? 'Field unit' : null, state: state, lastSeenAt: state == null ? null : '2026-10-01T15:00:00Z', claimedAt: '2026-10-0${9 - index}T00:00:00Z'));
  }
  app.backend.telemetry[device] = [FakeBackend.telemetryRow(time: '2026-10-01T15:00:00Z', batteryPct: 91.4, moistureRhPct: 54.3, airTempC: airTempC, bollsHarvestedTotal: 1287, solarActive: true, msgId: '01K6CQ4W0D8V9J4Q9W2Y000001')];
  return app;
}

/// What Android reports when the user leaves the app, and when they come back.
Future<void> toBackground(WidgetTester tester) async {
  addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
  for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pump();
}

Future<void> toForeground(WidgetTester tester) async {
  for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pumpAndSettle();
}

void main() {
  group('navigation', () {
    testWidgets('back from Settings (a new dashboard page replaces the old one): live updates stay on', (tester) async {
      final app = farmer();
      await startApp(tester, app);
      expect(textOf(tester, 'liveStatus'), 'Live updates on');

      // Settings on top of the dashboard; its back arrow opens a NEW dashboard page and removes
      // every page below it - the old dashboard page is disposed after the new one has opened.
      await tester.tap(find.byIcon(Icons.person));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsProfilePage), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsProfilePage), findsNothing);
      expect(find.byType(Dashboard), findsOneWidget);
      expect(app.live.openSockets, hasLength(1), reason: 'exactly one connection, for the page that is open');
      expect(textOf(tester, 'liveStatus'), 'Live updates on');
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:00:05Z', data: {'batteryPct': 80});
      await tester.pumpAndSettle();
      expect(textOf(tester, 'powerValue'), '80%');

      // Leaving the last dashboard page still closes the connection.
      await tester.ensureVisible(find.text('Logs').first);
      await tester.tap(find.text('Logs').first);
      await tester.pumpAndSettle();
      expect(find.byType(Dashboard), findsNothing);
      expect(app.live.openSockets, isEmpty);
      expect(app.services.live.state, LiveState.disconnected);
    });
  });

  group('app lifecycle', () {
    testWidgets('background closes the connection; foreground re-reads the state and reconnects', (tester) async {
      final app = farmer();
      await startApp(tester, app);
      final socket = app.live.sockets.single;
      expect(textOf(tester, 'liveStatus'), 'Live updates on');
      expect(textOf(tester, 'readingFreshness'), liveText);

      await toBackground(tester);
      expect(socket.closedByClient, isTrue);
      expect(app.live.openSockets, isEmpty);
      // (no frame is drawn in the background, so the state is read from the controller:)
      // the same values are held, no longer counted as current
      expect(app.services.dashboard.liveState, LiveState.disconnected);
      expect(app.services.dashboard.freshness, ReadingFreshness.notConnected);
      expect(app.services.dashboard.data!.telemetry!.batteryPct, 91.4);
      final restCalls = app.backend.calls.length;
      await tester.pump(const Duration(hours: 3));
      expect(app.live.attempts, hasLength(1));
      expect(app.backend.calls.length, restCalls, reason: 'no request and no attempt in the background');

      // the device kept working meanwhile
      app.backend.telemetry[device]!.insert(0, FakeBackend.telemetryRow(time: '2026-10-01T18:00:00Z', batteryPct: 70, moistureRhPct: 48, airTempC: 27, bollsHarvestedTotal: 1500, solarActive: false, msgId: '01K6CQ4W0D8V9J4Q9W2Y000200'));
      await toForeground(tester);

      expect(find.byType(Dashboard), findsOneWidget);
      expect(textOf(tester, 'powerValue'), '70%');
      expect(textOf(tester, 'bollValue'), '1,500');
      expect(textOf(tester, 'airTempValue'), '27 °C');
      expect(textOf(tester, 'liveStatus'), 'Live updates on');
      expect(textOf(tester, 'readingFreshness'), liveText);
      expect(app.live.attempts, hasLength(2));
      expect(app.live.openSockets, hasLength(1));
      expect(app.live.sockets.last.received, [{'op': 'start'}]);
      expect(find.byKey(const Key('dashboardError')), findsNothing);
      expect(find.byKey(const Key('dashboardRefreshError')), findsNothing);

      // live again
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T18:00:05Z', data: {'batteryPct': 69});
      await tester.pumpAndSettle();
      expect(textOf(tester, 'powerValue'), '69%');
    });

    testWidgets('a passing interruption (system dialog, app switcher) keeps the connection', (tester) async {
      final app = farmer();
      await startApp(tester, app);
      final restCalls = app.backend.calls.length;
      for (final state in [AppLifecycleState.inactive, AppLifecycleState.resumed, AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(app.live.attempts, hasLength(1));
      expect(app.live.openSockets, hasLength(1));
      expect(app.backend.calls.length, restCalls);
      expect(textOf(tester, 'liveStatus'), 'Live updates on');
    });

    testWidgets('background with another page on top of the dashboard, and back', (tester) async {
      final app = farmer();
      await startApp(tester, app);
      await tester.tap(find.byIcon(Icons.person)); // Settings over the dashboard
      await tester.pumpAndSettle();
      expect(app.live.openSockets, hasLength(1));

      await toBackground(tester);
      expect(app.live.openSockets, isEmpty);
      await toForeground(tester);
      expect(find.byType(SettingsProfilePage), findsOneWidget, reason: 'the user is where they were');
      expect(app.live.openSockets, hasLength(1));
      expect(app.services.dashboard.liveState, LiveState.connected);
    });

    testWidgets('session revoked while the app was in the background: sign-in page on return', (tester) async {
      final app = farmer();
      await startApp(tester, app);
      await toBackground(tester);
      app.backend
        ..expireAccessToken()
        ..sessionRevoked = true;
      final attempts = app.live.attempts.length;

      await toForeground(tester);

      expect(find.byType(SignInPage), findsOneWidget);
      expect(find.textContaining('session has ended'), findsOneWidget);
      expect(app.tokens.session, isNull);
      expect(app.services.dashboard.data, isNull);
      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
      await tester.pump(const Duration(hours: 1));
      expect(app.live.attempts.length, attempts, reason: 'no connection is attempted without a session');
      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);

      // lifecycle events after sign-out do nothing
      await toBackground(tester);
      await toForeground(tester);
      expect(app.live.attempts.length, attempts);
      expect(find.byType(SignInPage), findsOneWidget);
    });

    testWidgets('no network yet on return: the last values with a notice, then recovery without the user', (tester) async {
      final app = farmer();
      await startApp(tester, app);
      await toBackground(tester);
      app.backend.outage = Outage.offline;
      app.live.outage = LiveOutage.offline;
      await toForeground(tester);

      expect(find.byKey(const Key('dashboardRefreshError')), findsOneWidget);
      expect(textOf(tester, 'powerValue'), '91.4%');
      expect(textOf(tester, 'liveStatus'), 'Live updates interrupted - reconnecting. Showing the last values received.');
      expect(textOf(tester, 'readingFreshness'), notConnectedText);

      app.backend.telemetry[device]!.insert(0, FakeBackend.telemetryRow(time: '2026-10-01T18:00:00Z', batteryPct: 70, airTempC: 27, msgId: '01K6CQ4W0D8V9J4Q9W2Y000200'));
      app.backend.outage = Outage.none;
      app.live.outage = LiveOutage.none;
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'liveStatus'), 'Live updates on');
      expect(textOf(tester, 'powerValue'), '70%');
      expect(textOf(tester, 'readingFreshness'), liveText);
      expect(find.byKey(const Key('dashboardRefreshError')), findsNothing);
    });
  });

  group('current and last known readings', () {
    testWidgets('a live reading and a last known reading look different', (tester) async {
      final app = farmer();
      await startApp(tester, app);
      expect(textOf(tester, 'readingFreshness'), liveText);
      final liveColor = colorOf(tester, 'readingFreshness');
      for (final key in ['bollValue', 'moistureValue', 'powerValue', 'airTempValue']) {
        expect(colorOf(tester, key), Colors.black87, reason: key);
      }

      // the backend reports the device offline (Last Will)
      app.live.ingest(kind: 'status', deviceId: device, ts: '2026-10-01T14:00:00Z', receivedAt: '2026-10-01T15:02:00Z', data: {'state': 'offline'});
      await tester.pumpAndSettle();
      expect(textOf(tester, 'readingFreshness'), offlineText);
      expect(colorOf(tester, 'readingFreshness'), isNot(liveColor));
      for (final key in ['bollValue', 'moistureValue', 'powerValue', 'airTempValue']) {
        expect(colorOf(tester, key), Colors.black45, reason: '$key is shown as last known');
      }
      // the values themselves and their time are untouched; the app's connection is fine
      expect(textOf(tester, 'powerValue'), '91.4%');
      expect(textOf(tester, 'bollValue'), '1,287');
      expect(find.byKey(const Key('telemetryTime')), findsOneWidget);
      expect(textOf(tester, 'liveStatus'), 'Live updates on');
      expect(find.text('No reading'), findsNothing);

      // online again: a current reading again
      app.live.ingest(kind: 'status', deviceId: device, ts: '2026-10-01T15:03:00Z', receivedAt: '2026-10-01T15:03:01Z', data: {'state': 'online'});
      await tester.pumpAndSettle();
      expect(textOf(tester, 'readingFreshness'), liveText);
      expect(colorOf(tester, 'powerValue'), Colors.black87);
    });

    testWidgets('disconnected, reconnecting and reconnected', (tester) async {
      final app = farmer();
      await startApp(tester, app);
      app.live.outage = LiveOutage.offline;
      app.live.dropAll(code: 1011);
      await tester.pumpAndSettle();
      expect(textOf(tester, 'liveStatus'), 'Live updates interrupted - reconnecting. Showing the last values received.');
      expect(textOf(tester, 'readingFreshness'), notConnectedText);
      expect(colorOf(tester, 'powerValue'), Colors.black45);
      // the device row still says what the device last reported: not a sensor or device failure
      expect(find.descendant(of: find.byKey(const Key('deviceStatus')), matching: find.text('Online')), findsOneWidget);
      expect(find.byKey(const Key('dashboardError')), findsNothing);

      app.live.outage = LiveOutage.none;
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'liveStatus'), 'Live updates on');
      expect(textOf(tester, 'readingFreshness'), liveText);
      expect(colorOf(tester, 'powerValue'), Colors.black87);
    });

    testWidgets('a device that never reported its state; a device without readings', (tester) async {
      final unknown = farmer(state: null);
      await startApp(tester, unknown);
      expect(textOf(tester, 'readingFreshness'), unknownStatusText);
      expect(find.descendant(of: find.byKey(const Key('deviceStatus')), matching: find.text('Status not reported')), findsOneWidget);
    });

    testWidgets('no reading: nothing is called live or last known', (tester) async {
      final app = farmer()..backend.telemetry.clear();
      await startApp(tester, app);
      expect(find.text('No readings yet'), findsOneWidget);
      expect(find.byKey(const Key('readingFreshness')), findsNothing);
      for (final key in ['bollValue', 'moistureValue', 'powerValue', 'airTempValue']) {
        expect(textOf(tester, key), '—', reason: key);
      }
      expect(textOf(tester, 'liveStatus'), 'Live updates on', reason: 'the connection is there for when the device reports');

      // the first reading arrives live
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:00:05Z', data: {'batteryPct': 80, 'airTempC': 29.5});
      await tester.pumpAndSettle();
      expect(find.text('No readings yet'), findsNothing);
      expect(textOf(tester, 'readingFreshness'), liveText);
      expect(textOf(tester, 'powerValue'), '80%');
      expect(textOf(tester, 'airTempValue'), '29.5 °C');
    });

    testWidgets('a failed refresh keeps the freshness of the values shown; a failed first load shows none', (tester) async {
      final app = farmer();
      await startApp(tester, app);
      app.backend.overrides['/api/v1/devices/$device/telemetry'] = FakeReply.error(500, 'internal_error');
      await tester.tap(find.byKey(const Key('dashboardRefresh')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dashboardRefreshError')), findsOneWidget);
      // the REST refresh failed, but the live channel is connected and the device is online:
      // a newer reading would still arrive here
      expect(textOf(tester, 'readingFreshness'), liveText);
      expect(textOf(tester, 'liveStatus'), 'Live updates on');
    });

    testWidgets('first load failed: an error card, no values, no freshness line, no connection', (tester) async {
      final app = farmer();
      app.backend.overrides['/api/v1/devices/$device/telemetry'] = FakeReply.error(503, 'service_unavailable');
      await startApp(tester, app);
      expect(find.byKey(const Key('dashboardError')), findsOneWidget);
      expect(find.byKey(const Key('readingFreshness')), findsNothing);
      expect(find.byKey(const Key('liveStatus')), findsNothing);
      expect(find.byKey(const Key('powerValue')), findsNothing);
      expect(app.live.attempts, isEmpty);
    });
  });

  group('air temperature', () {
    testWidgets('shown as reported, with no verdict; "No reading" when the device did not send it', (tester) async {
      final app = farmer();
      await startApp(tester, app);
      expect(find.text('Air temperature'), findsOneWidget);
      expect(textOf(tester, 'airTempValue'), '31.5 °C');
      expect(textOf(tester, 'airTempCaption'), 'Sensor reading (°C)');

      // extreme values are still only readings
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:00:05Z', data: {'batteryPct': 90, 'airTempC': 49});
      await tester.pumpAndSettle();
      expect(textOf(tester, 'airTempValue'), '49 °C');
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:00:10Z', data: {'batteryPct': 90, 'airTempC': -3.5});
      await tester.pumpAndSettle();
      expect(textOf(tester, 'airTempValue'), '-3.5 °C');
      for (final text in ['Hot', 'Cold', 'High', 'Low', 'Normal', 'Optimal', 'Alert', 'Warning']) {
        expect(find.text(text), findsNothing, reason: text);
      }

      // a reading without the field: not zero, not the previous value
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:00:15Z', data: {'batteryPct': 89});
      await tester.pumpAndSettle();
      expect(textOf(tester, 'airTempValue'), '—');
      expect(textOf(tester, 'airTempCaption'), 'No reading');
      expect(find.textContaining('°C'), findsNothing);
    });

    testWidgets('a device whose readings never include it', (tester) async {
      final app = farmer(airTempC: null);
      await startApp(tester, app);
      expect(textOf(tester, 'airTempValue'), '—');
      expect(textOf(tester, 'airTempCaption'), 'No reading');
      expect(textOf(tester, 'powerValue'), '91.4%');
    });
  });

  group('live updates refused by the backend', () {
    testWidgets('switched off with the values kept; tried again later; on again when accepted', (tester) async {
      final app = farmer();
      await startApp(tester, app);
      app.live.refuseUpgrades = true;
      app.live.expireTokens();
      await tester.pumpAndSettle();
      expect(find.byType(Dashboard), findsOneWidget, reason: 'not a reason to sign the user out');
      expect(textOf(tester, 'liveStatus'), 'Live updates are off. Refresh to update.');
      expect(textOf(tester, 'readingFreshness'), notConnectedText);
      expect(textOf(tester, 'powerValue'), '91.4%');
      expect(find.byKey(const Key('dashboardError')), findsNothing);

      app.live.refuseUpgrades = false;
      await tester.pump(const Duration(seconds: 59));
      expect(textOf(tester, 'liveStatus'), 'Live updates are off. Refresh to update.');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'liveStatus'), 'Live updates on');
      expect(textOf(tester, 'readingFreshness'), liveText);
      expect(app.live.openSockets, hasLength(1));
    });

    testWidgets('leaving the page while a later try is pending cancels it', (tester) async {
      final app = farmer();
      await startApp(tester, app);
      app.live.refuseUpgrades = true;
      app.live.expireTokens();
      await tester.pumpAndSettle();
      final attempts = app.live.attempts.length;
      await tester.ensureVisible(find.text('Logs').first);
      await tester.tap(find.text('Logs').first);
      await tester.pumpAndSettle();
      expect(find.byType(Dashboard), findsNothing);
      await tester.pump(const Duration(hours: 1));
      expect(app.live.attempts.length, attempts);
      // (the test framework additionally fails any test that ends with a pending timer)
    });
  });

  group('device switching (unchanged from Phase 3C)', () {
    testWidgets('old connection closed, new snapshot, new connection; freshness follows the new device', (tester) async {
      final app = farmer(devices: [device, otherDevice]);
      await startApp(tester, app);
      final first = app.live.sockets.single;
      expect(textOf(tester, 'readingFreshness'), liveText);

      await tester.tap(find.byKey(const Key('deviceSelector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(otherDevice).last);
      await tester.pumpAndSettle();

      expect(first.closedByClient, isTrue);
      expect(app.live.sockets, hasLength(2));
      expect(app.live.openSockets, hasLength(1));
      expect(app.live.sockets.last.received, [{'op': 'start'}]);
      expect(find.text('No readings yet'), findsOneWidget, reason: 'the second device has sent nothing');
      expect(find.byKey(const Key('readingFreshness')), findsNothing);
      expect(textOf(tester, 'airTempValue'), '—');
      expect(textOf(tester, 'liveStatus'), 'Live updates on');
    });
  });
}
