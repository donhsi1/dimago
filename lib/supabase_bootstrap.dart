import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase project: DimaGo (`prxmhmkndgvnlrbmnyxp`).
///
/// **Anon key** (choose one):
/// 1. Compile-time: `--dart-define=SUPABASE_ANON_KEY=eyJ...` (see
///    [scripts/flutter_run_with_secrets.ps1] / [scripts/flutter_build_apk_with_secrets.ps1]
///    with `supabase_anon_key.txt` at repo root, gitignored).
/// 2. **Release APK without dart-define:** paste the same key into
///    `assets/supabase_config.json` → `"anon_key": "..."` (Dashboard → Project
///    Settings → API → `anon` `public`). Rebuild the app.
///
/// **URL** defaults to your project; override with `--dart-define=SUPABASE_URL=...`
/// or optional `"url"` in `assets/supabase_config.json`.
///
/// **Auth redirect URL** (password recovery, magic link, OAuth):
/// - Default: `dimago://login-callback` (custom scheme)
/// - Optional override via build arg:
///   `--dart-define=AUTH_REDIRECT_URL=https://your-domain.com/login-callback`
///
/// Add the exact redirect URL you use under Supabase Dashboard
/// → Authentication → URL Configuration → **Redirect URLs**.
class SupabaseBootstrap {
  SupabaseBootstrap._();

  /// Used for [resetPasswordForEmail], [signInWithOtp] `emailRedirectTo`, OAuth redirect, etc.
  static const String authRedirectUrl = String.fromEnvironment(
    'AUTH_REDIRECT_URL',
    defaultValue: 'dimago://login-callback',
  );

  static var _didInitialize = false;
  static var _triedAsset = false;
  static String _assetAnon = '';
  static String _assetUrl = '';

  static const _url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://prxmhmkndgvnlrbmnyxp.supabase.co',
  );

  static const _anonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: '',
  );

  static String get supabaseUrl {
    final fromAsset = _assetUrl.trim();
    if (fromAsset.isNotEmpty) return fromAsset;
    return _url.trim();
  }

  /// True when a non-empty anon key is available after [ensureInitialized]
  /// has loaded the optional asset config.
  static bool get isConfigured {
    if (_anonKey.trim().isNotEmpty) return true;
    return _assetAnon.trim().isNotEmpty;
  }

  static Future<void> _tryLoadAssetConfig() async {
    if (_triedAsset) return;
    _triedAsset = true;
    try {
      final raw = await rootBundle.loadString('assets/supabase_config.json');
      final map = jsonDecode(raw);
      if (map is! Map<String, dynamic>) return;
      final k = map['anon_key'];
      if (k is String && k.trim().isNotEmpty) {
        _assetAnon = k.trim();
      }
      final u = map['url'];
      if (u is String && u.trim().isNotEmpty) {
        _assetUrl = u.trim();
      }
    } catch (_) {
      // Missing asset, invalid JSON, or empty keys — leave _asset* unset.
    }
  }

  /// Initializes [Supabase]. No-op if no anon key (compile-time or asset).
  static Future<void> ensureInitialized() async {
    if (_anonKey.trim().isEmpty) {
      await _tryLoadAssetConfig();
    }
    final key = _anonKey.trim().isNotEmpty ? _anonKey.trim() : _assetAnon.trim();
    if (key.isEmpty) return;
    if (_didInitialize) return;
    await Supabase.initialize(
      url: supabaseUrl,
      anonKey: key,
    );
    _didInitialize = true;
  }

  /// Live client after [ensureInitialized]; null if Supabase was not configured.
  static SupabaseClient? get clientOrNull {
    if (!_didInitialize) return null;
    return Supabase.instance.client;
  }
}
