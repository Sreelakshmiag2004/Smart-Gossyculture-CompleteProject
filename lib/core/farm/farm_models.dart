/// Models of the farm-rules contract (Phase II 7b, backend/docs/farm-rules.md). Parsing is strict,
/// as in models.dart: a response that does not match the contract throws a [FormatException].
///
/// Everything here is computed by the backend's rules from cart scans and entered field data.
/// The app shows it; it derives no advice of its own.
library;

T _require<T>(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is T) return value;
  throw FormatException('Unexpected response: "$key" is missing or has the wrong type.');
}

T? _optional<T>(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is T) return value;
  throw FormatException('Unexpected response: "$key" has the wrong type.');
}

double _number(Map<String, dynamic> json, String key) => _require<num>(json, key).toDouble();
double? _optionalNumber(Map<String, dynamic> json, String key) => _optional<num>(json, key)?.toDouble();

DateTime? _optionalTime(Map<String, dynamic> json, String key) {
  final raw = _optional<String>(json, key);
  if (raw == null) return null;
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) throw FormatException('Unexpected response: "$key" is not a timestamp.');
  return parsed.toUtc();
}

DateTime _time(Map<String, dynamic> json, String key) {
  final parsed = _optionalTime(json, key);
  if (parsed == null) throw FormatException('Unexpected response: "$key" is missing.');
  return parsed;
}

Map<String, dynamic> _object(Object? data) {
  if (data is Map<String, dynamic>) return data;
  if (data is Map) return data.map((key, value) => MapEntry(key.toString(), value));
  throw const FormatException('Unexpected response: not a JSON object.');
}

List<Map<String, dynamic>> _objects(Object? data) {
  if (data is List) return data.map(_object).toList();
  throw const FormatException('Unexpected response: not a JSON list.');
}

List<String> _strings(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is List && value.every((e) => e is String)) return value.cast<String>();
  throw FormatException('Unexpected response: "$key" is not a list of strings.');
}

/// Readiness of one row segment from its latest cart scan.
class SegmentStatus {
  const SegmentStatus({required this.key, required this.row, required this.segment, required this.readiness, required this.status, required this.openBolls, required this.scannedAt});

  static const String ready = 'READY';
  static const String building = 'BUILDING';
  static const String notReady = 'NOT_READY';
  static const String noData = 'NO_DATA';

  /// "R003-S02".
  final String key;
  final int row;
  final int segment;

  /// open / (closed + cracking + open), 0..1; null when no bolls were seen.
  final double? readiness;
  final String status;
  final int openBolls;
  final DateTime scannedAt;

  factory SegmentStatus.fromJson(Map<String, dynamic> json) => SegmentStatus(
        key: _require<String>(json, 'key'),
        row: _require<int>(json, 'row'),
        segment: _require<int>(json, 'segment'),
        readiness: _optionalNumber(json, 'readiness'),
        status: _require<String>(json, 'status'),
        openBolls: _require<int>(json, 'openBolls'),
        scannedAt: _time(json, 'scannedAt'),
      );
}

/// Whether picking now is safe for fibre quality (dew, humidity, recent rain, time of day).
class PickingWindow {
  const PickingWindow({required this.safe, required this.dewpointC, required this.dewpointDepressionC, required this.reasons});

  final bool safe;
  final double dewpointC;
  final double dewpointDepressionC;

  /// Why it is not safe yet, in the backend's words (empty when safe).
  final List<String> reasons;

  factory PickingWindow.fromJson(Map<String, dynamic> json) {
    final status = _require<String>(json, 'status');
    if (status != 'SAFE' && status != 'WAIT') throw const FormatException('Unexpected response: unknown picking window status.');
    return PickingWindow(
      safe: status == 'SAFE',
      dewpointC: _number(json, 'dewpointC'),
      dewpointDepressionC: _number(json, 'dewpointDepressionC'),
      reasons: _strings(json, 'reasons'),
    );
  }
}

class WeatherNow {
  const WeatherNow({required this.airTempC, required this.airRhPct, required this.dewpointC, required this.fromCart});

  final double airTempC;
  final double airRhPct;
  final double? dewpointC;

  /// true: the cart's own sensor (last 2 h); false: the forecast model.
  final bool fromCart;

  factory WeatherNow.fromJson(Map<String, dynamic> json) => WeatherNow(
        airTempC: _number(json, 'airTempC'),
        airRhPct: _number(json, 'airRhPct'),
        dewpointC: _optionalNumber(json, 'dewpointC'),
        fromCart: _require<String>(json, 'source') == 'cart',
      );
}

/// One pest threshold rule evaluated on the farm's evidence.
class PestStatus {
  const PestStatus({required this.pest, required this.crossed, required this.insufficient, required this.value, required this.threshold, required this.action, required this.detail});

  final String pest;
  final bool crossed;

  /// Too little evidence to decide: the operator should scout more.
  final bool insufficient;
  final double? value;
  final double threshold;
  final String action;
  final String detail;

  factory PestStatus.fromJson(Map<String, dynamic> json) => PestStatus(
        pest: _require<String>(json, 'pest'),
        crossed: _require<bool>(json, 'crossed'),
        insufficient: _require<bool>(json, 'insufficient'),
        value: _optionalNumber(json, 'value'),
        threshold: _number(json, 'threshold'),
        action: _require<String>(json, 'action'),
        detail: _require<String>(json, 'detail'),
      );
}

