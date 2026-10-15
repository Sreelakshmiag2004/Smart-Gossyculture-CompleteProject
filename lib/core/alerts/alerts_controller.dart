import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_failure.dart';
import '../models.dart';
import '../realtime/live_messages.dart';
import 'alerts_repository.dart';

enum AlertsPhase {
  /// Nothing requested yet: what the backend holds is not known.
  idle,

  /// First load in progress; nothing to show.
  loading,

  /// [AlertsController.alerts] is available (possibly from an earlier load, see `failure`).
  ready,

  /// The first load failed; nothing to show.
  error,
}

/// The caller's alerts, exactly as the backend holds them.
///
/// * REST gives the state: the newest page of alerts and the open (not acknowledged) ones are
///   read when the dashboard or the Notifications page opens and when the user refreshes.
/// * The live channel adds to it: every live event carries the alerts the backend created from
///   that message (`alerts[]`). They arrive over the dashboard's existing connection - this
///   class opens no connection, keeps no cursor and has no timer.
/// * "Read" is the backend's `acknowledged` status and nothing else. An alert is acknowledged
///   by the REST call, one at a time, and shown as acknowledged only from the backend's reply.
/// * The backend only ever moves an alert from open to acknowledged. So an alert known to be
///   acknowledged is never shown as open again, whichever reply or event arrives later.
class AlertsController extends ChangeNotifier {
  AlertsController(this._repository);

  /// Alerts requested per page of the list.
  static const int pageSize = 50;

  /// Open alerts requested to know how many there are. When the backend has more than this,
  /// the number is a minimum (see [openCountIsMinimum]).
  static const int openQueryLimit = 100;

  final AlertsRepository _repository;

  AlertsPhase _phase = AlertsPhase.idle;
  List<Alert> _alerts = const [];
  String? _nextCursor;
  ApiFailure? _failure;
  bool _busy = false;
  bool _loadingMore = false;
  int _generation = 0;

  /// The stream started "from now" while a load was in flight: alerts created in between may be
  /// in neither, so the state is read once more.
  bool _reloadDue = false;

  /// Ids of the alerts known to be open.
  Set<String> _openIds = {};
  bool _openMore = false;

  /// Alerts that arrived over the live channel while a load was in flight. The reply may have
  /// been produced before them, so they are applied again on top of it.
  final List<Alert> _arrivedDuringLoad = [];
  final Set<String> _acknowledging = {};

  AlertsPhase get phase => _phase;

  /// Newest first, in the backend's order (device time, then id).
  List<Alert> get alerts => _alerts;

  /// The backend has older alerts than the ones loaded.
  bool get hasMore => _nextCursor != null;

  /// The failure of the most recent load. With [phase] == ready it means "refresh failed, the
  /// alerts shown are from the last successful load".
  ApiFailure? get failure => _failure;

  /// A load is in flight.
  bool get busy => _busy;
  bool get loadingMore => _loadingMore;

  /// Whether the number of open alerts is known at all (it is not before the first load).
  bool get openCountKnown => _phase == AlertsPhase.ready;

  /// Open alerts the app knows of. Derived only from the backend's `status` field.
  int get openCount => _openIds.length;

  /// The backend has more open alerts than were requested: [openCount] is a lower bound.
  bool get openCountIsMinimum => _openMore;

  bool isAcknowledging(String alertId) => _acknowledging.contains(alertId);

  /// Reads the newest page and the open alerts. Safe to call repeatedly: overlapping calls are
  /// ignored.
  Future<void> load() async {
    if (_busy) return;
    final generation = _generation;
    _busy = true;
    _reloadDue = false;
    _arrivedDuringLoad.clear();
    if (_phase != AlertsPhase.ready) _phase = AlertsPhase.loading;
    notifyListeners();
    try {
      final pages = await Future.wait([
        _repository.list(limit: pageSize),
        _repository.list(limit: openQueryLimit, status: Alert.open),
      ]);
      if (generation != _generation) return; // signed out meanwhile
      _applySnapshot(pages[0], pages[1]);
      _failure = null;
      _phase = AlertsPhase.ready;
    } on ApiFailure catch (failure) {
      if (generation != _generation) return;
      // An ended session is handled by the app shell (tokens cleared, return to sign-in).
      if (failure.kind != ApiFailureKind.sessionExpired) {
        _failure = failure;
        if (_phase != AlertsPhase.ready) _phase = AlertsPhase.error;
      }
    } finally {
      if (generation == _generation) {
        _busy = false;
        _arrivedDuringLoad.clear();
        notifyListeners();
        if (_reloadDue) unawaited(load());
      }
    }
  }

  /// Appends the next (older) page.
  Future<void> loadMore() async {
    final cursor = _nextCursor;
    if (cursor == null || _busy || _loadingMore || _phase != AlertsPhase.ready) return;
    final generation = _generation;
    _loadingMore = true;
    notifyListeners();
    try {
      final page = await _repository.list(limit: pageSize, cursor: cursor);
      if (generation != _generation || _nextCursor != cursor) return; // reloaded meanwhile
      final known = {for (final alert in _alerts) alert.id};
      _alerts = [..._alerts, ...page.items.where((alert) => !known.contains(alert.id))];
      _nextCursor = page.nextCursor;
      for (final alert in page.items) {
        _noteStatus(alert);
      }
      _failure = null;
    } on ApiFailure catch (failure) {
      if (generation != _generation) return;
      if (failure.kind != ApiFailureKind.sessionExpired) _failure = failure;
    } finally {
      if (generation == _generation) {
        _loadingMore = false;
        notifyListeners();
      }
    }
  }

