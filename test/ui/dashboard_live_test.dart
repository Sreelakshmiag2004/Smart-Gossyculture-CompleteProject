// Phase 3C: the Dashboard page with live updates - the real app (launch page included) with the
// fake REST backend and the fake live channel that follow the backend contracts.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/formatting.dart';
import 'package:smart_gossy_culture_app/core/realtime/live_connection.dart';
import 'package:smart_gossy_culture_app/ui/Harvest.dart';
import 'package:smart_gossy_culture_app/ui/dashboard.dart';
import 'package:smart_gossy_culture_app/ui/settings_profile_page.dart';
import 'package:smart_gossy_culture_app/ui/sign_in_page.dart';

import '../support/app_harness.dart';
import '../support/fake_backend.dart';
import '../support/fake_live.dart';

const device = 'unit-a';
const otherDevice = 'unit-b';

/// Wording the dashboard must never show: nothing in the backend contract supports it.
const unsupportedWording = ['Optimal', 'Low Battery', 'Low', 'Ready', 'Ready to harvest', 'Action Required', 'Critical', 'Moisture Alert', 'Alert', 'Recommended', 'Sensor error', 'Sensor offline'];

String textOf(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key(key))).data!;

TestApp farmer({List<String> devices = const [device]}) {
  final app = TestApp(random: FixedRandom(1.0))..signIn();
  app.backend.farms.add({'id': 'farm-1', 'name': 'North field', 'createdAt': '2026-10-01T00:00:00Z'});
  for (final (index, id) in devices.indexed) {
    app.backend.devices.add(FakeBackend.device(id, displayName: index == 0 ? 'Field unit' : null, state: 'online', lastSeenAt: '2026-10-01T15:00:00Z', claimedAt: '2026-10-0${9 - index}T00:00:00Z'));
  }
  app.backend.telemetry[device] = [FakeBackend.telemetryRow(time: '2026-10-01T15:00:00Z', batteryPct: 91.4, moistureRhPct: 54.3, bollsHarvestedTotal: 1287, solarActive: true, msgId: '01K6CQ4W0D8V9J4Q9W2Y000001')];
  return app;
}

void expectNoUnsupportedWording() {
  for (final text in unsupportedWording) {
    expect(find.text(text), findsNothing, reason: '"$text" is displayed');
  }
}

