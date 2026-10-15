// Phase 5A: the Dashboard page and time-based freshness - the real app (launch page included)
// with the fake REST backend and the fake live channel. The backend of these tests sends what
// the Phase 5A backend sends: receivedAt with every reading, and the 60 s / 180 s values with
// every device. Its clock differs from the phone's on purpose.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/realtime/live_connection.dart';
import 'package:smart_gossy_culture_app/ui/dashboard.dart';
import 'package:smart_gossy_culture_app/ui/settings_profile_page.dart';

import '../support/app_harness.dart';
import '../support/fake_backend.dart';
import '../support/fake_live.dart';

const device = 'unit-a';
const serverAhead = Duration(hours: 3, minutes: 7);

const liveText = 'Live - newest reading from the device';
const silentText = 'Last known reading - no reading received for over 3 minutes';
const notConnectedText = 'Last known reading - live updates are not connected';
const offlineText = 'Last known reading - the device is offline';

String textOf(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key(key))).data!;
Color colorOf(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key(key))).style!.color!;

DateTime phoneNow() => TestWidgetsFlutterBinding.instance.clock.now();
DateTime serverNow() => phoneNow().toUtc().add(serverAhead);

int _serial = 0;
String _two(int n) => n.toString().padLeft(2, '0');

TestApp farmer({Duration receivedAgo = Duration.zero, num battery = 91.4}) {
  final app = TestApp(clock: phoneNow, random: FixedRandom(1.0))..signIn();
  app.live.clock = serverNow;
  app.backend.farms.add({'id': 'farm-1', 'name': 'North field', 'createdAt': '2026-10-01T00:00:00Z'});
  // (the status is dated on the server's clock, a minute ago: the test clock is not "today")
  app.backend.devices.add(FakeBackend.device(device, displayName: 'Field unit', state: 'online', lastSeenAt: serverNow().subtract(const Duration(minutes: 1)).toIso8601String(), telemetryIntervalS: 60, telemetryStaleAfterS: 180));
  rest(app, receivedAgo: receivedAgo, battery: battery);
  return app;
}

/// The newest row the REST API returns from now on.
void rest(TestApp app, {required Duration receivedAgo, required num battery}) {
  _serial++;
  (app.backend.telemetry[device] ??= []).insert(
    0,
    FakeBackend.telemetryRow(time: '2026-10-01T15:${_two(_serial ~/ 60)}:${_two(_serial % 60)}Z', batteryPct: battery, moistureRhPct: 54.3, airTempC: 31.5, bollsHarvestedTotal: 1287, solarActive: true,
        msgId: '01K6CQ4W0D8V9J4Q9W2Y8${_serial.toString().padLeft(5, '0')}', receivedAt: serverNow().subtract(receivedAgo).toIso8601String()),
  );
}

/// A reading the backend receives now and sends over the live channel.
void live(TestApp app, {required num battery}) {
  _serial++;
  app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-02T10:${_two(_serial ~/ 60)}:${_two(_serial % 60)}Z', receivedAt: serverNow().toIso8601String(), data: {'batteryPct': battery, 'airTempC': 30});
}

