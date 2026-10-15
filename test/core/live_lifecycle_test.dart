// Phase 4: when the dashboard controller keeps, closes and reopens the live connection (app in
// the background / foreground, several dashboard pages, live updates refused by the backend) and
// how it judges whether the reading shown is the current one. The connection itself
// (lib/core/realtime) is unchanged and covered by live_connection_test.dart.
//
// testWidgets is used for its controllable clock; no widget is involved here. The page is
// covered by test/ui/dashboard_phase4_test.dart.

import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/api/api_failure.dart';
import 'package:smart_gossy_culture_app/core/auth/session_controller.dart';
import 'package:smart_gossy_culture_app/core/dashboard/dashboard_controller.dart';
import 'package:smart_gossy_culture_app/core/realtime/live_connection.dart';

import '../support/fake_backend.dart';
import '../support/fake_live.dart';

const device = 'unit-a';
const otherDevice = 'unit-b';
const snapshotPaths = ['/api/v1/devices', '/api/v1/devices/$device/telemetry', '/api/v1/detections'];

final List<TestApp> _apps = [];

/// Ends the way the app does when its dashboard pages are gone: every page detaches. A timer
/// that survived would fail the test ("Timer is still pending").
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

TestApp appWithDevice({Random? random, List<String> devices = const [device], String? state = 'online'}) {
  final app = TestApp(random: random ?? FixedRandom(1.0))..signIn();
  _apps.add(app);
  app.backend.farms.add({'id': 'farm-1', 'name': 'North field', 'createdAt': '2026-10-01T00:00:00Z'});
  for (final (index, id) in devices.indexed) {
    app.backend.devices.add(FakeBackend.device(id, state: state, lastSeenAt: state == null ? null : '2026-10-01T15:00:00Z', claimedAt: '2026-10-0${9 - index}T00:00:00Z'));
  }
  app.backend.telemetry[device] = [FakeBackend.telemetryRow(time: '2026-10-01T15:00:00Z', batteryPct: 66, moistureRhPct: 40, bollsHarvestedTotal: 10, solarActive: true, msgId: '01K6CQ4W0D8V9J4Q9W2Y000001')];
  return app;
}

/// Runs [work] to completion; only what is due now runs, no time passes.
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

/// What the Dashboard page does when it opens: ask for live updates, then load.
Future<void> openDashboard(WidgetTester tester, TestApp app) async {
  app.services.dashboard.attachLive();
  await settle(tester, app.services.dashboard.load());
  await tester.pump(Duration.zero);
}

Future<void> toForeground(WidgetTester tester, TestApp app) async {
  await settle(tester, app.services.dashboard.resumeLive());
  await tester.pump(Duration.zero);
}

