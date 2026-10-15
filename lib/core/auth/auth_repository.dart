import '../api/api_client.dart';
import '../api/api_failure.dart';
import '../models.dart';
import 'token_store.dart';

/// Phone sign-in against the existing backend contract (Phase 2):
///
///   POST /api/v1/auth/otp/request   {phone}          -> 202 (always, for eligible input)
///   POST /api/v1/auth/otp/verify    {phone, code}    -> 200 TokenPair | 401 invalid_credentials
///   POST /api/v1/auth/logout        (bearer)         -> 204
///   GET  /api/v1/me                 (bearer)         -> UserProfile
///
/// The app never knows a sign-in code: it only forwards what the user typed. How codes reach a
/// phone is a backend concern (development: allow-listed test numbers; production: U-4, undecided).
class AuthRepository {
  AuthRepository({required ApiClient api, required TokenStore tokens})
      : _api = api,
        _tokens = tokens;

  final ApiClient _api;
  final TokenStore _tokens;

  Future<void> requestCode(String phone) => guardApi(() async {
        await _api.public.post<dynamic>('/api/v1/auth/otp/request', data: {'phone': phone}, options: ApiClient.publicOptions);
      });

  /// Exchanges phone + code for a session and stores the tokens in secure storage.
  Future<UserProfile> verifyCode(String phone, String code) => guardApi(() async {
        final response = await _api.public.post<dynamic>('/api/v1/auth/otp/verify', data: {'phone': phone, 'code': code}, options: ApiClient.publicOptions);
        final pair = TokenPair.fromJson(asJsonObject(response.data));
        await _tokens.write(StoredSession.fromPair(pair));
        return pair.user;
      });

  Future<UserProfile> currentUser() => guardApi(() async {
        final response = await _api.authed.get<dynamic>('/api/v1/me');
        return UserProfile.fromJson(asJsonObject(response.data));
      });

  Future<bool> hasStoredSession() async => (await _tokens.read()) != null;

  /// Revokes the session on the backend when possible and ALWAYS deletes the local tokens.
  Future<void> logout() async {
    try {
      if (await hasStoredSession()) {
        await guardApi(() => _api.authed.post<dynamic>('/api/v1/auth/logout'));
      }
    } on ApiFailure {
      // Offline or already invalid: the local session is removed regardless.
    } finally {
      await _tokens.clear();
    }
  }
}
