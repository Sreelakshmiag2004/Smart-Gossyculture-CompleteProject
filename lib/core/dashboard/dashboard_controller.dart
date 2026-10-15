import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_failure.dart';
import '../models.dart';
import '../realtime/live_connection.dart';
import '../realtime/live_messages.dart';
import 'dashboard_repository.dart';

/// What the dashboard shows, exactly as the backend returned it.
class DashboardData {
  const DashboardData({required this.devices, required this.loadedAt, this.device, this.telemetry, this.latestDetection});

  /// The caller's active devices (empty only if onboarding state changed on the backend).
  final List<Device> devices;

  /// The device whose data is shown.
  final Device? device;

  /// Newest telemetry row of [device]; null = the device has not sent any reading.
  final TelemetryPoint? telemetry;

  /// Newest detection reported by [device]; null = none.
  final Detection? latestDetection;

  /// When the values shown were last received from the backend - by a REST load or by a live
  /// event (phone clock).
  final DateTime loadedAt;
}

enum DashboardPhase {
  /// Nothing requested yet.
  idle,

  /// First load in progress; nothing to show.
  loading,

  /// [DashboardController.data] is available (possibly from an earlier load, see `failure`).
  ready,

  /// The first load failed; nothing to show.
  error,
}

/// Whether the reading shown can be taken as the device's current one.
///
/// The rule uses only what the backend reports. Base rule (Phase 4): a reading is "last known"
/// when the app cannot be receiving newer ones, or when the backend says the device is not
/// connected. On top of it (Phase 5A): a reading is also "last known" when the backend has
/// received no telemetry for the device's `telemetryStaleAfter` (180 s in the contract) - a
/// device that is online but has stopped reporting. That age is counted from the backend's
/// receipt time against the server's clock, never from the device's timestamp or the phone's
/// clock.
enum ReadingFreshness {
  /// The live channel is connected, the backend reports the device online and telemetry is
  /// arriving: this is the newest reading the backend holds, and a newer one would arrive here.
  live,

  /// The device is online and the app is connected, but the backend has received no telemetry
  /// for longer than the device's threshold.
  noRecentReading,

  /// The backend reports the device offline (the device said so, or the broker's Last Will).
  deviceOffline,

  /// The device has never reported a connection state.
  deviceStatusUnknown,

  /// The app's live channel is not connected: a newer reading may exist on the backend.
  notConnected,
}

/// Loads the dashboard snapshot over REST on request and, while the dashboard page is open,
/// keeps it current from the live channel.
///
/// * REST gives the initial state: data is fetched when the dashboard opens, when the user
///   refreshes, and when the device is changed. There is no polling.
/// * The live channel only replaces a value with a NEWER one of the same kind for the device
///   shown: the telemetry row, the detection, the connection status. Nothing else is derived
///   from an event.
/// * A lost live connection changes nothing that is shown; the values stay until newer ones
///   arrive.
/// * The live connection exists only while a dashboard page is open and the app is in the
///   foreground. Returning to the foreground reads the snapshot again before reconnecting.
class DashboardController extends ChangeNotifier {
  DashboardController(this._repository, {LiveConnection? live, DateTime Function()? clock})
      : _live = live,
        _clock = clock ?? DateTime.now {
    _live?.addListener(_onLiveChanged);
  }

  /// When live updates were switched off because the backend refused the session's token on
  /// the live channel, the app tries again by itself after these delays - three times at most.
  /// After that it stays off until the user refreshes or the app returns to the foreground.
  static const List<Duration> authRetryDelays = [Duration(minutes: 1), Duration(minutes: 5), Duration(minutes: 15)];

  static const Object _anyPage = Object();

  final DashboardRepository _repository;
  final LiveConnection? _live;
  final DateTime Function() _clock;

  /// Receives every live event of the connection, whichever device it is for, before the
  /// dashboard applies it to the device shown (Phase 5B: the alerts an event carries).
  void Function(LiveEvent event)? onLiveEvent;

  /// Called when the live stream has started "from now" rather than from a cursor.
  void Function()? onLiveStreamFresh;

  DashboardPhase _phase = DashboardPhase.idle;
  DashboardData? _data;
  ApiFailure? _failure;
  bool _busy = false;
  String? _selectedDeviceId;
  int _generation = 0;

