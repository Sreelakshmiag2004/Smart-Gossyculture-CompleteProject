import '../api/api_client.dart';
import '../models.dart';

/// Alerts over the existing Phase 2 REST contract, through the authenticated client of Phase 3A
/// (bearer token, single refresh, session handling).
///
///   GET  /api/v1/alerts?limit=&cursor=&status=      -> Page<Alert> (newest first)
///   POST /api/v1/alerts/{alertId}/acknowledge       -> Alert       (idempotent)
///
/// Without `deviceId` the backend returns the alerts of every device the caller may read; that
/// is the scope used here, the same as the live channel's. Acknowledging changes the alert on
/// the backend only: it never reaches a device. There is no bulk acknowledgement in the contract.
class AlertsRepository {
  AlertsRepository({required ApiClient api}) : _api = api;

  final ApiClient _api;

  /// One page of the caller's alerts. [status] limits it to `open` or `acknowledged` alerts.
  Future<Page<Alert>> list({required int limit, String? cursor, String? status}) => guardApi(() async {
        final response = await _api.authed.get<dynamic>('/api/v1/alerts', queryParameters: {
          'limit': limit,
          if (cursor != null) 'cursor': cursor,
          if (status != null) 'status': status,
        });
        return Page.fromJson(response.data, Alert.fromJson);
      });

  /// Marks one alert as acknowledged and returns it as the backend now holds it.
  Future<Alert> acknowledge(String alertId) => guardApi(() async {
        final response = await _api.authed.post<dynamic>('/api/v1/alerts/${Uri.encodeComponent(alertId)}/acknowledge');
        return Alert.fromJson(asJsonObject(response.data));
      });
}
