// Phase 5A: time-based freshness on top of the Phase 4 status-based rule.
//
//   a reading is "last known" when the backend has received no telemetry for the device's
//   telemetryStaleAfterS (180 s in the contract), counted from the backend's receipt time
//   (receivedAt) against the server's clock (serverTime of the live channel).
//
// The phone's clock here is the test's fake clock; the server's clock is that clock plus a
// chosen error, so every test also shows that the phone's clock does not matter.
//
// testWidgets is used for its controllable clock; no widget is involved. The page is covered by
// test/ui/dashboard_phase5a_test.dart.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/dashboard/dashboard_controller.dart';
import 'package:smart_gossy_culture_app/core/formatting.dart';
import 'package:smart_gossy_culture_app/core/models.dart';
import 'package:smart_gossy_culture_app/core/realtime/live_connection.dart';
import 'package:smart_gossy_culture_app/core/realtime/live_messages.dart';

import '../support/fake_backend.dart';
import '../support/fake_live.dart';

const device = 'unit-a';
const otherDevice = 'unit-b';

final List<TestApp> _apps = [];

void liveTest(String description, Future<void> Function(WidgetTester tester) body) {
  testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      for (final app in _apps) {
        app.services.dashboard.detachLive();
      }
      _apps.clear();
      await tester.pump(Duration.zero);
    }
  });
}

/// The phone's clock: the test clock, which advances with `tester.pump(duration)`.
DateTime phoneNow() => TestWidgetsFlutterBinding.instance.clock.now();

/// A farmer's app talking to a backend whose clock differs from the phone's by [serverAhead].
class Scene {
  Scene({this.serverAhead = const Duration(hours: 2, minutes: 13), int? staleAfterS = 180, List<String> devices = const [device], String? state = 'online'}) {
    app = TestApp(clock: phoneNow, random: FixedRandom(1.0))..signIn();
    _apps.add(app);
    app.live.clock = serverNow;
    app.backend.farms.add({'id': 'farm-1', 'name': 'North field', 'createdAt': '2026-10-01T00:00:00Z'});
    for (final (index, id) in devices.indexed) {
      // (the status is dated on the server's clock, a minute ago: the test clock is not "today")
      app.backend.devices.add(FakeBackend.device(id, state: state, lastSeenAt: state == null ? null : serverTimeAgo(const Duration(minutes: 1)), claimedAt: '2026-10-0${9 - index}T00:00:00Z', telemetryIntervalS: staleAfterS == null ? null : 60, telemetryStaleAfterS: staleAfterS));
    }
  }

  final Duration serverAhead;
  late final TestApp app;
  int _serial = 0;

  DashboardController get dashboard => app.services.dashboard;
  DateTime serverNow() => phoneNow().toUtc().add(serverAhead);
  String serverTimeAgo(Duration ago) => serverNow().subtract(ago).toIso8601String();

  /// The newest row the REST API returns: received by the backend [receivedAgo] ago. The
  /// device's own timestamp is [deviceTime] - by default nonsense, to show it is not used.
  void restReading({required Duration receivedAgo, num battery = 66, String deviceTime = '2020-01-01T00:00:00Z', String forDevice = device, bool withReceivedAt = true}) {
    _serial++;
    (app.backend.telemetry[forDevice] ??= []).insert(
      0,
      FakeBackend.telemetryRow(time: deviceTime, batteryPct: battery, bollsHarvestedTotal: 10, msgId: '01K6CQ4W0D8V9J4Q9W2Y9${_serial.toString().padLeft(5, '0')}', receivedAt: withReceivedAt ? serverTimeAgo(receivedAgo) : null),
    );
  }

  /// A live telemetry event received by the backend right now (or [receivedAgo] ago).
  void liveReading({num battery = 70, Duration receivedAgo = Duration.zero, String? deviceTime, String forDevice = device}) {
    _serial++;
    app.live.ingest(kind: 'telemetry', deviceId: forDevice, ts: deviceTime ?? '2030-01-01T00:00:${(_serial % 60).toString().padLeft(2, '0')}Z', receivedAt: serverTimeAgo(receivedAgo), data: {'batteryPct': battery});
  }

