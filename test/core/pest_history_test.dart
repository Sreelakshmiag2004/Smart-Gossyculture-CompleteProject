// Phase 5C: the Pest page's history (lib/core/pest) - detection history and spray history of
// the dashboard's selected device over REST, and the rows that event/pest and event/spray
// events of the dashboard's existing live connection add - against the fakes that follow the
// backend contracts (test/support/fake_backend.dart, fake_live.dart).
//
// testWidgets is used for its controllable clock; no widget is involved here. The page is
// covered by test/ui/pest_page_test.dart.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/api/api_failure.dart';
import 'package:smart_gossy_culture_app/core/auth/session_controller.dart';
import 'package:smart_gossy_culture_app/core/models.dart';
import 'package:smart_gossy_culture_app/core/pest/pest_history_controller.dart';
import 'package:smart_gossy_culture_app/core/realtime/live_connection.dart';
import 'package:smart_gossy_culture_app/core/realtime/live_messages.dart';

import '../support/fake_backend.dart';
import '../support/fake_live.dart';

const device = 'unit-a';
const otherDevice = 'unit-b';
const page = Object();

String detId(int n) => '01K6CQ4W0D8V9J4Q9W2YDET${n.toString().padLeft(3, '0')}';
String sprayId(int n) => '01K6CQ4W0D8V9J4Q9W2YSPR${n.toString().padLeft(3, '0')}';

/// Minute [n] of the test hour: a larger n is a newer row.
String at(int n) => '2026-10-01T${(10 + n ~/ 60).toString().padLeft(2, '0')}:${(n % 60).toString().padLeft(2, '0')}:00Z';

Map<String, Object?> det(int n, {String deviceId = device, String label = 'bollworm', num confidence = 0.87}) =>
    FakeBackend.detectionRow(id: detId(n), deviceId: deviceId, detectedAt: at(n), label: label, confidence: confidence);

Map<String, Object?> spray(int n, {String deviceId = device, Object? durationMs = 1500}) => FakeBackend.sprayRow(deviceId: deviceId, time: at(n), msgId: sprayId(n), durationMs: durationMs);

final List<TestApp> _apps = [];

/// Ends the way the pages do when they are disposed; a surviving timer fails the test.
void liveTest(String description, Future<void> Function(WidgetTester tester) body) {
  testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      for (final app in _apps) {
        app.services.pestHistory.detach(page);
        app.services.dashboard.detachLive(page);
      }
      _apps.clear();
      await tester.pump(Duration.zero);
    }
  });
}

