import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_bootstrap.dart';

/// Google OAuth via Supabase on Windows desktop.
///
/// Flow:
///   1. Register the `dimago://` URI scheme in HKCU so Windows routes the
///      OAuth redirect back to this executable.
///   2. Call [Supabase.instance.client.auth.signInWithOAuth] — this opens the
///      default browser with the Google consent screen.
///   3. After the user grants access, Google redirects to
///      `dimago://login-callback#access_token=…`.
///   4. Windows relaunches the app (or re-uses the running instance via
///      the Named-Pipe mechanism in `app_links`).
///   5. `supabase_flutter` intercepts the deep link and calls
///      `getSessionFromUrl`, which fires `onAuthStateChange`.
///   6. We resolve the completer and return the user's email + display name.
///
/// **Prerequisite (one-time Supabase dashboard setup)**:
///   Auth → URL Configuration → Redirect URLs → add `dimago://login-callback`
class WindowsGoogleAuth {
  WindowsGoogleAuth._();

  /// Register `dimago://` as a URI scheme in the current-user registry hive.
  /// This is idempotent and silently ignores failures.
  static Future<void> registerUriScheme() async {
    if (!Platform.isWindows) return;
    final exe = Platform.resolvedExecutable;
    const base = r'HKCU\Software\Classes\dimago';
    const open = r'HKCU\Software\Classes\dimago\shell\open\command';
    try {
      await Process.run('reg', ['add', base, '/ve', '/d', 'URL:dimago Protocol', '/f']);
      await Process.run('reg', ['add', base, '/v', 'URL Protocol', '/d', '', '/f']);
      await Process.run('reg', ['add', open, '/ve', '/d', '"$exe" "%1"', '/f']);
    } catch (_) {
      // Non-fatal: sign-in will still work if the scheme was previously registered.
    }
  }

  /// Launches the Google OAuth flow via the system browser.
  ///
  /// Returns `(email, displayName)` on success.
  /// Throws on error or timeout.
  /// Returns `null` when Supabase is not configured.
  static Future<({String email, String displayName})?> signIn() async {
    final client = SupabaseBootstrap.clientOrNull;
    if (client == null) return null;

    await registerUriScheme();

    // Set up the auth-state listener BEFORE opening the browser so we
    // never miss the callback.
    final completer = Completer<Session>();
    final sub = client.auth.onAuthStateChange.listen((data) {
      // ignore: avoid_print
      print('[WindowsGoogleAuth] Auth event: ${data.event} session=${data.session != null}');
      if (data.event == AuthChangeEvent.signedIn &&
          data.session != null &&
          !completer.isCompleted) {
        // ignore: avoid_print
        print('[WindowsGoogleAuth] Received signedIn with session, completing completer.');
        completer.complete(data.session!);
      }
    });

    try {
      // ignore: avoid_print
      print('[WindowsGoogleAuth] Calling signInWithOAuth (Google) with redirectTo=${SupabaseBootstrap.authRedirectUrl} ...');
      await client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: SupabaseBootstrap.authRedirectUrl,
      );

      // Wait for the deep-link callback (user has up to 5 min in browser).
      final session = await completer.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw TimeoutException(
          'Google sign-in timed out. Please try again.',
        ),
      );

      final user = session.user;
      final email = user.email ?? '';
      final displayName =
          (user.userMetadata?['full_name'] as String?)?.trim() ??
          (user.userMetadata?['name'] as String?)?.trim() ??
          email;

      // ignore: avoid_print
      print('[WindowsGoogleAuth] Completed with email=$email displayName=$displayName');
      return (email: email, displayName: displayName);
    } finally {
      await sub.cancel();
    }
  }
}
