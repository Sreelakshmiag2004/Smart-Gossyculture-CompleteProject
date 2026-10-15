// Phase 5C: detection history and spray history against the LOCAL DEVELOPMENT backend with the
// running simulator (backend/deploy/dev/compose.yaml, started with `--profile simulator`).
//
//   simulator -> MQTT/TLS -> ingest -> PostgreSQL
//             -> REST /api/v1/detections, /api/v1/devices/{id}/events?type=spray -> app history
//             -> NOTIFY -> WebSocket event/pest, event/spray -> app live connection -> app history
//
// Skipped unless GOSSY_IT_BASE_URL and GOSSY_IT_OTP_CODE are set (see it_support.dart).
// The device-scope check uses a second device of the same farmer that reports nothing
// (GOSSY_IT_OTHER_DEVICE, default sim-0002; registered and claimed here if it is not yet).
// Only allow-listed +999 test numbers are used. Not a production test.

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/api/api_failure.dart';
import 'package:smart_gossy_culture_app/core/app_services.dart';
import 'package:smart_gossy_culture_app/core/models.dart';
import 'package:smart_gossy_culture_app/core/pest/pest_history_controller.dart';
import 'package:smart_gossy_culture_app/core/pest/pest_history_repository.dart';
import 'package:smart_gossy_culture_app/core/realtime/live_connection.dart';

import 'it_support.dart';

final String otherDevice = Platform.environment['GOSSY_IT_OTHER_DEVICE'] ?? 'sim-0002';

const String detectionsPath = '/api/v1/detections';
String eventsPath(String deviceId) => '/api/v1/devices/$deviceId/events';

Future<void> until(bool Function() condition, {required Duration timeout, required String what}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out after $timeout waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// One request the app sent.
class Sent {
  Sent(this.method, this.path, this.query);
  final String method;
  final String path;
  final Map<String, dynamic> query;
}

/// Records the REST requests the app sends and the `nextCursor` of each reply, by path.
class Recorder {
  Recorder(AppServices services) {
    services.api.authed.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        sent.add(Sent(options.method, options.path, Map.of(options.queryParameters)));
        handler.next(options);
      },
      onResponse: (response, handler) {
        final data = response.data;
        if (data is Map && data.containsKey('nextCursor')) lastNextCursor[response.requestOptions.path] = data['nextCursor'] as String?;
        handler.next(response);
      },
    ));
  }

  final List<Sent> sent = [];
  final Map<String, String?> lastNextCursor = {};

  /// The history requests: both lists' pages (the dashboard's own "newest detection" read asks for one row).
  Iterable<Sent> get history => sent.where((s) => (s.path == detectionsPath && s.query['limit'] != 1) || s.path.endsWith('/events'));
}

bool settled(AppServices services) => !services.dashboard.busy && !services.pestHistory.detections.busy && !services.pestHistory.sprays.busy;

/// What the Pest page does when it opens: the dashboard's connection kept in use, the
/// dashboard's snapshot read, both lists read for the device it shows.
Future<(AppServices, Recorder)> pestPageOnSimulator() async {
  final services = await signedIn(farmer);
  await ensureSimulatorDeviceClaimed(services);
  final recorder = Recorder(services);
  final page = Object();
  final dashboard = services.dashboard..attachLive(page);
  final history = services.pestHistory;
  addTearDown(() {
    history.detach(page);
    dashboard.detachLive(page);
  });
  await dashboard.load();
  if (dashboard.data!.device!.deviceId != simDevice) await dashboard.selectDevice(simDevice);
  // The Pest page opens now, with the simulator's device selected on the dashboard. What the
  // dashboard asked for before that (its own start-up, possibly for another device) is not the page's.
  recorder.sent.clear();
  history.attach(page);
  await history.load();
  await until(() => dashboard.liveState == LiveState.connected, timeout: const Duration(seconds: 20), what: 'the live connection');
  // the re-read that follows the start of the stream
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  await until(() => settled(services), timeout: const Duration(seconds: 20), what: 'the re-read after the stream started');
  expect(history.deviceId, simDevice);
  expect(history.detections.phase, HistoryPhase.ready);
  expect(history.sprays.phase, HistoryPhase.ready);
  return (services, recorder);
}

