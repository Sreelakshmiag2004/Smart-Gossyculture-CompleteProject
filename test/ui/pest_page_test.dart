// Phase 5C: the Pest page - the real app (launch page included) with the fake REST backend and
// the fake live channel that follow the backend contracts.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/formatting.dart';
import 'package:smart_gossy_culture_app/core/realtime/live_connection.dart';
import 'package:smart_gossy_culture_app/ui/dashboard.dart';
import 'package:smart_gossy_culture_app/ui/pest_alerts_page.dart';
import 'package:smart_gossy_culture_app/ui/sign_in_page.dart';

import '../support/app_harness.dart';
import '../support/fake_backend.dart';
import '../support/fake_live.dart';

const device = 'unit-a';
const otherDevice = 'unit-b';

/// What the old sample page showed and the backend has no source for. None of it may appear.
const fabricated = [
  'Live Scan View', 'Live', 'Capture', 'Treat', 'Detected Issues', 'Cotton Bollworm Infestation', 'Bacterial Blight', 'Spider Mite Presence', 'Confidence: 92%', 'Confidence: 78%',
  'Confidence: 65%', 'Insecticide Application', 'Fungicide Application', 'Routine Checkup', 'No issues found', 'Oct 26', 'Oct 18', 'Oct 05', 'Bollworm', 'Aphids',
];

/// Wording no record of the backend supports.
const unsupported = ['recommended', 'Recommended', 'insecticide', 'Cypermethrin', 'Copper', 'ml/acre', 'kg/acre', 'Prune', 'predators', 'Severity', 'severity', 'Safe', 'Healthy', 'No pests', 'Zone', 'Sector', 'dose', 'Scan'];

String detId(int n) => '01K6CQ4W0D8V9J4Q9W2YDET${n.toString().padLeft(3, '0')}';
String sprayId(int n) => '01K6CQ4W0D8V9J4Q9W2YSPR${n.toString().padLeft(3, '0')}';
String at(int n) => '2026-10-01T${(10 + n ~/ 60).toString().padLeft(2, '0')}:${(n % 60).toString().padLeft(2, '0')}:00Z';
DateTime timeOf(int n) => DateTime.parse(at(n));

Map<String, Object?> det(int n, {String deviceId = device, String label = 'bollworm', num confidence = 0.87}) =>
    FakeBackend.detectionRow(id: detId(n), deviceId: deviceId, detectedAt: at(n), label: label, confidence: confidence);

Map<String, Object?> spray(int n, {String deviceId = device, int durationMs = 1500}) => FakeBackend.sprayRow(deviceId: deviceId, time: at(n), msgId: sprayId(n), durationMs: durationMs, relatedMsgId: detId(n));

String textOf(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key(key))).data!;

/// A signed-in farmer with two devices; the dashboard selects [device] (the newest claim).
TestApp farmer() {
  final app = TestApp(random: FixedRandom(1.0))..signIn();
  app.backend.farms.add({'id': 'farm-1', 'name': 'North field', 'createdAt': '2026-10-01T00:00:00Z'});
  for (final (index, id) in [device, otherDevice].indexed) {
    app.backend.devices.add(FakeBackend.device(id, displayName: index == 0 ? 'Field unit' : null, state: 'online', lastSeenAt: '2026-10-01T15:00:00Z', claimedAt: '2026-10-0${9 - index}T00:00:00Z'));
  }
  app.backend.telemetry[device] = [FakeBackend.telemetryRow(time: '2026-10-01T15:00:00Z', batteryPct: 91.4, moistureRhPct: 54.3, bollsHarvestedTotal: 1287, solarActive: true, msgId: '01K6CQ4W0D8V9J4Q9W2Y000001')];
  return app;
}

/// Dashboard -> bottom navigation "Pests".
Future<void> openPests(WidgetTester tester, {bool settle = true}) async {
  expect(find.byType(Dashboard), findsOneWidget);
  await tester.tap(find.text('Pests'));
  if (!settle) return;
  await tester.pumpAndSettle();
  expect(find.byType(PestAlertsPage), findsOneWidget);
  expect(find.byType(Dashboard), findsNothing);
}

void expectNothingFabricated() {
  for (final text in fabricated) {
    expect(find.text(text), findsNothing, reason: '"$text" is displayed');
  }
  for (final text in unsupported) {
    expect(find.textContaining(text), findsNothing, reason: '"$text" is displayed');
  }
  expect(find.byType(Image), findsNothing, reason: 'the backend has no detection or spray photos');
  expect(find.byType(ElevatedButton), findsNothing, reason: 'the page has no action buttons');
}