  /// Acknowledges one alert on the backend. Returns null when the backend confirmed it, or the
  /// failure - in which case nothing changes: the alert stays as the backend last reported it.
  Future<ApiFailure?> acknowledge(String alertId) async {
    if (_acknowledging.contains(alertId)) return null;
    final generation = _generation;
    _acknowledging.add(alertId);
    notifyListeners();
    try {
      final alert = await _repository.acknowledge(alertId);
      if (generation == _generation) _merge(alert);
      return null;
    } on ApiFailure catch (failure) {
      return failure;
    } finally {
      if (generation == _generation) {
        _acknowledging.remove(alertId);
        notifyListeners();
      }
    }
  }

  /// A live event arrived on the dashboard's connection. Only its `alerts[]` are used here;
  /// nothing is derived from the event's readings.
  void onLiveEvent(LiveEvent event) {
    if (event.alerts.isEmpty || _phase == AlertsPhase.idle) return;
    if (_busy) _arrivedDuringLoad.addAll(event.alerts);
    if (_phase != AlertsPhase.ready) return;
    var changed = false;
    for (final alert in event.alerts) {
      changed = _merge(alert, notify: false) || changed;
    }
    if (changed) notifyListeners();
  }

  /// The live stream started "from now" (first connection, return to the foreground, or after
  /// too many missed events): what was created before that moment is not replayed, so the state
  /// is read again. Does nothing until alerts have been asked for at least once.
  void onLiveStreamFresh() {
    if (_phase == AlertsPhase.idle) return;
    if (_busy) {
      _reloadDue = true;
    } else {
      unawaited(load());
    }
  }

  /// Forgets everything (sign-out, or another user signing in).
  void reset() {
    if (_phase == AlertsPhase.idle && !_busy) return;
    _generation++;
    _phase = AlertsPhase.idle;
    _alerts = const [];
    _nextCursor = null;
    _failure = null;
    _busy = false;
    _loadingMore = false;
    _reloadDue = false;
    _openIds = {};
    _openMore = false;
    _arrivedDuringLoad.clear();
    _acknowledging.clear();
    notifyListeners();
  }

  // ------------------------------------------------------------------ merging

  /// Stores a REST snapshot: the reply is shown as is, except that an alert already known to be
  /// acknowledged stays acknowledged, and alerts that arrived live while the request was in
  /// flight are kept.
  void _applySnapshot(Page<Alert> newest, Page<Alert> open) {
    final held = {for (final alert in _alerts) alert.id: alert};
    _alerts = [for (final alert in newest.items) _later(held[alert.id], alert)];
    _nextCursor = newest.nextCursor;
    _openIds = {
      for (final alert in open.items)
        if (alert.isOpen && !(held[alert.id]?.isAcknowledged ?? false)) alert.id,
    };
    _openMore = open.nextCursor != null;
    for (final alert in _alerts) {
      _noteStatus(alert);
    }
    for (final alert in List.of(_arrivedDuringLoad)) {
      _merge(alert, notify: false);
    }
  }

  /// [incoming] unless [held] is already acknowledged and [incoming] still says open: that
  /// reply or event is older than the acknowledgement.
  static Alert _later(Alert? held, Alert incoming) => held != null && held.isAcknowledged && incoming.isOpen ? held : incoming;

  /// Applies one alert from a live event or from an acknowledgement reply. An alert already in
  /// the list is replaced, never added twice. Returns whether anything changed.
  bool _merge(Alert alert, {bool notify = true}) {
    final index = _alerts.indexWhere((held) => held.id == alert.id);
    var changed = false;
    var effective = alert;
    if (index >= 0) {
      final held = _alerts[index];
      effective = _later(held, alert);
      if (!identical(effective, held) && (held.status != effective.status || held.acknowledgedAt != effective.acknowledgedAt)) {
        _alerts = [..._alerts]..[index] = effective;
        changed = true;
      }
    } else if (_withinLoadedRange(alert)) {
      final position = _alerts.indexWhere((held) => _compare(alert, held) < 0);
      _alerts = [..._alerts]..insert(position < 0 ? _alerts.length : position, alert);
      changed = true;
    }
    changed = _noteStatus(effective) || changed;
    if (changed && notify) notifyListeners();
    return changed;
  }

  /// Whether [alert] belongs among the alerts loaded so far. An alert older than the last
  /// loaded one, when the backend has older pages, belongs to a page not loaded yet.
  bool _withinLoadedRange(Alert alert) => _nextCursor == null || (_alerts.isNotEmpty && _compare(alert, _alerts.last) < 0);

  /// The REST order: newest device time first, then the larger id first.
  static int _compare(Alert a, Alert b) {
    final byTime = b.occurredAt.compareTo(a.occurredAt);
    return byTime != 0 ? byTime : b.id.compareTo(a.id);
  }

  bool _noteStatus(Alert alert) => alert.isOpen ? _openIds.add(alert.id) : _openIds.remove(alert.id);
}