void expectDetectionAsBackend(Detection detection, Map<dynamic, dynamic> row) {
  expect(detection.id, row['id']);
  expect(detection.deviceId, row['deviceId']);
  expect(detection.detectedAt, DateTime.parse(row['detectedAt'] as String).toUtc());
  expect(detection.label, row['label'], reason: 'the label exactly as the backend holds it');
  expect(detection.confidence, (row['confidence'] as num).toDouble());
}

void expectSprayAsBackend(SprayRecord spray, Map<dynamic, dynamic> row) {
  expect(row['type'], 'spray');
  expect(spray.msgId, row['msgId']);
  expect(spray.deviceId, row['deviceId']);
  expect(spray.time, DateTime.parse(row['time'] as String).toUtc());
  expect(spray.durationMs, (row['data'] as Map)['durationMs']);
}

void expectNewestFirst<T>(List<T> rows, DateTime Function(T) timeOf, String Function(T) idOf) {
  for (var i = 1; i < rows.length; i++) {
    final byTime = timeOf(rows[i - 1]).compareTo(timeOf(rows[i]));
    expect(byTime > 0 || (byTime == 0 && idOf(rows[i - 1]).compareTo(idOf(rows[i])) > 0), isTrue, reason: 'row $i is not older than row ${i - 1}');
  }
}

Future<List<Map<dynamic, dynamic>>> rawItems(Dio raw, String path, Map<String, dynamic> query) async {
  final response = await raw.get<dynamic>(path, queryParameters: query);
  expect(response.statusCode, 200, reason: '$path $query');
  return ((response.data as Map)['items'] as List).cast<Map<dynamic, dynamic>>();
}