  /// The dashboard pages that are open and want live updates.
  final Set<Object> _liveOwners = {};
  bool get _liveWanted => _liveOwners.isNotEmpty;

  /// The app is in the background: no live connection is kept.
  bool _livePaused = false;

  /// Automatic attempts made since the last load (see [authRetryDelays]).
  int _authRetries = 0;
  Timer? _authRetryTimer;

  /// Fires at the moment the reading shown stops being current, so that the page says so
  /// without any new message having arrived. Armed only while the reading counts as live.
  Timer? _freshnessTimer;

  /// Counts completed snapshots; a background re-read that was overtaken is dropped.
  int _snapshots = 0;

  /// A live stream started "from now": events between the last REST read and that moment may
  /// have been missed, so the state must be read once more.
  bool _resyncDue = false;

  // Which of the shown values came from a live event since the last REST read. Only those can
  // be newer than what a REST reply contains.
  bool _telemetryFromLive = false;
  bool _detectionFromLive = false;
  bool _statusFromLive = false;

  DashboardPhase get phase => _phase;
  DashboardData? get data => _data;

  /// The failure of the most recent load. With [phase] == ready it means "refresh failed, the
  /// data shown is from [DashboardData.loadedAt]".
  ApiFailure? get failure => _failure;

  /// A request is in flight.
  bool get busy => _busy;

  /// State of the live channel. It says nothing about the device or its sensors.
  LiveState get liveState => _live?.state ?? LiveState.disconnected;

  /// Whether the reading shown is the device's current one; null when there is no reading.
  ReadingFreshness? get freshness {
    final data = _data;
    final device = data?.device;
    if (data == null || device == null || data.telemetry == null) return null;
    // Without the live channel the device's reported state may itself be out of date.
    if (liveState != LiveState.connected) return ReadingFreshness.notConnected;
    return switch (device.status.state) {
      'online' => _overdue(data) ? ReadingFreshness.noRecentReading : ReadingFreshness.live,
      'offline' => ReadingFreshness.deviceOffline,
      _ => ReadingFreshness.deviceStatusUnknown,
    };
  }

  /// The threshold of the device shown, for wording ("no reading for over 3 minutes").
  Duration? get staleAfter => _data?.device?.telemetryStaleAfter;

  /// How much longer the reading shown stays current: the backend's threshold minus the time
  /// since the backend received it, on the server's clock. Null when the time rule cannot be
  /// applied: the backend gave no threshold or no receipt time, or the server's clock is not
  /// known yet (it is known as soon as the live channel is connected).
  Duration? _currentFor(DashboardData data) {
    final threshold = data.device?.telemetryStaleAfter;
    final receivedAt = data.telemetry?.receivedAt;
    final offset = _live?.serverClockOffset;
    if (threshold == null || receivedAt == null || offset == null) return null;
    final serverNow = _clock().toUtc().add(offset);
    return threshold - serverNow.difference(receivedAt);
  }

  /// "No telemetry for 180 seconds": from the threshold on, the reading is no longer current.
  bool _overdue(DashboardData data) {
    final remaining = _currentFor(data);
    return remaining != null && remaining <= Duration.zero;
  }

  /// Re-evaluates the freshness when the reading shown is due to stop being current.
  void _armFreshnessTimer() {
    _freshnessTimer?.cancel();
    _freshnessTimer = null;
    final data = _data;
    if (data == null || freshness != ReadingFreshness.live) return;
    final remaining = _currentFor(data);
    if (remaining == null) return;
    // (never shorter than a millisecond: a timer that fires a moment early re-arms once, not in a loop)
    _freshnessTimer = Timer(remaining < const Duration(milliseconds: 1) ? const Duration(milliseconds: 1) : remaining, () {
      _freshnessTimer = null;
      notifyListeners(); // re-arms itself if the reading turns out to be current after all
    });
  }

  @override
  void notifyListeners() {
    // Every change of what is shown, and of the live channel, passes through here.
    _armFreshnessTimer();
    super.notifyListeners();
  }

  /// A dashboard page opened: the live connection is made after the next successful [load]
  /// (REST first, then live). Calling it again for the same [page] (rebuilds) changes nothing.
  void attachLive([Object page = _anyPage]) => _liveOwners.add(page);