void main() {
  testWidgets('the REST snapshot is displayed first; then one live connection is made', (tester) async {
    final app = farmer();
    app.live.talkative = false; // the live channel does not answer yet
    await startApp(tester, app);

    expect(find.byType(Dashboard), findsOneWidget);
    expect(textOf(tester, 'bollValue'), '1,287');
    expect(textOf(tester, 'moistureValue'), '54.3%');
    expect(textOf(tester, 'powerValue'), '91.4%');
    expect(textOf(tester, 'deviceName'), 'Field unit ($device)');
    expect(find.descendant(of: find.byKey(const Key('deviceStatus')), matching: find.text('Online')), findsOneWidget);
    // ... while the live channel is still connecting
    expect(textOf(tester, 'liveStatus'), 'Connecting to live updates...');
    expect(app.live.attempts, hasLength(1));

    app.live.talkative = true;
    app.live.openSockets.single.push({'type': 'hello', 'protocol': 'gossy.ws.v1', 'serverTime': 'x', 'latestCursor': 100, 'tokenExpiresAt': 'x', 'heartbeatIntervalS': 25, 'allowedOps': ['start', 'resume', 'ping']});
    await tester.pumpAndSettle();
    expect(textOf(tester, 'liveStatus'), 'Live updates on');
    expect(textOf(tester, 'powerValue'), '91.4%');
  });

  testWidgets('rebuilds, refreshes and other pages on top do not create another connection', (tester) async {
    final app = farmer();
    await startApp(tester, app);
    expect(app.live.attempts, hasLength(1));
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const Key('dashboardRefresh')));
      await tester.pumpAndSettle();
    }
    // rebuild the whole tree
    tester.view.physicalSize = const Size(1200, 2400);
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1080, 2340);
    await tester.pumpAndSettle();
    // another page on top of the dashboard (the avatar pushes Settings), and back
    await tester.tap(find.byIcon(Icons.person));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsProfilePage), findsOneWidget);
    expect(app.live.openSockets, hasLength(1), reason: 'the dashboard is still open underneath');
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.byType(Dashboard), findsOneWidget);

    expect(app.live.attempts, hasLength(1));
    expect(app.live.openSockets, hasLength(1));
    expect(textOf(tester, 'liveStatus'), 'Live updates on');
  });

  testWidgets('a telemetry event updates the cards; captions keep their meaning; no verdict is added', (tester) async {
    final app = farmer();
    await startApp(tester, app);
    expect(textOf(tester, 'bollValue'), '1,287');

    app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:00:05Z', receivedAt: '2026-10-01T15:00:06Z', data: {'batteryPct': 7, 'moistureRhPct': 3.5, 'airTempC': 44, 'bollsHarvestedTotal': 1290, 'solarActive': false});
    await tester.pumpAndSettle();

    expect(textOf(tester, 'bollValue'), '1,290');
    expect(textOf(tester, 'bollCaption'), 'Bolls harvested (device total)');
    expect(textOf(tester, 'moistureValue'), '3.5%');
    expect(textOf(tester, 'moistureCaption'), 'Sensor reading (%RH)');
    expect(textOf(tester, 'powerValue'), '7%');
    expect(textOf(tester, 'powerCaption'), 'Solar inactive');
    expect(textOf(tester, 'telemetryTime'), 'Reading taken by the device: ${formatDateTime(DateTime.utc(2026, 10, 1, 15, 0, 5))}');
    expect(textOf(tester, 'deviceLastSeen'), 'Last heard from: ${formatDateTime(DateTime.utc(2026, 10, 1, 15, 0, 6))}');
    // very low battery and moisture: still only readings
    expectNoUnsupportedWording();
    expect(find.byKey(const Key('detectionBanner')), findsNothing);
    // Phase 4: air temperature is shown as the reading it is - a very high value gets no verdict either.
    expect(textOf(tester, 'airTempValue'), '44 °C');
    expect(textOf(tester, 'airTempCaption'), 'Sensor reading (°C)');
    expect(find.textContaining('44'), findsOneWidget, reason: 'the value appears in its own card and nowhere else');
  });

  testWidgets('a telemetry event without optional readings shows "no reading" for them, not zero or the old value', (tester) async {
    final app = farmer();
    await startApp(tester, app);
    app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:00:05Z', data: {'batteryPct': 80});
    await tester.pumpAndSettle();
    expect(textOf(tester, 'powerValue'), '80%');
    expect(textOf(tester, 'powerCaption'), 'Battery level');
    expect(textOf(tester, 'bollValue'), '—');
    expect(textOf(tester, 'bollCaption'), 'No reading');
    expect(textOf(tester, 'moistureValue'), '—');
    expect(find.text('0'), findsNothing);
    expect(find.text('0%'), findsNothing);
    expect(find.text('1,287'), findsNothing);
  });

  testWidgets('a detection event shows the "Latest detection" card as reported - not an alert', (tester) async {
    final app = farmer();
    await startApp(tester, app);
    expect(find.byKey(const Key('detectionBanner')), findsNothing);

    app.live.ingest(kind: 'event/pest', deviceId: device, ts: '2026-10-01T15:01:00Z', data: {'label': 'leaf_curl_virus', 'confidence': 0.87, 'bbox': [0.1, 0.2, 0.1, 0.1]});
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('detectionBanner')), findsOneWidget);
    expect(find.text('Latest detection'), findsOneWidget);
    expect(textOf(tester, 'detectionText'), 'Leaf curl virus · confidence 87%\nReported ${formatDateTime(DateTime.utc(2026, 10, 1, 15, 1))}');
    expectNoUnsupportedWording();
    for (final text in ['infestation', 'Spray', 'pesticide', 'treatment', 'Sector']) {
      expect(find.textContaining(text), findsNothing, reason: text);
    }
    expect(find.descendant(of: find.byKey(const Key('detectionBanner')), matching: find.byType(Image)), findsNothing);

    // a newer detection replaces it; an older one does not
    app.live.ingest(kind: 'event/pest', deviceId: device, ts: '2026-10-01T15:02:00Z', data: {'label': 'bollworm', 'confidence': 0.6});
    app.live.ingest(kind: 'event/pest', deviceId: device, ts: '2026-10-01T14:00:00Z', data: {'label': 'aphid', 'confidence': 0.99});
    await tester.pumpAndSettle();
    expect(textOf(tester, 'detectionText'), contains('Bollworm · confidence 60%'));
  });

  testWidgets('a status event updates the device status in the device row', (tester) async {
    final app = farmer();
    await startApp(tester, app);
    Finder status(String text) => find.descendant(of: find.byKey(const Key('deviceStatus')), matching: find.text(text));
    expect(status('Online'), findsOneWidget);

    app.live.ingest(kind: 'status', deviceId: device, ts: '2026-10-01T14:00:00Z', receivedAt: '2026-10-01T15:02:00Z', data: {'state': 'offline'});
    await tester.pumpAndSettle();
    expect(status('Offline'), findsOneWidget);
    // the device being offline is not a problem of the live connection, and the readings stay
    expect(textOf(tester, 'liveStatus'), 'Live updates on');
    expect(textOf(tester, 'powerValue'), '91.4%');
    expect(textOf(tester, 'deviceLastSeen'), 'Last heard from: ${formatDateTime(DateTime.utc(2026, 10, 1, 15))}');

    app.live.ingest(kind: 'status', deviceId: device, ts: '2026-10-01T15:03:00Z', receivedAt: '2026-10-01T15:03:01Z', data: {'state': 'online'});
    await tester.pumpAndSettle();
    expect(status('Online'), findsOneWidget);
  });

  testWidgets('unknown and malformed messages leave the page as it is', (tester) async {
    final app = farmer();
    await startApp(tester, app);
    app.live.pushRaw('not json at all');
    app.live.pushRaw('{"type":"event","cursor":"x"}');
    app.live.pushRaw('{"type":"firmware_notice","text":"hello"}');
    app.live.ingest(kind: 'event/unknown', deviceId: device, ts: '2026-10-01T15:01:00Z', data: {'batteryPct': 1});
    app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:01:00Z', data: {'batteryPct': 'full'});
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(Dashboard), findsOneWidget);
    expect(textOf(tester, 'bollValue'), '1,287');
    expect(textOf(tester, 'powerValue'), '91.4%');
    expect(find.textContaining('full'), findsNothing);
    expect(find.byKey(const Key('dashboardError')), findsNothing);
    expect(textOf(tester, 'liveStatus'), 'Live updates on');
  });

  testWidgets('disconnect: the last values stay, a connection notice appears, nothing looks like a sensor failure', (tester) async {
    final app = farmer();
    await startApp(tester, app);
    // (airTempC included since Phase 4 shows it: every card has a reading before the disconnect)
    app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:00:05Z', data: {'batteryPct': 90, 'moistureRhPct': 50, 'airTempC': 30, 'bollsHarvestedTotal': 1290, 'solarActive': true});
    app.live.ingest(kind: 'event/pest', deviceId: device, ts: '2026-10-01T15:01:00Z', data: {'label': 'bollworm', 'confidence': 0.6});
    await tester.pumpAndSettle();

    app.live.outage = LiveOutage.offline;
    app.live.dropAll(code: 1011);
    await tester.pumpAndSettle();

    expect(textOf(tester, 'liveStatus'), 'Live updates interrupted - reconnecting. Showing the last values received.');
    expect(textOf(tester, 'bollValue'), '1,290');
    expect(textOf(tester, 'moistureValue'), '50%');
    expect(textOf(tester, 'powerValue'), '90%');
    expect(textOf(tester, 'powerCaption'), 'Solar Active');
    expect(textOf(tester, 'airTempValue'), '30 °C');
    expect(find.byKey(const Key('detectionBanner')), findsOneWidget);
    // the device row still says what the device last reported
    expect(find.descendant(of: find.byKey(const Key('deviceStatus')), matching: find.text('Online')), findsOneWidget);
    expect(find.text('No reading'), findsNothing);
    expect(find.text('—'), findsNothing);
    expect(find.byKey(const Key('dashboardError')), findsNothing);
    expect(find.byKey(const Key('dashboardRefreshError')), findsNothing);
    expect(find.byKey(const Key('dashboardLoading')), findsNothing);
    expectNoUnsupportedWording();

    // minutes later: still the same values; then the connection comes back
    await tester.pump(const Duration(minutes: 3));
    expect(textOf(tester, 'bollValue'), '1,290');
    app.live.outage = LiveOutage.none;
    app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:05:00Z', data: {'batteryPct': 88, 'bollsHarvestedTotal': 1301});
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(textOf(tester, 'liveStatus'), 'Live updates on');
    expect(textOf(tester, 'bollValue'), '1,301', reason: 'the event missed while disconnected was replayed');
    expect(app.live.openSockets, hasLength(1));
  });

  testWidgets('leaving the dashboard closes the socket and cancels a pending reconnection', (tester) async {
    final app = farmer();
    await startApp(tester, app);
    final socket = app.live.sockets.single;
    expect(socket.isOpen, isTrue);

    // "Logs" replaces the dashboard with the Harvest page: the Dashboard widget is disposed.
    await tester.ensureVisible(find.text('Logs').first);
    await tester.tap(find.text('Logs').first);
    await tester.pumpAndSettle();
    expect(find.byType(Harvest), findsOneWidget);
    expect(find.byType(Dashboard), findsNothing);
    expect(socket.closedByClient, isTrue);
    expect(app.live.openSockets, isEmpty);
    expect(app.services.live.state, LiveState.disconnected);
    await tester.pump(const Duration(hours: 1));
    expect(app.live.attempts, hasLength(1));
  });

  testWidgets('disposing the dashboard while a retry is pending cancels the timer', (tester) async {
    final app = farmer();
    await startApp(tester, app);
    app.live.outage = LiveOutage.offline;
    app.live.dropAll(code: 1011);
    await tester.pump(const Duration(seconds: 5));
    expect(app.services.live.state, LiveState.reconnecting);
    final attempts = app.live.attempts.length;

    await tester.ensureVisible(find.text('Logs').first);
    await tester.tap(find.text('Logs').first);
    await tester.pumpAndSettle();
    expect(find.byType(Dashboard), findsNothing);
    app.live.outage = LiveOutage.none;
    await tester.pump(const Duration(hours: 1));
    expect(app.live.attempts.length, attempts, reason: 'no attempt after the page was disposed');
    expect(app.live.openSockets, isEmpty);
    // (the test framework additionally fails any test that ends with a pending timer)
  });

  testWidgets('logout from Settings closes the socket; nothing reconnects', (tester) async {
    final app = farmer();
    await startApp(tester, app);
    final socket = app.live.sockets.single;
    await tester.tap(find.byIcon(Icons.person)); // Settings on top of the dashboard
    await tester.pumpAndSettle();
    expect(socket.isOpen, isTrue);
    await tester.scrollUntilVisible(find.widgetWithText(ElevatedButton, 'Log Out'), 300);
    await tester.tap(find.widgetWithText(ElevatedButton, 'Log Out'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Log Out'));
    await tester.pumpAndSettle();

    expect(find.byType(SignInPage), findsOneWidget);
    expect(socket.closedByClient, isTrue);
    expect(app.live.openSockets, isEmpty);
    expect(app.services.dashboard.data, isNull);
    await tester.pump(const Duration(hours: 1));
    expect(app.live.attempts, hasLength(1));
  });

  testWidgets('switching device: old connection closed, new snapshot, new connection for the new device', (tester) async {
    final app = farmer(devices: [device, otherDevice]);
    app.backend.telemetry[otherDevice] = [FakeBackend.telemetryRow(time: '2026-10-01T14:00:00Z', batteryPct: 22, msgId: '01K6CQ4W0D8V9J4Q9W2Y000050')];
    await startApp(tester, app);
    final first = app.live.sockets.single;
    expect(textOf(tester, 'powerValue'), '91.4%');

    await tester.tap(find.byKey(const Key('deviceSelector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(otherDevice).last);
    await tester.pumpAndSettle();

    expect(first.closedByClient, isTrue);
    expect(app.live.sockets, hasLength(2));
    expect(app.live.openSockets, hasLength(1));
    expect(app.live.sockets.last.received, [{'op': 'start'}]);
    expect(textOf(tester, 'powerValue'), '22%');
    expect(textOf(tester, 'liveStatus'), 'Live updates on');

    // live events of the first device no longer reach the page; the new device's do
    app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T16:00:00Z', data: {'batteryPct': 99, 'bollsHarvestedTotal': 5000});
    await tester.pumpAndSettle();
    expect(textOf(tester, 'powerValue'), '22%');
    expect(textOf(tester, 'bollValue'), '—');
    app.live.ingest(kind: 'telemetry', deviceId: otherDevice, ts: '2026-10-01T16:00:01Z', data: {'batteryPct': 21, 'bollsHarvestedTotal': 7});
    await tester.pumpAndSettle();
    expect(textOf(tester, 'powerValue'), '21%');
    expect(textOf(tester, 'bollValue'), '7');
  });

  testWidgets('session revoked on the live channel: back to sign-in through the Phase 3A mechanism', (tester) async {
    final app = farmer();
    await startApp(tester, app);
    expect(find.byType(Dashboard), findsOneWidget);

    app.backend
      ..expireAccessToken()
      ..sessionRevoked = true;
    app.live.revokeSessions();
    await tester.pumpAndSettle();

    expect(find.byType(SignInPage), findsOneWidget);
    expect(find.textContaining('session has ended'), findsOneWidget);
    expect(app.tokens.session, isNull);
    expect(app.services.dashboard.data, isNull);
    expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
    expect(app.live.openSockets, isEmpty);
    final attempts = app.live.attempts.length;
    await tester.pump(const Duration(hours: 1));
    expect(app.live.attempts.length, attempts);
    expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
  });

  testWidgets('access token expiry on the live channel: the user stays on the dashboard, live updates continue', (tester) async {
    final app = farmer();
    await startApp(tester, app);
    app.backend.expireAccessToken();
    app.live.expireTokens();
    await tester.pumpAndSettle();
    expect(find.byType(Dashboard), findsOneWidget);
    expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
    expect(textOf(tester, 'liveStatus'), 'Live updates on');
    app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:20:00Z', data: {'batteryPct': 85});
    await tester.pumpAndSettle();
    expect(textOf(tester, 'powerValue'), '85%');
  });

  testWidgets('live updates that cannot be authenticated are switched off without touching the values', (tester) async {
    final app = farmer();
    await startApp(tester, app);
    app.live.refuseUpgrades = true;
    app.live.expireTokens();
    await tester.pumpAndSettle();
    expect(find.byType(Dashboard), findsOneWidget);
    expect(textOf(tester, 'liveStatus'), 'Live updates are off. Refresh to update.');
    expect(textOf(tester, 'powerValue'), '91.4%');
    expect(find.byKey(const Key('dashboardError')), findsNothing);
  });

  testWidgets('no token is ever displayed', (tester) async {
    final app = farmer();
    await startApp(tester, app);
    final shown = <String>[];
    void collect() => shown.addAll(tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? t.textSpan?.toPlainText() ?? ''));
    collect();
    final first = app.tokens.session!;
    app.backend.expireAccessToken();
    app.live.expireTokens();
    await tester.pumpAndSettle();
    collect();
    app.live.outage = LiveOutage.offline;
    app.live.dropAll(code: 1011);
    await tester.pumpAndSettle();
    collect();
    final second = app.tokens.session!;
    final all = shown.join('\n');
    for (final secret in [first.accessToken, first.refreshToken, second.accessToken, second.refreshToken, 'Bearer']) {
      expect(all, isNot(contains(secret)));
    }
  });
}