Iterable<RecordedCall> historyCalls(TestApp app) => app.backend.calls.where((c) => (c.path == '/api/v1/detections' && c.query['limit'] != '1') || c.path.endsWith('/events'));

/// Runs [work] to completion under the test's fake clock (awaiting it directly would never
/// return: its requests and timers only advance when the tester pumps).
Future<void> settle(WidgetTester tester, Future<void> work) async {
  var done = false;
  Object? failure;
  unawaited(work.then((_) => done = true, onError: (Object error) {
    failure = error;
    done = true;
  }));
  for (var i = 0; i < 100 && !done; i++) {
    await tester.pump(Duration.zero);
  }
  if (failure != null) throw failure!;
  expect(done, isTrue, reason: 'the work did not finish');
}

Future<void> scrollTo(WidgetTester tester, Finder finder) => tester.scrollUntilVisible(finder, 400, scrollable: find.byType(Scrollable).last);

void main() {
  group('history from the backend', () {
    testWidgets('lists the selected device\'s detections and sprays, each as the backend stored it', (tester) async {
      final app = farmer();
      app.backend.detections[device] = [det(3, label: 'leaf_curl_virus', confidence: 0.874), det(2, label: 'Pink-Bollworm_stage2', confidence: 1), det(1, confidence: 0)];
      app.backend.events[device] = [spray(3), spray(1, durationMs: 2000)];
      app.backend.detections[otherDevice] = [det(50, deviceId: otherDevice, label: 'other_device_label')];
      app.backend.events[otherDevice] = [spray(50, deviceId: otherDevice)];
      await startApp(tester, app);
      await openPests(tester);

      expect(textOf(tester, 'pestDevice'), 'Device Field unit ($device)');
      // the label exactly as the device sent it: no renaming, no re-casing
      expect(textOf(tester, 'detectionLabel-${detId(3)}'), 'leaf_curl_virus');
      expect(textOf(tester, 'detectionConfidence-${detId(3)}'), 'Confidence: ${formatConfidence(0.874)}');
      expect(textOf(tester, 'detectionConfidence-${detId(3)}'), 'Confidence: 87%');
      expect(textOf(tester, 'detectionTime-${detId(3)}'), 'Reported ${formatDateTime(timeOf(3))}');
      expect(textOf(tester, 'detectionLabel-${detId(2)}'), 'Pink-Bollworm_stage2');
      expect(textOf(tester, 'detectionConfidence-${detId(2)}'), 'Confidence: 100%');
      expect(textOf(tester, 'detectionLabel-${detId(1)}'), 'bollworm');
      expect(textOf(tester, 'detectionConfidence-${detId(1)}'), 'Confidence: 0%', reason: 'a reported zero is a value');
      // newest first
      final tops = [for (final n in [3, 2, 1]) tester.getTopLeft(find.byKey(Key('detection-${detId(n)}'))).dy];
      expect(tops[0] < tops[1] && tops[1] < tops[2], isTrue);

      await scrollTo(tester, find.byKey(Key('spray-${sprayId(1)}')));
      expect(textOf(tester, 'sprayDuration-${sprayId(3)}'), 'Duration 1.5 s');
      expect(textOf(tester, 'sprayTime-${sprayId(3)}'), 'Reported ${formatDateTime(timeOf(3))}');
      expect(textOf(tester, 'sprayDuration-${sprayId(1)}'), 'Duration 2 s');
      expect(tester.getTopLeft(find.byKey(Key('spray-${sprayId(3)}'))).dy < tester.getTopLeft(find.byKey(Key('spray-${sprayId(1)}'))).dy, isTrue);

      // nothing of the other device, nothing invented
      expect(find.text('other_device_label'), findsNothing);
      expect(find.byKey(Key('spray-${sprayId(50)}')), findsNothing);
      expect(find.byKey(const Key('detectionsEmpty')), findsNothing);
      expect(find.byKey(const Key('detectionsError')), findsNothing);
      expectNothingFabricated();
      for (final call in historyCalls(app)) {
        expect(call.path == '/api/v1/detections' ? call.query['deviceId'] : call.path, call.path == '/api/v1/detections' ? device : '/api/v1/devices/$device/events');
      }
    });

    testWidgets('no Live Scan, Capture or Treat; no sample content; the page sends nothing but GET requests', (tester) async {
      final app = farmer();
      app.backend.detections[device] = [det(1)];
      app.backend.events[device] = [spray(1)];
      await startApp(tester, app);
      await openPests(tester);
      expectNothingFabricated();
      for (final label in ['Capture', 'Treat', 'Live Scan View', 'Scan Now']) {
        expect(find.text(label), findsNothing);
      }
      expect(find.byIcon(Icons.camera_alt_outlined), findsNothing);
      expect(find.byIcon(Icons.medical_services_outlined), findsNothing);
      // every button the page has: back, refresh, and the bottom navigation
      expect(find.descendant(of: find.byType(PestAlertsPage), matching: find.byType(IconButton)), findsNWidgets(2));
      expect(find.descendant(of: find.byType(PestAlertsPage), matching: find.byType(TextButton)), findsNothing);

      await tester.tap(find.byKey(const Key('pestRefresh')));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(Key('spray-${sprayId(1)}')));
      await tester.tap(find.byKey(Key('spray-${sprayId(1)}')));
      await tester.tap(find.byKey(Key('detection-${detId(1)}')), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(app.backend.calls.where((c) => c.method != 'GET'), isEmpty);
      expect(app.live.clientFrames, [{'op': 'start'}]);
    });

    testWidgets('empty states: each list says that the backend holds no record - no verdict', (tester) async {
      final app = farmer();
      await startApp(tester, app);
      await openPests(tester);
      expect(find.byKey(const Key('detectionsEmpty')), findsOneWidget);
      expect(find.text('No detection records'), findsOneWidget);
      expect(find.text('The backend holds no detection reported by this device.'), findsOneWidget);
      expect(find.byKey(const Key('spraysEmpty')), findsOneWidget);
      expect(find.text('No spray records'), findsOneWidget);
      expect(find.byKey(const Key('detectionsLoadMore')), findsNothing);
      expectNothingFabricated();

      // one list empty, the other not
      app.backend.events[device] = [spray(1)];
      await tester.tap(find.byKey(const Key('pestRefresh')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('detectionsEmpty')), findsOneWidget);
      expect(find.byKey(const Key('spraysEmpty')), findsNothing);
      expect(find.byKey(Key('spray-${sprayId(1)}')), findsOneWidget);
    });

    testWidgets('loading state of both lists, then the rows', (tester) async {
      final app = farmer();
      app.backend.detections[device] = [det(1)];
      app.backend.events[device] = [spray(1)];
      await startApp(tester, app);
      app.backend.latency = const Duration(seconds: 2);
      await openPests(tester, settle: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(PestAlertsPage), findsOneWidget);
      expect(find.byKey(const Key('detectionsLoading')), findsOneWidget);
      expect(find.text('Loading detections...'), findsOneWidget);
      expect(find.byKey(const Key('spraysLoading')), findsOneWidget);
      expect(find.text('Loading spray history...'), findsOneWidget);
      expect(find.byKey(Key('detection-${detId(1)}')), findsNothing);
      expect(find.byKey(const Key('detectionsEmpty')), findsNothing, reason: 'not known yet is not "none"');
      expectNothingFabricated();
      await tester.pump(const Duration(seconds: 2));
      app.backend.latency = Duration.zero;
      await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 30));
      expect(find.byKey(const Key('detectionsLoading')), findsNothing);
      expect(find.byKey(const Key('spraysLoading')), findsNothing);
      expect(find.byKey(Key('detection-${detId(1)}')), findsOneWidget);
      expect(find.byKey(Key('spray-${sprayId(1)}')), findsOneWidget);
    });

    testWidgets('error states are per list, with a safe message and a retry; a failed refresh keeps the rows', (tester) async {
      final app = farmer();
      app.backend.detections[device] = [det(1)];
      app.backend.events[device] = [spray(1)];
      app.backend.overrides['/api/v1/devices/$device/events'] = FakeReply.error(503, 'service_unavailable');
      await startApp(tester, app);
      await openPests(tester);
      expect(find.byKey(Key('detection-${detId(1)}')), findsOneWidget, reason: 'the detections are not affected');
      expect(find.byKey(const Key('detectionsError')), findsNothing);
      expect(find.byKey(const Key('spraysError')), findsOneWidget);
      expect(find.text('The spray history could not be loaded'), findsOneWidget);
      expect(find.textContaining('temporarily unavailable'), findsOneWidget);
      expect(find.textContaining('backend message that must never be shown'), findsNothing);
      expect(find.byKey(const Key('spraysEmpty')), findsNothing, reason: 'a failure is not "none"');
      expect(find.byKey(Key('spray-${sprayId(1)}')), findsNothing);

      app.backend.overrides.clear();
      await tester.tap(find.byKey(const Key('spraysRetry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('spraysError')), findsNothing);
      expect(find.byKey(Key('spray-${sprayId(1)}')), findsOneWidget);

      app.backend.overrides['/api/v1/detections'] = FakeReply.error(500, 'internal_error');
      await tester.tap(find.byKey(const Key('pestRefresh')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('detectionsRefreshError')), findsOneWidget);
      expect(find.text('The detections could not be updated'), findsOneWidget);
      expect(find.textContaining('Showing the records loaded earlier'), findsOneWidget);
      expect(find.byKey(Key('detection-${detId(1)}')), findsOneWidget);
      expect(find.byKey(const Key('spraysRefreshError')), findsNothing);
      expectNothingFabricated();
    });

    testWidgets('detections failing on first load: error state with retry', (tester) async {
      final app = farmer();
      app.backend.detections[device] = [det(1)];
      await startApp(tester, app);
      // (after the dashboard has read its own newest detection)
      app.backend.overrides['/api/v1/detections'] = FakeReply.error(503, 'service_unavailable');
      await openPests(tester);
      expect(find.byKey(const Key('detectionsError')), findsOneWidget);
      expect(find.text('The detections could not be loaded'), findsOneWidget);
      expect(find.byKey(const Key('detectionsEmpty')), findsNothing);
      expect(find.byKey(const Key('spraysEmpty')), findsOneWidget, reason: 'the spray list is independent');
      app.backend.overrides.clear();
      await tester.tap(find.byKey(const Key('detectionsRetry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('detectionsError')), findsNothing);
      expect(find.byKey(Key('detection-${detId(1)}')), findsOneWidget);
    });

    testWidgets('older detections and older sprays are fetched on request, page by page', (tester) async {
      final app = farmer();
      app.backend.detections[device] = [for (var n = 25; n >= 1; n--) det(n)];
      app.backend.events[device] = [for (var n = 25; n >= 1; n--) spray(n)];
      await startApp(tester, app);
      await openPests(tester);
      final history = app.services.pestHistory;
      expect(history.detections.rows, hasLength(20));
      expect(history.sprays.rows, hasLength(20));

      await scrollTo(tester, find.byKey(const Key('detectionsLoadMore')));
      expect(find.text('Show older detections'), findsOneWidget);
      await tester.tap(find.byKey(const Key('detectionsLoadMore')));
      await tester.pumpAndSettle();
      expect(history.detections.rows, hasLength(25));
      expect(history.sprays.rows, hasLength(20), reason: 'the lists page independently');
      expect(find.byKey(const Key('detectionsLoadMore')), findsNothing);

      await scrollTo(tester, find.byKey(const Key('spraysLoadMore')));
      await tester.tap(find.byKey(const Key('spraysLoadMore')));
      await tester.pumpAndSettle();
      expect(history.sprays.rows, hasLength(25));
      expect(find.byKey(const Key('spraysLoadMore')), findsNothing);
      await scrollTo(tester, find.byKey(Key('spray-${sprayId(1)}')));
      expect(find.byKey(Key('spray-${sprayId(1)}')), findsOneWidget);
      expect(historyCalls(app).where((c) => c.query['cursor'] != null).map((c) => c.query['cursor']), ['after-20', 'after-20']);
    });
  });

  group('live rows and the connection', () {
    testWidgets('going from the dashboard to the Pest page keeps the dashboard\'s connection: no second socket, no reconnection', (tester) async {
      final app = farmer();
      await startApp(tester, app);
      expect(app.live.openSockets, hasLength(1));
      final attempts = app.live.attempts.length;
      await openPests(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(app.live.openSockets, hasLength(1));
      expect(app.live.sockets, hasLength(1));
      expect(app.live.attempts.length, attempts);
      expect(app.live.clientFrames, [{'op': 'start'}]);
      expect(app.services.dashboard.liveState, LiveState.connected);
    });

    testWidgets('a live detection and a live spray appear on the open page by themselves, once', (tester) async {
      final app = farmer();
      app.backend.detections[device] = [det(1)];
      app.backend.events[device] = [spray(1)];
      await startApp(tester, app);
      await openPests(tester);
      final before = app.backend.calls.length;

      app.live.ingest(kind: 'event/pest', deviceId: device, ts: at(5), msgId: detId(5), data: {'label': 'leaf_curl_virus', 'confidence': 0.66, 'bbox': [0.1, 0.2, 0.1, 0.1]});
      app.live.ingest(kind: 'event/spray', deviceId: device, ts: at(5), msgId: sprayId(5), data: {'durationMs': 1200, 'relatedMsgId': detId(5)});
      // both again, and the rows already listed again
      app.live.ingest(kind: 'event/pest', deviceId: device, ts: at(5), msgId: detId(5), data: {'label': 'leaf_curl_virus', 'confidence': 0.66});
      app.live.ingest(kind: 'event/spray', deviceId: device, ts: at(5), msgId: sprayId(5), data: {'durationMs': 1200});
      app.live.ingest(kind: 'event/pest', deviceId: device, ts: at(1), msgId: detId(1), data: {'label': 'bollworm', 'confidence': 0.87});
      await tester.pumpAndSettle();

      expect(find.byKey(Key('detection-${detId(5)}')), findsOneWidget);
      expect(textOf(tester, 'detectionLabel-${detId(5)}'), 'leaf_curl_virus');
      expect(textOf(tester, 'detectionConfidence-${detId(5)}'), 'Confidence: 66%');
      expect(tester.getTopLeft(find.byKey(Key('detection-${detId(5)}'))).dy < tester.getTopLeft(find.byKey(Key('detection-${detId(1)}'))).dy, isTrue);
      expect(app.services.pestHistory.detections.rows, hasLength(2));
      expect(app.services.pestHistory.sprays.rows, hasLength(2));
      await scrollTo(tester, find.byKey(Key('spray-${sprayId(1)}')));
      expect(textOf(tester, 'sprayDuration-${sprayId(5)}'), 'Duration 1.2 s');
      expect(app.backend.calls.length, before, reason: 'no REST request: the rows came with the live events');
      expect(app.live.openSockets, hasLength(1));
      expect(app.live.clientFrames, [{'op': 'start'}]);
      expectNothingFabricated();
    });

    testWidgets('live events of another device, and events that do not match the contract, change nothing on the page', (tester) async {
      final app = farmer();
      app.backend.detections[device] = [det(1)];
      await startApp(tester, app);
      await openPests(tester);
      app.live.ingest(kind: 'event/pest', deviceId: otherDevice, ts: at(5), msgId: detId(5), data: {'label': 'other_device_label', 'confidence': 0.9});
      app.live.ingest(kind: 'event/spray', deviceId: otherDevice, ts: at(5), msgId: sprayId(5), data: {'durationMs': 1200});
      app.live.ingest(kind: 'event/pest', deviceId: device, ts: at(6), msgId: detId(6), data: {'confidence': 0.9});
      app.live.ingest(kind: 'event/spray', deviceId: device, ts: at(6), msgId: sprayId(6), data: {'durationMs': 'long'});
      app.live.pushRaw('not json');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('other_device_label'), findsNothing);
      expect(app.services.pestHistory.detections.rows, hasLength(1));
      expect(app.services.pestHistory.sprays.rows, isEmpty);
      expect(find.byKey(const Key('spraysEmpty')), findsOneWidget);
      expect(find.byKey(Key('detection-${detId(1)}')), findsOneWidget);
    });

    testWidgets('the selected device changes: the page shows the new device\'s history and nothing of the old one', (tester) async {
      final app = farmer();
      app.backend.detections[device] = [det(1, label: 'label_of_unit_a')];
      app.backend.events[device] = [spray(1)];
      app.backend.detections[otherDevice] = [det(60, deviceId: otherDevice, label: 'label_of_unit_b')];
      app.backend.events[otherDevice] = [spray(60, deviceId: otherDevice, durationMs: 3000)];
      await startApp(tester, app);
      await openPests(tester);
      expect(find.text('label_of_unit_a'), findsOneWidget);

      await settle(tester, app.services.dashboard.selectDevice(otherDevice));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'pestDevice'), 'Device $otherDevice');
      expect(find.text('label_of_unit_b'), findsOneWidget);
      expect(find.text('label_of_unit_a'), findsNothing);
      expect(find.byKey(Key('spray-${sprayId(1)}')), findsNothing);
      expect(textOf(tester, 'sprayDuration-${sprayId(60)}'), 'Duration 3 s');

      // live events now count for unit-b only
      app.live.ingest(kind: 'event/pest', deviceId: device, ts: at(70), msgId: detId(70), data: {'label': 'late_unit_a', 'confidence': 0.9});
      app.live.ingest(kind: 'event/pest', deviceId: otherDevice, ts: at(71), msgId: detId(71), data: {'label': 'new_unit_b', 'confidence': 0.9});
      await tester.pumpAndSettle();
      expect(find.text('late_unit_a'), findsNothing);
      expect(find.text('new_unit_b'), findsOneWidget);
    });

    testWidgets('app in the background on the Pest page: no connection; back in the foreground: state re-read, one connection', (tester) async {
      final app = farmer();
      app.backend.detections[device] = [det(1)];
      await startApp(tester, app);
      await openPests(tester);
      addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      expect(app.live.openSockets, isEmpty);
      final attempts = app.live.attempts.length;
      await tester.pump(const Duration(minutes: 30));
      expect(app.live.attempts.length, attempts, reason: 'nothing is attempted in the background');

      app.backend.detections[device]!.insert(0, det(2, label: 'reported_while_away'));
      for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(app.live.openSockets, hasLength(1));
      expect(find.text('reported_while_away'), findsOneWidget);
    });

    testWidgets('leaving the Pest page for a page without live data closes the connection; the dashboard opens it again', (tester) async {
      final app = farmer();
      await startApp(tester, app);
      await openPests(tester);
      await tester.tap(find.text('Field'));
      await tester.pumpAndSettle();
      expect(find.byType(PestAlertsPage), findsNothing);
      expect(app.live.openSockets, isEmpty);
      final calls = historyCalls(app).length;
      await tester.pump(const Duration(minutes: 10));
      expect(historyCalls(app).length, calls);
      expect(app.services.pestHistory.detections.rows, isEmpty);

      // and directly from Field to Pests: the page reads the dashboard's snapshot first, then connects
      await tester.tap(find.text('Pests'));
      await tester.pumpAndSettle();
      expect(find.byType(PestAlertsPage), findsOneWidget);
      expect(app.live.openSockets, hasLength(1));
      expect(textOf(tester, 'pestDevice'), 'Device Field unit ($device)');
      expect(find.byKey(const Key('detectionsEmpty')), findsOneWidget);
    });
  });

  group('device and session', () {
    testWidgets('no device linked: the page says so and requests no history', (tester) async {
      final app = farmer();
      await startApp(tester, app);
      await openPests(tester);
      app.backend.devices.clear();
      await tester.tap(find.byKey(const Key('pestRefresh')));
      await tester.pumpAndSettle();
      // the dashboard's snapshot was valid; a refresh of the page does not re-read it while live
      expect(find.byKey(const Key('pestDevice')), findsOneWidget);

      await settle(tester, app.services.dashboard.load());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pestNoDevice')), findsOneWidget);
      expect(find.byKey(const Key('detectionsEmpty')), findsNothing);
      final calls = historyCalls(app).length;
      await tester.tap(find.byKey(const Key('pestRefresh')));
      await tester.pumpAndSettle();
      expect(historyCalls(app).length, calls);
    });

    testWidgets('session ended on the Pest page: back to sign-in through the Phase 3A mechanism', (tester) async {
      final app = farmer();
      app.backend.detections[device] = [det(1)];
      await startApp(tester, app);
      await openPests(tester);
      app.backend
        ..expireAccessToken()
        ..sessionRevoked = true;
      await tester.tap(find.byKey(const Key('pestRefresh')));
      await tester.pumpAndSettle();

      expect(find.byType(SignInPage), findsOneWidget);
      expect(find.textContaining('session has ended'), findsOneWidget);
      expect(find.byType(PestAlertsPage), findsNothing);
      expect(app.tokens.session, isNull);
      expect(app.services.pestHistory.detections.rows, isEmpty);
      expect(app.services.dashboard.data, isNull);
      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
      expect(app.live.openSockets, isEmpty);
      final attempts = app.live.attempts.length;
      final calls = app.backend.calls.length;
      await tester.pump(const Duration(hours: 1));
      expect(app.live.attempts.length, attempts);
      expect(app.backend.calls.length, calls);
    });

    testWidgets('no token is displayed on the Pest page', (tester) async {
      final app = farmer();
      app.backend.detections[device] = [det(1)];
      app.backend.events[device] = [spray(1)];
      await startApp(tester, app);
      await openPests(tester);
      final stored = app.tokens.session!;
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        final shown = text.data ?? '';
        expect(shown.contains(stored.accessToken), isFalse);
        expect(shown.contains(stored.refreshToken), isFalse);
      }
    });
  });
}
