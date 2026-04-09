import 'dart:convert';

import 'package:flutter/services.dart';

/// Loads [installed.client_id] from the Google OAuth client JSON downloaded
/// from Google Cloud Console (OAuth 2.0 Client IDs).
///
/// Asset path must match [pubspec.yaml]. Register the Android app’s **SHA-1**
/// and package name (`com.example.lango`) under the same GCP project, or
/// Google Sign-In will fail on device with `sign_in_failed`.
class GoogleOAuthConfig {
  GoogleOAuthConfig._();

  static const String assetPath =
      'client_secret_327903108748-0quo28ikfd9t0sa6bftrp0sp0vcliv37.apps.googleusercontent.com.json';

  static String? _cachedClientId;

  /// OAuth client id (…apps.googleusercontent.com), for [GoogleSignIn.serverClientId].
  static Future<String> installedClientId() async {
    if (_cachedClientId != null) return _cachedClientId!;
    final raw = await rootBundle.loadString(assetPath);
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final installed = map['installed'] as Map<String, dynamic>?;
    final id = installed?['client_id'] as String?;
    if (id == null || id.isEmpty) {
      throw StateError('OAuth JSON missing installed.client_id');
    }
    _cachedClientId = id;
    return id;
  }
}
