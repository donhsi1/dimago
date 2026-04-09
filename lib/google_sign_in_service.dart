import 'package:google_sign_in/google_sign_in.dart';

import 'google_oauth_config.dart';

/// Wraps [google_sign_in] 7.x singleton: [initialize] once, then [authenticate].
class GoogleSignInService {
  GoogleSignInService._();

  static bool _initialized = false;

  static Future<void> _ensureInitialized() async {
    if (_initialized) return;
    final serverClientId = await GoogleOAuthConfig.installedClientId();
    // ignore: avoid_print
    print('[GoogleSignIn] Initializing google_sign_in with serverClientId=$serverClientId');
    await GoogleSignIn.instance.initialize(serverClientId: serverClientId);
    _initialized = true;
  }

  /// Interactive Google account picker, then scope consent when needed.
  /// Returns null if the user cancels either step.
  static Future<GoogleSignInAccount?> signIn() async {
    await _ensureInitialized();
    try {
      // ignore: avoid_print
      print('[GoogleSignIn] Showing Google account picker...');
      final account = await GoogleSignIn.instance.authenticate(
        scopeHint: const <String>['openid', 'email', 'profile'],
      );
      // Second step: OAuth consent / confirmation (required for a server-grade
      // id token and for Supabase [signInWithIdToken]).
      try {
        // ignore: avoid_print
        print('[GoogleSignIn] Requesting OAuth consent for openid/email/profile...');
        await account.authorizationClient.authorizeScopes(const <String>[
          'openid',
          'email',
          'profile',
        ]);
      } on GoogleSignInException catch (e) {
        switch (e.code) {
          case GoogleSignInExceptionCode.canceled:
          case GoogleSignInExceptionCode.interrupted:
          case GoogleSignInExceptionCode.uiUnavailable:
            // ignore: avoid_print
            print('[GoogleSignIn] Consent cancelled or unavailable: ${e.code}');
            return null;
          default:
            rethrow;
        }
      }
      return account;
    } on GoogleSignInException catch (e) {
      switch (e.code) {
        case GoogleSignInExceptionCode.canceled:
        case GoogleSignInExceptionCode.interrupted:
        case GoogleSignInExceptionCode.uiUnavailable:
          // ignore: avoid_print
          print('[GoogleSignIn] Account picker cancelled or unavailable: ${e.code}');
          return null;
        default:
          rethrow;
      }
    }
  }
}