  /// A dashboard page closed. When it was the last one, the socket is closed and its timers
  /// are cancelled; while another dashboard page is still open the connection is kept.
  void detachLive([Object page = _anyPage]) {
    if (!_liveOwners.remove(page) || _liveOwners.isNotEmpty) return;
    _livePaused = false;
    _cancelAuthRetry();
    _freshnessTimer?.cancel();
    _freshnessTimer = null;
    _live?.close(notify: false);
  }

  /// The app went to the background: the socket is closed and every timer is cancelled.
  /// Nothing that is shown changes.
  void pauseLive() {
    if (_livePaused) return;
    _livePaused = true;
    _cancelAuthRetry();
    _live?.close();
  }

  /// The app is in the foreground again: the snapshot is read once more (what happened in
  /// between is not replayed), then the live connection is made as after any load.
  /// Does nothing unless [pauseLive] was called before.
  Future<void> resumeLive() async {
    if (!_livePaused) return;
    _livePaused = false;
    if (_liveWanted) await load();
  }

  /// Fetches a fresh snapshot. Safe to call repeatedly: overlapping calls are ignored.
  Future<void> load() async {
    if (_busy) return;
    final generation = _generation;
    _busy = true;
    _authRetries = 0; // asked for by the user or the page: automatic attempts may start over
    if (_data == null) _phase = DashboardPhase.loading;
    notifyListeners();
    try {
      final devices = await _repository.devices();
      final device = _choose(devices);
      TelemetryPoint? telemetry;
      Detection? detection;
      if (device != null) {
        final results = await Future.wait<Object?>([
          _repository.latestTelemetry(device.deviceId),
          _repository.latestDetection(device.deviceId),
        ]);
        telemetry = results[0] as TelemetryPoint?;
        detection = results[1] as Detection?;
      }
      if (generation != _generation) return; // signed out meanwhile
      _selectedDeviceId = device?.deviceId;
      _applySnapshot(devices, device, telemetry, detection);
      _failure = null;
      _phase = DashboardPhase.ready;
      _ensureLive();
    } on ApiFailure catch (failure) {
      if (generation != _generation) return;
      // An ended session is handled by the app shell (tokens cleared, return to sign-in).
      if (failure.kind != ApiFailureKind.sessionExpired) {
        _failure = failure;
        _phase = _data == null ? DashboardPhase.error : DashboardPhase.ready;
        // An earlier snapshot is still shown (e.g. back in the foreground before the network
        // is): the live channel keeps trying with its backoff and re-reads the state once it
        // is connected. Without any snapshot no connection is made.
        if (_data != null) _ensureLive();
      }
    } finally {
      if (generation == _generation) {
        _busy = false;
        notifyListeners();
      }
    }
  }

  /// Shows another of the caller's devices. Nothing from the previous device is carried over:
  /// its live connection is closed before the new device's snapshot is requested.
  Future<void> selectDevice(String deviceId) async {
    if (_busy || deviceId == _selectedDeviceId) return;
    _cancelAuthRetry();
    _live?.close();
    _selectedDeviceId = deviceId;
    _data = null; // the previous device's values must not be shown for the new one
    _failure = null;
    _clearLiveMarks();
    await load();
  }

  /// The device kept from the previous selection if the backend still lists it; otherwise the
  /// most recently claimed one (the device just added during onboarding).
  Device? _choose(List<Device> devices) {
    if (devices.isEmpty) return null;
    final kept = devices.where((d) => d.deviceId == _selectedDeviceId).firstOrNull;
    if (kept != null) return kept;
    final sorted = [...devices]..sort((a, b) {
        final byClaim = (b.claimedAt ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)).compareTo(a.claimedAt ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
        return byClaim != 0 ? byClaim : a.deviceId.compareTo(b.deviceId);
      });
    return sorted.first;
  }

  /// Forgets everything (sign-out, or another user signing in).
  void reset() {
    _generation++;
    _cancelAuthRetry();
    _authRetries = 0;
    _live?.close();
    _phase = DashboardPhase.idle;
    _data = null;
    _failure = null;
    _busy = false;
    _selectedDeviceId = null;
    _resyncDue = false;
    _clearLiveMarks();
    notifyListeners();
  }

  @override
  void dispose() {
    _cancelAuthRetry();
    _freshnessTimer?.cancel();
    _freshnessTimer = null;
    _live?.removeListener(_onLiveChanged);
    _live?.close(notify: false);
    super.dispose();
  }

  // ------------------------------------------------------------------ REST snapshot

