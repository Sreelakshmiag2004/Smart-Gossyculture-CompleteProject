import 'package:flutter/foundation.dart';

import '../api/api_failure.dart';
import '../models.dart';
import 'farm_models.dart';
import 'farm_repository.dart';

enum FarmPhase {
  /// Nothing read yet.
  idle,

  /// First read in progress; nothing to show.
  loading,

  /// [FarmController.status] and [FarmController.advisories] are available (possibly from an
  /// earlier read, see `failure`).
  ready,

  /// The first read failed; nothing to show.
  error,
}

/// The Field page's state: the selected farm, its status and current advice from the backend's
/// farm rules, and the pest catalogue for data entry. Nothing is derived here: every value is
/// what the backend computed.
class FarmController extends ChangeNotifier {
  FarmController(this._repository);

  final FarmRepository _repository;

  FarmPhase _phase = FarmPhase.idle;
  List<Farm> _farms = const [];
  String? _farmId;
  FarmStatus? _status;
  List<Advisory> _advisories = const [];
  List<PestRule> _catalog = const [];
  ApiFailure? _failure;
  bool _busy = false;
  bool _tamil = false;
  int _generation = 0;

  FarmPhase get phase => _phase;
  List<Farm> get farms => _farms;
  Farm? get farm {
    for (final f in _farms) {
      if (f.id == _farmId) return f;
    }
    return null;
  }

  FarmStatus? get status => _status;

  /// Current advice, most urgent first: rain alert, then pest actions, then the pick list.
  List<Advisory> get advisories => _advisories;
  List<PestRule> get catalog => _catalog;

  /// Pest rules the operator can count in the field (they have a scouting key).
  List<PestRule> get scoutingRules => _catalog.where((r) => r.observation != null).toList();

  ApiFailure? get failure => _failure;
  bool get busy => _busy;

  /// Show the backend's Tamil texts instead of the English ones.
  bool get tamil => _tamil;
  set tamil(bool value) {
    if (value == _tamil) return;
    _tamil = value;
    notifyListeners();
  }

  /// Owner or operator: may enter field data. (Admins may only read.)
  bool get canEnterData => farm != null;

  PestRule? ruleFor(String pest) {
    for (final r in _catalog) {
      if (r.pest == pest) return r;
    }
    return null;
  }

  static const List<String> _urgency = [Advisory.pickNow, Advisory.spotTreat, Advisory.pestEtl, Advisory.sprayBlocked, Advisory.pestAlert, Advisory.pickList];

  static List<Advisory> _ordered(List<Advisory> items) =>
      List.of(items)..sort((a, b) {
        final byType = _urgency.indexOf(a.type).compareTo(_urgency.indexOf(b.type));
        return byType != 0 ? byType : b.updatedAt.compareTo(a.updatedAt);
      });

  /// Reads the farms, keeps (or makes) a selection and reads its status and advice.
  /// [recompute] asks the backend to run the rules now instead of returning the last result.
  Future<void> load({bool recompute = false}) async {
    if (_busy) return;
    final generation = ++_generation;
    _busy = true;
    if (_phase != FarmPhase.ready) _phase = FarmPhase.loading;
    notifyListeners();
    try {
      final farms = await _repository.listFarms();
      if (generation != _generation) return;
      _farms = farms;
      if (farm == null) _farmId = farms.isEmpty ? null : farms.first.id;
      final farmId = _farmId;
      if (farmId == null) {
        _status = null;
        _advisories = const [];
      } else {
        if (_catalog.isEmpty) _catalog = await _repository.catalog();
        final status = recompute ? await _repository.recompute(farmId) : await _repository.status(farmId);
        final advisories = await _repository.activeAdvisories(farmId);
        if (generation != _generation) return;
        _status = status;
        _advisories = _ordered(advisories);
      }
      _failure = null;
      _phase = FarmPhase.ready;
    } on ApiFailure catch (failure) {
      if (generation != _generation) return;
      // An ended session is handled by the app shell (tokens cleared, return to sign-in).
      if (failure.kind != ApiFailureKind.sessionExpired) {
        _failure = failure;
        if (_phase != FarmPhase.ready) _phase = FarmPhase.error;
      }
    } finally {
      if (generation == _generation) {
        _busy = false;
        notifyListeners();
      }
    }
  }

  /// Shows another of the caller's farms.
  Future<void> select(String farmId) async {
    if (farmId == _farmId) return;
    _farmId = farmId;
    _status = null;
    _advisories = const [];
    _phase = FarmPhase.loading;
    _generation++; // a reply still on its way for the previous farm is ignored
    _busy = false;
    notifyListeners();
    await load();
  }

  /// Field data entry. Each call throws [ApiFailure] on failure (the form shows it) and re-reads
  /// the advice on success: the backend has already re-run the rules.
  Future<void> addTrapCount({required String trap, required DateTime night, required int moths}) async {
    await _repository.addTrapCount(_requireFarm(), trap: trap, night: night, moths: moths);
    await _afterEntry();
  }

  Future<void> addObservation({required String observation, required DateTime observedOn, required int count, required int units}) async {
    await _repository.addObservation(_requireFarm(), observation: observation, observedOn: observedOn, count: count, units: units);
    await _afterEntry();
  }

  Future<void> addConfirmation({required int row, required int segment, required String className, required bool confirmed, required DateTime observedOn}) async {
    await _repository.addConfirmation(_requireFarm(), row: row, segment: segment, className: className, confirmed: confirmed, observedOn: observedOn);
    await _afterEntry();
  }

  /// Owner only. The forecast for the new location arrives with the backend's next hourly run.
  Future<void> setLocation({required double latitude, required double longitude}) async {
    final updated = await _repository.setLocation(_requireFarm(), latitude: latitude, longitude: longitude);
    _farms = [for (final f in _farms) f.id == updated.id ? updated : f];
    notifyListeners();
  }

  /// Owner only: lets the person with [phone] enter data for this farm.
  Future<FarmMember> addOperator(String phone) => _repository.addOperator(_requireFarm(), phone);

  Future<List<FarmMember>> operators() => _repository.members(_requireFarm());

  String _requireFarm() {
    final farmId = _farmId;
    if (farmId == null) throw StateError('no farm selected');
    return farmId;
  }

  Future<void> _afterEntry() async {
    _busy = false; // an entry supersedes a read in flight
    await load();
  }

  /// Signed out: forget everything that belonged to the user.
  void reset() {
    _generation++;
    _phase = FarmPhase.idle;
    _farms = const [];
    _farmId = null;
    _status = null;
    _advisories = const [];
    _failure = null;
    _busy = false;
    notifyListeners();
  }
}
