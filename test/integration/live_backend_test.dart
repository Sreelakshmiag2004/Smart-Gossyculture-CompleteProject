// Phase 3C: the live channel against the LOCAL DEVELOPMENT backend with the running simulator
// (backend/deploy/dev/compose.yaml, started with `--profile simulator`).
//
//   simulator -> MQTT/TLS -> ingest -> PostgreSQL/TimescaleDB -> NOTIFY -> API WebSocket
//             -> app live connection -> dashboard controller
//
// Skipped unless GOSSY_IT_BASE_URL and GOSSY_IT_OTP_CODE are set (see it_support.dart).
// Three checks take long or need something done to the stack while they wait, and are skipped
// unless asked for:
//   GOSSY_IT_WAIT_TOKEN_EXPIRY=1  - wait about 15 minutes for the access token to expire
//   GOSSY_IT_SILENT_DEVICE=sim-0002 - a second simulator started with --silent-after (Phase 5A)
//   GOSSY_IT_RESTART_SIMULATOR=1  - restart the simulator container during the test (status events)
//   GOSSY_IT_RESTART_API=1        - restart the api container during the test (reconnect + resume)
//
// Only allow-listed +999 test numbers are used. Not a production test.

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/app_services.dart';
import 'package:smart_gossy_culture_app/core/auth/session_controller.dart';
import 'package:smart_gossy_culture_app/core/dashboard/dashboard_controller.dart';
import 'package:smart_gossy_culture_app/core/realtime/live_connection.dart';
import 'package:smart_gossy_culture_app/core/realtime/live_messages.dart';
import 'package:smart_gossy_culture_app/core/realtime/live_socket.dart';

import 'it_support.dart';

/// Polls [condition] in real time.
Future<void> until(bool Function() condition, {required Duration timeout, required String what}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out after $timeout waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// Counts the REST requests the app sends (to tell a live update from a reload).
int Function() countRequests(AppServices services) {
  var sent = 0;
  services.api.authed.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
    sent++;
    handler.next(options);
  }));
  return () => sent;
}

/// The dashboard as the page opens it: live wanted, snapshot loaded, the simulator's device shown.
Future<AppServices> dashboardOnSimulator() async {
  final services = await signedIn(farmer);
  await ensureSimulatorDeviceClaimed(services);
  final dashboard = services.dashboard..attachLive();
  await dashboard.load();
  if (dashboard.data!.device!.deviceId != simDevice) await dashboard.selectDevice(simDevice);
  addTearDown(dashboard.detachLive);
  await until(() => dashboard.liveState == LiveState.connected, timeout: const Duration(seconds: 20), what: 'the live connection');
  return services;
}

