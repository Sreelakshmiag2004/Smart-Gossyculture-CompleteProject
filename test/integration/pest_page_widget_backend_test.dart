// Phase 5C: the Pest PAGE on the local development backend.
//
//   simulator -> MQTT/TLS -> ingest -> PostgreSQL -> REST history -> Pest page
//             -> WebSocket event/pest, event/spray -> app live connection -> Pest page
//
// Kept in its own file: a widget test installs a test binding that blocks HTTP for the whole
// file unless it is switched off, which this test does (HttpOverrides.global = null).
// Skipped unless GOSSY_IT_BASE_URL and GOSSY_IT_OTP_CODE are set (see it_support.dart).

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/app_services.dart';
import 'package:smart_gossy_culture_app/core/formatting.dart';
import 'package:smart_gossy_culture_app/core/pest/pest_history_controller.dart';
import 'package:smart_gossy_culture_app/core/realtime/live_connection.dart';
import 'package:smart_gossy_culture_app/ui/pest_alerts_page.dart';

import 'it_support.dart';

void main() {
  testWidgets('Pest page shows the backend\'s detections and sprays of the selected device, then rows delivered by real live events', (tester) async {
    HttpOverrides.global = null; // allow real HTTP and WebSocket connections in this widget test
    late AppServices services;
    late Dio raw;
    var requests = 0;
    var writes = 0;
    Future<void> realTime(bool Function() condition, Duration timeout, String what) async {
      final deadline = DateTime.now().add(timeout);
      while (!condition()) {
        if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    final owner = Object();
    await tester.runAsync(() async {
      final font = File('${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf');
      if (font.existsSync()) {
        await (FontLoader('Roboto')..addFont(Future.value(ByteData.view(font.readAsBytesSync().buffer)))).load();
      }
      services = await signedIn(farmer);
      await ensureSimulatorDeviceClaimed(services);
      raw = await rawClient(farmer);
      services.api.authed.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        requests++;
        if (options.method != 'GET') writes++;
        handler.next(options);
      }));
      // What the dashboard did before the user came to this page, done here so that the network
      // work runs in real time: live updates wanted, snapshot loaded, the simulator's device shown.
      final dashboard = services.dashboard..attachLive(owner);
      await dashboard.load();
      if (dashboard.data!.device!.deviceId != simDevice) await dashboard.selectDevice(simDevice);
      await realTime(() => dashboard.liveState == LiveState.connected, const Duration(seconds: 20), 'the live connection');
      await Future<void>.delayed(const Duration(milliseconds: 1500)); // the re-read after the stream starts
      await realTime(() => !dashboard.busy, const Duration(seconds: 20), 'the dashboard re-read');
    });
    final dashboard = services.dashboard;
    final history = services.pestHistory;
    final attempts = services.live.connectAttempts;

    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(services: services, child: MaterialApp(theme: ThemeData(fontFamily: 'Roboto'), home: const PestAlertsPage())));
    await tester.pump();

    // Requests the PAGE starts run inside the widget test's own clock: real time is let pass in
    // small steps, each followed by a frame, until the request has completed.
    Future<void> drive(bool Function() done, String what) async {
      for (var i = 0; i < 300 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(done(), isTrue, reason: 'timed out waiting for $what');
    }

    String text(String key) => tester.widget<Text>(find.byKey(Key(key))).data!;
    Future<void> show(Finder finder) => tester.scrollUntilVisible(finder, 400, scrollable: find.byType(Scrollable).last);
    bool ready() => history.detections.phase == HistoryPhase.ready && history.sprays.phase == HistoryPhase.ready && !history.detections.busy && !history.sprays.busy;

    // 1. The page's own first load: the backend's rows of the selected device.
    await drive(ready, 'the page\'s own load of both lists');
    expect(history.deviceId, simDevice);
    final deviceLine = text('pestDevice');
    expect(deviceLine, contains(simDevice));
    expect(history.detections.rows, isNotEmpty);
    expect(history.sprays.rows, isNotEmpty);
    late List<Map<dynamic, dynamic>> rawDetections;
    late List<Map<dynamic, dynamic>> rawSprays;
    Future<void> readRaw() => tester.runAsync(() async {
          rawDetections = (((await raw.get<dynamic>('/api/v1/detections', queryParameters: {'deviceId': simDevice, 'limit': 50})).data as Map)['items'] as List).cast<Map<dynamic, dynamic>>();
          rawSprays = (((await raw.get<dynamic>('/api/v1/devices/$simDevice/events', queryParameters: {'type': 'spray', 'limit': 50})).data as Map)['items'] as List).cast<Map<dynamic, dynamic>>();
        });
    await readRaw();
    final firstShown = history.detections.rows.first;
    final firstRow = rawDetections.firstWhere((row) => row['id'] == firstShown.id);
    expect(text('detectionLabel-${firstShown.id}'), firstRow['label'], reason: 'the label exactly as the backend holds it');
    expect(text('detectionConfidence-${firstShown.id}'), 'Confidence: ${formatConfidence((firstRow['confidence'] as num).toDouble())}');
    expect(text('detectionTime-${firstShown.id}'), 'Reported ${formatDateTime(DateTime.parse(firstRow['detectedAt'] as String))}');
    final restLine = 'label="${text('detectionLabel-${firstShown.id}')}" ${text('detectionConfidence-${firstShown.id}')} ${text('detectionTime-${firstShown.id}')}';
    for (final gone in ['Live Scan View', 'Capture', 'Treat', 'Detected Issues', 'Cotton Bollworm Infestation', 'Bacterial Blight', 'Spider Mite Presence', 'Insecticide Application', 'No issues found']) {
      expect(find.text(gone), findsNothing);
    }
    expect(find.byType(ElevatedButton), findsNothing);
    expect(find.byType(Image), findsNothing);

    // 2. Without any further request, the simulator's next detection and spray arrive over the live channel.
    final knownDetections = {for (final d in history.detections.rows) d.id};
    final knownSprays = {for (final s in history.sprays.rows) s.msgId};
    final requestsBefore = requests;
    await tester.runAsync(() => realTime(
          () => history.detections.rows.any((d) => !knownDetections.contains(d.id)) && history.sprays.rows.any((s) => !knownSprays.contains(s.msgId)),
          const Duration(minutes: 5),
          'a live detection and a live spray (simulator pest probability 0.1 per tick)',
        ));
    expect(requests, requestsBefore, reason: 'no REST request was sent: the rows came from live events');
    expect(services.live.connectAttempts, attempts, reason: 'on the dashboard\'s existing connection');
    await tester.pump();
    final detection = history.detections.rows.firstWhere((d) => !knownDetections.contains(d.id));
    final spray = history.sprays.rows.firstWhere((s) => !knownSprays.contains(s.msgId));

    // 3. The page shows them, exactly as the backend serves the same records over REST.
    await readRaw();
    final detectionRow = rawDetections.firstWhere((row) => row['id'] == detection.id);
    final sprayRow = rawSprays.firstWhere((row) => row['msgId'] == spray.msgId);
    expect(find.byKey(Key('detection-${detection.id}')), findsOneWidget);
    expect(text('detectionLabel-${detection.id}'), detectionRow['label']);
    expect(text('detectionConfidence-${detection.id}'), 'Confidence: ${formatConfidence((detectionRow['confidence'] as num).toDouble())}');
    expect(text('detectionTime-${detection.id}'), 'Reported ${formatDateTime(DateTime.parse(detectionRow['detectedAt'] as String))}');
    expect(tester.getTopLeft(find.byKey(Key('detection-${detection.id}'))).dy < tester.getTopLeft(find.byKey(Key('detection-${firstShown.id}'))).dy, isTrue, reason: 'newest first');
    final liveLine = 'label="${text('detectionLabel-${detection.id}')}" ${text('detectionConfidence-${detection.id}')} ${text('detectionTime-${detection.id}')}';
    await show(find.byKey(Key('spray-${spray.msgId}')));
    expect(find.byKey(Key('spray-${spray.msgId}')), findsOneWidget);
    expect(text('sprayDuration-${spray.msgId}'), 'Duration ${formatSeconds((sprayRow['data'] as Map)['durationMs'] as int)}');
    expect(text('sprayTime-${spray.msgId}'), 'Reported ${formatDateTime(DateTime.parse(sprayRow['time'] as String))}');
    expect(writes, 0, reason: 'the page only reads');

    // ignore: avoid_print
    print('IT-PEST widget: device="$deviceLine" restRow[id=${firstShown.id} $restLine] '
        'liveDetection[id=${detection.id} $liveLine] liveSpray[msgId=${spray.msgId} ${text('sprayDuration-${spray.msgId}')} ${text('sprayTime-${spray.msgId}')}] '
        'restRequestsBetween=${requests - requestsBefore} connectionAttempts=${services.live.connectAttempts - attempts} nonGetRequests=$writes liveState=${dashboard.liveState.name}');

    await tester.pumpWidget(const SizedBox());
    // The page's own requests were made inside the test clock: let their idle HTTP connections
    // time out there, so that no timer outlives the test.
    await tester.pump(const Duration(seconds: 30));
    expect(dashboard.liveState, LiveState.connected, reason: 'the test is still attached');
    await tester.runAsync(() async {
      dashboard.detachLive(owner);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    expect(dashboard.liveState, LiveState.disconnected);
  }, skip: skipReason != null, timeout: const Timeout(Duration(minutes: 8)));
}