void main() {
  final skip = skipReason;

  test('REST: both lists are the backend\'s rows for the selected device, field by field; older pages come with the backend\'s cursor', () async {
    final (services, recorder) = await pestPageOnSimulator();
    final history = services.pestHistory;
    final detections = history.detections;
    final sprays = history.sprays;
    expect(detections.failure, isNull);
    expect(sprays.failure, isNull);
    expect(detections.rows, isNotEmpty, reason: 'the simulator reports detections');
    expect(sprays.rows, isNotEmpty, reason: 'the simulator reports a spray with each detection');

    // Independent check: the same pages fetched without the app's models.
    final raw = await rawClient(farmer);
    final rawDetections = {for (final row in await rawItems(raw, detectionsPath, {'deviceId': simDevice, 'limit': 50})) row['id']: row};
    final rawSprays = {for (final row in await rawItems(raw, eventsPath(simDevice), {'type': 'spray', 'limit': 50})) row['msgId']: row};
    for (final detection in detections.rows) {
      expectDetectionAsBackend(detection, rawDetections[detection.id]!);
    }
    for (final spray in sprays.rows) {
      expectSprayAsBackend(spray, rawSprays[spray.msgId]!);
    }
    expect(detections.rows.every((d) => d.deviceId == simDevice), isTrue);
    expect(sprays.rows.every((s) => s.deviceId == simDevice), isTrue);
    expectNewestFirst<Detection>(detections.rows, (d) => d.detectedAt, (d) => d.id);
    expectNewestFirst<SprayRecord>(sprays.rows, (s) => s.time, (s) => s.msgId);

    // Every request names the selected device and only reads.
    expect(recorder.history, isNotEmpty);
    expect(recorder.sent.every((s) => s.method == 'GET'), isTrue);
    for (final request in recorder.sent.where((s) => s.path == detectionsPath)) {
      expect(request.query['deviceId'], simDevice);
    }
    for (final request in recorder.sent.where((s) => s.path.endsWith('/events'))) {
      expect(request.path, eventsPath(simDevice));
      expect(request.query['type'], 'spray');
    }
    final firstDetections = detections.rows.length;
    final firstSprays = sprays.rows.length;

    // Older pages: the cursor sent is the one the backend gave, unchanged.
    var pagedDetections = 'the backend has no older page';
    if (detections.hasMore) {
      final cursor = recorder.lastNextCursor[detectionsPath];
      expect(cursor, isNotNull);
      final before = [for (final d in detections.rows) d.id];
      await detections.loadMore();
      expect(detections.failure, isNull);
      expect(recorder.sent.last.path, detectionsPath);
      expect(recorder.sent.last.query['cursor'], cursor);
      expect(recorder.sent.last.query['deviceId'], simDevice);
      final ids = [for (final d in detections.rows) d.id];
      expect(ids.toSet(), hasLength(ids.length), reason: 'no row twice');
      expect(ids.sublist(0, before.length), before, reason: 'the rows already shown stay where they are');
      final older = await rawItems(raw, detectionsPath, {'deviceId': simDevice, 'limit': HistoryFeed.pageSize, 'cursor': cursor});
      expect(ids.sublist(before.length), [for (final row in older) row['id']], reason: 'the backend\'s next page');
      expectNewestFirst<Detection>(detections.rows, (d) => d.detectedAt, (d) => d.id);
      pagedDetections = '${before.length} -> ${ids.length} rows, hasMore=${detections.hasMore}';
    }
    var pagedSprays = 'the backend has no older page';
    if (sprays.hasMore) {
      final cursor = recorder.lastNextCursor[eventsPath(simDevice)];
      expect(cursor, isNotNull);
      final before = [for (final s in sprays.rows) s.msgId];
      await sprays.loadMore();
      expect(sprays.failure, isNull);
      expect(recorder.sent.last.path, eventsPath(simDevice));
      expect(recorder.sent.last.query['cursor'], cursor);
      expect(recorder.sent.last.query['type'], 'spray');
      final ids = [for (final s in sprays.rows) s.msgId];
      expect(ids.toSet(), hasLength(ids.length), reason: 'no row twice');
      expect(ids.sublist(0, before.length), before);
      final older = await rawItems(raw, eventsPath(simDevice), {'type': 'spray', 'limit': HistoryFeed.pageSize, 'cursor': cursor});
      expect(ids.sublist(before.length), [for (final row in older) row['msgId']], reason: 'the backend\'s next page');
      expectNewestFirst<SprayRecord>(sprays.rows, (s) => s.time, (s) => s.msgId);
      pagedSprays = '${before.length} -> ${ids.length} rows, hasMore=${sprays.hasMore}';
    }
    final newest = detections.rows.first;
    // ignore: avoid_print
    print('IT-PEST rest: device=$simDevice detections firstPage=$firstDetections sprays firstPage=$firstSprays pageSize=${HistoryFeed.pageSize} '
        'newestDetection id=${newest.id} label="${newest.label}" confidence=${newest.confidence} detectedAt=${newest.detectedAt.toIso8601String()} '
        'newestSpray msgId=${sprays.rows.first.msgId} durationMs=${sprays.rows.first.durationMs} | older detections: $pagedDetections | older sprays: $pagedSprays | '
        'requests=${recorder.sent.length} allGET=true');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('live: a simulator detection and its spray become rows without a REST request, once; a refresh and an older page add no duplicate', () async {
    final (services, recorder) = await pestPageOnSimulator();
    final history = services.pestHistory;
    final detections = history.detections;
    final sprays = history.sprays;
    final knownDetections = {for (final d in detections.rows) d.id};
    final knownSprays = {for (final s in sprays.rows) s.msgId};
    final attempts = services.live.connectAttempts;
    final requestsBefore = recorder.sent.length;

    // The simulator reports a detection - and a spray linked to it - with probability 0.1 per 5 s tick.
    await until(
      () => detections.rows.any((d) => !knownDetections.contains(d.id)) && sprays.rows.any((s) => !knownSprays.contains(s.msgId)),
      timeout: const Duration(minutes: 5),
      what: 'a live detection and a live spray (simulator pest probability 0.1 per tick)',
    );
    expect(recorder.sent.length, requestsBefore, reason: 'the rows arrived over the live channel, not through a REST request');
    expect(services.live.connectAttempts, attempts, reason: 'on the dashboard\'s existing connection');
    final detection = detections.rows.firstWhere((d) => !knownDetections.contains(d.id));
    final spray = sprays.rows.firstWhere((s) => !knownSprays.contains(s.msgId));
    expect(detections.rows.first.id, detection.id, reason: 'newest first');
    expect(sprays.rows.first.msgId, spray.msgId, reason: 'newest first');
    expect(detection.deviceId, simDevice);
    expect(spray.deviceId, simDevice);
    expect(detections.rows.where((d) => d.id == detection.id), hasLength(1));
    expect(sprays.rows.where((s) => s.msgId == spray.msgId), hasLength(1));

    // The same records as the backend serves them over REST (independent of the app's models).
    final raw = await rawClient(farmer);
    final detectionRow = (await rawItems(raw, detectionsPath, {'deviceId': simDevice, 'limit': 50})).firstWhere((row) => row['id'] == detection.id);
    final sprayRow = (await rawItems(raw, eventsPath(simDevice), {'type': 'spray', 'limit': 50})).firstWhere((row) => row['msgId'] == spray.msgId);
    expectDetectionAsBackend(detection, detectionRow);
    expectSprayAsBackend(spray, sprayRow);
    // ignore: avoid_print
    print('IT-PEST live: detection id=${detection.id} label="${detection.label}" confidence=${detection.confidence} detectedAt=${detection.detectedAt.toIso8601String()} | '
        'spray msgId=${spray.msgId} durationMs=${spray.durationMs} relatedMsgId=${(sprayRow['data'] as Map)['relatedMsgId']} | '
        'restRequestsWhileWaiting=${recorder.sent.length - requestsBefore} connectionAttempts=${services.live.connectAttempts - attempts} equalToRestRows=true');

    // A REST refresh now returns the same records: still one row each.
    await history.load();
    expect(detections.failure, isNull);
    expect(detections.rows.where((d) => d.id == detection.id), hasLength(1));
    expect(sprays.rows.where((s) => s.msgId == spray.msgId), hasLength(1));
    expect(detections.rows.first.id.compareTo(detection.id) >= 0, isTrue);
    // An older page after the live rows: no row twice.
    if (detections.hasMore) await detections.loadMore();
    if (sprays.hasMore) await sprays.loadMore();
    final detectionIds = [for (final d in detections.rows) d.id];
    final sprayIds = [for (final s in sprays.rows) s.msgId];
    expect(detectionIds.toSet(), hasLength(detectionIds.length));
    expect(sprayIds.toSet(), hasLength(sprayIds.length));
    expectNewestFirst<Detection>(detections.rows, (d) => d.detectedAt, (d) => d.id);
    expectNewestFirst<SprayRecord>(sprays.rows, (s) => s.time, (s) => s.msgId);
    expect(recorder.sent.every((s) => s.method == 'GET'), isTrue);
    expect(services.live.connectAttempts, attempts, reason: 'no new connection for any of this');
    // ignore: avoid_print
    print('IT-PEST live dedup: after refresh + older page detections=${detectionIds.length} unique=${detectionIds.toSet().length} sprays=${sprayIds.length} unique=${sprayIds.toSet().length} liveState=${services.dashboard.liveState.name}');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 7)));

  test('device scope: with another device selected, requests are for that device only and the simulator\'s new detections add nothing', () async {
    final (services, recorder) = await pestPageOnSimulator();
    final dashboard = services.dashboard;
    final history = services.pestHistory;
    await ensureDeviceClaimed(services, otherDevice, 'Second device (reports nothing)');
    final raw = await rawClient(farmer);
    Future<String?> newestSimDetection() async => (await rawItems(raw, detectionsPath, {'deviceId': simDevice, 'limit': 1})).firstOrNull?['id'] as String?;

    final requestsBefore = recorder.sent.length;
    await dashboard.selectDevice(otherDevice);
    expect(dashboard.data!.device!.deviceId, otherDevice);
    await until(() => dashboard.liveState == LiveState.connected, timeout: const Duration(seconds: 20), what: 'the live connection for the other device');
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await until(() => settled(services) && history.detections.phase == HistoryPhase.ready && history.sprays.phase == HistoryPhase.ready, timeout: const Duration(seconds: 20), what: 'the other device\'s history');
    expect(history.deviceId, otherDevice);
    expect(history.detections.rows.every((d) => d.deviceId == otherDevice), isTrue, reason: 'nothing of the previous device');
    expect(history.sprays.rows.every((s) => s.deviceId == otherDevice), isTrue);
    final switchRequests = recorder.sent.sublist(requestsBefore);
    for (final request in switchRequests.where((s) => s.path == detectionsPath)) {
      expect(request.query['deviceId'], otherDevice);
    }
    for (final request in switchRequests.where((s) => s.path.endsWith('/events'))) {
      expect(request.path, eventsPath(otherDevice));
    }
    expect(switchRequests.where((s) => s.path == detectionsPath && s.query['limit'] != 1), isNotEmpty);
    expect(switchRequests.where((s) => s.path == eventsPath(otherDevice)), isNotEmpty);

    // The simulator keeps reporting for ITS device: wait until the backend holds a new detection.
    final shownDetections = [for (final d in history.detections.rows) d.id];
    final shownSprays = [for (final s in history.sprays.rows) s.msgId];
    final newestBefore = await newestSimDetection();
    String? newestNow = newestBefore;
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (newestNow == newestBefore) {
      if (DateTime.now().isAfter(deadline)) fail('timed out waiting for a new detection of $simDevice on the backend');
      await Future<void>.delayed(const Duration(seconds: 2));
      newestNow = await newestSimDetection();
    }
    await Future<void>.delayed(const Duration(seconds: 2)); // its live event has been delivered by now
    expect(dashboard.liveState, LiveState.connected);
    expect([for (final d in history.detections.rows) d.id], shownDetections, reason: 'an event of another device adds no row');
    expect([for (final s in history.sprays.rows) s.msgId], shownSprays);
    expect(history.detections.rows.any((d) => d.id == newestNow), isFalse);

    // Back to the simulator's device: its history is read again and holds that detection.
    final before = recorder.sent.length;
    await dashboard.selectDevice(simDevice);
    await until(() => settled(services) && history.deviceId == simDevice && history.detections.phase == HistoryPhase.ready && history.sprays.phase == HistoryPhase.ready, timeout: const Duration(seconds: 30), what: 'the simulator device\'s history');
    expect(history.detections.rows.any((d) => d.id == newestNow), isTrue);
    expect(history.detections.rows.every((d) => d.deviceId == simDevice), isTrue);
    expect(history.sprays.rows.every((s) => s.deviceId == simDevice), isTrue);
    for (final request in recorder.sent.sublist(before).where((s) => s.path == detectionsPath)) {
      expect(request.query['deviceId'], simDevice);
    }
    // ignore: avoid_print
    print('IT-PEST scope: $simDevice -> $otherDevice: history requests for $otherDevice only; shown detections=${shownDetections.length} sprays=${shownSprays.length}; '
        'new $simDevice detection $newestNow reached the backend and added no row; back to $simDevice: listed=${history.detections.rows.any((d) => d.id == newestNow)}');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 7)));

  test('authorization is the backend\'s: another farmer cannot read the device\'s detections or sprays', () async {
    final owner = await signedIn(farmer);
    await ensureSimulatorDeviceClaimed(owner);
    final other = await signedIn(otherFarmer);
    final repository = PestHistoryRepository(api: other.api);
    await expectLater(repository.detections(simDevice, limit: HistoryFeed.pageSize), throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', ApiFailureKind.notFound)));
    await expectLater(repository.sprays(simDevice, limit: HistoryFeed.pageSize), throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', ApiFailureKind.notFound)));
    // ignore: avoid_print
    print('IT-PEST authorization: $otherFarmer asking for the detections and sprays of $simDevice -> not found (both)');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