  /// Stores a REST snapshot. A value that arrived over the live channel after the reply was
  /// produced is newer than the reply and is kept; in every other case the reply is shown as is.
  void _applySnapshot(List<Device> devices, Device? device, TelemetryPoint? telemetry, Detection? detection) {
    final held = _data;
    if (device != null && held != null && held.device?.deviceId == device.deviceId) {
      final heldTelemetry = held.telemetry;
      if (_telemetryFromLive && heldTelemetry != null && (telemetry == null || _isNewer(heldTelemetry.time, heldTelemetry.msgId, telemetry.time, telemetry.msgId))) {
        telemetry = heldTelemetry;
      } else {
        _telemetryFromLive = false;
      }
      final heldDetection = held.latestDetection;
      if (_detectionFromLive && heldDetection != null && (detection == null || _isNewer(heldDetection.detectedAt, heldDetection.id, detection.detectedAt, detection.id))) {
        detection = heldDetection;
      } else {
        _detectionFromLive = false;
      }
      if (_statusFromLive) {
        final merged = _laterStatus(device.status, held.device!.status);
        if (identical(merged, device.status)) {
          _statusFromLive = false;
        } else {
          device = _withStatus(device, merged);
          devices = [for (final d in devices) d.deviceId == device.deviceId ? device : d];
        }
      }
    } else {
      _clearLiveMarks();
    }
    _snapshots++;
    _data = DashboardData(devices: devices, device: device, telemetry: telemetry, latestDetection: detection, loadedAt: _clock());
  }

  void _clearLiveMarks() {
    _telemetryFromLive = false;
    _detectionFromLive = false;
    _statusFromLive = false;
  }

  /// Rows are ordered as the REST API orders them: by device time, then by message id.
  static bool _isNewer(DateTime time, String id, DateTime thanTime, String thanId) => time.isAfter(thanTime) || (time.isAtSameMomentAs(thanTime) && id.compareTo(thanId) > 0);

  /// [rest] unless [live] holds a later state or a later "last seen"; then the later of each.
  static DeviceStatus _laterStatus(DeviceStatus rest, DeviceStatus live) {
    final liveStateAt = live.stateAt;
    final liveSeen = live.lastSeenAt;
    final stateIsLater = liveStateAt != null && (rest.stateAt == null || liveStateAt.isAfter(rest.stateAt!));
    final seenIsLater = liveSeen != null && (rest.lastSeenAt == null || liveSeen.isAfter(rest.lastSeenAt!));
    if (!stateIsLater && !seenIsLater) return rest;
    return DeviceStatus(
      state: stateIsLater ? live.state : rest.state,
      stateAt: stateIsLater ? liveStateAt : rest.stateAt,
      lastSeenAt: seenIsLater ? liveSeen : rest.lastSeenAt,
    );
  }

  static Device _withStatus(Device device, DeviceStatus status) => Device(
        deviceId: device.deviceId,
        registrationState: device.registrationState,
        displayName: device.displayName,
        farmId: device.farmId,
        claimedAt: device.claimedAt,
        status: status,
        telemetryInterval: device.telemetryInterval,
        telemetryStaleAfter: device.telemetryStaleAfter,
      );

  // ------------------------------------------------------------------ live channel

  /// One connection while a page is open, the app is in the foreground and a device is shown;
  /// none otherwise.
  void _ensureLive() {
    final live = _live;
    if (live == null) return;
    if (!_liveWanted || _livePaused || _phase != DashboardPhase.ready || _data?.device == null) {
      if (live.isOpen) live.close();
      return;
    }
    if (live.isOpen) return;
    _cancelAuthRetry();
    _resyncDue = false;
    live.open(onEvent: _onLiveEvent, onStreamReady: _onLiveStreamReady);
  }

  void _onLiveChanged() {
    if (_live!.state == LiveState.authFailed) _scheduleAuthRetry();
    notifyListeners();
  }

  /// The live channel refused the session's token even after it was renewed, and gave up.
  /// One later attempt is scheduled, [authRetryDelays].length times at most; the count starts
  /// over only with a [load], which the user or the page asks for. Never a loop.
  void _scheduleAuthRetry() {
    if (_authRetryTimer != null || _authRetries >= authRetryDelays.length) return;
    _authRetryTimer = Timer(authRetryDelays[_authRetries++], () {
      _authRetryTimer = null;
      _ensureLive();
    });
  }

