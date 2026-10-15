import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_failure.dart';
import '../dashboard/dashboard_controller.dart';
import '../models.dart';
import '../realtime/live_messages.dart';
import 'pest_history_repository.dart';

enum HistoryPhase {
  /// Nothing requested: what the backend holds is not known.
  idle,

  /// First page being read; nothing to show.
  loading,

  /// [HistoryFeed.rows] is available (possibly from an earlier read, see `failure`).
  ready,

  /// The first page could not be read; nothing to show.
  error,
}

/// One history list of one device, newest first, exactly as the backend holds it.
///
/// * REST gives the rows: the first page when the list is loaded or refreshed, older pages on
///   request with the backend's own cursor.
/// * A live event adds the row of a new device message. A row is identified by the id of its
///   device message - the same in the REST row and in the live event - so a row is never listed
///   twice, whichever way it arrived first.
/// * Rows are kept in the backend's order: device time, then message id, newest first. Rows do
///   not change once stored, so an event never replaces a row that is already listed.
class HistoryFeed<T> extends ChangeNotifier {
  HistoryFeed({required Future<Page<T>> Function(String deviceId, {required int limit, String? cursor}) fetch, required String Function(T row) idOf, required DateTime Function(T row) timeOf})
      : _fetch = fetch,
        _idOf = idOf,
        _timeOf = timeOf;

  /// Rows requested per page (the contract's `limit`).
  static const int pageSize = 20;

  final Future<Page<T>> Function(String deviceId, {required int limit, String? cursor}) _fetch;
  final String Function(T row) _idOf;
  final DateTime Function(T row) _timeOf;

  String? _deviceId;
  HistoryPhase _phase = HistoryPhase.idle;
  List<T> _rows = const [];
  String? _nextCursor;
  ApiFailure? _failure;
  bool _busy = false;
  bool _loadingMore = false;
  int _generation = 0;

  /// The stream started "from now" while a read was in flight: rows created in between may be
  /// in neither, so the first page is read once more.
  bool _reloadDue = false;

  /// Rows that arrived live while a read was in flight. The reply may have been produced
  /// before them, so they are applied again on top of it.
  final List<T> _arrivedDuringLoad = [];

  /// The device whose history this is; null = none selected.
  String? get deviceId => _deviceId;
  HistoryPhase get phase => _phase;
  List<T> get rows => _rows;

  /// The backend has older rows than the ones loaded.
  bool get hasMore => _nextCursor != null;

  /// The failure of the most recent read. With [phase] == ready it means "the rows shown are
  /// from the last successful read".
  ApiFailure? get failure => _failure;
  bool get busy => _busy;
  bool get loadingMore => _loadingMore;

  /// Another device (or none): everything held for the previous one is dropped, and a reply
  /// still on its way for it is ignored.
  void switchTo(String? deviceId) {
    if (deviceId == _deviceId && _phase == HistoryPhase.idle && !_busy) return;
    _generation++;
    _deviceId = deviceId;
    _phase = HistoryPhase.idle;
    _rows = const [];
    _nextCursor = null;
    _failure = null;
    _busy = false;
    _loadingMore = false;
    _reloadDue = false;
    _arrivedDuringLoad.clear();
    notifyListeners();
  }

