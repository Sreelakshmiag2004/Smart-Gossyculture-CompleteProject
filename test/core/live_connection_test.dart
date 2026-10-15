// Phase 3C: the live channel client (lib/core/realtime) and its use by the dashboard controller,
// against a fake that follows backend/docs/websocket-contract.md (test/support/fake_live.dart).
//
// testWidgets is used for its controllable clock (timers, backoff); no widget is involved here.
// The Dashboard page itself is covered by test/ui/dashboard_live_test.dart.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/api/api_failure.dart';
import 'package:smart_gossy_culture_app/core/auth/session_controller.dart';
import 'package:smart_gossy_culture_app/core/dashboard/dashboard_controller.dart';
import 'package:smart_gossy_culture_app/core/realtime/live_connection.dart';
import 'package:smart_gossy_culture_app/core/realtime/live_messages.dart';
import 'package:smart_gossy_culture_app/core/realtime/live_socket.dart';

import '../support/fake_backend.dart';
import '../support/fake_live.dart';

const device = 'unit-a';
const otherDevice = 'unit-b';

final List<TestApp> _apps = [];

/// A widget-clock test that ends the way the Dashboard page does when it is disposed: the live
/// connection is detached. A timer that survived would fail the test ("Timer is still pending").
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

TestApp appWithDevice({Random? random, List<String> devices = const [device]}) {
  final app = TestApp(random: random)..signIn();
  _apps.add(app);
  app.backend.farms.add({'id': 'farm-1', 'name': 'North field', 'createdAt': '2026-10-01T00:00:00Z'});
  for (final (index, id) in devices.indexed) {
    app.backend.devices.add(FakeBackend.device(id, state: 'online', lastSeenAt: '2026-10-01T15:00:00Z', claimedAt: '2026-10-0${9 - index}T00:00:00Z'));
  }
  app.backend.telemetry[device] = [FakeBackend.telemetryRow(time: '2026-10-01T15:00:00Z', batteryPct: 66, moistureRhPct: 40, bollsHarvestedTotal: 10, solarActive: true, msgId: '01K6CQ4W0D8V9J4Q9W2Y000001')];
  return app;
}

/// Runs [work] to completion inside a widget test, where pending work only advances when the
/// test clock is pumped. No time passes: only what is due now runs.
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
    await tester.pump(Duration.zero); // also runs timers that are due now
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

Map<String, Object?> telemetryData({num battery = 70, num? moisture, int? bolls, bool? solar, num? airTemp}) => {
      'batteryPct': battery,
      if (moisture != null) 'moistureRhPct': moisture,
      if (airTemp != null) 'airTempC': airTemp,
      if (bolls != null) 'bollsHarvestedTotal': bolls,
      if (solar != null) 'solarActive': solar,
    };