  Future<void> open(WidgetTester tester) async {
    dashboard.attachLive();
    await settle(tester, dashboard.load());
    await tester.pump(Duration.zero);
  }
}

Future<T> settle<T>(WidgetTester tester, Future<T> work) async {
  var done = false;
  T? result;
  Object? failure;
  unawaited(work.then((value) {
    result = value;
    done = true;
  }, onError: (Object error) {
    failure = error;
    done = true;
  }));
  for (var i = 0; i < 100 && !done; i++) {
    await tester.pump(Duration.zero);
  }
  expect(done, isTrue, reason: 'the operation did not complete');
  if (failure != null) throw failure!;
  return result as T;
}

void main() {
  group('no telemetry for 180 seconds', () {
    liveTest('before 180 s the reading is live; at 180 s it is last known, without any message arriving', (tester) async {
      final scene = Scene()..restReading(receivedAgo: const Duration(seconds: 10));
      final dashboard = scene.dashboard;
      await scene.open(tester);
      expect(dashboard.liveState, LiveState.connected);
      expect(dashboard.staleAfter, const Duration(seconds: 180), reason: 'the threshold is the backend\'s');
      expect(dashboard.freshness, ReadingFreshness.live);
      final shown = dashboard.data!;
      final restCalls = scene.app.backend.calls.length;
      var notified = 0;
      dashboard.addListener(() => notified++);

      await tester.pump(const Duration(seconds: 169)); // 179 s since the backend received it
      expect(dashboard.freshness, ReadingFreshness.live);
      expect(notified, 0, reason: 'nothing changed, nothing is redrawn');

      await tester.pump(const Duration(seconds: 1)); // 180 s
      expect(dashboard.freshness, ReadingFreshness.noRecentReading);
      expect(notified, 1, reason: 'the page is told once, at that moment');

      // Nothing else changed: same values, the device still online, the app still connected,
      // no request and no new connection.
      expect(identical(dashboard.data, shown), isTrue);
      expect(dashboard.data!.device!.status.state, 'online');
      expect(dashboard.liveState, LiveState.connected);
      expect(dashboard.failure, isNull);
      expect(scene.app.backend.calls.length, restCalls);
      expect(scene.app.live.attempts, hasLength(1));
      // and it stays that way; no timer keeps firing
      await tester.pump(const Duration(hours: 1));
      expect(dashboard.freshness, ReadingFreshness.noRecentReading);
      expect(notified, 1);
    });

    liveTest('a new reading makes it current again, and the 180 s start over', (tester) async {
      final scene = Scene()..restReading(receivedAgo: const Duration(seconds: 10));
      final dashboard = scene.dashboard;
      await scene.open(tester);
      await tester.pump(const Duration(seconds: 200));
      expect(dashboard.freshness, ReadingFreshness.noRecentReading);

      scene.liveReading(battery: 71);
      await tester.pump(Duration.zero);
      expect(dashboard.data!.telemetry!.batteryPct, 71);
      expect(dashboard.freshness, ReadingFreshness.live);
      await tester.pump(const Duration(seconds: 179));
      expect(dashboard.freshness, ReadingFreshness.live);
      await tester.pump(const Duration(seconds: 1));
      expect(dashboard.freshness, ReadingFreshness.noRecentReading);
    });

    liveTest('a device reporting every 60 s stays live the whole time', (tester) async {
      final scene = Scene()..restReading(receivedAgo: const Duration(seconds: 5));
      final dashboard = scene.dashboard;
      await scene.open(tester);
      final seen = <ReadingFreshness?>{};
      dashboard.addListener(() => seen.add(dashboard.freshness));
      for (var minute = 1; minute <= 30; minute++) {
        await tester.pump(const Duration(seconds: 60));
        expect(dashboard.freshness, ReadingFreshness.live, reason: 'minute $minute, before the report');
        scene.liveReading(battery: 70 - minute * 0.1);
        await tester.pump(Duration.zero);
      }
      expect(seen, {ReadingFreshness.live});
      // two reports missed is still current (120 s); the third missed one is the limit
      await tester.pump(const Duration(seconds: 179));
      expect(dashboard.freshness, ReadingFreshness.live);
      await tester.pump(const Duration(seconds: 1));
      expect(dashboard.freshness, ReadingFreshness.noRecentReading);
    });

    liveTest('an online-but-silent device is found out as soon as the dashboard opens', (tester) async {
      final scene = Scene()..restReading(receivedAgo: const Duration(minutes: 10));
      await scene.open(tester);
      final dashboard = scene.dashboard;
      expect(dashboard.data!.device!.status.state, 'online');
      expect(dashboard.liveState, LiveState.connected);
      expect(dashboard.freshness, ReadingFreshness.noRecentReading);
      // refreshing does not help while the backend has nothing newer
      await settle(tester, dashboard.load());
      await tester.pump(Duration.zero);
      expect(dashboard.freshness, ReadingFreshness.noRecentReading);
    });

    liveTest('the threshold is whatever the backend says, per device', (tester) async {
      final scene = Scene(staleAfterS: 90)..restReading(receivedAgo: Duration.zero);
      await scene.open(tester);
      expect(scene.dashboard.staleAfter, const Duration(seconds: 90));
      await tester.pump(const Duration(seconds: 89));
      expect(scene.dashboard.freshness, ReadingFreshness.live);
      await tester.pump(const Duration(seconds: 1));
      expect(scene.dashboard.freshness, ReadingFreshness.noRecentReading);
    });
  });

  group('what the age is measured with', () {
    liveTest('the backend receipt time, not the device timestamp', (tester) async {
      // Device clock years in the future, received just now: current.
      final ahead = Scene()..restReading(receivedAgo: const Duration(seconds: 5), deviceTime: '2031-06-01T00:00:00Z');
      await ahead.open(tester);
      expect(ahead.dashboard.freshness, ReadingFreshness.live);

      // Device clock says "this very second", but the backend received it four minutes ago
      // (an offline replay, or a device clock that runs fast): not current.
      final replay = Scene();
      replay.restReading(receivedAgo: const Duration(minutes: 4), deviceTime: replay.serverNow().toIso8601String());
      await replay.open(tester);
      expect(replay.dashboard.freshness, ReadingFreshness.noRecentReading);

      // The same for live events: a late delivery of an old receipt is not a current reading.
      final late = Scene()..restReading(receivedAgo: const Duration(seconds: 5));
      await late.open(tester);
      late.liveReading(battery: 50, receivedAgo: const Duration(minutes: 5), deviceTime: '2031-06-01T00:00:00Z');
      await tester.pump(Duration.zero);
      expect(late.dashboard.data!.telemetry!.batteryPct, 50, reason: 'newest by device time, as before');
      expect(late.dashboard.freshness, ReadingFreshness.noRecentReading);
    });

    for (final skew in const [Duration.zero, Duration(hours: 5, minutes: 30), Duration(hours: -3), Duration(days: 400), Duration(seconds: -170)]) {
      liveTest('the server\'s clock, not the phone\'s (server ahead of the phone by $skew)', (tester) async {
        final scene = Scene(serverAhead: skew)..restReading(receivedAgo: const Duration(seconds: 30));
        await scene.open(tester);
        expect(scene.app.services.live.serverClockOffset, skew);
        expect(scene.dashboard.freshness, ReadingFreshness.live);
        await tester.pump(const Duration(seconds: 149));
        expect(scene.dashboard.freshness, ReadingFreshness.live, reason: '179 s on the server\'s clock');
        await tester.pump(const Duration(seconds: 1));
        expect(scene.dashboard.freshness, ReadingFreshness.noRecentReading, reason: '180 s on the server\'s clock');
      });
    }

    liveTest('the offset follows the server time of hello and of every heartbeat', (tester) async {
      var ahead = const Duration(minutes: 10);
      final scene = Scene()..restReading(receivedAgo: Duration.zero);
      scene.app.live.clock = () => phoneNow().toUtc().add(ahead);
      await scene.open(tester);
      expect(scene.app.services.live.serverClockOffset, const Duration(minutes: 10));
      ahead = const Duration(minutes: 12); // e.g. the phone's clock was set back two minutes
      await tester.pump(const Duration(seconds: 25)); // next heartbeat
      expect(scene.app.services.live.serverClockOffset, const Duration(minutes: 12));
    });
  });

  group('the Phase 4 status-based rule stays the base', () {
    liveTest('not connected and device offline come first; the time rule applies to an online device on a connected app', (tester) async {
      final scene = Scene()..restReading(receivedAgo: const Duration(seconds: 10));
      final dashboard = scene.dashboard;
      await scene.open(tester);
      await tester.pump(const Duration(seconds: 200));
      expect(dashboard.freshness, ReadingFreshness.noRecentReading);

      // the device goes offline: that is the reason shown
      scene.app.live.ingest(kind: 'status', deviceId: device, ts: '2026-10-01T14:00:00Z', receivedAt: scene.serverTimeAgo(Duration.zero), data: {'state': 'offline'});
      await tester.pump(Duration.zero);
      expect(dashboard.freshness, ReadingFreshness.deviceOffline);
      // online again (a second later) without a reading: silent again
      await tester.pump(const Duration(seconds: 1));
      scene.app.live.ingest(kind: 'status', deviceId: device, ts: '2026-10-01T15:03:00Z', receivedAt: scene.serverTimeAgo(Duration.zero), data: {'state': 'online'});
      await tester.pump(Duration.zero);
      expect(dashboard.freshness, ReadingFreshness.noRecentReading);

      // the app loses the channel: not connected, whatever the age
      scene.liveReading(battery: 60);
      await tester.pump(Duration.zero);
      expect(dashboard.freshness, ReadingFreshness.live);
      scene.app.live.outage = LiveOutage.offline;
      scene.app.live.dropAll(code: 1011);
      await tester.pump(Duration.zero);
      expect(dashboard.freshness, ReadingFreshness.notConnected);
      // reconnected after four minutes with nothing new: connected, online, but no recent reading
      await tester.pump(const Duration(minutes: 4));
      scene.app.live.outage = LiveOutage.none;
      await tester.pump(const Duration(seconds: 30));
      expect(dashboard.liveState, LiveState.connected);
      expect(dashboard.freshness, ReadingFreshness.noRecentReading);
    });

    liveTest('a device that never reported its state, and a device without readings, are unchanged', (tester) async {
      final unknown = Scene(state: null)..restReading(receivedAgo: const Duration(minutes: 10));
      await unknown.open(tester);
      expect(unknown.dashboard.freshness, ReadingFreshness.deviceStatusUnknown);

      final empty = Scene();
      await empty.open(tester);
      expect(empty.dashboard.freshness, isNull);
      await tester.pump(const Duration(hours: 1));
      expect(empty.dashboard.freshness, isNull);
    });

    liveTest('a backend that sends no threshold or no receipt time: the status-based rule alone', (tester) async {
      final noThreshold = Scene(staleAfterS: null)..restReading(receivedAgo: const Duration(days: 30));
      await noThreshold.open(tester);
      expect(noThreshold.dashboard.staleAfter, isNull);
      expect(noThreshold.dashboard.freshness, ReadingFreshness.live);

      final noReceipt = Scene()..restReading(receivedAgo: Duration.zero, withReceivedAt: false);
      await noReceipt.open(tester);
      expect(noReceipt.dashboard.data!.telemetry!.receivedAt, isNull);
      expect(noReceipt.dashboard.freshness, ReadingFreshness.live);
      await tester.pump(const Duration(hours: 1));
      expect(noReceipt.dashboard.freshness, ReadingFreshness.live);
    });
  });

  group('lifecycle', () {
    liveTest('background cancels the re-evaluation; on return the freshness is judged again', (tester) async {
      final scene = Scene()..restReading(receivedAgo: const Duration(seconds: 10));
      final dashboard = scene.dashboard;
      await scene.open(tester);
      expect(dashboard.freshness, ReadingFreshness.live);

      dashboard.pauseLive();
      expect(dashboard.freshness, ReadingFreshness.notConnected);
      var notified = 0;
      dashboard.addListener(() => notified++);
      await tester.pump(const Duration(hours: 2));
      expect(notified, 0, reason: 'no timer fires in the background');

      // back, and the device has been silent all the time
      await settle(tester, dashboard.resumeLive());
      await tester.pump(Duration.zero);
      expect(dashboard.liveState, LiveState.connected);
      expect(dashboard.freshness, ReadingFreshness.noRecentReading);

      // back again after another pause, and this time the device has been reporting
      dashboard.pauseLive();
      await tester.pump(const Duration(minutes: 5));
      scene.restReading(receivedAgo: const Duration(seconds: 20), battery: 55);
      await settle(tester, dashboard.resumeLive());
      await tester.pump(Duration.zero);
      expect(dashboard.data!.telemetry!.batteryPct, 55);
      expect(dashboard.freshness, ReadingFreshness.live);
      await tester.pump(const Duration(seconds: 159));
      expect(dashboard.freshness, ReadingFreshness.live);
      await tester.pump(const Duration(seconds: 1));
      expect(dashboard.freshness, ReadingFreshness.noRecentReading);
    });

    liveTest('closing the page, logging out and switching device leave no timer behind', (tester) async {
      // page closed while a reading is live (a timer is pending): nothing fires afterwards
      final closed = Scene()..restReading(receivedAgo: Duration.zero);
      await closed.open(tester);
      var notified = 0;
      closed.dashboard.addListener(() => notified++);
      closed.dashboard.detachLive();
      await tester.pump(const Duration(hours: 1));
      expect(notified, 0);

      // logout
      final signedOut = Scene()..restReading(receivedAgo: Duration.zero);
      await settle(tester, signedOut.app.services.session.restore());
      await signedOut.open(tester);
      await settle(tester, signedOut.app.services.session.logout());
      notified = 0;
      signedOut.dashboard.addListener(() => notified++);
      await tester.pump(const Duration(hours: 1));
      expect(notified, 0);
      expect(signedOut.dashboard.freshness, isNull);

      // device switch (unchanged from Phase 4): the new device is judged by its own reading
      final switched = Scene(devices: [device, otherDevice]);
      switched.restReading(receivedAgo: const Duration(minutes: 10));
      switched.restReading(receivedAgo: const Duration(seconds: 15), forDevice: otherDevice, battery: 22);
      await switched.open(tester);
      expect(switched.dashboard.freshness, ReadingFreshness.noRecentReading);
      final first = switched.app.live.sockets.single;
      await settle(tester, switched.dashboard.selectDevice(otherDevice));
      await tester.pump(Duration.zero);
      expect(first.closedByClient, isTrue);
      expect(switched.app.live.openSockets, hasLength(1));
      expect(switched.dashboard.data!.telemetry!.batteryPct, 22);
      expect(switched.dashboard.freshness, ReadingFreshness.live);
      await tester.pump(const Duration(seconds: 165));
      expect(switched.dashboard.freshness, ReadingFreshness.noRecentReading);
      // (the test framework additionally fails any test that ends with a pending timer)
    });
  });

  group('parsing', () {
    test('device: interval and threshold are optional whole seconds', () {
      final json = FakeBackend.device('bb-000123', state: 'online', telemetryIntervalS: 60, telemetryStaleAfterS: 180);
      final parsed = Device.fromJson(Map<String, dynamic>.from(json));
      expect(parsed.telemetryInterval, const Duration(seconds: 60));
      expect(parsed.telemetryStaleAfter, const Duration(seconds: 180));
      final old = Device.fromJson(Map<String, dynamic>.from(FakeBackend.device('bb-000123')));
      expect(old.telemetryInterval, isNull);
      expect(old.telemetryStaleAfter, isNull);
      for (final bad in [0, -5, '180', 180.5]) {
        expect(() => Device.fromJson({...json, 'telemetryStaleAfterS': bad}), throwsFormatException, reason: '$bad');
      }
    });

    test('telemetry: receivedAt from REST and from the live event', () {
      final row = TelemetryPoint.fromJson(Map<String, dynamic>.from(FakeBackend.telemetryRow(time: '2026-10-02T16:54:42.556Z', batteryPct: 50, receivedAt: '2026-10-02T16:54:42.557827Z')));
      expect(row.receivedAt, DateTime.utc(2026, 10, 2, 16, 54, 42, 557, 827));
      expect(row.time, DateTime.utc(2026, 10, 2, 16, 54, 42, 556));
      expect(TelemetryPoint.fromJson(Map<String, dynamic>.from(FakeBackend.telemetryRow(time: '2026-10-02T16:54:42Z', batteryPct: 50))).receivedAt, isNull);
      expect(() => TelemetryPoint.fromJson({...FakeBackend.telemetryRow(time: '2026-10-02T16:54:42Z', batteryPct: 50), 'receivedAt': 'yesterday'}), throwsFormatException);

      final event = LiveMessage.parse('{"type":"event","cursor":5,"kind":"telemetry","deviceId":"bb-000123","msgId":"01K6CQ4W0D8V9J4Q9W2Y1S7ZPX","ts":"2020-01-01T00:00:00+00:00","receivedAt":"2026-10-02T16:54:42.557827+00:00","data":{"batteryPct":50},"alerts":[]}') as LiveEvent;
      expect(event.toTelemetry().receivedAt, DateTime.utc(2026, 10, 2, 16, 54, 42, 557, 827));
      expect(event.toTelemetry().time, DateTime.utc(2020));
    });

    test('server time: read from hello, heartbeat and pong; unreadable is "not known", never an error', () {
      final hello = LiveMessage.parse('{"type":"hello","protocol":"gossy.ws.v1","serverTime":"2026-10-02T16:54:42.100000+00:00","latestCursor":1,"tokenExpiresAt":"x","heartbeatIntervalS":25,"allowedOps":[]}') as LiveHello;
      expect(hello.serverTime, DateTime.utc(2026, 10, 2, 16, 54, 42, 100));
      expect((LiveMessage.parse('{"type":"heartbeat","serverTime":"2026-10-02T22:24:42+05:30","cursor":1}') as LiveHeartbeat).serverTime, DateTime.utc(2026, 10, 2, 16, 54, 42));
      expect((LiveMessage.parse('{"type":"pong","serverTime":"2026-10-02T16:54:42Z"}') as LivePong).serverTime, DateTime.utc(2026, 10, 2, 16, 54, 42));
      expect((LiveMessage.parse('{"type":"heartbeat","serverTime":"x","cursor":1}') as LiveHeartbeat).serverTime, isNull);
      expect((LiveMessage.parse('{"type":"heartbeat","cursor":1}') as LiveHeartbeat).serverTime, isNull);
      expect((LiveMessage.parse('{"type":"heartbeat","serverTime":7,"cursor":1}') as LiveHeartbeat).serverTime, isNull);
    });

    test('a duration in words', () {
      expect(formatDurationWords(const Duration(seconds: 180)), '3 minutes');
      expect(formatDurationWords(const Duration(seconds: 60)), '1 minute');
      expect(formatDurationWords(const Duration(seconds: 90)), '90 seconds');
      expect(formatDurationWords(const Duration(seconds: 1)), '1 second');
    });
  });
}