  /// Reads the first (newest) page. Safe to call repeatedly: overlapping calls are ignored.
  Future<void> load() async {
    final deviceId = _deviceId;
    if (deviceId == null || _busy) return;
    final generation = _generation;
    _busy = true;
    _reloadDue = false;
    _arrivedDuringLoad.clear();
    if (_phase != HistoryPhase.ready) _phase = HistoryPhase.loading;
    notifyListeners();
    try {
      final page = await _fetch(deviceId, limit: pageSize);
      if (generation != _generation) return; // another device, or signed out, meanwhile
      _rows = _unique(page.items);
      _nextCursor = page.nextCursor;
      for (final row in List.of(_arrivedDuringLoad)) {
        _insert(row);
      }
      _failure = null;
      _phase = HistoryPhase.ready;
    } on ApiFailure catch (failure) {
      if (generation != _generation) return;
      // An ended session is handled by the app shell (tokens cleared, return to sign-in).
      if (failure.kind != ApiFailureKind.sessionExpired) {
        _failure = failure;
        if (_phase != HistoryPhase.ready) _phase = HistoryPhase.error;
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

  /// Appends the next (older) page, asked for with the backend's cursor.
  Future<void> loadMore() async {
    final deviceId = _deviceId;
    final cursor = _nextCursor;
    if (deviceId == null || cursor == null || _busy || _loadingMore || _phase != HistoryPhase.ready) return;
    final generation = _generation;
    _loadingMore = true;
    notifyListeners();
    try {
      final page = await _fetch(deviceId, limit: pageSize, cursor: cursor);
      if (generation != _generation || _nextCursor != cursor) return; // reloaded meanwhile
      final known = {for (final row in _rows) _idOf(row)};
      _rows = [..._rows, ...page.items.where((row) => known.add(_idOf(row)))];
      _nextCursor = page.nextCursor;
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

  /// A row from a live event of this feed's device. Ignored until the list has been asked for.
  void addLive(T row) {
    if (_phase == HistoryPhase.idle) return;
    if (_busy) _arrivedDuringLoad.add(row);
    if (_phase != HistoryPhase.ready) return;
    if (_insert(row)) notifyListeners();
  }

  /// The live stream started "from now": what was created before that moment is not replayed,
  /// so the first page is read again. Does nothing until the list has been asked for.
  void onStreamFresh() {
    if (_phase == HistoryPhase.idle) return;
    if (_busy) {
      _reloadDue = true;
    } else {
      unawaited(load());
    }
  }

  /// Puts [row] at its place. Returns false when it is already listed, or when it is older
  /// than the loaded rows while the backend has older pages - then it belongs to a page that
  /// has not been loaded and will come with it.
  bool _insert(T row) {
    final id = _idOf(row);
    if (_rows.any((held) => _idOf(held) == id)) return false;
    if (_nextCursor != null && (_rows.isEmpty || _compare(row, _rows.last) > 0)) return false;
    final position = _rows.indexWhere((held) => _compare(row, held) < 0);
    _rows = [..._rows]..insert(position < 0 ? _rows.length : position, row);
    return true;
  }

  List<T> _unique(List<T> rows) {
    final seen = <String>{};
    return [
      for (final row in rows)
        if (seen.add(_idOf(row))) row,
    ];
  }

  /// The REST order: newest device time first, then the larger message id first.
  int _compare(T a, T b) {
    final byTime = _timeOf(b).compareTo(_timeOf(a));
    return byTime != 0 ? byTime : _idOf(b).compareTo(_idOf(a));
  }
}

/// Detection history and spray history of the device selected on the dashboard (Pest page).
///
/// * The device is the dashboard's: this class has no selection of its own. When the dashboard
///   shows another device, both lists are emptied and - while a Pest page is open - read again
///   for that device.
/// * New rows come from `event/pest` and `event/spray` events of the dashboard's existing live
///   connection. This class opens no connection, keeps no cursor and has no timer.
/// * Read-only: nothing here writes to the backend or reaches a device.
class PestHistoryController {
  PestHistoryController(PestHistoryRepository repository, this._dashboard)
      : detections = HistoryFeed<Detection>(fetch: repository.detections, idOf: (row) => row.id, timeOf: (row) => row.detectedAt),
        sprays = HistoryFeed<SprayRecord>(fetch: repository.sprays, idOf: (row) => row.msgId, timeOf: (row) => row.time) {
    _dashboard.addListener(_followDashboard);
  }

  final DashboardController _dashboard;

  /// Detections the selected device reported.
  final HistoryFeed<Detection> detections;

  /// Spray actions the selected device reported.
  final HistoryFeed<SprayRecord> sprays;

  /// The Pest pages that are open.
  final Set<Object> _pages = {};

  /// The device both lists are for: the one the dashboard shows. Null when it shows none.
  String? get deviceId => detections.deviceId;

  /// A Pest page opened. The page then calls [load].
  void attach(Object page) => _pages.add(page);

  /// A Pest page closed. With the last one, the lists are forgotten: nothing is read or kept
  /// for a page that is not shown.
  void detach(Object page) {
    if (!_pages.remove(page) || _pages.isNotEmpty) return;
    detections.switchTo(deviceId);
    sprays.switchTo(deviceId);
  }

  /// Reads the first page of both lists for the selected device.
  Future<void> load() async {
    await Future.wait([detections.load(), sprays.load()]);
  }

  /// A live event arrived on the dashboard's connection. Only a detection or a spray of the
  /// selected device adds a row; an event that does not match the contract adds nothing.
  void onLiveEvent(LiveEvent event) {
    if (event.deviceId != deviceId) return;
    try {
      switch (event.kind) {
        case LiveEvent.pest:
          detections.addLive(event.toDetection());
        case LiveEvent.spray:
          sprays.addLive(event.toSpray());
      }
    } on FormatException {
      // not a contract event: nothing is shown from it
    }
  }

  void onLiveStreamFresh() {
    detections.onStreamFresh();
    sprays.onStreamFresh();
  }

  /// Forgets everything (sign-out, or another user signing in).
  void reset() => _switchTo(null);

  void _followDashboard() => _switchTo(_dashboard.data?.device?.deviceId);

  void _switchTo(String? selected) {
    if (selected == deviceId) return;
    detections.switchTo(selected);
    sprays.switchTo(selected);
    if (selected != null && _pages.isNotEmpty) unawaited(load());
  }
}
