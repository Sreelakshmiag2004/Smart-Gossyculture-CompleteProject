import '../api/api_client.dart';
import '../models.dart';
import 'farm_models.dart';

/// The farm-rules endpoints of the backend (Phase II 7b), through the authenticated client:
///
///   GET   /api/v1/farms                                   farms the caller owns or operates
///   PATCH /api/v1/farms/{farmId}            {latitude, longitude}   owner only
///   GET   /api/v1/farm-rules/catalog                       pest rules and scouting keys
///   GET   /api/v1/farms/{farmId}/status                    readiness, picking window, pests
///   POST  /api/v1/farms/{farmId}/status/recompute          the same, computed now
///   GET   /api/v1/farms/{farmId}/advisories?active=true    current advice
///   POST  /api/v1/farms/{farmId}/traps | observations | confirmations   field data (owner, operator)
///   GET/POST /api/v1/farms/{farmId}/members                operators (owner only)
///
/// Entering data re-runs the farm's rules on the backend. Nothing here reaches a device.
class FarmRepository {
  FarmRepository({required ApiClient api}) : _api = api;

  final ApiClient _api;

  String _farm(String farmId) => '/api/v1/farms/${Uri.encodeComponent(farmId)}';

  Future<List<Farm>> listFarms() => guardApi(() async {
        final response = await _api.authed.get<dynamic>('/api/v1/farms');
        return asJsonList(response.data).map(Farm.fromJson).toList();
      });

  Future<Farm> setLocation(String farmId, {required double latitude, required double longitude}) => guardApi(() async {
        final response = await _api.authed.patch<dynamic>(_farm(farmId), data: {'latitude': latitude, 'longitude': longitude});
        return Farm.fromJson(asJsonObject(response.data));
      });

  Future<List<PestRule>> catalog() => guardApi(() async {
        final response = await _api.authed.get<dynamic>('/api/v1/farm-rules/catalog');
        return PestRule.listFromJson(response.data);
      });

  Future<FarmStatus> status(String farmId) => guardApi(() async {
        final response = await _api.authed.get<dynamic>('${_farm(farmId)}/status');
        return FarmStatus.fromJson(asJsonObject(response.data));
      });

  Future<FarmStatus> recompute(String farmId) => guardApi(() async {
        final response = await _api.authed.post<dynamic>('${_farm(farmId)}/status/recompute');
        return FarmStatus.fromJson(asJsonObject(response.data));
      });

  Future<List<Advisory>> activeAdvisories(String farmId) => guardApi(() async {
        final response = await _api.authed.get<dynamic>('${_farm(farmId)}/advisories', queryParameters: {'active': 'true', 'limit': 100});
        return Page.fromJson(response.data, Advisory.fromJson).items;
      });

  Future<void> addTrapCount(String farmId, {required String trap, required DateTime night, required int moths}) => guardApi(() async {
        await _api.authed.post<dynamic>('${_farm(farmId)}/traps', data: {'trap': trap, 'night': formatDay(night), 'moths': moths});
      });

  Future<void> addObservation(String farmId, {required String observation, required DateTime observedOn, required int count, required int units}) => guardApi(() async {
        await _api.authed.post<dynamic>('${_farm(farmId)}/observations', data: {'observedOn': formatDay(observedOn), 'observation': observation, 'count': count, 'units': units});
      });

  Future<void> addConfirmation(String farmId, {required int row, required int segment, required String className, required bool confirmed, required DateTime observedOn}) => guardApi(() async {
        await _api.authed.post<dynamic>('${_farm(farmId)}/confirmations', data: {
          'observedOn': formatDay(observedOn), 'row': row, 'segment': segment, 'className': className, 'verdict': confirmed ? 'confirmed' : 'rejected',
        });
      });

  Future<List<FarmMember>> members(String farmId) => guardApi(() async {
        final response = await _api.authed.get<dynamic>('${_farm(farmId)}/members');
        return FarmMember.listFromJson(response.data);
      });

  Future<FarmMember> addOperator(String farmId, String phone) => guardApi(() async {
        final response = await _api.authed.post<dynamic>('${_farm(farmId)}/members', data: {'phone': phone});
        return FarmMember.fromJson(asJsonObject(response.data));
      });
}