void main() {
  group('app in the background', () {
    liveTest('the socket is closed and nothing is attempted while away; the values stay', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:00:05Z', data: {'batteryPct': 64, 'bollsHarvestedTotal': 11});
      await tester.pump(Duration.zero);
      final shown = dashboard.data!;
      final socket = app.live.sockets.single;
      final restCalls = app.backend.calls.length;

      dashboard.pauseLive();
      expect(socket.closedByClient, isTrue);
      expect(app.live.openSockets, isEmpty);
      expect(dashboard.liveState, LiveState.disconnected);
      expect(identical(dashboard.data, shown), isTrue, reason: 'going to the background erases nothing');
      expect(dashboard.phase, DashboardPhase.ready);
      expect(dashboard.failure, isNull);

      // hours in the background: no connection attempt, no request, no timer firing
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T16:00:00Z', data: {'batteryPct': 50});
      await tester.pump(const Duration(hours: 6));
      expect(app.live.attempts, hasLength(1));
      expect(app.backend.calls.length, restCalls);
      expect(dashboard.data!.telemetry!.batteryPct, 64);
    });

    liveTest('going to the background during a reconnection cancels the pending retry', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      app.live.outage = LiveOutage.offline;
      app.live.dropAll(code: 1011);
      await tester.pump(const Duration(seconds: 4));
      expect(dashboard.liveState, LiveState.reconnecting);
      final attempts = app.live.attempts.length;

      dashboard.pauseLive();
      expect(dashboard.liveState, LiveState.disconnected);
      app.live.outage = LiveOutage.none;
      await tester.pump(const Duration(hours: 1));
      expect(app.live.attempts.length, attempts, reason: 'no attempt in the background');
      expect(app.live.openSockets, isEmpty);
    });

    liveTest('going to the background while a load is in flight: no connection when it completes', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      app.backend.latency = const Duration(seconds: 2);
      dashboard.attachLive();
      unawaited(dashboard.load());
      await tester.pump(const Duration(seconds: 1));
      expect(dashboard.busy, isTrue);

      dashboard.pauseLive();
      await tester.pump(const Duration(seconds: 5));
      expect(dashboard.phase, DashboardPhase.ready);
      expect(dashboard.data!.telemetry!.batteryPct, 66, reason: 'the snapshot itself is kept');
      expect(app.live.attempts, isEmpty);

      // back in the foreground: the usual sequence
      unawaited(dashboard.resumeLive());
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 5));
      expect(dashboard.liveState, LiveState.connected);
      expect(app.live.attempts, hasLength(1));
    });
  });

  group('app back in the foreground', () {
    liveTest('REST snapshot first, then one new connection that starts from now', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      dashboard.pauseLive();
      // what happened while away: readings ingested, the newest of which REST now returns
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:30:00Z', data: {'batteryPct': 55});
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T16:00:00Z', data: {'batteryPct': 50});
      app.backend.telemetry[device]!.insert(0, FakeBackend.telemetryRow(time: '2026-10-01T16:00:00Z', batteryPct: 50, bollsHarvestedTotal: 20, msgId: '01K6CQ4W0D8V9J4Q9W2Y000102'));
      await tester.pump(const Duration(hours: 1));
      final restBefore = app.backend.calls.length;

      // (slow replies, to see the order: the snapshot takes 4 s, and no upgrade is made before it)
      app.backend.latency = const Duration(seconds: 2);
      unawaited(dashboard.resumeLive());
      await tester.pump(const Duration(seconds: 3));
      expect(dashboard.busy, isTrue);
      expect(app.live.attempts, hasLength(1), reason: 'no upgrade before the snapshot has arrived');
      expect(dashboard.liveState, LiveState.disconnected);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 3)); // the background re-read after the fresh start
      app.backend.latency = Duration.zero;
      await tester.pump(Duration.zero);

      expect(dashboard.data!.telemetry!.batteryPct, 50);
      expect(dashboard.data!.telemetry!.bollsHarvestedTotal, 20);
      expect(dashboard.liveState, LiveState.connected);
      expect(dashboard.failure, isNull);
      expect(app.live.attempts, hasLength(2));
      expect(app.live.openSockets, hasLength(1));
      // the snapshot was requested before the upgrade, and the stream starts from now (the
      // events ingested while away are not replayed: the snapshot already contains their result)
      expect(app.backend.calls.skip(restBefore).take(3).map((c) => c.path), snapshotPaths);
      expect(app.live.sockets.last.received, [{'op': 'start'}]);
      // one load, and the one background re-read that follows every fresh start of the stream
      expect(app.backend.calls.length, restBefore + 6);

      // and live events are applied again
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T16:00:05Z', data: {'batteryPct': 49});
      await tester.pump(Duration.zero);
      expect(dashboard.data!.telemetry!.batteryPct, 49);
    });

    liveTest('"resumed" without having been in the background does nothing; pause and resume are idempotent', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      final restCalls = app.backend.calls.length;

      // e.g. a system dialog or the notification shade: inactive -> resumed, never paused
      await toForeground(tester, app);
      await toForeground(tester, app);
      expect(app.backend.calls.length, restCalls);
      expect(app.live.attempts, hasLength(1));
      expect(app.live.openSockets, hasLength(1));

      dashboard.pauseLive();
      dashboard.pauseLive();
      await toForeground(tester, app);
      await toForeground(tester, app);
      expect(app.backend.calls.length, restCalls + 6, reason: 'one reload (and its background re-read), not two');
      expect(app.live.attempts, hasLength(2));
      expect(app.live.openSockets, hasLength(1));
    });

    liveTest('the access token expired while away: one refresh, then snapshot and connection', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      await settle(tester, app.services.session.restore());
      await openDashboard(tester, app);
      final oldToken = app.tokens.session!.accessToken;
      dashboard.pauseLive();
      app.backend.expireAccessToken();
      await tester.pump(const Duration(hours: 2));

      await toForeground(tester, app);

      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
      expect(app.tokens.session!.accessToken, isNot(oldToken));
      expect(app.live.attempts.last.headers['Authorization'], 'Bearer ${app.tokens.session!.accessToken}');
      expect(dashboard.liveState, LiveState.connected);
      expect(dashboard.failure, isNull);
      expect(app.services.session.status, SessionStatus.signedIn);
      expect(app.live.attempts, hasLength(2), reason: 'no upgrade was tried with the expired token');
    });

    liveTest('the session was revoked while away: ended by Phase 3A, no connection is attempted', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      var forcedSignOuts = 0;
      app.services.session.onForcedSignOut = () => forcedSignOuts++;
      await settle(tester, app.services.session.restore());
      await openDashboard(tester, app);
      dashboard.pauseLive();
      app.backend
        ..expireAccessToken()
        ..sessionRevoked = true;
      final attempts = app.live.attempts.length;

      await toForeground(tester, app);

      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
      expect(app.tokens.session, isNull);
      expect(app.services.session.status, SessionStatus.signedOut);
      expect(forcedSignOuts, 1);
      expect(dashboard.data, isNull);
      expect(dashboard.phase, DashboardPhase.idle);
      expect(dashboard.liveState, LiveState.disconnected);
      await tester.pump(const Duration(hours: 1));
      expect(app.live.attempts.length, attempts);
      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1, reason: 'a rejected refresh is never repeated');
    });

    liveTest('no network yet on return: values kept, failure shown; the live channel recovers by itself', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      dashboard.pauseLive();
      app.backend.telemetry[device]!.insert(0, FakeBackend.telemetryRow(time: '2026-10-01T16:00:00Z', batteryPct: 50, msgId: '01K6CQ4W0D8V9J4Q9W2Y000102'));
      app.backend.outage = Outage.offline;
      app.live.outage = LiveOutage.offline;

      await toForeground(tester, app);

      expect(dashboard.failure!.kind, ApiFailureKind.network);
      expect(dashboard.phase, DashboardPhase.ready);
      expect(dashboard.data!.telemetry!.batteryPct, 66, reason: 'the last loaded values stay');
      expect(dashboard.liveState, LiveState.reconnecting);
      expect(dashboard.freshness, ReadingFreshness.notConnected);
      // bounded backoff, as for any lost connection
      await tester.pump(const Duration(minutes: 2));
      expect(app.live.attempts.length, lessThan(12));
      expect(app.live.openSockets, isEmpty);

      // the network is back: connected at the next attempt, state re-read, the notice is gone
      app.backend.outage = Outage.none;
      app.live.outage = LiveOutage.none;
      await tester.pump(const Duration(seconds: 30));
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);
      expect(dashboard.liveState, LiveState.connected);
      expect(dashboard.data!.telemetry!.batteryPct, 50);
      expect(dashboard.failure, isNull);
      expect(dashboard.freshness, ReadingFreshness.live);
      expect(app.live.openSockets, hasLength(1));
    });

    liveTest('a first load that failed makes no connection (no snapshot, no live channel)', (tester) async {
      final app = appWithDevice()..backend.outage = Outage.offline;
      await openDashboard(tester, app);
      expect(app.services.dashboard.phase, DashboardPhase.error);
      app.services.dashboard.pauseLive();
      await toForeground(tester, app);
      expect(app.services.dashboard.phase, DashboardPhase.error);
      expect(app.live.attempts, isEmpty);
    });
  });

  group('several dashboard pages', () {
    liveTest('the connection is kept until the last page has closed', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      final first = Object();
      final second = Object();
      dashboard.attachLive(first);
      await settle(tester, dashboard.load());
      await tester.pump(Duration.zero);
      expect(app.live.openSockets, hasLength(1));

      // a new page opens and loads, then the old one is disposed
      dashboard.attachLive(second);
      await settle(tester, dashboard.load());
      dashboard.detachLive(first);
      await tester.pump(Duration.zero);
      expect(app.live.openSockets, hasLength(1), reason: 'the new page still needs it');
      expect(app.live.attempts, hasLength(1), reason: 'and it is the same connection');
      expect(dashboard.liveState, LiveState.connected);

      dashboard.detachLive(first); // a page that is not attached changes nothing
      expect(app.live.openSockets, hasLength(1));
      dashboard.detachLive(second);
      expect(app.live.openSockets, isEmpty);
      expect(dashboard.liveState, LiveState.disconnected);
      await tester.pump(const Duration(hours: 1));
      expect(app.live.attempts, hasLength(1));
    });

    liveTest('attaching the same page again changes nothing (Phase 3C behaviour)', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      dashboard.attachLive();
      dashboard.attachLive();
      await settle(tester, dashboard.load());
      await tester.pump(Duration.zero);
      expect(app.live.openSockets, hasLength(1));
      dashboard.detachLive();
      expect(app.live.openSockets, isEmpty);
    });
  });

  group('live updates refused by the backend (controlled retry)', () {
    Future<void> refuse(WidgetTester tester, TestApp app) async {
      app.live.refuseUpgrades = true;
      app.live.expireTokens();
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);
      expect(app.services.dashboard.liveState, LiveState.authFailed);
    }

    liveTest('the schedule is 1, 5 and 15 minutes, then it stays off', (tester) async {
      expect(DashboardController.authRetryDelays, const [Duration(minutes: 1), Duration(minutes: 5), Duration(minutes: 15)]);
      final app = appWithDevice();
      await openDashboard(tester, app);
      await refuse(tester, app);
      var attempts = app.live.attempts.length;

      for (final delay in DashboardController.authRetryDelays) {
        await tester.pump(delay - const Duration(seconds: 1));
        expect(app.live.attempts.length, attempts, reason: 'nothing before $delay has passed');
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(Duration.zero);
        expect(app.live.attempts.length, attempts + 2, reason: 'one try after $delay');
        expect(app.services.dashboard.liveState, LiveState.authFailed);
        attempts += 2;
      }
      await tester.pump(const Duration(days: 2));
      expect(app.live.attempts.length, attempts, reason: 'no fourth try');
      // the REST session was never touched by any of this
      expect(app.services.session.status, isNot(SessionStatus.signedOut));
      expect(app.tokens.session, isNotNull);
      expect(app.tokens.clears, 0);
    });

    liveTest('the first later try succeeds when the backend accepts the token again', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      await refuse(tester, app);
      final shown = dashboard.data!.telemetry!.batteryPct;
      final attempts = app.live.attempts.length;

      app.live.refuseUpgrades = false;
      await tester.pump(const Duration(seconds: 59));
      expect(dashboard.liveState, LiveState.authFailed, reason: 'not before the delay');
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(Duration.zero);
      expect(dashboard.liveState, LiveState.connected);
      expect(app.live.attempts.length, attempts + 1);
      expect(app.live.openSockets, hasLength(1));
      expect(dashboard.data!.telemetry!.batteryPct, shown);
      // and nothing else is scheduled
      await tester.pump(const Duration(hours: 2));
      expect(app.live.attempts.length, attempts + 1);
      expect(app.live.openSockets, hasLength(1));
    });

    liveTest('a refresh by the user tries at once and starts the schedule over', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      await refuse(tester, app);
      await tester.pump(const Duration(hours: 1)); // the three automatic tries are used up
      final used = app.live.attempts.length;
      expect(used, 2 + 3 * 2);

      await settle(tester, dashboard.load());
      await tester.pump(Duration.zero);
      expect(app.live.attempts.length, used + 2, reason: 'tried at once');
      expect(dashboard.liveState, LiveState.authFailed);
      await tester.pump(const Duration(hours: 1));
      expect(app.live.attempts.length, used + 2 + 3 * 2, reason: 'three more, then off again');
      await tester.pump(const Duration(days: 1));
      expect(app.live.attempts.length, used + 2 + 3 * 2);
    });

    liveTest('a pending try is cancelled by the background, by closing the page, by a device switch and by logout', (tester) async {
      // background
      final paused = appWithDevice();
      await openDashboard(tester, paused);
      await refuse(tester, paused);
      var attempts = paused.live.attempts.length;
      paused.services.dashboard.pauseLive();
      await tester.pump(const Duration(hours: 1));
      expect(paused.live.attempts.length, attempts);
      expect(paused.services.dashboard.liveState, LiveState.disconnected);

      // page closed
      final closed = appWithDevice();
      await openDashboard(tester, closed);
      await refuse(tester, closed);
      attempts = closed.live.attempts.length;
      closed.services.dashboard.detachLive();
      await tester.pump(const Duration(hours: 1));
      expect(closed.live.attempts.length, attempts);

      // logout
      final signedOut = appWithDevice();
      await settle(tester, signedOut.services.session.restore());
      await openDashboard(tester, signedOut);
      await refuse(tester, signedOut);
      attempts = signedOut.live.attempts.length;
      await settle(tester, signedOut.services.session.logout());
      await tester.pump(const Duration(hours: 1));
      expect(signedOut.live.attempts.length, attempts);
      expect(signedOut.services.dashboard.data, isNull);

      // device switch: the pending try is dropped; the new device's own connection is tried at once
      final switched = appWithDevice(devices: [device, otherDevice]);
      await openDashboard(tester, switched);
      await refuse(tester, switched);
      attempts = switched.live.attempts.length;
      switched.live.refuseUpgrades = false;
      await settle(tester, switched.services.dashboard.selectDevice(otherDevice));
      await tester.pump(Duration.zero);
      expect(switched.services.dashboard.liveState, LiveState.connected);
      expect(switched.live.attempts.length, attempts + 1);
      await tester.pump(const Duration(hours: 1));
      expect(switched.live.attempts.length, attempts + 1, reason: 'the old try did not fire on top of it');
      expect(switched.live.openSockets, hasLength(1));
    });
  });

  group('reading freshness (status-based, no age limit)', () {
    liveTest('live only while the channel is connected and the backend reports the device online', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      expect(dashboard.freshness, isNull, reason: 'nothing loaded');
      dashboard.attachLive();
      app.live.talkative = false; // connecting
      await settle(tester, dashboard.load());
      await tester.pump(Duration.zero);
      expect(dashboard.liveState, LiveState.connecting);
      expect(dashboard.freshness, ReadingFreshness.notConnected);

      app.live.openSockets.single.push({'type': 'hello', 'protocol': 'gossy.ws.v1', 'serverTime': 'x', 'latestCursor': 100, 'tokenExpiresAt': 'x', 'heartbeatIntervalS': 25, 'allowedOps': ['start', 'resume', 'ping']});
      await tester.pump(Duration.zero);
      app.live.talkative = true;
      expect(dashboard.liveState, LiveState.connected);
      expect(dashboard.freshness, ReadingFreshness.live);

      // the device goes offline (Last Will), then comes back
      app.live.ingest(kind: 'status', deviceId: device, ts: '2026-10-01T14:00:00Z', receivedAt: '2026-10-01T15:02:00Z', data: {'state': 'offline'});
      await tester.pump(Duration.zero);
      expect(dashboard.freshness, ReadingFreshness.deviceOffline);
      app.live.ingest(kind: 'status', deviceId: device, ts: '2026-10-01T15:03:00Z', receivedAt: '2026-10-01T15:03:01Z', data: {'state': 'online'});
      await tester.pump(Duration.zero);
      expect(dashboard.freshness, ReadingFreshness.live);

      // the app loses the channel: whatever the device last said, the reading is "last known"
      app.live.outage = LiveOutage.offline;
      app.live.dropAll(code: 1011);
      await tester.pump(Duration.zero);
      expect(dashboard.liveState, LiveState.reconnecting);
      expect(dashboard.freshness, ReadingFreshness.notConnected);
      app.live.outage = LiveOutage.none;
      await tester.pump(const Duration(seconds: 1));
      expect(dashboard.liveState, LiveState.connected);
      expect(dashboard.freshness, ReadingFreshness.live);

      // background
      dashboard.pauseLive();
      expect(dashboard.freshness, ReadingFreshness.notConnected);
    });

    liveTest('a device that never reported its state, and a device without readings', (tester) async {
      final unknown = appWithDevice(state: null);
      await openDashboard(tester, unknown);
      expect(unknown.services.dashboard.liveState, LiveState.connected);
      expect(unknown.services.dashboard.freshness, ReadingFreshness.deviceStatusUnknown);

      final empty = appWithDevice()..backend.telemetry.clear();
      await openDashboard(tester, empty);
      expect(empty.services.dashboard.data!.telemetry, isNull);
      expect(empty.services.dashboard.freshness, isNull, reason: 'there is no reading to qualify');
    });

    liveTest('without a threshold from the backend no age limit is applied (Phase 4 rule alone)', (tester) async {
      // The time rule of Phase 5A needs the backend's threshold and receipt time; this backend
      // sends neither, so age alone never marks a reading (see freshness_time_test.dart).
      final app = appWithDevice();
      app.backend.telemetry[device] = [FakeBackend.telemetryRow(time: '2020-01-01T00:00:00Z', batteryPct: 66, msgId: '01K6CQ4W0D8V9J4Q9W2Y000001')];
      await openDashboard(tester, app);
      expect(app.services.dashboard.freshness, ReadingFreshness.live);
      expect(app.services.dashboard.data!.telemetry!.time, DateTime.utc(2020));
    });

    liveTest('live updates refused: last known, and live again after the controlled retry', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      app.live.refuseUpgrades = true;
      app.live.expireTokens();
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);
      expect(dashboard.liveState, LiveState.authFailed);
      expect(dashboard.freshness, ReadingFreshness.notConnected);
      app.live.refuseUpgrades = false;
      await tester.pump(const Duration(minutes: 1));
      await tester.pump(Duration.zero);
      expect(dashboard.freshness, ReadingFreshness.live);
    });
  });
}