void main() {
  final skip = skipReason;

  test('authentication is the contract\'s: no token or a wrong token is refused on the upgrade; the session token is accepted', () async {
    final url = liveUrlFor(Uri.parse(baseUrl!));
    await expectLater(connectLiveSocket(url, const {}), throwsA(isA<LiveHandshakeRejected>()));
    await expectLater(connectLiveSocket(url, const {'Authorization': 'Bearer not-a-valid-jwt'}), throwsA(isA<LiveHandshakeRejected>()));

    final services = await signedIn(farmer);
    final token = await services.api.interceptor.accessToken();
    final socket = await connectLiveSocket(url, {'Authorization': 'Bearer $token'});
    final hello = LiveMessage.parse(await socket.frames.first) as LiveHello;
    await socket.close();
    expect(hello.protocol, liveProtocol);
    expect(hello.heartbeatInterval, greaterThan(Duration.zero));
    // ignore: avoid_print
    print('IT-LIVE auth: no token -> refused; invalid token -> refused; session token -> hello protocol=${hello.protocol} latestCursor=${hello.latestCursor} heartbeat=${hello.heartbeatInterval.inMilliseconds}ms url=$url');
  }, skip: skip);

  test('REST snapshot, then a telemetry event produced by the running simulator updates the dashboard data', () async {
    final services = await dashboardOnSimulator();
    final dashboard = services.dashboard;
    final sent = countRequests(services);
    final snapshot = dashboard.data!;
    expect(snapshot.telemetry, isNotNull, reason: 'the simulator must be running (docker compose --profile simulator up -d simulator)');
    final restMsg = snapshot.telemetry!.msgId;

    // Let the background re-read that follows the start of the stream finish, then stop counting it.
    await Future<void>.delayed(const Duration(seconds: 1));
    final requestsBefore = sent();
    final before = dashboard.data!.telemetry!;
    await until(() => dashboard.data!.telemetry!.msgId != before.msgId, timeout: const Duration(seconds: 30), what: 'a live telemetry event');
    final live = dashboard.data!.telemetry!;
    expect(sent(), requestsBefore, reason: 'the new reading arrived over the live channel, not through a REST request');
    expect(live.time.isAfter(before.time), isTrue);
    expect(dashboard.liveState, LiveState.connected);
    expect(dashboard.failure, isNull);

    // The live value is the same row the REST API serves for that message.
    final raw = await rawClient(farmer);
    final page = (await raw.get<dynamic>('/api/v1/devices/$simDevice/telemetry', queryParameters: {'limit': 50})).data as Map;
    final row = (page['items'] as List).cast<Map>().firstWhere((r) => r['msgId'] == live.msgId);
    expect(live.batteryPct, (row['batteryPct'] as num).toDouble());
    expect(live.moistureRhPct, (row['moistureRhPct'] as num?)?.toDouble());
    expect(live.airTempC, (row['airTempC'] as num?)?.toDouble());
    expect(live.bollsHarvestedTotal, row['bollsHarvestedTotal']);
    expect(live.solarActive, row['solarActive']);
    expect(live.time, DateTime.parse(row['time'] as String).toUtc());
    // ignore: avoid_print
    print('IT-LIVE service: device=$simDevice restSnapshotMsgId=$restMsg liveMsgId=${live.msgId} time=${live.time.toIso8601String()} battery=${live.batteryPct} moisture=${live.moistureRhPct} '
        'airTemp=${live.airTempC} bolls=${live.bollsHarvestedTotal} solar=${live.solarActive} restRequestsDuringLiveUpdate=${sent() - requestsBefore} state=${dashboard.liveState.name}');

    // It keeps following the simulator: several more readings, strictly newer each time.
    var last = live;
    for (var i = 0; i < 2; i++) {
      final seen = last;
      await until(() => dashboard.data!.telemetry!.msgId != seen.msgId, timeout: const Duration(seconds: 30), what: 'the next live telemetry event');
      expect(dashboard.data!.telemetry!.time.isAfter(seen.time), isTrue);
      last = dashboard.data!.telemetry!;
    }
    expect(sent(), requestsBefore);
    expect(dashboard.data!.device!.status.lastSeenAt!.isAfter(snapshot.device!.status.lastSeenAt!), isTrue, reason: '"last heard from" follows the live events');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));

  test('a detection reported by the simulator arrives over the live channel and matches GET /detections', () async {
    final services = await dashboardOnSimulator();
    final dashboard = services.dashboard;
    final sent = countRequests(services);
    await Future<void>.delayed(const Duration(seconds: 1));
    final requestsBefore = sent();
    final before = dashboard.data!.latestDetection?.id;
    // The simulator reports a detection with probability 0.1 per 5 s tick.
    await until(() => dashboard.data!.latestDetection?.id != before, timeout: const Duration(minutes: 5), what: 'a live detection event (simulator pest probability 0.1 per tick)');
    final detection = dashboard.data!.latestDetection!;
    expect(sent(), requestsBefore);
    final raw = await rawClient(farmer);
    final page = (await raw.get<dynamic>('/api/v1/detections', queryParameters: {'deviceId': simDevice, 'limit': 20})).data as Map;
    final row = (page['items'] as List).cast<Map>().firstWhere((r) => r['id'] == detection.id);
    expect(detection.label, row['label']);
    expect(detection.confidence, (row['confidence'] as num).toDouble());
    expect(detection.detectedAt, DateTime.parse(row['detectedAt'] as String).toUtc());
    expect(detection.deviceId, simDevice);
    // ignore: avoid_print
    print('IT-LIVE detection: device=$simDevice id=${detection.id} label=${detection.label} confidence=${detection.confidence} detectedAt=${detection.detectedAt.toIso8601String()} previousId=$before restRequests=${sent() - requestsBefore}');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 6)));

  test('events are filtered by the backend: another farmer\'s connection receives nothing for the device', () async {
    final owner = await dashboardOnSimulator();
    final other = await signedIn(otherFarmer);
    expect((await other.onboarding.listDevices()).map((d) => d.deviceId), isNot(contains(simDevice)));
    final received = <LiveEvent>[];
    other.live.open(onEvent: received.add, onStreamReady: ({required bool fresh}) {});
    addTearDown(other.live.close);
    await until(() => other.live.state == LiveState.connected, timeout: const Duration(seconds: 20), what: 'the other farmer\'s live connection');
    final ownerBefore = owner.dashboard.data!.telemetry!.msgId;
    await until(() => owner.dashboard.data!.telemetry!.msgId != ownerBefore, timeout: const Duration(seconds: 30), what: 'an event for the owner');
    await Future<void>.delayed(const Duration(seconds: 6));
    expect(received.where((e) => e.deviceId == simDevice), isEmpty);
    // ignore: avoid_print
    print('IT-LIVE authorization: owner received live events for $simDevice; $otherFarmer connected for the same period and received ${received.length} event(s), none for $simDevice');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('switching device closes the connection and opens a new one after the new snapshot', () async {
    final services = await dashboardOnSimulator();
    final dashboard = services.dashboard;
    final others = dashboard.data!.devices.where((d) => d.deviceId != simDevice).toList();
    if (others.isEmpty) {
      // ignore: avoid_print
      print('IT-LIVE switch: $farmer owns only $simDevice; skipping the device-switch check');
      return;
    }
    final states = <LiveState>[];
    services.live.addListener(() => states.add(services.live.state));
    await dashboard.selectDevice(others.first.deviceId);
    expect(dashboard.data!.device!.deviceId, others.first.deviceId);
    await until(() => dashboard.liveState == LiveState.connected, timeout: const Duration(seconds: 20), what: 'the new live connection');
    expect(states.first, LiveState.disconnected, reason: 'the old connection was closed first');
    expect(states.last, LiveState.connected);
    // The simulator keeps publishing for its own device; the other device's values do not move.
    final shown = dashboard.data!.telemetry?.msgId;
    await Future<void>.delayed(const Duration(seconds: 8));
    expect(dashboard.data!.telemetry?.msgId, shown);
    expect(dashboard.data!.device!.deviceId, others.first.deviceId);
    // ignore: avoid_print
    print('IT-LIVE switch: $simDevice -> ${others.first.deviceId}; live states=${states.map((s) => s.name).join('>')}; telemetry of the silent device unchanged (${shown ?? 'none'}) while $simDevice kept publishing');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('session revoked on the backend: the live channel is closed, the refresh is rejected, the session ends', () async {
    final services = await dashboardOnSimulator();
    final dashboard = services.dashboard;
    var forced = 0;
    services.session.onForcedSignOut = () => forced++;
    final refreshesBefore = services.api.interceptor.refreshRequests;
    // Revoked by another client of the same session (the harness reads the token from the
    // in-memory test store and never prints it).
    final raw = Dio(BaseOptions(baseUrl: baseUrl!, validateStatus: (_) => true));
    final revoked = await raw.post<dynamic>('/api/v1/auth/logout', options: Options(headers: {'Authorization': 'Bearer ${stores[services]!.session!.accessToken}'}));
    expect(revoked.statusCode, 204);
    final started = DateTime.now();
    // The backend re-checks the session of an open connection periodically (3 s in development).
    await until(() => services.session.status == SessionStatus.signedOut, timeout: const Duration(seconds: 45), what: 'the session to end');
    final took = DateTime.now().difference(started);
    expect(forced, 1);
    expect(stores[services]!.session, isNull);
    expect(dashboard.data, isNull);
    expect(dashboard.phase, DashboardPhase.idle);
    expect(dashboard.liveState, LiveState.disconnected);
    expect(services.api.interceptor.refreshRequests, refreshesBefore + 1, reason: 'exactly one refresh attempt');
    final attempts = services.live.connectAttempts;
    await Future<void>.delayed(const Duration(seconds: 8));
    expect(services.live.connectAttempts, attempts, reason: 'nothing reconnects after the session ended');
    expect(services.api.interceptor.refreshRequests, refreshesBefore + 1);
    // ignore: avoid_print
    print('IT-LIVE session: logout on the backend -> live channel closed and session ended after ${took.inMilliseconds} ms; refresh attempts=1; forcedSignOut=$forced; reconnect attempts afterwards=0');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('Phase 4 - background and foreground: closed while away; on return the snapshot is re-read and the stream is live again', () async {
    final services = await dashboardOnSimulator();
    final dashboard = services.dashboard;
    final sent = countRequests(services);
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(dashboard.freshness, ReadingFreshness.live, reason: 'connected, and the backend reports the simulator online');
    final atPause = dashboard.data!.telemetry!;

    dashboard.pauseLive(); // what the page does when Android reports "paused"
    expect(dashboard.liveState, LiveState.disconnected);
    expect(dashboard.freshness, ReadingFreshness.notConnected);
    final requestsAtPause = sent();
    final attemptsAtPause = services.live.connectAttempts;
    // long enough for the simulator to publish at least two readings (one every 5 s)
    await Future<void>.delayed(const Duration(seconds: 12));
    expect(sent(), requestsAtPause, reason: 'no request in the background');
    expect(services.live.connectAttempts, attemptsAtPause, reason: 'no connection attempt in the background');
    expect(dashboard.data!.telemetry!.msgId, atPause.msgId, reason: 'the values shown are kept as they were');

    await dashboard.resumeLive(); // "resumed"
    final afterRest = dashboard.data!.telemetry!;
    expect(afterRest.time.isAfter(atPause.time), isTrue, reason: 'the REST snapshot brought what was missed');
    expect(dashboard.failure, isNull);
    await until(() => dashboard.liveState == LiveState.connected, timeout: const Duration(seconds: 20), what: 'the live connection after the return');
    expect(dashboard.freshness, ReadingFreshness.live);
    await Future<void>.delayed(const Duration(seconds: 1)); // the background re-read after the fresh start
    final requestsBefore = sent();
    final shown = dashboard.data!.telemetry!.msgId;
    await until(() => dashboard.data!.telemetry!.msgId != shown, timeout: const Duration(seconds: 30), what: 'a live event after the return');
    expect(sent(), requestsBefore, reason: 'that reading arrived over the live channel');
    expect(services.session.status, SessionStatus.signedIn);
    // ignore: avoid_print
    print('IT-LIVE lifecycle: paused 12 s -> state=disconnected, requests=0, connection attempts=0, shown msgId kept=${atPause.msgId}; resumed -> REST msgId=${afterRest.msgId} '
        '(${afterRest.time.difference(atPause.time).inMilliseconds} ms newer), live state=${dashboard.liveState.name}, freshness=${dashboard.freshness!.name}, next live msgId=${dashboard.data!.telemetry!.msgId}, restRequestsDuringLiveUpdate=${sent() - requestsBefore}');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('Phase 5A - the backend gives the receipt time and the freshness threshold; a reporting device is live by them', () async {
    final services = await dashboardOnSimulator();
    final dashboard = services.dashboard;
    await Future<void>.delayed(const Duration(seconds: 1));
    final device = dashboard.data!.device!;
    // the contract values, from the backend - nothing in the app defines them
    expect(device.telemetryInterval, const Duration(seconds: 60));
    expect(device.telemetryStaleAfter, const Duration(seconds: 180));
    expect(dashboard.staleAfter, const Duration(seconds: 180));

    // REST: receivedAt equals what the API returns for that message, and is the backend's time
    final rest = dashboard.data!.telemetry!;
    expect(rest.receivedAt, isNotNull);
    final raw = await rawClient(farmer);
    final page = (await raw.get<dynamic>('/api/v1/devices/$simDevice/telemetry', queryParameters: {'limit': 50})).data as Map;
    final rows = {for (final r in (page['items'] as List).cast<Map>()) r['msgId'] as String: r};
    expect(rest.receivedAt, DateTime.parse(rows[rest.msgId]!['receivedAt'] as String).toUtc());

    // the server's clock is known from the live channel, so the phone's clock is not what counts
    final offset = services.live.serverClockOffset;
    expect(offset, isNotNull);
    DateTime serverNow() => DateTime.now().toUtc().add(services.live.serverClockOffset!);
    final age = serverNow().difference(rest.receivedAt!);
    expect(age < const Duration(seconds: 180), isTrue, reason: 'the simulator reports every few seconds (age $age)');
    expect(dashboard.freshness, ReadingFreshness.live);

    // a live event carries the receipt time too, and REST then returns the same value for it
    final before = dashboard.data!.telemetry!.msgId;
    await until(() => dashboard.data!.telemetry!.msgId != before, timeout: const Duration(seconds: 30), what: 'a live telemetry event');
    final live = dashboard.data!.telemetry!;
    expect(live.receivedAt, isNotNull);
    expect(live.receivedAt!.isAfter(rest.receivedAt!), isTrue);
    final again = (await raw.get<dynamic>('/api/v1/devices/$simDevice/telemetry', queryParameters: {'limit': 50})).data as Map;
    final row = (again['items'] as List).cast<Map>().firstWhere((r) => r['msgId'] == live.msgId);
    expect(live.receivedAt, DateTime.parse(row['receivedAt'] as String).toUtc(), reason: 'live event and REST agree on the receipt time');
    expect(dashboard.freshness, ReadingFreshness.live);
    // ignore: avoid_print
    print('IT-LIVE freshness: device=$simDevice intervalS=${device.telemetryInterval!.inSeconds} staleAfterS=${device.telemetryStaleAfter!.inSeconds} serverClockOffsetMs=${offset!.inMilliseconds} '
        'restMsgId=${rest.msgId} restReceivedAt=${rest.receivedAt!.toIso8601String()} ageAtLoadMs=${age.inMilliseconds} liveMsgId=${live.msgId} liveReceivedAt=${live.receivedAt!.toIso8601String()} '
        'deviceTime=${live.time.toIso8601String()} freshness=${dashboard.freshness!.name}');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('Phase 5A - online but silent: the device stays online, and after 180 s without telemetry its reading is "last known"', () async {
    final silentDevice = Platform.environment['GOSSY_IT_SILENT_DEVICE']!;
    final services = await signedIn(farmer);
    await ensureDeviceClaimed(services, silentDevice, 'Silent simulator');
    final dashboard = services.dashboard..attachLive();
    await dashboard.load();
    if (dashboard.data!.device!.deviceId != silentDevice) await dashboard.selectDevice(silentDevice);
    addTearDown(dashboard.detachLive);
    await until(() => dashboard.liveState == LiveState.connected, timeout: const Duration(seconds: 20), what: 'the live connection');
    await Future<void>.delayed(const Duration(seconds: 1));
    final sent = countRequests(services);
    DateTime serverNow() => DateTime.now().toUtc().add(services.live.serverClockOffset!);

    final shown = dashboard.data!.telemetry;
    expect(shown, isNotNull, reason: 'start the silent simulator first (python -m gossy_sim --device-id $silentDevice --silent-after 3)');
    final threshold = dashboard.staleAfter!;
    expect(threshold, const Duration(seconds: 180));
    expect(dashboard.data!.device!.status.state, 'online', reason: 'the silent simulator keeps its broker connection');
    final ageAtStart = serverNow().difference(shown!.receivedAt!);
    expect(ageAtStart < threshold, isTrue, reason: 'the test must start within 180 s of the last reading (age $ageAtStart)');
    expect(dashboard.freshness, ReadingFreshness.live);

    final requestsBefore = sent();
    final attemptsBefore = services.live.connectAttempts;
    final changes = <String>[];
    dashboard.addListener(() {
      final now = '${dashboard.freshness?.name}/${dashboard.data?.device?.status.state}/${dashboard.liveState.name}';
      if (changes.isEmpty || changes.last != now) changes.add(now);
    });
    await until(() => dashboard.freshness == ReadingFreshness.noRecentReading, timeout: threshold + const Duration(seconds: 30), what: 'the reading to stop being current');
    final ageAtChange = serverNow().difference(dashboard.data!.telemetry!.receivedAt!);

    // it changed at the threshold - not before, and not long after
    expect(ageAtChange >= threshold, isTrue, reason: 'age $ageAtChange');
    expect(ageAtChange < threshold + const Duration(seconds: 2), isTrue, reason: 'age $ageAtChange');
    // and nothing else changed: the same reading, the device still online, the app still connected
    expect(dashboard.data!.telemetry!.msgId, shown.msgId);
    expect(dashboard.data!.device!.status.state, 'online');
    expect(dashboard.liveState, LiveState.connected);
    expect(services.live.connectAttempts, attemptsBefore);
    expect(sent(), requestsBefore, reason: 'decided by the app\'s timer: no request was needed');
    expect(dashboard.failure, isNull);
    // the backend agrees: nothing newer over REST either, and the device is reported online
    await dashboard.load();
    expect(dashboard.data!.telemetry!.msgId, shown.msgId);
    expect(dashboard.data!.device!.status.state, 'online');
    expect(dashboard.freshness, ReadingFreshness.noRecentReading);
    // ignore: avoid_print
    print('IT-LIVE silent: device=$silentDevice status=${dashboard.data!.device!.status.state} live=${dashboard.liveState.name} msgId=${shown.msgId} receivedAt=${shown.receivedAt!.toIso8601String()} '
        'deviceTime=${shown.time.toIso8601String()} ageAtStartMs=${ageAtStart.inMilliseconds} ageAtChangeMs=${ageAtChange.inMilliseconds} thresholdS=${threshold.inSeconds} '
        'changes=${changes.join(' > ')} restRequestsWhileWaiting=${sent() - requestsBefore - 3} connectionAttempts=${services.live.connectAttempts - attemptsBefore}');
  }, skip: skip ?? (Platform.environment['GOSSY_IT_SILENT_DEVICE'] != null ? null : 'set GOSSY_IT_SILENT_DEVICE to the id of a simulator started with --silent-after (about 3 minutes)'), timeout: const Timeout(Duration(minutes: 6)));

  test('access token expires on an open connection: one refresh, resumed from the cursor, the user stays signed in', () async {
    final services = await dashboardOnSimulator();
    final dashboard = services.dashboard;
    final sent = countRequests(services);
    await Future<void>.delayed(const Duration(seconds: 1));
    final requestsBefore = sent();
    final refreshesBefore = services.api.interceptor.refreshRequests;
    final attemptsBefore = services.live.connectAttempts;
    final tokenBefore = stores[services]!.session!.accessToken;
    final states = <LiveState>[];
    services.live.addListener(() => states.add(services.live.state));
    final started = DateTime.now();
    // The backend closes the connection with 4401 when the access token it was opened with
    // expires (15 minutes in development). Nothing is done to the stack: the test only waits.
    await until(() => services.api.interceptor.refreshRequests > refreshesBefore, timeout: const Duration(minutes: 17), what: 'the access token to expire');
    final took = DateTime.now().difference(started);
    // The attempt that asked for the renewed token is already counted. Connections replaced
    // earlier for other reasons (a stalled machine, a network drop) are not this test's subject.
    final attemptsAtRefresh = services.live.connectAttempts;
    await until(() => dashboard.liveState == LiveState.connected, timeout: const Duration(seconds: 30), what: 'the connection to come back with the renewed token');
    final atReturn = dashboard.data!.telemetry!.msgId;
    await until(() => dashboard.data!.telemetry!.msgId != atReturn, timeout: const Duration(seconds: 30), what: 'a reading on the renewed connection');
    expect(services.api.interceptor.refreshRequests, refreshesBefore + 1, reason: 'exactly one refresh');
    expect(services.live.connectAttempts, attemptsAtRefresh, reason: 'the attempt that renewed the token is the one that connected: no further attempt');
    expect(stores[services]!.session!.accessToken, isNot(tokenBefore));
    expect(states.sublist(states.length - 2), [LiveState.reconnecting, LiveState.connected]);
    expect(states.toSet(), {LiveState.reconnecting, LiveState.connected}, reason: 'never switched off, never signed out');
    expect(services.session.status, SessionStatus.signedIn);
    expect(dashboard.failure, isNull);
    expect(sent(), requestsBefore, reason: 'resumed from the cursor: no REST reload was needed');
    // ignore: avoid_print
    print('IT-LIVE token expiry: connection closed by the backend after ${took.inSeconds} s; refresh requests=${services.api.interceptor.refreshRequests - refreshesBefore}; '
        'connections for the renewal=${services.live.connectAttempts - attemptsAtRefresh + 1}; other reconnections during the wait=${attemptsAtRefresh - attemptsBefore - 1}; '
        'states=${states.map((s) => s.name).join('>')}; session=${services.session.status.name}; newestAfterResume=${dashboard.data!.telemetry!.msgId}; restRequests=${sent() - requestsBefore}');
  }, skip: skip ?? (Platform.environment['GOSSY_IT_WAIT_TOKEN_EXPIRY'] == '1' ? null : 'set GOSSY_IT_WAIT_TOKEN_EXPIRY=1 to wait for the access token to expire (about 15 minutes)'), timeout: const Timeout(Duration(minutes: 20)));

  test('status events: the device going offline and online is shown from live events', () async {
    final services = await dashboardOnSimulator();
    final dashboard = services.dashboard;
    final sent = countRequests(services);
    await Future<void>.delayed(const Duration(seconds: 1));
    final requestsBefore = sent();
    final seen = <String>[dashboard.data!.device!.status.state ?? 'null'];
    final freshness = <ReadingFreshness?>[dashboard.freshness]; // Phase 4
    dashboard.addListener(() {
      final state = dashboard.data?.device?.status.state ?? 'null';
      if (state != seen.last) seen.add(state);
      if (dashboard.freshness != freshness.last) freshness.add(dashboard.freshness);
    });
    // ignore: avoid_print
    print('IT-LIVE status: waiting - restart the simulator now (docker restart gossy-dev-simulator-1)');
    await until(() => seen.contains('offline') && seen.last == 'online', timeout: const Duration(minutes: 3), what: 'offline then online status events');
    expect(sent(), requestsBefore);
    // Phase 4: while the backend reported the device offline its reading was "last known".
    expect(freshness, containsAllInOrder([ReadingFreshness.live, ReadingFreshness.deviceOffline, ReadingFreshness.live]));
    // ignore: avoid_print
    print('IT-LIVE status: device=$simDevice states seen through the live channel=${seen.join('>')} stateAt=${dashboard.data!.device!.status.stateAt!.toIso8601String()} restRequests=${sent() - requestsBefore} '
        'freshness=${freshness.map((f) => f?.name ?? 'none').join('>')}');
  }, skip: skip ?? (Platform.environment['GOSSY_IT_RESTART_SIMULATOR'] == '1' ? null : 'set GOSSY_IT_RESTART_SIMULATOR=1 and restart the simulator while the test waits'), timeout: const Timeout(Duration(minutes: 4)));

  test('API restart: the last values stay, the connection is retried with backoff and resumes from its cursor', () async {
    final services = await dashboardOnSimulator();
    final dashboard = services.dashboard;
    final sent = countRequests(services);
    await Future<void>.delayed(const Duration(seconds: 1));
    final requestsBefore = sent();
    final states = <LiveState>[];
    final delays = <Duration>[];
    services.live.addListener(() => states.add(services.live.state));
    // Every retry delay the connection chooses (the state stays "reconnecting" between attempts).
    final watcher = Timer.periodic(const Duration(milliseconds: 20), (_) {
      final delay = services.live.lastRetryDelay;
      if (services.live.state == LiveState.reconnecting && delay != null && (delays.isEmpty || delays.last != delay)) delays.add(delay);
    });
    addTearDown(watcher.cancel);
    // ignore: avoid_print
    print('IT-LIVE resume: waiting - restart the API now (docker restart gossy-dev-api-1)');
    await until(() => states.contains(LiveState.reconnecting), timeout: const Duration(minutes: 3), what: 'the connection to drop');
    final atDrop = dashboard.data!;
    expect(atDrop.telemetry, isNotNull, reason: 'values are kept while disconnected');
    expect(dashboard.failure, isNull);
    await until(() => dashboard.liveState == LiveState.connected, timeout: const Duration(minutes: 3), what: 'the connection to come back');
    await until(() => dashboard.data!.telemetry!.msgId != atDrop.telemetry!.msgId, timeout: const Duration(seconds: 30), what: 'a reading after the reconnection');
    expect(delays, isNotEmpty);
    expect(delays.every((d) => d >= const Duration(milliseconds: 500) && d <= services.live.maxDelay), isTrue, reason: '$delays');
    // Exponential: the n-th delay lies in the jitter range of its ceiling, [2^n / 2, 2^n] seconds.
    for (final (n, delay) in delays.indexed) {
      final ceiling = Duration(seconds: 1 << n) > services.live.maxDelay ? services.live.maxDelay : Duration(seconds: 1 << n);
      expect(delay >= ceiling * 0.5 && delay <= ceiling, isTrue, reason: 'retry $n waited $delay');
    }
    expect(sent(), requestsBefore, reason: 'resumed from the cursor: no REST reload was needed');
    expect(services.session.status, SessionStatus.signedIn);
    // ignore: avoid_print
    print('IT-LIVE resume: api restarted; valuesKept=${atDrop.telemetry!.msgId}; connectAttempts=${services.live.connectAttempts}; retryDelaysMs=${delays.map((d) => d.inMilliseconds).join(',')}; '
        'states=${states.map((s) => s.name).join('>')}; newestAfterResume=${dashboard.data!.telemetry!.msgId}; restRequests=${sent() - requestsBefore}');
  }, skip: skip ?? (Platform.environment['GOSSY_IT_RESTART_API'] == '1' ? null : 'set GOSSY_IT_RESTART_API=1 and restart the api container while the test waits'), timeout: const Timeout(Duration(minutes: 7)));
}