/// A signed-in farmer with two devices; [device] is the one the dashboard selects.
TestApp appWithDevices() {
  final app = TestApp(random: FixedRandom(1.0))..signIn();
  _apps.add(app);
  app.backend.farms.add({'id': 'farm-1', 'name': 'North field', 'createdAt': '2026-10-01T00:00:00Z'});
  for (final (index, id) in [device, otherDevice].indexed) {
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

/// What the Pest page does when it opens: the dashboard's connection kept in use, the
/// dashboard's snapshot read if needed, then both lists.
Future<void> openPest(WidgetTester tester, TestApp app) async {
  final services = app.services;
  services.dashboard.attachLive(page);
  services.pestHistory.attach(page);
  await settle(tester, services.dashboard.load());
  await settle(tester, services.pestHistory.load());
  // the stream starts "from now": both lists are read once more
  for (var i = 0; i < 6; i++) {
    await tester.pump(Duration.zero);
  }
}

Iterable<RecordedCall> detectionCalls(TestApp app) => app.backend.calls.where((c) => c.path == '/api/v1/detections' && c.query['limit'] != '1');
Iterable<RecordedCall> eventCalls(TestApp app) => app.backend.calls.where((c) => c.path.endsWith('/events'));
int historyCalls(TestApp app) => detectionCalls(app).length + eventCalls(app).length;

void livePest(TestApp app, int n, {String deviceId = device, String label = 'bollworm'}) =>
    app.live.ingest(kind: 'event/pest', deviceId: deviceId, ts: at(n), msgId: detId(n), data: {'label': label, 'confidence': 0.91, 'bbox': [0.1, 0.2, 0.1, 0.1]});

void liveSpray(TestApp app, int n, {String deviceId = device}) => app.live.ingest(kind: 'event/spray', deviceId: deviceId, ts: at(n), msgId: sprayId(n), data: {'durationMs': 1200, 'relatedMsgId': detId(n)});

List<String> ids(HistoryFeed<Detection> feed) => [for (final row in feed.rows) row.id];
List<String> sprayIds(HistoryFeed<SprayRecord> feed) => [for (final row in feed.rows) row.msgId];

void main() {
  group('REST history', () {
    liveTest('detections: the first page for the selected device, with the session token', (tester) async {
      final app = appWithDevices();
      app.backend.detections[device] = [det(3, label: 'leaf_curl_virus', confidence: 0.5), det(2), det(1)];
      app.backend.detections[otherDevice] = [det(9, deviceId: otherDevice)];
      await openPest(tester, app);
      final feed = app.services.pestHistory.detections;

      expect(app.services.pestHistory.deviceId, device);
      expect(feed.phase, HistoryPhase.ready);
      expect(feed.failure, isNull);
      expect(ids(feed), [detId(3), detId(2), detId(1)]);
      expect(feed.rows.first.label, 'leaf_curl_virus');
      expect(feed.rows.first.confidence, 0.5);
      expect(feed.rows.first.detectedAt, DateTime.utc(2026, 10, 1, 10, 3));
      expect(feed.hasMore, isFalse);
      for (final call in detectionCalls(app)) {
        expect(call.method, 'GET');
        expect(call.query, {'deviceId': device, 'limit': '${HistoryFeed.pageSize}'}, reason: 'the selected device, one page, no cursor');
        expect(call.authorization, startsWith('Bearer access-'));
      }
      expect(detectionCalls(app), isNotEmpty);
    });

    liveTest('sprays: the first page of the selected device\'s spray events, and of no other device', (tester) async {
      final app = appWithDevices();
      app.backend.events[device] = [spray(3, durationMs: 2000), {'time': at(2), 'msgId': 'harvest-1', 'deviceId': device, 'type': 'harvest', 'data': {'maturity': 'mature', 'picked': true}}, spray(1)];
      app.backend.events[otherDevice] = [spray(9, deviceId: otherDevice)];
      await openPest(tester, app);
      final feed = app.services.pestHistory.sprays;

      expect(feed.phase, HistoryPhase.ready);
      expect(sprayIds(feed), [sprayId(3), sprayId(1)]);
      expect(feed.rows.first.durationMs, 2000);
      expect(feed.rows.first.time, DateTime.utc(2026, 10, 1, 10, 3));
      expect(eventCalls(app), isNotEmpty);
      for (final call in eventCalls(app)) {
        expect(call.method, 'GET');
        expect(call.path, '/api/v1/devices/$device/events', reason: 'only the selected device');
        expect(call.query, {'type': 'spray', 'limit': '${HistoryFeed.pageSize}'});
        expect(call.authorization, startsWith('Bearer access-'));
      }
      expect(app.backend.calls.where((c) => c.path.contains(otherDevice)), isEmpty);
    });

    liveTest('nothing stored: both lists are ready and empty', (tester) async {
      final app = appWithDevices();
      await openPest(tester, app);
      final history = app.services.pestHistory;
      expect(history.detections.phase, HistoryPhase.ready);
      expect(history.detections.rows, isEmpty);
      expect(history.detections.hasMore, isFalse);
      expect(history.sprays.phase, HistoryPhase.ready);
      expect(history.sprays.rows, isEmpty);
    });

    liveTest('the two lists load and fail independently: loading -> error; retry -> ready; a failed refresh keeps the rows', (tester) async {
      final app = appWithDevices();
      app.backend.detections[device] = [det(1)];
      app.backend.events[device] = [spray(1)];
      final history = app.services.pestHistory;
      app.services.dashboard.attachLive(page);
      await settle(tester, app.services.dashboard.load());
      for (var i = 0; i < 6; i++) {
        await tester.pump(Duration.zero);
      }
      expect(history.detections.phase, HistoryPhase.idle, reason: 'no Pest page is open yet');
      history.attach(page);

      app.backend.overrides['/api/v1/devices/$device/events'] = FakeReply.error(503, 'service_unavailable');
      final loading = history.load();
      expect(history.detections.phase, HistoryPhase.loading);
      expect(history.sprays.phase, HistoryPhase.loading);
      expect(history.detections.busy, isTrue);
      await settle(tester, loading);
      await tester.pump(Duration.zero);
      expect(history.detections.phase, HistoryPhase.ready);
      expect(ids(history.detections), [detId(1)]);
      expect(history.sprays.phase, HistoryPhase.error);
      expect(history.sprays.failure!.kind, ApiFailureKind.unavailable);
      expect(history.sprays.rows, isEmpty);

      app.backend.overrides.clear();
      await settle(tester, history.sprays.load());
      expect(history.sprays.phase, HistoryPhase.ready);
      expect(history.sprays.failure, isNull);
      expect(sprayIds(history.sprays), [sprayId(1)]);

      app.backend.overrides['/api/v1/detections'] = FakeReply.error(500, 'internal_error');
      await settle(tester, history.load());
      expect(history.detections.phase, HistoryPhase.ready, reason: 'the rows read earlier stay');
      expect(history.detections.failure!.kind, ApiFailureKind.server);
      expect(ids(history.detections), [detId(1)]);
      expect(history.sprays.failure, isNull);
    });

    liveTest('a reply that does not match the contract is an error, not a partial list', (tester) async {
      final app = appWithDevices();
      app.backend.detections[device] = [det(2), {...det(1), 'confidence': 'high'}];
      app.backend.events[device] = [spray(2), spray(1, durationMs: null)];
      await openPest(tester, app);
      final history = app.services.pestHistory;
      expect(history.detections.phase, HistoryPhase.error);
      expect(history.detections.failure!.kind, ApiFailureKind.invalidResponse);
      expect(history.detections.rows, isEmpty);
      expect(history.sprays.phase, HistoryPhase.error, reason: 'a missing duration is not shown as zero');
      expect(history.sprays.rows, isEmpty);
    });

    liveTest('detections: older pages are asked for with the backend\'s cursor, unchanged, without duplicates', (tester) async {
      final app = appWithDevices();
      app.backend.detections[device] = [for (var n = 45; n >= 1; n--) det(n)];
      await openPest(tester, app);
      final feed = app.services.pestHistory.detections;
      expect(feed.rows, hasLength(20));
      expect(feed.hasMore, isTrue);

      await settle(tester, feed.loadMore());
      expect(detectionCalls(app).last.query, {'deviceId': device, 'limit': '20', 'cursor': 'after-20'}, reason: 'the cursor the backend returned');
      expect(feed.rows, hasLength(40));
      await settle(tester, feed.loadMore());
      expect(detectionCalls(app).last.query['cursor'], 'after-40');
      expect(ids(feed), [for (var n = 45; n >= 1; n--) detId(n)]);
      expect(feed.hasMore, isFalse);
      final before = detectionCalls(app).length;
      await settle(tester, feed.loadMore());
      expect(detectionCalls(app).length, before, reason: 'no cursor, no request');

      // a refresh starts from the first page again
      await settle(tester, feed.load());
      expect(detectionCalls(app).last.query.containsKey('cursor'), isFalse);
      expect(feed.rows, hasLength(20));
      expect(feed.hasMore, isTrue);
    });

    liveTest('sprays: older pages are asked for with the backend\'s cursor; a failed page keeps what is shown', (tester) async {
      final app = appWithDevices();
      app.backend.events[device] = [for (var n = 30; n >= 1; n--) spray(n)];
      await openPest(tester, app);
      final feed = app.services.pestHistory.sprays;
      expect(feed.rows, hasLength(20));
      expect(feed.hasMore, isTrue);

      app.backend.outage = Outage.offline;
      await settle(tester, feed.loadMore());
      expect(feed.rows, hasLength(20));
      expect(feed.failure!.kind, ApiFailureKind.network);
      expect(feed.hasMore, isTrue, reason: 'the cursor is kept for another attempt');

      app.backend.outage = Outage.none;
      await settle(tester, feed.loadMore());
      expect(eventCalls(app).last.query, {'type': 'spray', 'limit': '20', 'cursor': 'after-20'});
      expect(eventCalls(app).last.path, '/api/v1/devices/$device/events');
      expect(sprayIds(feed), [for (var n = 30; n >= 1; n--) sprayId(n)]);
      expect(feed.failure, isNull);
      expect(feed.hasMore, isFalse);
    });

    test('spray parsing: the contract row becomes a typed record; anything else is refused, not guessed', () {
      final record = SprayRecord.fromJson({'time': '2026-10-01T10:15:02.412+00:00', 'msgId': 'm1', 'deviceId': device, 'type': 'spray', 'data': {'durationMs': 1500, 'relatedMsgId': 'm0'}});
      expect(record.msgId, 'm1');
      expect(record.deviceId, device);
      expect(record.time, DateTime.utc(2026, 10, 1, 10, 15, 2, 412));
      expect(record.durationMs, 1500);
      for (final bad in <Map<String, dynamic>>[
        {'time': '2026-10-01T10:15:02Z', 'msgId': 'm1', 'deviceId': device, 'type': 'pest', 'data': {'durationMs': 1500}},
        {'time': '2026-10-01T10:15:02Z', 'msgId': 'm1', 'deviceId': device, 'type': 'spray', 'data': <String, dynamic>{}},
        {'time': '2026-10-01T10:15:02Z', 'msgId': 'm1', 'deviceId': device, 'type': 'spray', 'data': {'durationMs': '1500'}},
        {'time': '2026-10-01T10:15:02Z', 'msgId': 'm1', 'deviceId': device, 'type': 'spray', 'data': {'durationMs': 0}},
        {'time': 'yesterday', 'msgId': 'm1', 'deviceId': device, 'type': 'spray', 'data': {'durationMs': 1500}},
        {'time': '2026-10-01T10:15:02Z', 'deviceId': device, 'type': 'spray', 'data': {'durationMs': 1500}},
      ]) {
        expect(() => SprayRecord.fromJson(bad), throwsFormatException, reason: '$bad');
      }
    });
  });

  group('selected device', () {
    liveTest('changing the dashboard\'s device empties both lists and reads them for the new device, from the first page', (tester) async {
      final app = appWithDevices();
      app.backend.detections[device] = [for (var n = 30; n >= 1; n--) det(n)];
      app.backend.events[device] = [spray(1)];
      app.backend.detections[otherDevice] = [det(102, deviceId: otherDevice, label: 'leaf_curl_virus'), det(101, deviceId: otherDevice)];
      app.backend.events[otherDevice] = [spray(101, deviceId: otherDevice)];
      await openPest(tester, app);
      final history = app.services.pestHistory;
      await settle(tester, history.detections.loadMore());
      expect(history.detections.rows, hasLength(30));
      final before = app.backend.calls.length;

      final change = app.services.dashboard.selectDevice(otherDevice);
      // at once: nothing of the previous device is shown for the new one
      expect(history.deviceId, isNull);
      expect(history.detections.rows, isEmpty);
      expect(history.sprays.rows, isEmpty);
      expect(history.detections.phase, HistoryPhase.idle);
      await settle(tester, change);
      for (var i = 0; i < 8; i++) {
        await tester.pump(Duration.zero);
      }

      expect(history.deviceId, otherDevice);
      expect(ids(history.detections), [detId(102), detId(101)]);
      expect(sprayIds(history.sprays), [sprayId(101)]);
      expect(history.detections.hasMore, isFalse);
      final after = app.backend.calls.skip(before).toList();
      final detections = after.where((c) => c.path == '/api/v1/detections' && c.query['limit'] != '1').toList();
      final events = after.where((c) => c.path.endsWith('/events')).toList();
      expect(detections, isNotEmpty);
      expect(events, isNotEmpty);
      for (final call in detections) {
        expect(call.query, {'deviceId': otherDevice, 'limit': '20'}, reason: 'the new device, no cursor of the old one');
      }
      for (final call in events) {
        expect(call.path, '/api/v1/devices/$otherDevice/events');
        expect(call.query.containsKey('cursor'), isFalse);
      }
    });

    liveTest('a reply for the previous device that arrives after the change is dropped', (tester) async {
      final app = appWithDevices();
      app.backend.detections[device] = [det(1)];
      app.backend.detections[otherDevice] = [det(101, deviceId: otherDevice)];
      await openPest(tester, app);
      final history = app.services.pestHistory;

      app.backend.latency = const Duration(seconds: 2);
      final stale = history.load(); // for unit-a, still on its way
      await tester.pump(const Duration(milliseconds: 100));
      final change = app.services.dashboard.selectDevice(otherDevice);
      await tester.pump(const Duration(seconds: 10));
      await settle(tester, Future.wait([stale, change]));
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(Duration.zero);

      expect(history.deviceId, otherDevice);
      expect(ids(history.detections), [detId(101)]);
      expect(history.detections.rows.every((row) => row.deviceId == otherDevice), isTrue);
      app.backend.latency = Duration.zero;
    });

    liveTest('after the change, live events are applied only for the newly selected device', (tester) async {
      final app = appWithDevices();
      await openPest(tester, app);
      final history = app.services.pestHistory;
      await settle(tester, app.services.dashboard.selectDevice(otherDevice));
      for (var i = 0; i < 8; i++) {
        await tester.pump(Duration.zero);
      }
      expect(app.services.dashboard.liveState, LiveState.connected);

      livePest(app, 5, deviceId: device);
      liveSpray(app, 5, deviceId: device);
      livePest(app, 6, deviceId: otherDevice);
      liveSpray(app, 6, deviceId: otherDevice);
      await tester.pump(Duration.zero);
      expect(ids(history.detections), [detId(6)]);
      expect(sprayIds(history.sprays), [sprayId(6)]);
    });

    liveTest('no device (nothing claimed): nothing is requested and nothing is shown', (tester) async {
      final app = appWithDevices();
      app.backend.devices.clear();
      await openPest(tester, app);
      final history = app.services.pestHistory;
      expect(history.deviceId, isNull);
      expect(history.detections.phase, HistoryPhase.idle);
      expect(historyCalls(app), 0);
    });
  });

  group('live rows (event/pest and event/spray of the existing connection)', () {
    liveTest('a live detection is added to the detection history, without a REST request', (tester) async {
      final app = appWithDevices();
      app.backend.detections[device] = [det(1)];
      await openPest(tester, app);
      final history = app.services.pestHistory;
      final before = app.backend.calls.length;

      livePest(app, 2, label: 'leaf_curl_virus');
      await tester.pump(Duration.zero);
      expect(ids(history.detections), [detId(2), detId(1)]);
      final row = history.detections.rows.first;
      expect(row.label, 'leaf_curl_virus');
      expect(row.confidence, 0.91);
      expect(row.deviceId, device);
      expect(row.detectedAt, DateTime.utc(2026, 10, 1, 10, 2));
      expect(history.sprays.rows, isEmpty, reason: 'a detection is not a spray');
      expect(app.backend.calls.length, before, reason: 'the row came with the event');
    });

    liveTest('a live spray is added to the spray history, without a REST request', (tester) async {
      final app = appWithDevices();
      app.backend.events[device] = [spray(1)];
      await openPest(tester, app);
      final history = app.services.pestHistory;
      final before = app.backend.calls.length;

      liveSpray(app, 2);
      await tester.pump(Duration.zero);
      expect(sprayIds(history.sprays), [sprayId(2), sprayId(1)]);
      expect(history.sprays.rows.first.durationMs, 1200);
      expect(history.sprays.rows.first.time, DateTime.utc(2026, 10, 1, 10, 2));
      expect(history.detections.rows, isEmpty);
      expect(app.backend.calls.length, before);
    });

    liveTest('events of the caller\'s other device add nothing', (tester) async {
      final app = appWithDevices();
      app.backend.detections[device] = [det(1)];
      await openPest(tester, app);
      final history = app.services.pestHistory;
      livePest(app, 2, deviceId: otherDevice);
      liveSpray(app, 2, deviceId: otherDevice);
      await tester.pump(Duration.zero);
      expect(ids(history.detections), [detId(1)]);
      expect(history.sprays.rows, isEmpty);
    });

    liveTest('telemetry, status and harvest events add nothing: rows are not derived from other data', (tester) async {
      final app = appWithDevices();
      await openPest(tester, app);
      final history = app.services.pestHistory;
      app.live.ingest(kind: 'telemetry', deviceId: device, ts: at(3), data: {'batteryPct': 3, 'moistureRhPct': 99});
      app.live.ingest(kind: 'status', deviceId: device, ts: at(4), data: {'state': 'offline'});
      app.live.ingest(kind: 'event/harvest', deviceId: device, ts: at(5), data: {'maturity': 'mature', 'picked': true});
      await tester.pump(Duration.zero);
      expect(history.detections.rows, isEmpty);
      expect(history.sprays.rows, isEmpty);
    });

    liveTest('the same event delivered twice gives one row', (tester) async {
      final app = appWithDevices();
      await openPest(tester, app);
      final history = app.services.pestHistory;
      livePest(app, 2);
      livePest(app, 2);
      liveSpray(app, 2);
      liveSpray(app, 2);
      await tester.pump(Duration.zero);
      expect(ids(history.detections), [detId(2)]);
      expect(sprayIds(history.sprays), [sprayId(2)]);
    });

    liveTest('a row already read over REST and then delivered live stays one row, unchanged', (tester) async {
      final app = appWithDevices();
      app.backend.detections[device] = [det(2, label: 'leaf_curl_virus', confidence: 0.5), det(1)];
      app.backend.events[device] = [spray(2, durationMs: 2000)];
      await openPest(tester, app);
      final history = app.services.pestHistory;
      livePest(app, 2); // the same message id
      liveSpray(app, 2);
      await tester.pump(Duration.zero);
      expect(ids(history.detections), [detId(2), detId(1)]);
      expect(history.detections.rows.first.label, 'leaf_curl_virus');
      expect(history.detections.rows.first.confidence, 0.5);
      expect(sprayIds(history.sprays), [sprayId(2)]);
      expect(history.sprays.rows.single.durationMs, 2000);

      // and the other way round: live first, then a REST refresh that contains it
      livePest(app, 3);
      await tester.pump(Duration.zero);
      app.backend.detections[device]!.insert(0, det(3));
      await settle(tester, history.load());
      expect(ids(history.detections), [detId(3), detId(2), detId(1)]);
    });

    liveTest('paging and live rows together: no row twice, in the backend\'s order', (tester) async {
      final app = appWithDevices();
      app.backend.detections[device] = [for (var n = 45; n >= 1; n--) det(n)];
      await openPest(tester, app);
      final feed = app.services.pestHistory.detections;
      await settle(tester, feed.loadMore());
      expect(feed.rows, hasLength(40));

      // a new detection arrives live, and the backend now holds it too
      livePest(app, 50);
      app.backend.detections[device]!.insert(0, det(50));
      // a row already on a loaded page is delivered again
      livePest(app, 30);
      // a row older than the loaded pages (the backend has more): it belongs to a later page
      livePest(app, 3);
      await tester.pump(Duration.zero);
      expect(feed.rows, hasLength(41));
      expect(feed.rows.first.id, detId(50));
      expect(ids(feed).contains(detId(3)), isFalse);

      // the fake's next page now overlaps the loaded rows by one (its cursor is an offset)
      await settle(tester, feed.loadMore());
      expect(ids(feed), [detId(50), for (var n = 45; n >= 1; n--) detId(n)]);
      expect(ids(feed).toSet(), hasLength(46));
      expect(feed.hasMore, isFalse);

      // with every page loaded, an older row that is not listed is put at its place
      livePest(app, 0);
      await tester.pump(Duration.zero);
      expect(feed.rows.last.id, detId(0));
    });

    liveTest('an event with an older device time is placed by its time; it does not displace newer rows', (tester) async {
      final app = appWithDevices();
      app.backend.detections[device] = [det(9), det(5)];
      app.backend.events[device] = [spray(9), spray(5)];
      await openPest(tester, app);
      final history = app.services.pestHistory;
      livePest(app, 7);
      liveSpray(app, 7);
      await tester.pump(Duration.zero);
      expect(ids(history.detections), [detId(9), detId(7), detId(5)]);
      expect(sprayIds(history.sprays), [sprayId(9), sprayId(7), sprayId(5)]);
    });

    liveTest('events that do not match the contract add nothing and break nothing', (tester) async {
      final app = appWithDevices();
      app.backend.detections[device] = [det(1)];
      app.backend.events[device] = [spray(1)];
      await openPest(tester, app);
      final history = app.services.pestHistory;

      app.live.ingest(kind: 'event/pest', deviceId: device, ts: at(2), data: {'confidence': 0.9}); // no label
      app.live.ingest(kind: 'event/pest', deviceId: device, ts: at(3), data: {'label': 'bollworm', 'confidence': 'high'});
      app.live.ingest(kind: 'event/pest', deviceId: device, ts: at(4)); // no data at all
      app.live.ingest(kind: 'event/spray', deviceId: device, ts: at(5), data: {'durationMs': '1500'});
      app.live.ingest(kind: 'event/spray', deviceId: device, ts: at(6), data: {});
      app.live.ingest(kind: 'event/spray', deviceId: device, ts: at(7), data: {'durationMs': -5});
      app.live.ingest(kind: 'event/treat', deviceId: device, ts: at(8), data: {'label': 'bollworm', 'confidence': 0.9, 'durationMs': 1500});
      app.live.pushRaw('{"type":"event","cursor":"x"}');
      app.live.pushRaw('not json');
      app.live.pushRaw('{"type":"something_new"}');
      await tester.pump(Duration.zero);
      expect(ids(history.detections), [detId(1)]);
      expect(sprayIds(history.sprays), [sprayId(1)]);
      expect(history.detections.failure, isNull);
      expect(history.sprays.failure, isNull);

      // the connection and the lists still work
      livePest(app, 20);
      liveSpray(app, 20);
      await tester.pump(Duration.zero);
      expect(history.detections.rows.first.id, detId(20));
      expect(history.sprays.rows.first.msgId, sprayId(20));
    });

    liveTest('a row that arrives live while a REST read is in flight is not lost when the older reply lands', (tester) async {
      final app = appWithDevices();
      app.backend.detections[device] = [det(1)];
      app.backend.events[device] = [spray(1)];
      await openPest(tester, app);
      final history = app.services.pestHistory;

      app.backend.latency = const Duration(seconds: 2);
      final refresh = history.load();
      await tester.pump(const Duration(milliseconds: 100));
      livePest(app, 2); // the backend's reply does not contain it
      liveSpray(app, 2);
      await tester.pump(const Duration(seconds: 3));
      await settle(tester, refresh);
      app.backend.latency = Duration.zero;
      expect(ids(history.detections), [detId(2), detId(1)]);
      expect(sprayIds(history.sprays), [sprayId(2), sprayId(1)]);
    });

    liveTest('a stream that started "from now" reads both lists again: nothing created in between is missed', (tester) async {
      final app = appWithDevices();
      app.backend.detections[device] = [det(1)];
      await openPest(tester, app);
      final history = app.services.pestHistory;
      final before = historyCalls(app);

      // the connection is lost for good and a new one starts from now; meanwhile a detection was stored
      app.backend.detections[device]!.insert(0, det(2));
      app.backend.events[device] = [spray(2)];
      app.services.dashboard.pauseLive();
      await tester.pump(Duration.zero);
      await settle(tester, app.services.dashboard.resumeLive());
      for (var i = 0; i < 8; i++) {
        await tester.pump(Duration.zero);
      }
      expect(app.services.dashboard.liveState, LiveState.connected);
      expect(ids(history.detections), [detId(2), detId(1)]);
      expect(sprayIds(history.sprays), [sprayId(2)]);
      expect(historyCalls(app), before + 2, reason: 'one read of each list');
    });

    liveTest('while no Pest page is open, nothing is requested and nothing is kept (earlier phases\' request counts are unchanged)', (tester) async {
      final app = appWithDevices();
      app.backend.detections[device] = [det(1)];
      app.backend.events[device] = [spray(1)];
      final history = app.services.pestHistory;
      app.services.dashboard.attachLive(page);
      await settle(tester, app.services.dashboard.load());
      for (var i = 0; i < 6; i++) {
        await tester.pump(Duration.zero);
      }
      livePest(app, 2);
      liveSpray(app, 2);
      await settle(tester, app.services.dashboard.selectDevice(otherDevice));
      for (var i = 0; i < 6; i++) {
        await tester.pump(Duration.zero);
      }
      expect(historyCalls(app), 0);
      expect(history.detections.rows, isEmpty);
      expect(history.sprays.rows, isEmpty);

      // a page opens, then closes: the lists are forgotten again
      await settle(tester, app.services.dashboard.selectDevice(device));
      history.attach(page);
      await settle(tester, history.load());
      expect(history.detections.rows, isNotEmpty);
      history.detach(page);
      expect(history.detections.phase, HistoryPhase.idle);
      expect(history.detections.rows, isEmpty);
      final calls = historyCalls(app);
      livePest(app, 3);
      await tester.pump(const Duration(minutes: 5));
      expect(historyCalls(app), calls);
      expect(history.detections.rows, isEmpty);
    });

    test('live event parsing: an event/spray event becomes the row GET /devices/{id}/events returns', () {
      final event = LiveMessage.parse('{"type":"event","cursor":4813,"kind":"event/spray","deviceId":"unit-a","msgId":"01K6CQ4W0D8V9J4Q9W2YSPR001","ts":"2026-09-30T10:15:04.000000+00:00","receivedAt":"2026-09-30T10:15:04.120000+00:00",'
          '"data":{"durationMs":1500,"relatedMsgId":"01K6CQ4W0D8V9J4Q9W2Y1S7ZPX"},"alerts":[]}') as LiveEvent;
      expect(event.kind, LiveEvent.spray);
      final row = event.toSpray();
      expect(row.msgId, '01K6CQ4W0D8V9J4Q9W2YSPR001');
      expect(row.deviceId, device);
      expect(row.time, DateTime.utc(2026, 9, 30, 10, 15, 4));
      expect(row.durationMs, 1500);
    });
  });

  group('session (Phase 3A)', () {
    liveTest('session ended while reading the history: cleared by the Phase 3A mechanism, no error state, nothing kept', (tester) async {
      final app = appWithDevices();
      app.backend.detections[device] = [det(1)];
      app.backend.events[device] = [spray(1)];
      var forced = 0;
      app.services.session.onForcedSignOut = () => forced++;
      await settle(tester, app.services.session.restore());
      await openPest(tester, app);
      final history = app.services.pestHistory;
      expect(history.detections.rows, hasLength(1));

      app.backend
        ..expireAccessToken()
        ..sessionRevoked = true;
      await settle(tester, history.load());
      await tester.pump(Duration.zero);
      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1, reason: 'the two requests share one refresh');
      expect(app.tokens.session, isNull);
      expect(app.services.session.status, SessionStatus.signedOut);
      expect(forced, 1);
      expect(history.deviceId, isNull);
      expect(history.detections.phase, HistoryPhase.idle);
      expect(history.detections.rows, isEmpty);
      expect(history.detections.failure, isNull);
      expect(history.sprays.rows, isEmpty);
      expect(app.live.openSockets, isEmpty);
    });

    liveTest('access token expired: the history requests are repeated after one refresh; logout forgets the rows', (tester) async {
      final app = appWithDevices();
      app.backend.detections[device] = [det(1)];
      app.backend.events[device] = [spray(1)];
      await settle(tester, app.services.session.restore());
      await openPest(tester, app);
      final history = app.services.pestHistory;
      app.backend.expireAccessToken();
      await settle(tester, history.load());
      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
      expect(history.detections.failure, isNull);
      expect(history.sprays.failure, isNull);
      expect(history.detections.rows, hasLength(1));
      expect(history.sprays.rows, hasLength(1));

      await settle(tester, app.services.session.logout());
      await tester.pump(Duration.zero);
      expect(history.deviceId, isNull);
      expect(history.detections.rows, isEmpty);
      expect(history.sprays.rows, isEmpty);
      final calls = historyCalls(app);
      await tester.pump(const Duration(hours: 1));
      expect(historyCalls(app), calls);
    });
  });

  group('boundaries', () {
    liveTest('the history adds no socket, no frame and no write: one connection, only start / resume sent, only GET requests', (tester) async {
      final app = appWithDevices();
      app.backend.detections[device] = [for (var n = 30; n >= 1; n--) det(n)];
      app.backend.events[device] = [for (var n = 30; n >= 1; n--) spray(n)];
      await openPest(tester, app);
      final history = app.services.pestHistory;
      livePest(app, 40);
      liveSpray(app, 40);
      await tester.pump(Duration.zero);
      await settle(tester, history.detections.loadMore());
      await settle(tester, history.sprays.loadMore());
      await settle(tester, history.load());
      app.live.dropAll(code: 1011);
      await tester.pump(const Duration(seconds: 2));
      await settle(tester, history.load());
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
      expect(app.backend.calls.where((c) => c.method != 'GET'), isEmpty, reason: 'the history only reads');
      final calls = app.backend.calls.length;
      await tester.pump(const Duration(hours: 1));
      expect(app.backend.calls.length, calls, reason: 'no polling');
    });

    test('the Pest code has no control path: no command, no socket write, no MQTT or Bluetooth, no request other than GET', () {
      final files = [...Directory('lib/core/pest').listSync().whereType<File>(), File('lib/ui/pest_alerts_page.dart')];
      expect(files, hasLength(3));
      for (final file in files) {
        final code = file.readAsStringSync().replaceAll(RegExp(r'//.*'), ''); // comments say what is absent
        for (final word in ['.send(', 'sink.add', 'WebSocket', 'LiveConnection(', 'Timer', 'mqtt', 'Mqtt', 'MQTT', 'bluetooth', 'Bluetooth', 'command', 'Command', 'publish', '.post<', '.put<', '.patch<', '.delete<', 'actuator', 'robot']) {
          expect(code, isNot(contains(word)), reason: '${file.path}: $word');
        }
      }
      // the page offers none of the old controls and none of the old sample content
      final pageCode = File('lib/ui/pest_alerts_page.dart').readAsStringSync().replaceAll(RegExp(r'//.*'), '');
      for (final word in ['Live Scan', 'Capture', 'Treat', 'camera', 'AssetImage', 'Image.', 'Cypermethrin', 'Copper Oxychloride', 'Routine Checkup', 'Bollworm Infestation', 'Bacterial Blight', 'Spider Mite', 'Aphids', 'recommend', 'ElevatedButton']) {
        expect(pageCode, isNot(contains(word)), reason: word);
      }
      // the repository reads two routes of the existing contract and nothing else
      final repository = File('lib/core/pest/pest_history_repository.dart').readAsStringSync().replaceAll(RegExp(r'//.*'), '');
      expect(RegExp(r'\.get<').allMatches(repository), hasLength(2));
      expect(RegExp(r"'/api/v1/[^']*'").allMatches(repository).map((m) => m.group(0)), ["'/api/v1/detections'", "'/api/v1/devices/\${Uri.encodeComponent(deviceId)}/events'"]);
    });

    test('no device id is written into the Pest code: the device is the dashboard\'s selection', () {
      for (final file in [...Directory('lib/core/pest').listSync().whereType<File>(), File('lib/ui/pest_alerts_page.dart')]) {
        final code = file.readAsStringSync();
        expect(RegExp(r'\b(sim|bb|unit)-[0-9a-z]{1,}', caseSensitive: false).hasMatch(code), isFalse, reason: file.path);
      }
      final controller = File('lib/core/pest/pest_history_controller.dart').readAsStringSync();
      expect(controller, contains('_dashboard.data?.device?.deviceId'), reason: 'the only source of the device');
      expect(RegExp(r'switchTo\(').allMatches(controller.replaceAll(RegExp(r'//.*'), '')).length, greaterThan(0));
    });
  });
}