/// Lets time pass until the backend received the shown reading [age] ago.
Future<void> untilAge(WidgetTester tester, TestApp app, Duration age) async {
  final receivedAt = app.services.dashboard.data!.telemetry!.receivedAt!;
  final wait = age - serverNow().difference(receivedAt);
  expect(wait.isNegative, isFalse, reason: 'already older than $age');
  await tester.pump(wait);
  await tester.pump();
}

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
  testWidgets('live until 180 s without a reading, then "Last known"; live again with the next reading', (tester) async {
    final app = farmer();
    await startApp(tester, app);
    expect(textOf(tester, 'liveStatus'), 'Live updates on');
    expect(textOf(tester, 'readingFreshness'), liveText);
    expect(colorOf(tester, 'powerValue'), Colors.black87);

    await untilAge(tester, app, const Duration(seconds: 179));
    expect(textOf(tester, 'readingFreshness'), liveText, reason: '179 s: still current');

    await untilAge(tester, app, const Duration(seconds: 180));
    expect(textOf(tester, 'readingFreshness'), silentText);
    // shown as last known: grey values, the same numbers, the reading's own time still there
    for (final key in ['bollValue', 'moistureValue', 'powerValue', 'airTempValue']) {
      expect(colorOf(tester, key), Colors.black45, reason: key);
    }
    expect(textOf(tester, 'powerValue'), '91.4%');
    expect(find.byKey(const Key('telemetryTime')), findsOneWidget);
    // it is neither a device-offline nor a connection problem, and not an error
    expect(find.descendant(of: find.byKey(const Key('deviceStatus')), matching: find.text('Online')), findsOneWidget);
    expect(textOf(tester, 'liveStatus'), 'Live updates on');
    expect(find.byKey(const Key('dashboardError')), findsNothing);
    expect(find.byKey(const Key('dashboardRefreshError')), findsNothing);
    expect(find.text('No reading'), findsNothing);
    expect(app.live.openSockets, hasLength(1));

    live(app, battery: 80);
    await tester.pumpAndSettle();
    expect(textOf(tester, 'powerValue'), '80%');
    expect(textOf(tester, 'readingFreshness'), liveText);
    expect(colorOf(tester, 'powerValue'), Colors.black87);
  });

  testWidgets('an online-but-silent device is shown as such when the dashboard opens', (tester) async {
    final app = farmer(receivedAgo: const Duration(minutes: 12));
    await startApp(tester, app);
    expect(find.descendant(of: find.byKey(const Key('deviceStatus')), matching: find.text('Online')), findsOneWidget);
    expect(textOf(tester, 'liveStatus'), 'Live updates on');
    expect(textOf(tester, 'readingFreshness'), silentText);
    expect(colorOf(tester, 'powerValue'), Colors.black45);
    // a refresh by the user changes nothing while the backend has nothing newer
    await tester.tap(find.byKey(const Key('dashboardRefresh')));
    await tester.pumpAndSettle();
    expect(textOf(tester, 'readingFreshness'), silentText);
  });

  testWidgets('device offline and lost connection keep their own wording (Phase 4 rule first)', (tester) async {
    final app = farmer();
    await startApp(tester, app);
    await untilAge(tester, app, const Duration(seconds: 200));
    expect(textOf(tester, 'readingFreshness'), silentText);

    app.live.ingest(kind: 'status', deviceId: device, ts: '2026-10-01T14:00:00Z', receivedAt: serverNow().toIso8601String(), data: {'state': 'offline'});
    await tester.pumpAndSettle();
    expect(textOf(tester, 'readingFreshness'), offlineText);
    expect(find.descendant(of: find.byKey(const Key('deviceStatus')), matching: find.text('Offline')), findsOneWidget);

    app.live.outage = LiveOutage.offline;
    app.live.dropAll(code: 1011);
    await tester.pumpAndSettle();
    expect(textOf(tester, 'readingFreshness'), notConnectedText);
    expect(textOf(tester, 'liveStatus'), 'Live updates interrupted - reconnecting. Showing the last values received.');
  });

  testWidgets('a device reporting every 60 s stays "Live" on the page for ten minutes', (tester) async {
    final app = farmer();
    await startApp(tester, app);
    for (var minute = 1; minute <= 10; minute++) {
      await tester.pump(const Duration(seconds: 60));
      await tester.pump();
      expect(textOf(tester, 'readingFreshness'), liveText, reason: 'minute $minute');
      live(app, battery: 90 - minute);
      await tester.pumpAndSettle();
      expect(textOf(tester, 'powerValue'), '${90 - minute}%');
    }
    expect(app.live.attempts, hasLength(1));
  });

  testWidgets('background and foreground: judged again on return; Phase 4 behaviour unchanged', (tester) async {
    final app = farmer();
    await startApp(tester, app);
    final socket = app.live.sockets.single;
    expect(textOf(tester, 'readingFreshness'), liveText);

    await toBackground(tester);
    expect(socket.closedByClient, isTrue);
    expect(app.live.openSockets, isEmpty);
    final restCalls = app.backend.calls.length;
    await tester.pump(const Duration(hours: 1));
    expect(app.backend.calls.length, restCalls, reason: 'no request, and no timer, in the background');
    expect(app.live.attempts, hasLength(1));

    // return: the device stopped reporting an hour ago
    await toForeground(tester);
    expect(textOf(tester, 'liveStatus'), 'Live updates on');
    expect(textOf(tester, 'readingFreshness'), silentText);
    expect(app.live.attempts, hasLength(2));
    expect(app.live.sockets.last.received, [{'op': 'start'}]);

    // background again; this time the device kept reporting
    await toBackground(tester);
    await tester.pump(const Duration(minutes: 10));
    rest(app, receivedAgo: const Duration(seconds: 20), battery: 70);
    await toForeground(tester);
    expect(textOf(tester, 'powerValue'), '70%');
    expect(textOf(tester, 'readingFreshness'), liveText);
    await untilAge(tester, app, const Duration(seconds: 180));
    expect(textOf(tester, 'readingFreshness'), silentText);
  });

  testWidgets('navigation lifecycle: back from Settings keeps the connection and the freshness', (tester) async {
    final app = farmer();
    await startApp(tester, app);
    await tester.tap(find.byIcon(Icons.person));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsProfilePage), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(find.byType(Dashboard), findsOneWidget);
    expect(app.live.openSockets, hasLength(1));
    expect(app.live.attempts, hasLength(1), reason: 'the same connection');
    expect(textOf(tester, 'liveStatus'), 'Live updates on');
    expect(textOf(tester, 'readingFreshness'), liveText);
    // the new page re-evaluates the freshness by itself
    await untilAge(tester, app, const Duration(seconds: 180));
    expect(textOf(tester, 'readingFreshness'), silentText);
    live(app, battery: 77);
    await tester.pumpAndSettle();
    expect(textOf(tester, 'readingFreshness'), liveText);
    expect(textOf(tester, 'powerValue'), '77%');

    // leaving the dashboard closes the socket and leaves no timer behind
    await tester.ensureVisible(find.text('Logs').first);
    await tester.tap(find.text('Logs').first);
    await tester.pumpAndSettle();
    expect(find.byType(Dashboard), findsNothing);
    expect(app.live.openSockets, isEmpty);
    expect(app.services.live.state, LiveState.disconnected);
    await tester.pump(const Duration(hours: 1));
    // (the test framework additionally fails any test that ends with a pending timer)
  });

  testWidgets('the wording uses the backend\'s threshold', (tester) async {
    final app = farmer();
    app.backend.devices
      ..clear()
      ..add(FakeBackend.device(device, state: 'online', lastSeenAt: '2026-10-01T15:00:00Z', telemetryIntervalS: 30, telemetryStaleAfterS: 90));
    await startApp(tester, app);
    await untilAge(tester, app, const Duration(seconds: 90));
    expect(textOf(tester, 'readingFreshness'), 'Last known reading - no reading received for over 90 seconds');
  });
}