/// GET /api/v1/farms/{farmId}/status.
class FarmStatus {
  const FarmStatus({required this.farmId, this.computedAt, this.segments = const [], this.window, this.weatherNow, this.forecastFetchedAt, this.rainLast24hMm, this.rainMaxProb48hPct, this.pests = const []});

  final String farmId;

  /// Null until the rules have run for this farm.
  final DateTime? computedAt;
  final List<SegmentStatus> segments;

  /// Null without a weather reading (no recent cart reading and no forecast).
  final PickingWindow? window;
  final WeatherNow? weatherNow;
  final DateTime? forecastFetchedAt;
  final double? rainLast24hMm;
  final double? rainMaxProb48hPct;
  final List<PestStatus> pests;

  factory FarmStatus.fromJson(Map<String, dynamic> json) {
    final window = json['window'];
    final weather = json['weatherNow'];
    return FarmStatus(
      farmId: _require<String>(json, 'farmId'),
      computedAt: _optionalTime(json, 'computedAt'),
      segments: _objects(json['segments']).map(SegmentStatus.fromJson).toList(),
      window: window == null ? null : PickingWindow.fromJson(_object(window)),
      weatherNow: weather == null ? null : WeatherNow.fromJson(_object(weather)),
      forecastFetchedAt: _optionalTime(json, 'forecastFetchedAt'),
      rainLast24hMm: _optionalNumber(json, 'rainLast24HMm'),
      rainMaxProb48hPct: _optionalNumber(json, 'rainMaxProb48HPct'),
      pests: _objects(json['pests']).map(PestStatus.fromJson).toList(),
    );
  }
}

/// One piece of advice from the rules, in English and Tamil.
class Advisory {
  const Advisory({required this.id, required this.type, required this.pest, required this.segments, required this.textEn, required this.textTa, required this.active, required this.createdAt, required this.updatedAt});

  static const String pickNow = 'PICK_NOW';
  static const String pickList = 'PICK_LIST';
  static const String pestEtl = 'PEST_ETL';
  static const String spotTreat = 'SPOT_TREAT';
  static const String pestAlert = 'PEST_ALERT';
  static const String sprayBlocked = 'SPRAY_BLOCKED';
  static const Set<String> types = {pickNow, pickList, pestEtl, spotTreat, pestAlert, sprayBlocked};

  final String id;
  final String type;
  final String? pest;
  final List<String> segments;
  final String textEn;
  final String textTa;
  final bool active;
  final DateTime createdAt;
  final DateTime updatedAt;

  String text(bool tamil) => tamil && textTa.isNotEmpty ? textTa : textEn;

  factory Advisory.fromJson(Map<String, dynamic> json) {
    final type = _require<String>(json, 'type');
    if (!types.contains(type)) throw const FormatException('Unexpected response: unknown advisory type.');
    return Advisory(
      id: _require<String>(json, 'id'),
      type: type,
      pest: _optional<String>(json, 'pest'),
      segments: _strings(json, 'segments'),
      textEn: _require<String>(json, 'textEn'),
      textTa: _require<String>(json, 'textTa'),
      active: _require<bool>(json, 'active'),
      createdAt: _time(json, 'createdAt'),
      updatedAt: _time(json, 'updatedAt'),
    );
  }
}

/// One pest rule of GET /api/v1/farm-rules/catalog: what to count in the field, and the threshold.
class PestRule {
  const PestRule({required this.pest, required this.nameEn, required this.nameTa, required this.ruleType, required this.observation, required this.trapPrefix, required this.threshold, required this.comparison, required this.minUnits, required this.action});

  final String pest;
  final String nameEn;
  final String nameTa;
  final String ruleType;

  /// The scouting key to send (manual rules); null for trap and camera rules.
  final String? observation;
  final String? trapPrefix;
  final double threshold;

  /// ">" or ">=".
  final String comparison;
  final int? minUnits;
  final String action;

  /// percent_units counts plants that meet a condition, so the count cannot exceed the plants
  /// examined; mean_per_unit counts insects, which can.
  bool get countsUnits => ruleType == 'percent_units';

  String name(bool tamil) => tamil && nameTa.isNotEmpty ? nameTa : nameEn;

  factory PestRule.fromJson(Map<String, dynamic> json) => PestRule(
        pest: _require<String>(json, 'pest'),
        nameEn: _require<String>(json, 'nameEn'),
        nameTa: _require<String>(json, 'nameTa'),
        ruleType: _require<String>(json, 'ruleType'),
        observation: _optional<String>(json, 'observation'),
        trapPrefix: _optional<String>(json, 'trapPrefix'),
        threshold: _number(json, 'threshold'),
        comparison: _require<String>(json, 'comparison'),
        minUnits: _optional<int>(json, 'minUnits'),
        action: _require<String>(json, 'action'),
      );

  static List<PestRule> listFromJson(Object? data) => _objects(data).map(PestRule.fromJson).toList();
}

/// An operator of the farm (GET/POST /api/v1/farms/{farmId}/members).
class FarmMember {
  const FarmMember({required this.userId, required this.phone, this.displayName});

  final String userId;
  final String phone;
  final String? displayName;

  factory FarmMember.fromJson(Map<String, dynamic> json) => FarmMember(
        userId: _require<String>(json, 'userId'),
        phone: _require<String>(json, 'phone'),
        displayName: _optional<String>(json, 'displayName'),
      );

  static List<FarmMember> listFromJson(Object? data) => _objects(data).map(FarmMember.fromJson).toList();
}

/// "2026-10-15" for a calendar day (the backend's `date` fields; Indian calendar days).
String formatDay(DateTime day) => '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