void main() {
  group('connection and authentication (contract gossy.ws.v1)', () {
    liveTest('connects once after the REST snapshot, with the session\'s bearer token on the upgrade', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      expect(dashboard.liveState, LiveState.disconnected);
      await openDashboard(tester, app);

      expect(dashboard.liveState, LiveState.connected);
      expect(app.live.attempts, hasLength(1));
      final attempt = app.live.attempts.single;
      // The channel of the configured backend: same host, /api/v1/ws, TLS because the API is https.
      expect(attempt.url.toString(), 'wss://backend.test/api/v1/ws');
      expect(attempt.url.hasQuery, isFalse, reason: 'the token must not travel in the URL');
      expect(attempt.headers, {'Authorization': 'Bearer ${app.tokens.session!.accessToken}'});
      // REST first: the snapshot's three requests were sent before the upgrade.
      expect(app.backend.calls.take(3).map((c) => c.path), ['/api/v1/devices', '/api/v1/devices/$device/telemetry', '/api/v1/detections']);
      // The only frame sent: begin delivery.
      expect(app.live.clientFrames, [{'op': 'start'}]);
      expect(app.live.openSockets, hasLength(1));
    });

    liveTest('nothing is connected before a snapshot exists, or without the page asking for live updates', (tester) async {
      final app = appWithDevice();
      await settle(tester, app.services.dashboard.load()); // not attached: e.g. a service-level caller
      await tester.pump(Duration.zero);
      expect(app.live.attempts, isEmpty);

      final failing = appWithDevice()..backend.outage = Outage.offline;
      failing.services.dashboard.attachLive();
      await settle(tester, failing.services.dashboard.load());
      await tester.pump(Duration.zero);
      expect(failing.services.dashboard.phase, DashboardPhase.error);
      expect(failing.live.attempts, isEmpty);
    });

    liveTest('the live URL follows GOSSY_API_BASE_URL: ws only for the local development backend', (tester) async {
      expect(liveUrlFor(Uri.parse('http://10.0.2.2:8000')).toString(), 'ws://10.0.2.2:8000/api/v1/ws');
      expect(liveUrlFor(Uri.parse('http://127.0.0.1:8000/')).toString(), 'ws://127.0.0.1:8000/api/v1/ws');
      expect(liveUrlFor(Uri.parse('https://api.example.test')).toString(), 'wss://api.example.test/api/v1/ws');
      expect(liveUrlFor(Uri.parse('https://api.example.test/base/')).toString(), 'wss://api.example.test/base/api/v1/ws');
    });

    liveTest('a server that speaks another protocol is not used and not retried', (tester) async {
      final app = appWithDevice()..live.protocol = 'gossy.ws.v2';
      await openDashboard(tester, app);
      expect(app.services.dashboard.liveState, LiveState.unavailable);
      expect(app.live.clientFrames, isEmpty);
      await tester.pump(const Duration(minutes: 10));
      expect(app.live.attempts, hasLength(1));
      expect(app.services.dashboard.data!.telemetry!.batteryPct, 66); // the REST values are untouched
    });
  });

  group('live events update the snapshot', () {
    liveTest('telemetry: the newer reading replaces the shown one, field by field as sent', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      expect(dashboard.data!.telemetry!.batteryPct, 66);

      final event = app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:00:05.250+00:00', receivedAt: '2026-10-01T15:00:05.400+00:00', data: telemetryData(battery: 65.5, moisture: 41, bolls: 11, solar: false, airTemp: 30.5));
      await tester.pump(Duration.zero);
      final point = dashboard.data!.telemetry!;
      expect(point.msgId, event['msgId']);
      expect(point.time, DateTime.utc(2026, 10, 1, 15, 0, 5, 250));
      expect(point.batteryPct, 65.5);
      expect(point.moistureRhPct, 41.0);
      expect(point.airTempC, 30.5);
      expect(point.bollsHarvestedTotal, 11);
      expect(point.solarActive, isFalse);
      // any message means the device was heard from, at the backend's receipt time
      expect(dashboard.data!.device!.status.lastSeenAt, DateTime.utc(2026, 10, 1, 15, 0, 5, 400));
    });

    liveTest('telemetry: readings the device did not send stay null - never zero, never the previous value', (tester) async {
      final app = appWithDevice();
      await openDashboard(tester, app);
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:00:05Z', data: telemetryData(battery: 64));
      await tester.pump(Duration.zero);
      final point = app.services.dashboard.data!.telemetry!;
      expect(point.batteryPct, 64);
      expect(point.moistureRhPct, isNull);
      expect(point.bollsHarvestedTotal, isNull);
      expect(point.solarActive, isNull);
      expect(point.airTempC, isNull);
    });

    liveTest('detection: label and confidence as reported; nothing else is derived from it', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      expect(dashboard.data!.latestDetection, isNull);
      final event = app.live.ingest(kind: 'event/pest', deviceId: device, ts: '2026-10-01T15:01:00Z', data: {'label': 'leaf_curl_virus', 'confidence': 0.87, 'bbox': [0.1, 0.2, 0.1, 0.1]});
      await tester.pump(Duration.zero);
      final detection = dashboard.data!.latestDetection!;
      expect(detection.id, event['msgId']);
      expect(detection.deviceId, device);
      expect(detection.label, 'leaf_curl_virus');
      expect(detection.confidence, 0.87);
      expect(detection.detectedAt, DateTime.utc(2026, 10, 1, 15, 1));
      expect(dashboard.data!.telemetry!.batteryPct, 66, reason: 'a detection does not touch the readings');
    });

    liveTest('status: online/offline by receipt time; an offline Last Will is not "heard from"', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      expect(dashboard.data!.device!.status.state, 'online');

      // The Last Will carries an old device timestamp; the backend orders status by receipt.
      app.live.ingest(kind: 'status', deviceId: device, ts: '2026-10-01T14:00:00Z', receivedAt: '2026-10-01T15:02:00Z', data: {'state': 'offline'});
      await tester.pump(Duration.zero);
      var status = dashboard.data!.device!.status;
      expect(status.state, 'offline');
      expect(status.stateAt, DateTime.utc(2026, 10, 1, 15, 2));
      expect(status.lastSeenAt, DateTime.utc(2026, 10, 1, 15), reason: 'unchanged by an offline notice');
      expect(dashboard.data!.devices.single.status.state, 'offline', reason: 'the device list shows the same state');

      app.live.ingest(kind: 'status', deviceId: device, ts: '2026-10-01T15:03:00Z', receivedAt: '2026-10-01T15:03:01Z', data: {'state': 'online'});
      await tester.pump(Duration.zero);
      status = dashboard.data!.device!.status;
      expect(status.state, 'online');
      expect(status.lastSeenAt, DateTime.utc(2026, 10, 1, 15, 3, 1));
    });

    liveTest('spray and harvest records change no dashboard value (only "last heard from")', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      final before = dashboard.data!;
      app.live.ingest(kind: 'event/spray', deviceId: device, ts: '2026-10-01T15:04:00Z', data: {'durationMs': 1500});
      app.live.ingest(kind: 'event/harvest', deviceId: device, ts: '2026-10-01T15:04:30Z', data: {'maturity': 'mature', 'picked': true, 'moistureRhPct': 12});
      await tester.pump(Duration.zero);
      final after = dashboard.data!;
      expect(identical(after.telemetry, before.telemetry), isTrue);
      expect(after.telemetry!.moistureRhPct, 40, reason: 'a harvest record\'s moisture is not the sensor reading');
      expect(after.latestDetection, isNull);
      expect(after.device!.status.state, 'online');
      expect(after.device!.status.lastSeenAt, DateTime.utc(2026, 10, 1, 15, 4, 30));
    });

    liveTest('events of the caller\'s other devices are not shown for the selected device', (tester) async {
      final app = appWithDevice(devices: [device, otherDevice]);
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      expect(dashboard.data!.device!.deviceId, device);
      final before = dashboard.data!;
      app.live.ingest(kind: 'telemetry', deviceId: otherDevice, ts: '2026-10-01T16:00:00Z', data: telemetryData(battery: 5, bolls: 999));
      app.live.ingest(kind: 'event/pest', deviceId: otherDevice, ts: '2026-10-01T16:00:00Z', data: {'label': 'bollworm', 'confidence': 0.9});
      app.live.ingest(kind: 'status', deviceId: otherDevice, ts: '2026-10-01T16:00:00Z', data: {'state': 'offline'});
      await tester.pump(Duration.zero);
      expect(identical(dashboard.data, before), isTrue);
    });
  });

  group('unknown and malformed messages', () {
    liveTest('unknown message types and unknown event kinds are ignored', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      final before = dashboard.data!;
      app.live.pushRaw('{"type":"announcement","text":"maintenance at noon"}');
      app.live.pushRaw('{"type":"pong","serverTime":"2026-10-01T15:00:00+00:00"}');
      app.live.ingest(kind: 'event/image', deviceId: device, ts: '2026-10-01T16:00:00Z', data: {'url': 'https://example.test/x.jpg'});
      app.live.ingest(kind: 'alert', deviceId: device, ts: '2026-10-01T16:00:00Z', data: {'severity': 'critical'});
      await tester.pump(Duration.zero);
      expect(identical(dashboard.data, before), isTrue);
      expect(dashboard.liveState, LiveState.connected);
      expect(app.services.live.malformedFrames, 0);
      // the stream is still usable
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T16:00:05Z', data: telemetryData(battery: 61));
      await tester.pump(Duration.zero);
      expect(dashboard.data!.telemetry!.batteryPct, 61);
    });

    liveTest('malformed frames are dropped: no crash, no partial or invented value, connection kept', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      final before = dashboard.data!;
      final frames = [
        'not json',
        '',
        '[]',
        '"event"',
        '{}',
        '{"type":7}',
        '{"type":"event"}',
        '{"type":"event","cursor":"900","kind":"telemetry","deviceId":"$device","msgId":"m","ts":"2026-10-01T16:00:00Z","receivedAt":"2026-10-01T16:00:00Z","data":{"batteryPct":1}}',
        '{"type":"event","cursor":900,"kind":"telemetry","deviceId":"$device","msgId":"m","ts":"yesterday","receivedAt":"2026-10-01T16:00:00Z","data":{"batteryPct":1}}',
        '{"type":"event","cursor":900,"kind":"telemetry","deviceId":"$device","msgId":"m","ts":"2026-10-01T16:00:00Z","receivedAt":"2026-10-01T16:00:00Z","data":[1]}',
        '{"type":"event","cursor":true,"kind":"telemetry","deviceId":"$device","msgId":"m","ts":"2026-10-01T16:00:00Z","receivedAt":"2026-10-01T16:00:00Z","data":{}}',
        '{"type":"resumed","cursor":-1,"replayed":0}',
        '{"type":"error"}',
      ];
      frames.forEach(app.live.pushRaw);
      await tester.pump(Duration.zero);
      expect(app.services.live.malformedFrames, frames.length);
      expect(identical(dashboard.data, before), isTrue);
      expect(dashboard.liveState, LiveState.connected);
      expect(tester.takeException(), isNull);
    });

    liveTest('an event whose data does not match the contract shows nothing from it', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      final before = dashboard.data!;
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T16:00:00Z', data: {'batteryPct': 'ninety', 'bollsHarvestedTotal': 50});
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T16:00:01Z', data: {'moistureRhPct': 'wet'}); // reading of the wrong type
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T16:00:02Z', data: {'batteryPct': 50, 'bollsHarvestedTotal': 12.5});
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T16:00:03Z'); // no data object
      app.live.ingest(kind: 'event/pest', deviceId: device, ts: '2026-10-01T16:00:04Z', data: {'label': 'bollworm'}); // confidence missing
      app.live.ingest(kind: 'event/pest', deviceId: device, ts: '2026-10-01T16:00:05Z', data: {'label': 7, 'confidence': 0.5});
      app.live.ingest(kind: 'status', deviceId: device, ts: '2026-10-01T16:00:06Z', data: {'state': 'sleeping'});
      await tester.pump(Duration.zero);
      expect(identical(dashboard.data, before), isTrue);
      expect(dashboard.data!.telemetry!.bollsHarvestedTotal, 10);
      expect(dashboard.liveState, LiveState.connected);
      expect(tester.takeException(), isNull);
    });

    test('message parsing: contract messages become typed models; anything else is a FormatException', () {
      final hello = LiveMessage.parse('{"type":"hello","protocol":"gossy.ws.v1","serverTime":"2026-10-01T15:00:00+00:00","latestCursor":4812,"tokenExpiresAt":"2026-10-01T15:15:00+00:00","heartbeatIntervalS":25.0,"allowedOps":["start","resume","ping"]}') as LiveHello;
      expect(hello.protocol, liveProtocol);
      expect(hello.latestCursor, 4812);
      expect(hello.heartbeatInterval, const Duration(seconds: 25));
      // the example of the contract document
      final event = LiveMessage.parse('{"type":"event","cursor":4812,"kind":"event/pest","deviceId":"sim-0002","msgId":"01K6CQ4W0D8V9J4Q9W2Y1S7ZPX","ts":"2026-09-30T10:15:02.412000+00:00","receivedAt":"2026-09-30T10:15:02.530114+00:00",'
          '"data":{"label":"bollworm","confidence":0.87,"bbox":[0.1,0.2,0.1,0.1]},"alerts":[{"id":"x","type":"pest_detected","severity":"warning","status":"open"}]}') as LiveEvent;
      expect(event.cursor, 4812);
      expect(event.kind, LiveEvent.pest);
      expect(event.ts, DateTime.utc(2026, 9, 30, 10, 15, 2, 412));
      expect(event.receivedAt, DateTime.utc(2026, 9, 30, 10, 15, 2, 530, 114));
      expect(event.toDetection().label, 'bollworm');
      expect(event.toDetection().id, '01K6CQ4W0D8V9J4Q9W2Y1S7ZPX');
      expect((LiveMessage.parse('{"type":"resumed","cursor":12,"replayed":3}') as LiveResumed).replayed, 3);
      expect(LiveMessage.parse('{"type":"resync_required","latestCursor":9,"message":"x"}'), isA<LiveResyncRequired>());
      expect(LiveMessage.parse('{"type":"heartbeat","serverTime":"x","cursor":1}'), isA<LiveHeartbeat>());
      expect((LiveMessage.parse('{"type":"error","code":"token_expired","message":"x"}') as LiveError).code, LiveError.tokenExpired);
      expect((LiveMessage.parse('{"type":"something_new"}') as LiveUnknown).type, 'something_new');
      for (final bad in ['nope', '[1]', '{"type":"hello","protocol":"gossy.ws.v1","latestCursor":1,"heartbeatIntervalS":0}', '{"type":"hello","protocol":"gossy.ws.v1","latestCursor":1.5,"heartbeatIntervalS":25}']) {
        expect(() => LiveMessage.parse(bad), throwsFormatException, reason: bad);
      }
    });
  });

  group('ordering: REST and live', () {
    liveTest('a stale or duplicate event never replaces newer data', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      app.backend.detections[device] = [FakeBackend.detectionRow(deviceId: device, detectedAt: '2026-10-01T14:50:00Z', label: 'bollworm', confidence: 0.9)];
      await openDashboard(tester, app);

      // An offline replay delivers an OLD reading with a NEW cursor (the backend accepts late data).
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T14:00:00Z', data: telemetryData(battery: 99, bolls: 1));
      app.live.ingest(kind: 'event/pest', deviceId: device, ts: '2026-10-01T14:00:00Z', data: {'label': 'aphid', 'confidence': 0.5});
      // The very row the REST snapshot already shows.
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:00:00Z', msgId: '01K6CQ4W0D8V9J4Q9W2Y000001', data: telemetryData(battery: 1));
      await tester.pump(Duration.zero);
      expect(dashboard.data!.telemetry!.batteryPct, 66);
      expect(dashboard.data!.telemetry!.bollsHarvestedTotal, 10);
      expect(dashboard.data!.latestDetection!.label, 'bollworm');

      // Same device time: the REST order (time, then message id) decides.
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:00:00Z', msgId: '01K6CQ4W0D8V9J4Q9W2Y000000', data: telemetryData(battery: 2));
      await tester.pump(Duration.zero);
      expect(dashboard.data!.telemetry!.batteryPct, 66);
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:00:00Z', msgId: '01K6CQ4W0D8V9J4Q9W2Y000002', data: telemetryData(battery: 67));
      await tester.pump(Duration.zero);
      expect(dashboard.data!.telemetry!.batteryPct, 67);

      // An older status does not replace a newer one.
      app.live.ingest(kind: 'status', deviceId: device, ts: '2026-10-01T13:00:00Z', receivedAt: '2026-10-01T13:00:00Z', data: {'state': 'offline'});
      await tester.pump(Duration.zero);
      expect(dashboard.data!.device!.status.state, 'online');
    });

    liveTest('an event the connection has already processed (cursor not greater) is dropped', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      final event = app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:00:05Z', data: telemetryData(battery: 60));
      await tester.pump(Duration.zero);
      var notified = 0;
      dashboard.addListener(() => notified++);
      // the same cursor again, with other content: must not be applied
      app.live.openSockets.single.push({...event, 'ts': '2026-10-01T15:00:09Z', 'msgId': '01K6CQ4W0D8V9J4Q9W2Y999999', 'data': telemetryData(battery: 1)});
      await tester.pump(Duration.zero);
      expect(dashboard.data!.telemetry!.batteryPct, 60);
      expect(notified, 0);
    });

    liveTest('a REST reply that is older than a live value does not bring the old value back', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:00:10Z', data: telemetryData(battery: 62, bolls: 12));
      app.live.ingest(kind: 'event/pest', deviceId: device, ts: '2026-10-01T15:00:11Z', data: {'label': 'bollworm', 'confidence': 0.8});
      app.live.ingest(kind: 'status', deviceId: device, ts: '2026-10-01T15:00:12Z', receivedAt: '2026-10-01T15:00:12Z', data: {'state': 'offline'});
      await tester.pump(Duration.zero);

      // The fake REST backend still answers with the state from before those events.
      await settle(tester, dashboard.load());
      expect(dashboard.data!.telemetry!.batteryPct, 62);
      expect(dashboard.data!.telemetry!.bollsHarvestedTotal, 12);
      expect(dashboard.data!.latestDetection!.label, 'bollworm');
      expect(dashboard.data!.device!.status.state, 'offline');
      expect(dashboard.data!.device!.status.lastSeenAt, DateTime.utc(2026, 10, 1, 15, 0, 11));

      // Once REST has caught up - or is ahead - its values are shown.
      app.backend.telemetry[device]!.insert(0, FakeBackend.telemetryRow(time: '2026-10-01T15:00:20Z', batteryPct: 58, bollsHarvestedTotal: 13, msgId: '01K6CQ4W0D8V9J4Q9W2Y000009'));
      await settle(tester, dashboard.load());
      expect(dashboard.data!.telemetry!.batteryPct, 58);
      expect(dashboard.data!.telemetry!.bollsHarvestedTotal, 13);
    });

    liveTest('without live values a refresh shows exactly what REST returns (Phase 3B behaviour)', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      // REST now returns an OLDER row than before (e.g. a row was removed on the backend).
      app.backend.telemetry[device] = [FakeBackend.telemetryRow(time: '2026-10-01T12:00:00Z', batteryPct: 33, msgId: '01K6CQ4W0D8V9J4Q9W2Y000000')];
      await settle(tester, dashboard.load());
      expect(dashboard.data!.telemetry!.batteryPct, 33);
      app.backend.telemetry.clear();
      await settle(tester, dashboard.load());
      expect(dashboard.data!.telemetry, isNull);
    });

    liveTest('events ingested between the REST snapshot and the start of the stream are not lost', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      dashboard.attachLive();
      app.live.talkative = false; // the upgrade succeeds but the stream has not started yet
      await settle(tester, dashboard.load());
      await tester.pump(Duration.zero);
      expect(dashboard.data!.telemetry!.batteryPct, 66);
      final callsAfterSnapshot = app.backend.calls.length;

      // Ingested now: after the snapshot, before `start`. No live event will ever carry it.
      app.backend.telemetry[device]!.insert(0, FakeBackend.telemetryRow(time: '2026-10-01T15:00:03Z', batteryPct: 65, msgId: '01K6CQ4W0D8V9J4Q9W2Y000005'));
      app.live.openSockets.single.push({'type': 'hello', 'protocol': 'gossy.ws.v1', 'serverTime': 'x', 'latestCursor': 100, 'tokenExpiresAt': 'x', 'heartbeatIntervalS': 25, 'allowedOps': ['start', 'resume', 'ping']});
      await tester.pump(Duration.zero);

      expect(dashboard.liveState, LiveState.connected);
      expect(dashboard.data!.telemetry!.batteryPct, 65, reason: 'read again over REST once the stream was live');
      expect(app.backend.calls.length, callsAfterSnapshot + 3);
      expect(dashboard.busy, isFalse);
    });
  });

  group('disconnects, backoff and resume', () {
    liveTest('a lost connection keeps the last values and is retried with bounded exponential backoff', (tester) async {
      final random = FixedRandom(1.0); // top of the jitter range: the ceiling itself
      final app = appWithDevice(random: random);
      final dashboard = app.services.dashboard;
      final live = app.services.live;
      await openDashboard(tester, app);
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:00:05Z', data: telemetryData(battery: 64, bolls: 11));
      await tester.pump(Duration.zero);
      final shown = dashboard.data!;

      app.live.outage = LiveOutage.offline;
      app.live.dropAll(code: 1011);
      await tester.pump(Duration.zero);
      expect(dashboard.liveState, LiveState.reconnecting);
      expect(identical(dashboard.data, shown), isTrue, reason: 'nothing is erased by a disconnect');
      expect(dashboard.failure, isNull, reason: 'a live disconnect is not a load failure');
      expect(dashboard.phase, DashboardPhase.ready);

      // 1 s, 2 s, 4 s, 8 s, 16 s, then never more than 30 s.
      final expected = [1, 2, 4, 8, 16, 30, 30, 30];
      var attempts = app.live.attempts.length;
      for (final seconds in expected) {
        expect(live.lastRetryDelay, Duration(seconds: seconds));
        await tester.pump(Duration(seconds: seconds) - const Duration(milliseconds: 1));
        expect(app.live.attempts.length, attempts, reason: 'no attempt before the ${seconds}s delay has passed');
        await tester.pump(const Duration(milliseconds: 1));
        expect(app.live.attempts.length, ++attempts);
      }
      expect(app.live.openSockets, isEmpty);
      expect(identical(dashboard.data, shown), isTrue);

      // The jitter: at the bottom of the range the delay is half the ceiling - never zero.
      random.value = 0.0;
      await tester.pump(const Duration(seconds: 30));
      expect(live.lastRetryDelay, const Duration(seconds: 15));
      random.value = 0.5;
      await tester.pump(const Duration(seconds: 15));
      expect(live.lastRetryDelay, const Duration(milliseconds: 22500));
      expect(live.lastRetryDelay! <= live.maxDelay, isTrue);
    });

    liveTest('the first retry is never immediate: no tight loop even at the lowest jitter', (tester) async {
      final app = appWithDevice(random: FixedRandom(0.0));
      app.live.outage = LiveOutage.offline;
      await openDashboard(tester, app);
      expect(app.live.attempts, hasLength(1));
      expect(app.services.live.lastRetryDelay, const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 499));
      expect(app.live.attempts, hasLength(1));
      // In one hour of a dead server: at most one attempt per 15 s once the ceiling is reached.
      await tester.pump(const Duration(hours: 1));
      expect(app.live.attempts.length, lessThan(3600 ~/ 15 + 8));
      expect(app.live.attempts.length, greaterThan(200));
    });

    liveTest('reconnecting resumes from the last cursor: missed events arrive once, in order', (tester) async {
      final app = appWithDevice(random: FixedRandom(1.0));
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      final seen = app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:00:05Z', data: telemetryData(battery: 64));
      await tester.pump(Duration.zero);
      final restCalls = app.backend.calls.length;

      app.live.dropAll(code: 1011);
      await tester.pump(Duration.zero);
      // ingested while the app is disconnected
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:00:10Z', data: telemetryData(battery: 63));
      app.live.ingest(kind: 'event/pest', deviceId: device, ts: '2026-10-01T15:00:12Z', data: {'label': 'bollworm', 'confidence': 0.7});
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:00:15Z', data: telemetryData(battery: 62));
      expect(dashboard.data!.telemetry!.batteryPct, 64);

      await tester.pump(const Duration(seconds: 1));
      expect(dashboard.liveState, LiveState.connected);
      expect(app.live.sockets.last.received, [{'op': 'resume', 'cursor': seen['cursor']}]);
      expect(dashboard.data!.telemetry!.batteryPct, 62);
      expect(dashboard.data!.latestDetection!.label, 'bollworm');
      expect(app.backend.calls.length, restCalls, reason: 'a resume needs no REST reload');
      expect(app.live.openSockets, hasLength(1));
    });

    liveTest('a healthy connection resets the backoff; a flapping one does not', (tester) async {
      final app = appWithDevice(random: FixedRandom(1.0));
      final live = app.services.live;
      await openDashboard(tester, app);

      // Flapping: the server accepts and drops at once, again and again.
      final delays = <Duration>[];
      for (var i = 0; i < 4; i++) {
        app.live.dropAll(code: 1011);
        await tester.pump(Duration.zero);
        delays.add(live.lastRetryDelay!);
        await tester.pump(live.lastRetryDelay!);
        expect(app.services.dashboard.liveState, LiveState.connected);
      }
      expect(delays, const [Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 4), Duration(seconds: 8)]);

      // Stable for a while: the next loss starts again at the first delay.
      await tester.pump(const Duration(seconds: 11));
      app.live.dropAll(code: 1011);
      await tester.pump(Duration.zero);
      expect(live.lastRetryDelay, const Duration(seconds: 1));
    });

    liveTest('repeated failures never create a second socket or a second retry timer', (tester) async {
      final app = appWithDevice(random: FixedRandom(1.0));
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      for (var round = 0; round < 6; round++) {
        app.live.dropAll(code: round.isEven ? 1011 : null);
        // refreshes, rebuild-style re-attachments and state notifications during the outage
        dashboard.attachLive();
        await settle(tester, dashboard.load());
        dashboard.attachLive();
        await tester.pump(const Duration(seconds: 40));
        expect(app.live.openSockets, hasLength(1), reason: 'round $round');
        expect(dashboard.liveState, LiveState.connected);
      }
      // one attempt per loss, plus the first connection
      expect(app.live.attempts, hasLength(7));
      expect(app.live.sockets.where((s) => s.isOpen), hasLength(1));
    });

    liveTest('a silent connection (no heartbeat) is treated as lost and replaced', (tester) async {
      final app = appWithDevice(random: FixedRandom(1.0));
      await openDashboard(tester, app);
      final first = app.live.sockets.single;
      first.serverGoesSilent();
      // heartbeat every 25 s: after two missed ones plus slack (55 s) the socket is given up
      await tester.pump(const Duration(seconds: 54));
      expect(first.isOpen, isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(first.closedByClient, isTrue);
      expect(app.services.dashboard.liveState, LiveState.reconnecting);
      await tester.pump(const Duration(seconds: 1));
      expect(app.services.dashboard.liveState, LiveState.connected);
      expect(app.live.openSockets, hasLength(1));
    });

    liveTest('an upgrade that never answers times out and is retried; a late socket is closed', (tester) async {
      final app = appWithDevice(random: FixedRandom(1.0));
      app.live.outage = LiveOutage.hang;
      await openDashboard(tester, app);
      expect(app.services.dashboard.liveState, LiveState.connecting);
      await tester.pump(const Duration(seconds: 10));
      expect(app.services.dashboard.liveState, LiveState.reconnecting);
      app.live.outage = LiveOutage.none;
      await tester.pump(const Duration(seconds: 1));
      expect(app.services.dashboard.liveState, LiveState.connected);
      expect(app.live.openSockets, hasLength(1));
    });

    liveTest('resync_required: delivery restarts from now and the state is re-read over REST', (tester) async {
      final app = appWithDevice(random: FixedRandom(1.0));
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      app.live.dropAll(code: 4008); // slow consumer
      await tester.pump(Duration.zero);
      app.live.replayLimit = 2;
      for (var i = 1; i <= 5; i++) {
        app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:01:0${i}Z', data: telemetryData(battery: 60 - i));
      }
      // what REST returns for those missed messages
      app.backend.telemetry[device]!.insert(0, FakeBackend.telemetryRow(time: '2026-10-01T15:01:05Z', batteryPct: 55, msgId: '01K6CQ4W0D8V9J4Q9W2Y000105'));
      final restCalls = app.backend.calls.length;
      await tester.pump(const Duration(seconds: 1));
      expect(app.live.sockets.last.received, [{'op': 'resume', 'cursor': 100}, {'op': 'start'}]);
      expect(dashboard.liveState, LiveState.connected);
      expect(dashboard.data!.telemetry!.batteryPct, 55);
      expect(app.backend.calls.length, restCalls + 3);
    });
  });

  group('session', () {
    liveTest('access token expired: one refresh through the Phase 3A mechanism, then resume', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      final oldToken = app.tokens.session!.accessToken;
      final cursor = app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:00:05Z', data: telemetryData(battery: 64))['cursor'];
      await tester.pump(Duration.zero);

      app.backend.expireAccessToken();
      app.live.expireTokens(); // error/token_expired + close 4401
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);

      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
      expect(app.tokens.session!.accessToken, isNot(oldToken));
      expect(app.live.attempts.last.headers['Authorization'], 'Bearer ${app.tokens.session!.accessToken}');
      expect(app.live.sockets.last.received, [{'op': 'resume', 'cursor': cursor}]);
      expect(dashboard.liveState, LiveState.connected);
      expect(dashboard.data!.telemetry!.batteryPct, 64);
      expect(app.services.session.status, isNot(SessionStatus.signedOut));
      expect(app.live.openSockets, hasLength(1));
    });

    liveTest('live channel and REST need a new token at the same moment: exactly one refresh request', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      app.backend.refreshDelay = const Duration(seconds: 2);
      app.backend.expireAccessToken();

      app.live.expireTokens();
      final loads = [dashboard.load(), app.services.onboarding.listDevices(), app.services.onboarding.listFarms()];
      await tester.pump(const Duration(seconds: 1));
      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1, reason: 'all callers wait for the same request');
      await tester.pump(const Duration(seconds: 2));
      await settle(tester, Future.wait(loads));
      await tester.pump(Duration.zero);

      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
      expect(app.services.api.interceptor.refreshRequests, 1);
      expect(app.tokens.writes, 1);
      expect(dashboard.liveState, LiveState.connected);
      expect(dashboard.failure, isNull);
      expect(app.backend.sessionRevoked, isFalse, reason: 'no rotated refresh token was presented twice');
      expect(app.live.attempts.last.headers['Authorization'], 'Bearer ${app.tokens.session!.accessToken}');
    });

    liveTest('handshake refused because the token expired while disconnected: refreshed once, connected', (tester) async {
      final app = appWithDevice(random: FixedRandom(1.0));
      await openDashboard(tester, app);
      app.live.dropAll(); // network loss, no close frame
      app.backend.expireAccessToken();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(Duration.zero);
      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
      expect(app.services.dashboard.liveState, LiveState.connected);
      expect(app.live.openSockets, hasLength(1));
    });

    liveTest('session revoked: the refresh is rejected, the session is ended by Phase 3A, nothing reconnects', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      var forcedSignOuts = 0;
      app.services.session.onForcedSignOut = () => forcedSignOuts++;
      await settle(tester, app.services.session.restore());
      await openDashboard(tester, app);
      final attempts = app.live.attempts.length;

      app.backend
        ..expireAccessToken()
        ..sessionRevoked = true;
      app.live.revokeSessions(); // error/session_revoked + close 4401
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);

      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
      expect(app.tokens.session, isNull);
      expect(app.tokens.clears, 1);
      expect(app.services.session.status, SessionStatus.signedOut);
      expect(forcedSignOuts, 1);
      expect(dashboard.data, isNull);
      expect(dashboard.phase, DashboardPhase.idle);
      expect(dashboard.liveState, LiveState.disconnected);
      expect(app.live.openSockets, isEmpty);
      await tester.pump(const Duration(hours: 1));
      expect(app.live.attempts.length, attempts, reason: 'no upgrade is attempted without a session');
      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1, reason: 'a rejected refresh is never repeated');
    });

    liveTest('a token the live channel keeps refusing is not retried in a loop', (tester) async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      final shown = dashboard.data!;
      app.live.refuseUpgrades = true;
      app.live.expireTokens();
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);

      // one renewal, one more upgrade with the renewed token, then it stops
      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
      expect(dashboard.liveState, LiveState.authFailed);
      expect(app.live.attempts.length, 2);
      // Phase 4: nothing at once, and nothing for the first minute ...
      await tester.pump(const Duration(seconds: 59));
      expect(app.live.attempts.length, 2);
      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
      // ... then three later tries (after 1, 5 and 15 minutes; each is one connection with the
      // current token and one with a renewed one), and after those it stays off: never a loop.
      await tester.pump(const Duration(hours: 1));
      expect(app.live.attempts.length, 2 + 3 * 2);
      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1 + 3);
      expect(dashboard.liveState, LiveState.authFailed);
      await tester.pump(const Duration(hours: 24));
      expect(app.live.attempts.length, 2 + 3 * 2);
      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1 + 3);
      // the REST session is untouched and so are the values
      expect(app.services.session.status, isNot(SessionStatus.signedOut));
      expect(app.tokens.session, isNotNull);
      expect(identical(dashboard.data, shown), isTrue);

      // a refresh by the user tries the live channel again
      app.live.refuseUpgrades = false;
      await settle(tester, dashboard.load());
      await tester.pump(Duration.zero);
      expect(dashboard.liveState, LiveState.connected);
    });

    liveTest('backend unreachable while renewing the token: session kept, retried with backoff', (tester) async {
      final app = appWithDevice(random: FixedRandom(1.0));
      await openDashboard(tester, app);
      app.backend.expireAccessToken();
      app.backend.outage = Outage.offline;
      app.live.expireTokens();
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);
      expect(app.services.dashboard.liveState, LiveState.reconnecting);
      expect(app.tokens.session, isNotNull, reason: 'a network failure does not end the session');
      expect(app.services.live.lastRetryDelay, const Duration(seconds: 1));
      app.backend.outage = Outage.none;
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(Duration.zero);
      expect(app.services.dashboard.liveState, LiveState.connected);
    });

    liveTest('logout closes the socket and cancels the reconnection', (tester) async {
      final app = appWithDevice(random: FixedRandom(1.0));
      await settle(tester, app.services.session.restore());
      await openDashboard(tester, app);
      final socket = app.live.sockets.single;
      await settle(tester, app.services.session.logout());
      await tester.pump(Duration.zero);
      expect(socket.closedByClient, isTrue);
      expect(app.live.openSockets, isEmpty);
      expect(app.services.dashboard.liveState, LiveState.disconnected);
      expect(app.services.dashboard.data, isNull);

      // ... also when the logout happens while a retry is pending
      final second = appWithDevice(random: FixedRandom(1.0));
      await settle(tester, second.services.session.restore());
      await openDashboard(tester, second);
      second.live.outage = LiveOutage.offline;
      second.live.dropAll(code: 1011);
      await tester.pump(Duration.zero);
      expect(second.services.dashboard.liveState, LiveState.reconnecting);
      final attempts = second.live.attempts.length;
      await settle(tester, second.services.session.logout());
      await tester.pump(const Duration(hours: 1));
      expect(second.live.attempts.length, attempts);
      expect(second.services.dashboard.liveState, LiveState.disconnected);
    });
  });

  group('device scope', () {
    liveTest('switching device closes the old connection before the new snapshot and stream', (tester) async {
      final app = appWithDevice(devices: [device, otherDevice]);
      app.backend.telemetry[otherDevice] = [FakeBackend.telemetryRow(time: '2026-10-01T14:00:00Z', batteryPct: 22, msgId: '01K6CQ4W0D8V9J4Q9W2Y000050')];
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      final first = app.live.sockets.single;
      app.live.ingest(kind: 'event/pest', deviceId: device, ts: '2026-10-01T15:00:11Z', data: {'label': 'bollworm', 'confidence': 0.8});
      await tester.pump(Duration.zero);
      expect(dashboard.data!.latestDetection, isNotNull);

      final restBefore = app.backend.calls.length;
      final switching = dashboard.selectDevice(otherDevice);
      // synchronously: the old socket is closed and nothing of the old device is shown
      expect(first.closedByClient, isTrue);
      expect(app.live.openSockets, isEmpty);
      expect(dashboard.data, isNull);
      expect(dashboard.liveState, LiveState.disconnected);
      expect(app.live.attempts, hasLength(1), reason: 'the new connection waits for the new snapshot');
      await settle(tester, switching);
      await tester.pump(Duration.zero);

      expect(dashboard.data!.device!.deviceId, otherDevice);
      expect(dashboard.data!.telemetry!.batteryPct, 22);
      expect(dashboard.data!.latestDetection, isNull);
      expect(app.backend.calls.skip(restBefore).take(3).map((c) => c.path), ['/api/v1/devices', '/api/v1/devices/$otherDevice/telemetry', '/api/v1/detections']);
      expect(app.live.attempts, hasLength(2));
      expect(app.live.openSockets, hasLength(1));
      expect(app.live.sockets.last.received, [{'op': 'start'}], reason: 'a fresh stream, not a resume of the other device\'s cursor');

      // the new stream shows the new device's events and ignores the old device's
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T16:00:00Z', data: telemetryData(battery: 99));
      app.live.ingest(kind: 'telemetry', deviceId: otherDevice, ts: '2026-10-01T16:00:01Z', data: telemetryData(battery: 21));
      await tester.pump(Duration.zero);
      expect(dashboard.data!.telemetry!.batteryPct, 21);
    });

    liveTest('no device: no live connection; a device that disappears closes it', (tester) async {
      final app = appWithDevice();
      await openDashboard(tester, app);
      expect(app.live.openSockets, hasLength(1));
      app.backend.devices.clear();
      await settle(tester, app.services.dashboard.load());
      await tester.pump(Duration.zero);
      expect(app.services.dashboard.data!.device, isNull);
      expect(app.live.openSockets, isEmpty);
      expect(app.services.dashboard.liveState, LiveState.disconnected);
    });
  });

  group('monitoring-only boundary', () {
    liveTest('the app sends nothing but start and resume, whatever happens on the channel', (tester) async {
      final app = appWithDevice(random: FixedRandom(1.0), devices: [device, otherDevice]);
      final dashboard = app.services.dashboard;
      await openDashboard(tester, app);
      // a busy session: events of every kind, junk, errors, drops, token expiry, device switch
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:00:05Z', data: telemetryData(battery: 64));
      app.live.ingest(kind: 'event/pest', deviceId: device, ts: '2026-10-01T15:00:06Z', data: {'label': 'bollworm', 'confidence': 0.9});
      app.live.ingest(kind: 'event/spray', deviceId: device, ts: '2026-10-01T15:00:07Z', data: {'durationMs': 1500});
      app.live.ingest(kind: 'event/harvest', deviceId: device, ts: '2026-10-01T15:00:08Z', data: {'maturity': 'mature', 'picked': true});
      app.live.ingest(kind: 'status', deviceId: device, ts: '2026-10-01T15:00:09Z', data: {'state': 'offline'});
      app.live.pushRaw('{"type":"error","code":"unsupported_op","message":"x"}');
      app.live.pushRaw('{"type":"command_request","op":"spray"}');
      app.live.pushRaw('garbage');
      await tester.pump(Duration.zero);
      app.live.dropAll(code: 1011);
      await tester.pump(const Duration(seconds: 2));
      app.backend.expireAccessToken();
      app.live.expireTokens();
      await tester.pump(const Duration(seconds: 2));
      await settle(tester, dashboard.selectDevice(otherDevice));
      await tester.pump(const Duration(minutes: 5)); // heartbeats
      await settle(tester, dashboard.load());
      await tester.pump(Duration.zero);

      expect(app.live.sockets.length, greaterThanOrEqualTo(4));
      for (final frame in app.live.clientFrames) {
        final message = frame! as Map;
        expect(message['op'], anyOf('start', 'resume'), reason: '$message');
        expect(message.keys.toSet().difference({'op', 'cursor'}), isEmpty, reason: '$message');
        if (message['op'] == 'resume') expect(message['cursor'], isA<int>());
        if (message['op'] == 'start') expect(message, {'op': 'start'});
      }
      // one frame per connection: nothing is sent after delivery has begun
      for (final socket in app.live.sockets) {
        expect(socket.received.length, lessThanOrEqualTo(1));
      }
    });

    test('the code has one place that writes to the socket, and it can only write start or resume', () {
      final connection = File('lib/core/realtime/live_connection.dart').readAsStringSync();
      expect(RegExp(r'\.send\(').allMatches(connection), hasLength(1));
      expect(connection, contains('enum _ClientOp { start, resume }'));
      expect(RegExp(r"'op':\s*'(\w+)'").allMatches(connection).map((m) => m.group(1)).toSet(), {'start', 'resume'});
      // no public way to send: the only sender is private, and no other file touches a socket sink
      expect(RegExp(r'^\s+(?:Future<void>|void)\s+send\w*\(', multiLine: true).hasMatch(connection), isFalse);
      final sources = Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));
      final writers = [
        for (final file in sources)
          if (RegExp(r'sink\.add|\.send\(|WebSocket\.connect|IOWebSocketChannel|MqttClient|package:mqtt|package:flutter_blue|BluetoothDevice', caseSensitive: false).hasMatch(file.readAsStringSync())) file.path.replaceAll('\\', '/'),
      ]..sort();
      expect(writers, ['lib/core/realtime/live_connection.dart', 'lib/core/realtime/live_socket.dart']);
      // and no device-control vocabulary anywhere in the live channel code
      for (final file in Directory('lib/core/realtime').listSync().whereType<File>()) {
        final code = file.readAsStringSync().replaceAll(RegExp(r'//.*'), '');
        for (final word in ['command', 'actuator', 'publish', 'motor']) {
          expect(code.toLowerCase(), isNot(contains(word)), reason: '${file.path}: $word');
        }
      }
    });
  });

  group('tokens and device ids in code and output', () {
    test('no access or refresh token is printed or put into an error text', () async {
      final printed = <String>[];
      final previousDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) => printed.add('$message');
      addTearDown(() => debugPrint = previousDebugPrint);
      final errors = <Object>[];
      late TestApp app;
      final oldTokens = <String>[];
      await runZonedGuarded(() async {
        app = appWithDevice(random: FixedRandom(0.0));
        final dashboard = app.services.dashboard..attachLive();
        await dashboard.load();
        await pumpEventQueue();
        oldTokens.addAll([app.tokens.session!.accessToken, app.tokens.session!.refreshToken]);
        app.live.ingest(kind: 'telemetry', deviceId: device, ts: '2026-10-01T15:00:05Z', data: telemetryData(battery: 64));
        app.live.pushRaw('garbage');
        // token expiry -> refresh -> resume
        app.backend.expireAccessToken();
        app.live.expireTokens();
        await pumpEventQueue();
        oldTokens.addAll([app.tokens.session!.accessToken, app.tokens.session!.refreshToken]);
        expect(dashboard.liveState, LiveState.connected);
        // refused upgrades, connection failures
        app.live.refuseUpgrades = true;
        app.live.expireTokens();
        await pumpEventQueue();
        oldTokens.addAll([app.tokens.session!.accessToken, app.tokens.session!.refreshToken]);
        app.live.refuseUpgrades = false;
        app.live.outage = LiveOutage.offline;
        await dashboard.load();
        await pumpEventQueue();
        // revoked session
        app.live.outage = LiveOutage.none;
        app.backend.sessionRevoked = true;
        await dashboard.load();
        await pumpEventQueue();
        dashboard.detachLive();
        printed.add('${app.services.live.state} ${dashboard.failure} ${const LiveConnectFailed()} ${const LiveHandshakeRejected()}');
      }, (error, stack) => errors.add(error), zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) => printed.add(line)));

      expect(errors, isEmpty);
      expect(oldTokens.toSet().length, greaterThanOrEqualTo(4));
      final output = printed.join('\n');
      for (final token in oldTokens) {
        expect(output, isNot(contains(token)));
      }
      expect(output, isNot(contains('Bearer')));
      expect(output, isNot(contains('refresh-token')));
    });

    test('the live channel code has no logging and never puts a token into a URL', () {
      for (final file in Directory('lib/core/realtime').listSync().whereType<File>()) {
        final code = file.readAsStringSync();
        for (final call in ['print(', 'debugPrint(', 'log(', 'dart:developer', 'Logger', 'queryParameters', '?token', 'access_token']) {
          expect(code, isNot(contains(call)), reason: '${file.path}: $call');
        }
      }
      // the bearer header is built in exactly one place
      expect(RegExp('Bearer').allMatches(File('lib/core/realtime/live_connection.dart').readAsStringSync().replaceAll(RegExp(r'///.*'), '')), hasLength(1));
    });

    test('no device id is written into the app code', () {
      // Device ids follow ^[a-z0-9][a-z0-9-]{2,63}$ and real ones look like bb-000123 / sim-0001.
      final literal = RegExp(r'''['"]((?:bb|sim|it|dev|unit|device)-[a-z0-9-]+)['"]''');
      final assigned = RegExp(r'''deviceId\s*(?::|=|==)\s*['"][^'"$]+['"]''');
      final sources = Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')).toList();
      expect(sources.length, greaterThan(20));
      for (final file in sources) {
        final code = file.readAsStringSync();
        expect(literal.allMatches(code).map((m) => m.group(1)), isEmpty, reason: file.path);
        expect(assigned.allMatches(code).map((m) => m.group(0)), isEmpty, reason: file.path);
      }
    });

    test('ApiFailure and live exceptions carry no request detail', () {
      expect(const LiveConnectFailed().toString(), 'LiveConnectFailed');
      expect(const LiveHandshakeRejected().toString(), 'LiveHandshakeRejected');
      expect(const ApiFailure.sessionExpired().toString(), isNot(contains('Bearer')));
    });
  });
}
