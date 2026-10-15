// Phase 5B: the alerts controller (lib/core/alerts) - REST snapshot, acknowledgement, and the
// alerts[] carried by the events of the dashboard's existing live connection - against the
// fakes that follow the backend contracts (test/support/fake_backend.dart, fake_live.dart).
//
// testWidgets is used for its controllable clock; no widget is involved here. The pages are
// covered by test/ui/notifications_test.dart.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/alerts/alerts_controller.dart';
import 'package:smart_gossy_culture_app/core/api/api_failure.dart';
import 'package:smart_gossy_culture_app/core/auth/session_controller.dart';
import 'package:smart_gossy_culture_app/core/models.dart';
import 'package:smart_gossy_culture_app/core/realtime/live_connection.dart';
import 'package:smart_gossy_culture_app/core/realtime/live_messages.dart';

import '../support/fake_backend.dart';
import '../support/fake_live.dart';

const device = 'unit-a';
const otherDevice = 'unit-b';

String alertId(int n) => 'a0000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

final List<TestApp> _apps = [];

/// Ends the way the Dashboard page does when it is disposed; a surviving timer fails the test.
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

TestApp appWithDevices({List<String> devices = const [device, otherDevice]}) {
  final app = TestApp(random: FixedRandom(1.0))..signIn();
  _apps.add(app);
  app.backend.farms.add({'id': 'farm-1', 'name': 'North field', 'createdAt': '2026-10-01T00:00:00Z'});
  for (final (index, id) in devices.indexed) {
    app.backend.devices.add(FakeBackend.device(id, state: 'online', lastSeenAt: '2026-10-01T15:00:00Z', claimedAt: '2026-10-0${9 - index}T00:00:00Z'));
  }
  app.backend.telemetry[device] = [FakeBackend.telemetryRow(time: '2026-10-01T15:00:00Z', batteryPct: 66, msgId: '01K6CQ4W0D8V9J4Q9W2Y000001')];
  return app;
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

/// What the Dashboard page does when it opens: live updates wanted, snapshot and alerts loaded.
Future<void> openDashboard(WidgetTester tester, TestApp app) async {
  app.services.dashboard.attachLive();
  await settle(tester, Future.wait([app.services.dashboard.load(), app.services.alerts.load()]));
  await tester.pump(Duration.zero);
  await tester.pump(Duration.zero);
}

Map<String, Object?> pest(int n, {String deviceId = device, String at = '2026-10-01T15:00:00Z', String status = 'open', String? acknowledgedAt, String label = 'bollworm', num confidence = 0.87}) =>
    FakeBackend.alertRow(id: alertId(n), type: 'pest_detected', deviceId: deviceId, occurredAt: at, status: status, acknowledgedAt: acknowledgedAt, details: {'label': label, 'confidence': confidence});

Iterable<RecordedCall> alertCalls(TestApp app) => app.backend.calls.where((c) => c.path.startsWith('/api/v1/alerts'));

void main() {
  group('REST snapshot', () {
    liveTest('loads the newest alerts and the open ones with the session token, for all of the caller\'s devices', (tester) async {
      final app = appWithDevices();
      app.backend.alerts.addAll([
        pest(3, at: '2026-10-01T15:03:00Z'),
        FakeBackend.alertRow(id: alertId(2), type: 'spray_performed', severity: 'info', deviceId: otherDevice, occurredAt: '2026-10-01T15:02:00Z', details: {'durationMs': 1500}, status: 'acknowledged', acknowledgedAt: '2026-10-01T15:30:00Z'),
        FakeBackend.alertRow(id: alertId(1), type: 'device_offline', deviceId: device, occurredAt: '2026-10-01T09:00:00Z', createdAt: '2026-10-01T15:01:00Z'),
      ]);
      final alerts = app.services.alerts;
      expect(alerts.phase, AlertsPhase.idle);
      expect(alerts.openCountKnown, isFalse);

      await settle(tester, alerts.load());
      expect(alerts.phase, AlertsPhase.ready);
      expect(alerts.failure, isNull);
      expect(alerts.alerts.map((a) => a.id), [alertId(3), alertId(2), alertId(1)]);

      // the two requests of the contract, nothing else
      final calls = alertCalls(app).toList();
      expect(calls.map((c) => '${c.method} ${c.path}'), ['GET /api/v1/alerts', 'GET /api/v1/alerts']);
      expect(calls.map((c) => c.query), [
        {'limit': '${AlertsController.pageSize}'},
        {'limit': '${AlertsController.openQueryLimit}', 'status': 'open'},
      ]);
      expect(calls.every((c) => c.authorization == 'Bearer ${app.tokens.session!.accessToken}'), isTrue);
      expect(calls.any((c) => c.query.containsKey('deviceId')), isFalse, reason: 'the backend scopes alerts to the caller\'s devices');

      // every field as sent
      final first = alerts.alerts.first;
      expect(first.type, Alert.pestDetected);
      expect(first.severity, 'warning');
      expect(first.isOpen, isTrue);
      expect(first.deviceId, device);
      expect(first.occurredAt, DateTime.utc(2026, 10, 1, 15, 3));
      expect(first.details, {'label': 'bollworm', 'confidence': 0.87});
      expect(first.acknowledgedAt, isNull);
      final spray = alerts.alerts[1];
      expect(spray.isAcknowledged, isTrue);
      expect(spray.acknowledgedAt, DateTime.utc(2026, 10, 1, 15, 30));
      expect(spray.deviceId, otherDevice);
      final offline = alerts.alerts[2];
      expect(offline.occurredAt, DateTime.utc(2026, 10, 1, 9));
      expect(offline.createdAt, DateTime.utc(2026, 10, 1, 15, 1));

      // open = the backend's status field
      expect(alerts.openCountKnown, isTrue);
      expect(alerts.openCount, 2);
      expect(alerts.openCountIsMinimum, isFalse);
    });

    liveTest('no alerts: ready and empty, zero open', (tester) async {
      final app = appWithDevices();
      await settle(tester, app.services.alerts.load());
      expect(app.services.alerts.phase, AlertsPhase.ready);
      expect(app.services.alerts.alerts, isEmpty);
      expect(app.services.alerts.openCount, 0);
      expect(app.services.alerts.hasMore, isFalse);
    });

    liveTest('first load: loading -> error on failure; retry -> ready; a failed refresh keeps the alerts', (tester) async {
      final app = appWithDevices();
      final alerts = app.services.alerts;
      app.backend.alerts.add(pest(1));
      app.backend.latency = const Duration(seconds: 1);
      app.backend.overrides['/api/v1/alerts'] = FakeReply.error(503, 'service_unavailable');
      final loading = alerts.load();
      await tester.pump(Duration.zero);
      expect(alerts.phase, AlertsPhase.loading);
      expect(alerts.busy, isTrue);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester, loading);
      expect(alerts.phase, AlertsPhase.error);
      expect(alerts.failure!.kind, ApiFailureKind.unavailable);
      expect(alerts.openCountKnown, isFalse, reason: 'nothing is known about open alerts');

      app.backend
        ..latency = Duration.zero
        ..overrides.clear();
      await settle(tester, alerts.load());
      expect(alerts.phase, AlertsPhase.ready);
      expect(alerts.alerts, hasLength(1));

      app.backend.outage = Outage.offline;
      await settle(tester, alerts.load());
      expect(alerts.phase, AlertsPhase.ready);
      expect(alerts.failure!.kind, ApiFailureKind.network);
      expect(alerts.alerts, hasLength(1), reason: 'the alerts loaded earlier stay');
      expect(alerts.openCount, 1);
    });

    liveTest('overlapping loads are ignored: one pair of requests', (tester) async {
      final app = appWithDevices();
      final alerts = app.services.alerts;
      await settle(tester, Future.wait([alerts.load(), alerts.load(), alerts.load()]));
      expect(alertCalls(app), hasLength(2));
    });

    liveTest('older alerts are loaded page by page with the backend\'s cursor, without duplicates', (tester) async {
      final app = appWithDevices();
      for (var n = 120; n >= 1; n--) {
        app.backend.alerts.add(pest(n, at: '2026-10-01T${(n ~/ 60).toString().padLeft(2, '0')}:${(n % 60).toString().padLeft(2, '0')}:00Z', status: 'acknowledged', acknowledgedAt: '2026-10-01T15:30:00Z'));
      }
      final alerts = app.services.alerts;
      await settle(tester, alerts.load());
      expect(alerts.alerts, hasLength(50));
      expect(alerts.hasMore, isTrue);
      await settle(tester, alerts.loadMore());
      expect(alerts.alerts, hasLength(100));
      expect(alertCalls(app).last.query, {'limit': '50', 'cursor': '50'});
      await settle(tester, alerts.loadMore());
      expect(alerts.alerts, hasLength(120));
      expect(alerts.hasMore, isFalse);
      expect(alerts.alerts.map((a) => a.id).toSet(), hasLength(120));
      await settle(tester, alerts.loadMore());
      expect(alertCalls(app), hasLength(4), reason: 'nothing is requested when there is no next page');
    });

    liveTest('more open alerts than were read: the number is a minimum, not a count', (tester) async {
      final app = appWithDevices();
      for (var n = 130; n >= 1; n--) {
        app.backend.alerts.add(pest(n, at: '2026-10-01T${(n ~/ 60).toString().padLeft(2, '0')}:${(n % 60).toString().padLeft(2, '0')}:00Z'));
      }
      final alerts = app.services.alerts;
      await settle(tester, alerts.load());
      expect(alerts.openCount, AlertsController.openQueryLimit);
      expect(alerts.openCountIsMinimum, isTrue);
    });

    test('alert parsing: the contract object becomes a typed model; anything else is refused, not guessed', () {
      final row = FakeBackend.alertRow(id: alertId(1), type: 'pest_detected', deviceId: device, occurredAt: '2026-10-01T15:00:00+00:00', details: {'label': 'bollworm', 'confidence': 0.87});
      final alert = Alert.fromJson({...row});
      expect(alert.id, alertId(1));
      expect(alert.isOpen, isTrue);
      // a type or severity the app does not know is kept as sent
      final unknown = Alert.fromJson({...row, 'type': 'firmware_notice', 'severity': 'critical'});
      expect(unknown.type, 'firmware_notice');
      expect(unknown.severity, 'critical');
      for (final bad in [
        {...row, 'status': 'snoozed'},
        {...row, 'status': null},
        {...row, 'id': 7},
        {...row, 'occurredAt': 'yesterday'},
        {...row, 'details': 'none'},
        {...row}..remove('deviceId'),
        {...row, 'acknowledgedAt': 5},
      ]) {
        expect(() => Alert.fromJson(bad), throwsFormatException, reason: '$bad');
      }
    });

    liveTest('a reply that does not match the contract is an error, not a partial list', (tester) async {
      final app = appWithDevices();
      app.backend.alerts.add({...pest(1), 'status': 'snoozed'});
      await settle(tester, app.services.alerts.load());
      expect(app.services.alerts.phase, AlertsPhase.error);
      expect(app.services.alerts.failure!.kind, ApiFailureKind.invalidResponse);
      expect(app.services.alerts.alerts, isEmpty);
    });
  });

  group('live alerts (alerts[] in the events of the existing connection)', () {
    liveTest('a live event with an alert adds it to the list and to the open count, without a REST request', (tester) async {
      final app = appWithDevices();
      app.backend.alerts.add(pest(1, at: '2026-10-01T14:00:00Z'));
      final alerts = app.services.alerts;
      await openDashboard(tester, app);
      expect(alerts.openCount, 1);
      final restCalls = app.backend.calls.length;
      var notified = 0;
      alerts.addListener(() => notified++);

      app.live.ingest(kind: 'event/pest', deviceId: device, ts: '2026-10-01T15:10:00Z', data: {'label': 'leaf_curl_virus', 'confidence': 0.91}, alerts: [pest(2, at: '2026-10-01T15:10:00Z', label: 'leaf_curl_virus', confidence: 0.91)]);
      await tester.pump(Duration.zero);

      expect(alerts.alerts.map((a) => a.id), [alertId(2), alertId(1)], reason: 'newest first');
      expect(alerts.alerts.first.details['label'], 'leaf_curl_virus');
      expect(alerts.openCount, 2);
      expect(notified, 1);
      expect(app.backend.calls.length, restCalls, reason: 'the alert came from the live event');
      // the same event still updates the dashboard's detection (Phase 3C behaviour)
      expect(app.services.dashboard.data!.latestDetection!.label, 'leaf_curl_virus');
      // one connection, and the app sent it nothing but `start`
      expect(app.live.sockets, hasLength(1));
      expect(app.live.clientFrames, [{'op': 'start'}]);
    });

    liveTest('events without alerts change nothing; alerts are not derived from readings', (tester) async {
      final app = appWithDevices();
      final alerts = app.services.alerts;
      await openDashboard(tester, app);
      var notified = 0;
      alerts.addListener(() => notified++);
      // a very low battery and humidity: readings only - the backend created no alert
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:10:00Z', data: {'batteryPct': 2, 'moistureRhPct': 1});
      app.live.ingest(kind: 'event/harvest', deviceId: device, ts: '2026-10-01T15:10:01Z', data: {'maturity': 'mature', 'picked': true});
      await tester.pump(Duration.zero);
      expect(alerts.alerts, isEmpty);
      expect(alerts.openCount, 0);
      expect(notified, 0);
    });

    liveTest('the same alert delivered twice appears once', (tester) async {
      final app = appWithDevices();
      final alerts = app.services.alerts;
      await openDashboard(tester, app);
      final row = pest(5, at: '2026-10-01T15:10:00Z');
      app.live.ingest(kind: 'event/pest', deviceId: device, ts: '2026-10-01T15:10:00Z', data: {'label': 'bollworm', 'confidence': 0.87}, alerts: [row]);
      // a second event (new cursor) carrying the same alert, and the same alert twice in one event
      app.live.ingest(kind: 'event/pest', deviceId: device, ts: '2026-10-01T15:10:01Z', data: {'label': 'bollworm', 'confidence': 0.87}, alerts: [row, row]);
      await tester.pump(Duration.zero);
      expect(alerts.alerts.map((a) => a.id), [alertId(5)]);
      expect(alerts.openCount, 1);

      // a reconnect replays the events after the cursor: still once
      app.live.dropAll(code: 1011);
      await tester.pump(Duration.zero);
      app.live.ingest(kind: 'status', deviceId: device, ts: '2026-10-01T15:11:00Z', data: {'state': 'offline'}, alerts: [FakeBackend.alertRow(id: alertId(6), type: 'device_offline', deviceId: device, occurredAt: '2026-10-01T15:11:00Z')]);
      await tester.pump(const Duration(seconds: 1));
      expect(app.services.dashboard.liveState, LiveState.connected);
      expect(alerts.alerts.map((a) => a.id), [alertId(6), alertId(5)]);
      expect(alerts.openCount, 2);
    });

    liveTest('an alert already loaded over REST and then delivered live stays one entry', (tester) async {
      final app = appWithDevices();
      final row = pest(1, at: '2026-10-01T15:00:00Z');
      app.backend.alerts.add(row);
      final alerts = app.services.alerts;
      await openDashboard(tester, app);
      var notified = 0;
      alerts.addListener(() => notified++);
      app.live.ingest(kind: 'event/pest', deviceId: device, ts: '2026-10-01T15:00:00Z', data: {'label': 'bollworm', 'confidence': 0.87}, alerts: [row]);
      await tester.pump(Duration.zero);
      expect(alerts.alerts, hasLength(1));
      expect(alerts.openCount, 1);
      expect(notified, 0, reason: 'nothing changed');
    });

    liveTest('alerts of the caller\'s other devices are listed too (the backend\'s scope), whichever device the dashboard shows', (tester) async {
      final app = appWithDevices();
      final alerts = app.services.alerts;
      await openDashboard(tester, app);
      expect(app.services.dashboard.data!.device!.deviceId, device);
      app.live.ingest(kind: 'event/spray', deviceId: otherDevice, ts: '2026-10-01T15:10:00Z', data: {'durationMs': 1500},
          alerts: [FakeBackend.alertRow(id: alertId(9), type: 'spray_performed', severity: 'info', deviceId: otherDevice, occurredAt: '2026-10-01T15:10:00Z', details: {'durationMs': 1500})]);
      await tester.pump(Duration.zero);
      expect(alerts.alerts.single.deviceId, otherDevice);
      expect(alerts.openCount, 1);
    });

    liveTest('an entry of alerts[] that is not a contract alert is left out; the event itself is still applied', (tester) async {
      final app = appWithDevices();
      final alerts = app.services.alerts;
      await openDashboard(tester, app);
      final good = pest(2, at: '2026-10-01T15:10:00Z');
      final event = app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:10:00Z', data: {'batteryPct': 61});
      app.live.openSockets.single.push({
        ...event, 'cursor': (event['cursor']! as int) + 1, 'msgId': '01K6CQ4W0D8V9J4Q9W2Y777777', 'ts': '2026-10-01T15:10:05Z', 'data': {'batteryPct': 60},
        'alerts': [
          'not an object',
          {'id': alertId(3), 'type': 'pest_detected'},
          {...pest(4), 'status': 'snoozed'},
          good,
        ],
      });
      // alerts that is not a list at all
      app.live.openSockets.single.push({...event, 'cursor': (event['cursor']! as int) + 2, 'msgId': '01K6CQ4W0D8V9J4Q9W2Y777778', 'ts': '2026-10-01T15:10:06Z', 'data': {'batteryPct': 59}, 'alerts': 'none'});
      await tester.pump(Duration.zero);
      expect(alerts.alerts.map((a) => a.id), [alertId(2)]);
      expect(app.services.dashboard.data!.telemetry!.batteryPct, 59, reason: 'the readings of those events were applied');
      expect(app.services.live.malformedFrames, 0);
      expect(tester.takeException(), isNull);
    });

    liveTest('an alert of a type this app does not know is kept as sent', (tester) async {
      final app = appWithDevices();
      final alerts = app.services.alerts;
      await openDashboard(tester, app);
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:10:00Z', data: {'batteryPct': 61},
          alerts: [FakeBackend.alertRow(id: alertId(8), type: 'firmware_notice', severity: 'critical', deviceId: device, occurredAt: '2026-10-01T15:10:00Z', details: {'version': '2'})]);
      await tester.pump(Duration.zero);
      expect(alerts.alerts.single.type, 'firmware_notice');
      expect(alerts.openCount, 1);
    });

    liveTest('before alerts have been asked for, live alerts cause no request and no state (Phase 3C request counts unchanged)', (tester) async {
      final app = appWithDevices();
      app.services.dashboard.attachLive();
      await settle(tester, app.services.dashboard.load());
      await tester.pump(Duration.zero);
      expect(app.services.dashboard.liveState, LiveState.connected);
      app.live.ingest(kind: 'event/pest', deviceId: device, ts: '2026-10-01T15:10:00Z', data: {'label': 'bollworm', 'confidence': 0.87}, alerts: [pest(2, at: '2026-10-01T15:10:00Z')]);
      await tester.pump(Duration.zero);
      expect(alertCalls(app), isEmpty);
      expect(app.services.alerts.phase, AlertsPhase.idle);
      expect(app.services.alerts.alerts, isEmpty);
      expect(app.services.alerts.openCountKnown, isFalse);
    });

    liveTest('a stream that started "from now" reads the alerts again: nothing created in between is missed', (tester) async {
      final app = appWithDevices();
      final alerts = app.services.alerts;
      app.services.dashboard.attachLive();
      app.live.talkative = false; // the upgrade succeeds but the stream has not started yet
      await settle(tester, Future.wait([app.services.dashboard.load(), alerts.load()]));
      await tester.pump(Duration.zero);
      expect(alerts.alerts, isEmpty);
      final before = alertCalls(app).length;

      // Created now: after the snapshot, before `start`. No live event will ever carry it.
      app.backend.alerts.add(pest(1, at: '2026-10-01T15:00:03Z'));
      app.live.openSockets.single.push({'type': 'hello', 'protocol': 'gossy.ws.v1', 'serverTime': 'x', 'latestCursor': 100, 'tokenExpiresAt': 'x', 'heartbeatIntervalS': 25, 'allowedOps': ['start', 'resume', 'ping']});
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);

      expect(app.services.dashboard.liveState, LiveState.connected);
      expect(alerts.alerts.map((a) => a.id), [alertId(1)]);
      expect(alertCalls(app).length, before + 2);

      // a reconnection that resumes from the cursor needs no REST read
      app.live.talkative = true;
      app.live.dropAll(code: 1011);
      await tester.pump(const Duration(seconds: 2));
      expect(app.services.dashboard.liveState, LiveState.connected);
      expect(alertCalls(app).length, before + 2);
    });

    liveTest('an alert that arrives live while a REST read is in flight is not lost when the older reply lands', (tester) async {
      final app = appWithDevices();
      final alerts = app.services.alerts;
      await openDashboard(tester, app);
      app.backend.latency = const Duration(seconds: 2);
      final refresh = alerts.load(); // the reply will not contain the alert below
      await tester.pump(const Duration(seconds: 1));
      final row = pest(2, at: '2026-10-01T15:10:00Z');
      app.live.ingest(kind: 'event/pest', deviceId: device, ts: '2026-10-01T15:10:00Z', data: {'label': 'bollworm', 'confidence': 0.87}, alerts: [row]);
      await tester.pump(Duration.zero);
      expect(alerts.alerts.map((a) => a.id), [alertId(2)]);
      await tester.pump(const Duration(seconds: 2));
      await settle(tester, refresh);
      expect(alerts.alerts.map((a) => a.id), [alertId(2)]);
      expect(alerts.openCount, 1);
    });

    liveTest('a live alert older than the loaded pages is counted as open but not put into a page it does not belong to', (tester) async {
      final app = appWithDevices();
      for (var n = 60; n >= 1; n--) {
        app.backend.alerts.add(pest(n, at: '2026-10-01T10:${n.toString().padLeft(2, '0')}:00Z', status: 'acknowledged', acknowledgedAt: '2026-10-01T15:30:00Z'));
      }
      final alerts = app.services.alerts;
      await openDashboard(tester, app);
      expect(alerts.alerts, hasLength(50));
      // a device that was offline replays an old detection: new alert, old device time
      app.live.ingest(kind: 'event/pest', deviceId: device, ts: '2026-10-01T08:00:00Z', data: {'label': 'bollworm', 'confidence': 0.87}, alerts: [pest(99, at: '2026-10-01T08:00:00Z')]);
      await tester.pump(Duration.zero);
      expect(alerts.alerts, hasLength(50));
      expect(alerts.alerts.any((a) => a.id == alertId(99)), isFalse);
      expect(alerts.openCount, 1);
    });
  });

  group('acknowledgement ("read" = acknowledged on the backend)', () {
    liveTest('acknowledging calls the backend\'s endpoint for that alert and shows the backend\'s reply', (tester) async {
      final app = appWithDevices();
      app.backend.alerts.addAll([pest(2, at: '2026-10-01T15:02:00Z'), pest(1, at: '2026-10-01T15:01:00Z')]);
      final alerts = app.services.alerts;
      await openDashboard(tester, app);
      expect(alerts.openCount, 2);
      final before = app.backend.calls.length;

      final pending = alerts.acknowledge(alertId(2));
      expect(alerts.isAcknowledging(alertId(2)), isTrue);
      expect(alerts.alerts.first.isOpen, isTrue, reason: 'not shown as acknowledged before the backend has answered');
      expect(await settle(tester, pending), isNull);

      final call = app.backend.calls.skip(before).single;
      expect('${call.method} ${call.path}', 'POST /api/v1/alerts/${alertId(2)}/acknowledge');
      expect(call.body, isNull, reason: 'the endpoint takes no body');
      expect(call.authorization, 'Bearer ${app.tokens.session!.accessToken}');

      final acknowledged = alerts.alerts.first;
      expect(acknowledged.id, alertId(2));
      expect(acknowledged.isAcknowledged, isTrue);
      expect(acknowledged.acknowledgedAt, DateTime.utc(2026, 10, 1, 16), reason: 'the time the backend returned');
      expect(alerts.alerts[1].isOpen, isTrue, reason: 'only that alert');
      expect(alerts.openCount, 1);
      expect(alerts.isAcknowledging(alertId(2)), isFalse);

      // a later REST refresh agrees
      await settle(tester, alerts.load());
      expect(alerts.alerts.first.isAcknowledged, isTrue);
      expect(alerts.openCount, 1);
      // nothing went over the live channel
      expect(app.live.clientFrames, [{'op': 'start'}]);
    });

    liveTest('a failed acknowledgement leaves the alert open and reports the failure', (tester) async {
      final app = appWithDevices();
      app.backend.alerts.add(pest(1));
      final alerts = app.services.alerts;
      await openDashboard(tester, app);

      for (final (reply, kind) in [
        (FakeReply.error(503, 'service_unavailable'), ApiFailureKind.unavailable),
        (FakeReply.error(404, 'not_found'), ApiFailureKind.notFound),
        (const FakeReply(200, {'unexpected': true}), ApiFailureKind.invalidResponse),
      ]) {
        app.backend.overrides['/api/v1/alerts/${alertId(1)}/acknowledge'] = reply;
        final failure = await settle(tester, alerts.acknowledge(alertId(1)));
        expect(failure!.kind, kind);
        expect(alerts.alerts.single.isOpen, isTrue);
        expect(alerts.alerts.single.acknowledgedAt, isNull);
        expect(alerts.openCount, 1);
        expect(alerts.isAcknowledging(alertId(1)), isFalse);
      }
      app.backend
        ..overrides.clear()
        ..outage = Outage.offline;
      expect((await settle(tester, alerts.acknowledge(alertId(1))))!.kind, ApiFailureKind.network);
      expect(alerts.alerts.single.isOpen, isTrue);
      expect(app.backend.alerts.single['status'], 'open');
    });

    liveTest('acknowledging twice at once sends one request; acknowledging again later is harmless (idempotent endpoint)', (tester) async {
      final app = appWithDevices();
      app.backend.alerts.add(pest(1));
      final alerts = app.services.alerts;
      await openDashboard(tester, app);
      await settle(tester, Future.wait([alerts.acknowledge(alertId(1)), alerts.acknowledge(alertId(1))]));
      expect(app.backend.count('POST', '/api/v1/alerts/${alertId(1)}/acknowledge'), 1);
      await settle(tester, alerts.acknowledge(alertId(1)));
      expect(alerts.alerts.single.isAcknowledged, isTrue);
      expect(alerts.alerts.single.acknowledgedAt, DateTime.utc(2026, 10, 1, 16));
    });

    liveTest('an older event or an older REST reply cannot make an acknowledged alert open again', (tester) async {
      final app = appWithDevices();
      final row = pest(1, at: '2026-10-01T15:00:00Z');
      app.backend.alerts.add(row);
      final alerts = app.services.alerts;
      await openDashboard(tester, app);
      final seen = app.live.ingest(kind: 'event/pest', deviceId: device, ts: '2026-10-01T15:00:00Z', data: {'label': 'bollworm', 'confidence': 0.87}, alerts: [row]);
      await tester.pump(Duration.zero);

      // a REST read is in flight (its reply was produced while the alert was still open) ...
      app.backend.latency = const Duration(seconds: 2);
      final stale = Map<String, Object?>.of(app.backend.alerts.single);
      final refresh = alerts.load();
      await tester.pump(const Duration(seconds: 1));
      // ... when the acknowledgement is confirmed
      app.backend.latency = Duration.zero;
      expect(await settle(tester, alerts.acknowledge(alertId(1))), isNull);
      expect(alerts.alerts.single.isAcknowledged, isTrue);
      app.backend.alerts[0] = stale; // what the in-flight reply contains
      await tester.pump(const Duration(seconds: 2));
      await settle(tester, refresh);
      expect(alerts.alerts.single.isAcknowledged, isTrue, reason: 'the older REST reply does not undo it');
      expect(alerts.openCount, 0);

      // the live event that created the alert, delivered again with a new cursor
      app.live.openSockets.single.push({...seen, 'cursor': (seen['cursor']! as int) + 50});
      await tester.pump(Duration.zero);
      expect(alerts.alerts.single.isAcknowledged, isTrue);
      expect(alerts.openCount, 0);
    });

    liveTest('an alert acknowledged elsewhere shows as acknowledged after a refresh or a replayed event', (tester) async {
      final app = appWithDevices();
      app.backend.alerts.addAll([pest(2, at: '2026-10-01T15:02:00Z'), pest(1, at: '2026-10-01T15:01:00Z')]);
      final alerts = app.services.alerts;
      await openDashboard(tester, app);
      expect(alerts.openCount, 2);
      // another phone of the same farmer acknowledges alert 2: only REST tells this app
      app.backend.alerts[0] = {...app.backend.alerts[0], 'status': 'acknowledged', 'acknowledgedAt': '2026-10-01T15:40:00Z'};
      await settle(tester, alerts.load());
      expect(alerts.alerts.first.isAcknowledged, isTrue);
      expect(alerts.openCount, 1);
      // a replayed event carries the alert as the backend holds it now
      final replayed = {...pest(1, at: '2026-10-01T15:01:00Z'), 'status': 'acknowledged', 'acknowledgedAt': '2026-10-01T15:41:00Z'};
      app.live.ingest(kind: 'event/pest', deviceId: device, ts: '2026-10-01T15:01:00Z', data: {'label': 'bollworm', 'confidence': 0.87}, alerts: [replayed]);
      await tester.pump(Duration.zero);
      expect(alerts.alerts[1].isAcknowledged, isTrue);
      expect(alerts.alerts[1].acknowledgedAt, DateTime.utc(2026, 10, 1, 15, 41));
      expect(alerts.openCount, 0);
    });
  });

  group('session', () {
    liveTest('session ended while loading alerts: cleared by the Phase 3A mechanism, no error state, nothing kept', (tester) async {
      final app = appWithDevices();
      app.backend.alerts.add(pest(1));
      final alerts = app.services.alerts;
      var forced = 0;
      app.services.session.onForcedSignOut = () => forced++;
      await settle(tester, app.services.session.restore());
      await openDashboard(tester, app);
      expect(alerts.alerts, hasLength(1));

      app.backend
        ..expireAccessToken()
        ..sessionRevoked = true;
      await settle(tester, alerts.load());
      await tester.pump(Duration.zero);
      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1, reason: 'the two alert requests share one refresh');
      expect(app.tokens.session, isNull);
      expect(app.services.session.status, SessionStatus.signedOut);
      expect(forced, 1);
      expect(alerts.phase, AlertsPhase.idle);
      expect(alerts.alerts, isEmpty);
      expect(alerts.failure, isNull);
      expect(alerts.openCountKnown, isFalse);
      expect(app.live.openSockets, isEmpty);
    });

    liveTest('session ended while acknowledging: the alert is not marked, the session is cleared', (tester) async {
      final app = appWithDevices();
      app.backend.alerts.add(pest(1));
      final alerts = app.services.alerts;
      await settle(tester, app.services.session.restore());
      await openDashboard(tester, app);
      app.backend
        ..expireAccessToken()
        ..sessionRevoked = true;
      final failure = await settle(tester, alerts.acknowledge(alertId(1)));
      expect(failure!.kind, ApiFailureKind.sessionExpired);
      expect(app.backend.alerts.single['status'], 'open');
      expect(app.services.session.status, SessionStatus.signedOut);
      expect(alerts.alerts, isEmpty);
    });

    liveTest('access token expired: alerts and dashboard requests share one refresh; logout forgets the alerts', (tester) async {
      final app = appWithDevices();
      app.backend.alerts.add(pest(1));
      final alerts = app.services.alerts;
      await settle(tester, app.services.session.restore());
      await openDashboard(tester, app);
      app.backend.expireAccessToken();
      await settle(tester, Future.wait([alerts.load(), app.services.dashboard.load()]));
      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
      expect(alerts.failure, isNull);
      expect(alerts.alerts, hasLength(1));

      await settle(tester, app.services.session.logout());
      await tester.pump(Duration.zero);
      expect(alerts.phase, AlertsPhase.idle);
      expect(alerts.alerts, isEmpty);
      expect(alerts.openCount, 0);
      // a reply that arrives after sign-out is dropped
      final attempts = alertCalls(app).length;
      await tester.pump(const Duration(hours: 1));
      expect(alertCalls(app).length, attempts);
    });
  });

  group('boundaries', () {
    liveTest('alerts add no socket, no frame and no timer: one connection, only start / resume sent', (tester) async {
      final app = appWithDevices();
      app.backend.alerts.addAll([pest(2, at: '2026-10-01T15:02:00Z'), pest(1, at: '2026-10-01T15:01:00Z')]);
      final alerts = app.services.alerts;
      await openDashboard(tester, app);
      app.live.ingest(kind: 'event/pest', deviceId: device, ts: '2026-10-01T15:10:00Z', data: {'label': 'bollworm', 'confidence': 0.87}, alerts: [pest(3, at: '2026-10-01T15:10:00Z')]);
      await tester.pump(Duration.zero);
      await settle(tester, alerts.acknowledge(alertId(3)));
      await settle(tester, alerts.acknowledge(alertId(2)));
      await settle(tester, alerts.load());
      app.live.dropAll(code: 1011);
      await tester.pump(const Duration(seconds: 2));
      await settle(tester, alerts.acknowledge(alertId(1)));
      await tester.pump(const Duration(minutes: 5));

      expect(app.live.openSockets, hasLength(1));
      expect(app.live.sockets, hasLength(2), reason: 'the first connection and its one replacement');
      for (final frame in app.live.clientFrames) {
        final message = frame! as Map;
        expect(message['op'], anyOf('start', 'resume'), reason: '$message');
        expect(message.keys.toSet().difference({'op', 'cursor'}), isEmpty, reason: '$message');
      }
      for (final socket in app.live.sockets) {
        expect(socket.received.length, lessThanOrEqualTo(1));
      }
      // the only requests that change anything on the backend: one acknowledgement per alert
      final writes = app.backend.calls.where((c) => c.method != 'GET').map((c) => '${c.method} ${c.path}').toList();
      expect(writes, [for (final n in [3, 2, 1]) 'POST /api/v1/alerts/${alertId(n)}/acknowledge']);
    });

    test('the app code has no bulk acknowledgement, and acknowledges in exactly one place, over REST', () {
      final sources = Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')).toList();
      expect(sources.length, greaterThan(20));
      final acknowledgeCalls = <String>[];
      for (final file in sources) {
        final code = file.readAsStringSync().replaceAll(RegExp(r'//.*'), ''); // comments say what is absent
        final path = file.path.replaceAll('\\', '/');
        expect(code.toLowerCase(), isNot(contains('mark all')), reason: path);
        expect(code.toLowerCase(), isNot(contains('marked as read')), reason: path);
        expect(RegExp(r'acknowledge[-_/]?all|bulk', caseSensitive: false).hasMatch(code), isFalse, reason: path);
        if (code.contains('/acknowledge')) acknowledgeCalls.add(path);
      }
      expect(acknowledgeCalls, ['lib/core/alerts/alerts_repository.dart']);
      // the controller acknowledges one alert per call and never loops over alerts to do it
      final controller = File('lib/core/alerts/alerts_controller.dart').readAsStringSync();
      expect(RegExp(r'_repository\.acknowledge\(').allMatches(controller), hasLength(1));
      // alert code never writes to a socket and has no connection, timer or device channel
      for (final file in Directory('lib/core/alerts').listSync().whereType<File>()) {
        final code = file.readAsStringSync().replaceAll(RegExp(r'//.*'), '');
        for (final word in ['.send(', 'sink.add', 'WebSocket', 'LiveConnection', 'Timer', 'mqtt', 'Mqtt', 'command', 'publish']) {
          expect(code, isNot(contains(word)), reason: '${file.path}: $word');
        }
      }
    });

    test('no device id is written into the app code: alerts are asked for without one', () {
      final sources = Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')).toList();
      expect(sources.length, greaterThan(20));
      for (final file in sources) {
        // the ids devices have in this project: sim-0001, bb-0001, ...
        expect(RegExp(r'\b(sim|bb)-\d{3,}', caseSensitive: false).hasMatch(file.readAsStringSync()), isFalse, reason: file.path);
      }
      // the alert requests carry no deviceId at all: the scope is the backend's (the caller's devices)
      final repository = File('lib/core/alerts/alerts_repository.dart').readAsStringSync().replaceAll(RegExp(r'//.*'), '');
      expect(repository, isNot(contains('deviceId')));
    });

    test('live event parsing: alerts[] becomes typed alerts; the contract example parses', () {
      final event = LiveMessage.parse('{"type":"event","cursor":4812,"kind":"event/pest","deviceId":"sim-0002","msgId":"01K6CQ4W0D8V9J4Q9W2Y1S7ZPX","ts":"2026-09-30T10:15:02.412000+00:00","receivedAt":"2026-09-30T10:15:02.530114+00:00",'
          '"data":{"label":"bollworm","confidence":0.87,"bbox":[0.1,0.2,0.1,0.1]},"alerts":[{"id":"3f2b0c1e-0000-4000-8000-000000000001","type":"pest_detected","severity":"warning","status":"open","deviceId":"sim-0002",'
          '"occurredAt":"2026-09-30T10:15:02.412000+00:00","createdAt":"2026-09-30T10:15:02.530114+00:00","sourceMsgId":"01K6CQ4W0D8V9J4Q9W2Y1S7ZPX","details":{"label":"bollworm","confidence":0.87},"acknowledgedAt":null}]}') as LiveEvent;
      final alert = event.alerts.single;
      expect(alert.id, '3f2b0c1e-0000-4000-8000-000000000001');
      expect(alert.type, Alert.pestDetected);
      expect(alert.isOpen, isTrue);
      expect(alert.sourceMsgId, event.msgId);
      expect(alert.createdAt, event.receivedAt);
      // no alerts key, null, or an empty list: no alerts, the event is still an event
      for (final tail in ['', ',"alerts":null', ',"alerts":[]']) {
        final plain = LiveMessage.parse('{"type":"event","cursor":1,"kind":"telemetry","deviceId":"d","msgId":"m","ts":"2026-10-01T15:00:00Z","receivedAt":"2026-10-01T15:00:00Z","data":{"batteryPct":1}$tail}') as LiveEvent;
        expect(plain.alerts, isEmpty);
      }
    });
  });
}
