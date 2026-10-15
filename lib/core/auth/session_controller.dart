import 'package:flutter/foundation.dart';

import '../api/api_failure.dart';
import '../models.dart';
import 'auth_repository.dart';

enum SessionStatus { unknown, signedOut, signedIn }

/// Result of looking for a stored session when the app starts.
enum SessionRestore {
  /// No stored session: show the sign-in page.
  none,

  /// A stored session was accepted by the backend.
  restored,

  /// A stored session existed but the backend no longer accepts it: sign in again.
  expired,

  /// A stored session exists but the backend could not be reached. Nothing was deleted.
  unreachable,
}

/// Who is signed in. Holds the profile only - tokens stay in secure storage.
class SessionController extends ChangeNotifier {
  SessionController();

  late final AuthRepository _auth;

  void attach(AuthRepository auth) => _auth = auth;

  SessionStatus _status = SessionStatus.unknown;
  UserProfile? _user;

  SessionStatus get status => _status;
  UserProfile? get user => _user;

  /// Called when a signed-in user loses the session (refresh rejected, token reuse detected,
  /// session revoked). The app shell uses it to return to the sign-in page.
  VoidCallback? onForcedSignOut;

  Future<SessionRestore> restore() async {
    if (!await _auth.hasStoredSession()) {
      _set(SessionStatus.signedOut, null);
      return SessionRestore.none;
    }
    try {
      _set(SessionStatus.signedIn, await _auth.currentUser());
      return SessionRestore.restored;
    } on ApiFailure catch (failure) {
      if (failure.kind == ApiFailureKind.sessionExpired || failure.kind == ApiFailureKind.unauthorized) {
        await _auth.logout();
        _set(SessionStatus.signedOut, null);
        return SessionRestore.expired;
      }
      return SessionRestore.unreachable;
    }
  }

  Future<void> requestCode(String phone) => _auth.requestCode(phone);

  Future<void> verifyCode(String phone, String code) async {
    _set(SessionStatus.signedIn, await _auth.verifyCode(phone, code));
  }

  Future<void> logout() async {
    await _auth.logout();
    _set(SessionStatus.signedOut, null);
  }

  /// From the HTTP layer: the stored tokens were rejected and have already been deleted.
  void handleInvalidated() {
    final wasSignedIn = _status == SessionStatus.signedIn;
    _set(SessionStatus.signedOut, null);
    if (wasSignedIn) onForcedSignOut?.call();
  }

  void _set(SessionStatus status, UserProfile? user) {
    _status = status;
    _user = user;
    notifyListeners();
  }
}