  void _cancelAuthRetry() {
    _authRetryTimer?.cancel();
    _authRetryTimer = null;
  }

  void _onLiveStreamReady({required bool fresh}) {
    if (fresh) onLiveStreamFresh?.call();
    if (fresh) _resyncDue = true;
    if (_resyncDue) _resync();
  }

  /// Reads the snapshot once more, without any loading state: the stream is live now, so
  /// whatever was ingested before it started is in this reply and nothing in between is missed.
  /// A failure is not shown - the values on screen are still the last valid ones - and the read
  /// is repeated when the stream next becomes live.
  Future<void> _resync() async {
    final deviceId = _data?.device?.deviceId;
    if (deviceId == null) return;
    final generation = _generation;
    final snapshots = _snapshots;
    try {
      final results = await Future.wait<Object?>([
        _repository.devices(),
        _repository.latestTelemetry(deviceId),
        _repository.latestDetection(deviceId),
      ]);
      if (generation != _generation || _data?.device?.deviceId != deviceId) return;
      _resyncDue = false;
      if (snapshots != _snapshots) return; // a user refresh finished meanwhile and is at least as new
      final devices = results[0]! as List<Device>;
      final device = devices.where((d) => d.deviceId == deviceId).firstOrNull;
      if (device == null) return; // no longer listed: the next refresh shows that
      _applySnapshot(devices, device, results[1] as TelemetryPoint?, results[2] as Detection?);
      if (!_busy) _failure = null; // the state has just been read: an earlier failed refresh is over
      notifyListeners();
    } on ApiFailure {
      // Kept as due. An ended session is handled by the app shell.
    }
  }

  /// Applies one event to the device shown. Events of the caller's other devices, unknown
  /// kinds and events whose data does not match the contract change nothing.
  void _onLiveEvent(LiveEvent event) {
    onLiveEvent?.call(event);
    final data = _data;
    final device = data?.device;
    if (data == null || device == null || event.deviceId != device.deviceId) return;

    var telemetry = data.telemetry;
    var detection = data.latestDetection;
    var status = device.status;
    try {
      switch (event.kind) {
        case LiveEvent.telemetry:
          final point = event.toTelemetry();
          if (telemetry == null || _isNewer(point.time, point.msgId, telemetry.time, telemetry.msgId)) {
            telemetry = point;
            _telemetryFromLive = true;
          }
        case LiveEvent.pest:
          final reported = event.toDetection();
          if (detection == null || _isNewer(reported.detectedAt, reported.id, detection.detectedAt, detection.id)) {
            detection = reported;
            _detectionFromLive = true;
          }
        case LiveEvent.status:
          // As the backend stores it: a state replaces an older one by receipt time, and an
          // "offline" (the broker's Last Will) is not evidence that the device was heard from.
          final state = event.toConnectionState();
          final stateIsLater = status.stateAt == null || event.receivedAt.isAfter(status.stateAt!);
          if (stateIsLater) status = DeviceStatus(state: state, stateAt: event.receivedAt, lastSeenAt: status.lastSeenAt);
          if (state == 'offline') break;
          status = _seenAt(status, event.receivedAt);
        default:
          // event/spray, event/harvest and kinds added later: the dashboard has no field for
          // their data. A spray or harvest record still means the device was heard from.
          if (event.kind != 'event/spray' && event.kind != 'event/harvest') return;
      }
    } on FormatException {
      return; // not a contract event: nothing is shown from it
    }
    if (event.kind != LiveEvent.status) status = _seenAt(status, event.receivedAt);

    if (identical(telemetry, data.telemetry) && identical(detection, data.latestDetection) && identical(status, device.status)) return;
    var devices = data.devices;
    var shown = device;
    if (!identical(status, device.status)) {
      _statusFromLive = true;
      shown = _withStatus(device, status);
      devices = [for (final d in devices) d.deviceId == shown.deviceId ? shown : d];
    }
    _data = DashboardData(devices: devices, device: shown, telemetry: telemetry, latestDetection: detection, loadedAt: _clock());
    notifyListeners();
  }

  static DeviceStatus _seenAt(DeviceStatus status, DateTime receivedAt) {
    if (status.lastSeenAt != null && !receivedAt.isAfter(status.lastSeenAt!)) return status;
    return DeviceStatus(state: status.state, stateAt: status.stateAt, lastSeenAt: receivedAt);
  }
}
