import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'google_sign_in_service.dart';
import 'language_prefs.dart';
import 'database_helper.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, AuthException, OAuthProvider, OtpType;
import 'supabase_bootstrap.dart';
import 'windows_google_auth.dart';

class LoginPage extends StatefulWidget {
  final bool fromSetup;
  /// Called after login is complete (used when shown as root widget, not pushed).
  final VoidCallback? onComplete;
  const LoginPage({super.key, this.fromSetup = false, this.onComplete});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool _loading = false;
  String? _loadingProvider;
  bool _rememberMe = true;
  bool _showEmailRegister = false;
  bool _codeSent = false;
  bool _showPassword = false;

  final _inputController = TextEditingController();
  final _passwordController = TextEditingController();
  final _codeController = TextEditingController();

  /// Listens for Supabase auth state after OTP is sent (covers magic-link clicks).
  StreamSubscription? _authSub;

  L10n get _l => L10n(AppLangNotifier().uiLang);

  Widget _appLogoBadge() {
    return Container(
      width: 76,
      height: 76,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1565C0).withValues(alpha: 0.3),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Image.asset(
          'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png',
          fit: BoxFit.cover,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _inputController.dispose();
    _passwordController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _signInGoogle() async {
    // On Windows/Linux: use Supabase OAuth (opens system browser).
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      await _signInGoogleDesktop();
      return;
    }
    // Mobile / macOS: use google_sign_in native SDK.
    setState(() {
      _loading = true;
      _loadingProvider = 'google';
    });
    try {
      // Debug: entered Google sign-in on this platform.
      // ignore: avoid_print
      print('[GoogleSignIn] Starting google_sign_in flow...');
      final account = await GoogleSignInService.signIn();
      if (!mounted) return;
      if (account == null) {
        // User cancelled account picker or consent.
        // ignore: avoid_print
        print('[GoogleSignIn] User cancelled or no account selected.');
        setState(() {
          _loading = false;
          _loadingProvider = null;
        });
        return;
      }

      final client = SupabaseBootstrap.clientOrNull;
      if (client == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _loadingProvider = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_l.isEn
                ? 'Supabase is not configured.'
                : 'Supabase 未配置。'),
            duration: const Duration(seconds: 5),
          ),
        );
        return;
      }

      final idToken = account.authentication.idToken;
      if (idToken == null || idToken.isEmpty) {
        // ignore: avoid_print
        print('[GoogleSignIn] google_sign_in returned empty idToken for ${account.email}');
        if (!mounted) return;
        setState(() {
          _loading = false;
          _loadingProvider = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_l.isEn
                ? 'Google sign-in did not return an ID token. Use the Web client ID from Google Cloud as serverClientId, and add the same ID in Supabase → Auth → Google.'
                : 'Google 未返回 ID 令牌。请在应用中使用 Google Cloud 的「网页应用」客户端 ID 作为 serverClientId，并在 Supabase 身份验证 → Google 中填写同一客户端 ID。'),
            duration: const Duration(seconds: 8),
          ),
        );
        return;
      }

      // ignore: avoid_print
      print('[GoogleSignIn] Received idToken (len=${idToken.length}) for ${account.email}, calling Supabase signInWithIdToken...');
      await client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
      );

      final name = account.displayName?.trim();
      final label =
          (name != null && name.isNotEmpty) ? name : account.email;

      // Persist user to public.users (best-effort)
      try {
        await client.from('users').upsert({
          'email': account.email,
          'display_name': label,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }, onConflict: 'email');
      } catch (_) {}

      if (!mounted) return;
      // ignore: avoid_print
      print('[GoogleSignIn] Supabase signInWithIdToken succeeded, calling _onLoginSuccess...');
      await _onLoginSuccess(provider: 'google', displayName: label);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingProvider = null;
      });
      // ignore: avoid_print
      print('[GoogleSignIn] Supabase AuthException: ${e.message}');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _l.isEn ? 'Google sign-in failed: ${e.message}' : 'Google 登录失败：${e.message}',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingProvider = null;
      });
      // ignore: avoid_print
      print('[GoogleSignIn] Unexpected error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _l.isEn ? 'Google sign-in failed: $e' : 'Google 登录失败：$e',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  /// Windows/Linux: opens the system browser for Google OAuth via Supabase.
  Future<void> _signInGoogleDesktop() async {
    setState(() {
      _loading = true;
      _loadingProvider = 'google';
    });
    try {
      final result = await WindowsGoogleAuth.signIn();
      if (!mounted) return;
      if (result == null) {
        // Supabase not configured — fall back to guest message
        setState(() { _loading = false; _loadingProvider = null; });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_l.isEn
                ? 'Supabase not configured.'
                : 'Supabase 未配置。'),
            duration: const Duration(seconds: 5),
          ),
        );
        return;
      }
      await _onLoginSuccess(
        provider: 'google',
        displayName: result.displayName.isNotEmpty ? result.displayName : result.email,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _loadingProvider = null; });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_l.isEn ? 'Google sign-in failed: $e' : 'Google 登录失败：$e'),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  Future<void> _signInApple() async {
    if (kIsWeb || (!Platform.isIOS && !Platform.isMacOS)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_l.loginAppleUnavailable),
          duration: const Duration(seconds: 4),
        ),
      );
      return;
    }

    setState(() {
      _loading = true;
      _loadingProvider = 'apple';
    });
    try {
      if (!(await SignInWithApple.isAvailable())) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _loadingProvider = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_l.loginAppleUnavailable)),
        );
        return;
      }

      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );

      final gn = credential.givenName?.trim();
      final fn = credential.familyName?.trim();
      final parts = <String>[];
      if (gn != null && gn.isNotEmpty) parts.add(gn);
      if (fn != null && fn.isNotEmpty) parts.add(fn);
      final combined = parts.join(' ');
      final email = credential.email?.trim();
      final label = combined.isNotEmpty
          ? combined
          : (email != null && email.isNotEmpty)
              ? email
              : 'Apple ID';

      if (!mounted) return;
      await _onLoginSuccess(provider: 'apple', displayName: label);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingProvider = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _l.isEn ? 'Apple sign-in failed: $e' : 'Apple 登录失败：$e',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  void _signInWeChat() {
    _showNotConfiguredDialog('WeChat / 微信');
  }

  void _showNotConfiguredDialog(String providerName) {
    final l = _l;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.orange),
          const SizedBox(width: 8),
          Text(l.isEn ? 'Not Configured' : '尚未配置'),
        ]),
        content: Text(
          l.isEn
              ? '$providerName login requires a registered AppID.\n\nPlease configure the AppID in the developer console before using this login method.'
              : '$providerName 登录需要已注册的 AppID。\n\n请先在开发者后台配置 AppID 后再使用此登录方式。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l.confirm),
          ),
        ],
      ),
    );
  }

  Future<void> _sendCode() async {
    final email = _inputController.text.trim();
    if (email.isEmpty) return;

    final client = SupabaseBootstrap.clientOrNull;
    if (client == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_l.isEn
              ? 'Supabase not configured.'
              : 'Supabase 未配置。'),
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    setState(() {
      _loading = true;
      _loadingProvider = 'code';
    });

    try {
      // Magic link must redirect to a URL that opens this app (not localhost).
      final redirectTo =
          kIsWeb ? null : SupabaseBootstrap.authRedirectUrl;

      await client.auth.signInWithOtp(
        email: email,
        shouldCreateUser: true,
        emailRedirectTo: redirectTo,
      );
      if (!mounted) return;
      setState(() {
        _codeSent = true;
        _loading = false;
        _loadingProvider = null;
      });

      // Listen for sign-in from magic-link click (deep-link path).
      _authSub?.cancel();
      _authSub = client.auth.onAuthStateChange.listen((data) async {
        if (data.event == AuthChangeEvent.signedIn && mounted) {
          _authSub?.cancel();
          _authSub = null;
          final user = data.session?.user;
          final displayName =
              user?.userMetadata?['full_name'] as String? ??
              user?.email?.split('@').first ??
              email.split('@').first;
          try {
            if (user != null) {
              await client.from('users').upsert({
                'email': user.email ?? email,
                'display_name': displayName,
                'updated_at': DateTime.now().toUtc().toIso8601String(),
              }, onConflict: 'email');
            }
          } catch (_) {}
          if (mounted) {
            await _onLoginSuccess(provider: 'email', displayName: displayName);
          }
        }
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_l.loginCodeSent),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingProvider = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_l.isEn
              ? 'Failed to send code: $e'
              : '发送验证码失败：$e'),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  Future<void> _verifyCode() async {
    final email = _inputController.text.trim();
    final code = _codeController.text.trim();
    if (email.isEmpty || code.isEmpty) return;

    final client = SupabaseBootstrap.clientOrNull;
    if (client == null) return;

    setState(() {
      _loading = true;
      _loadingProvider = 'code';
    });

    try {
      final response = await client.auth.verifyOTP(
        email: email,
        token: code,
        type: OtpType.email,
      );

      if (!mounted) return;

      final user = response.user;
      final displayName = user?.userMetadata?['full_name'] as String? ??
          user?.email?.split('@').first ??
          email.split('@').first;

      // Cancel magic-link listener — we're completing via code path.
      _authSub?.cancel();
      _authSub = null;

      // Persist to users table (best-effort)
      try {
        if (user != null) {
          await client.from('users').upsert({
            'email': user.email ?? email,
            'display_name': displayName,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          }, onConflict: 'email');
        }
      } catch (_) {}

      await _onLoginSuccess(provider: 'email', displayName: displayName);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingProvider = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_l.isEn
              ? 'Invalid code: ${e.message}'
              : '验证码无效：${e.message}'),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingProvider = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_l.isEn
              ? 'Verification failed: $e'
              : '验证失败：$e'),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  Future<void> _signInWithPassword() async {
    final email = _inputController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) return;
    final client = SupabaseBootstrap.clientOrNull;
    if (client == null) return;

    setState(() {
      _loading = true;
      _loadingProvider = 'password';
    });
    try {
      final response = await client.auth
          .signInWithPassword(email: email, password: password);
      final user = response.user;
      final displayName = user?.userMetadata?['full_name'] as String? ??
          user?.email?.split('@').first ??
          email.split('@').first;

      try {
        if (user != null) {
          await client.from('users').upsert({
            'email': user.email ?? email,
            'display_name': displayName,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          }, onConflict: 'email');
        }
      } catch (_) {}

      if (!mounted) return;
      await _onLoginSuccess(provider: 'email_password', displayName: displayName);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingProvider = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l.isEn ? e.message : '登录失败：${e.message}')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingProvider = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l.isEn ? 'Sign in failed: $e' : '登录失败：$e')),
      );
    }
  }

  Future<void> _registerWithPassword() async {
    final email = _inputController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) return;
    final client = SupabaseBootstrap.clientOrNull;
    if (client == null) return;

    setState(() {
      _loading = true;
      _loadingProvider = 'password_register';
    });
    try {
      final response = await client.auth.signUp(email: email, password: password);
      final user = response.user;
      final displayName = user?.userMetadata?['full_name'] as String? ??
          user?.email?.split('@').first ??
          email.split('@').first;

      try {
        if (user != null) {
          await client.from('users').upsert({
            'email': user.email ?? email,
            'display_name': displayName,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          }, onConflict: 'email');
        }
      } catch (_) {}

      if (!mounted) return;
      // If project requires email confirmation, user may not be signed in yet.
      if (response.session == null) {
        setState(() {
          _loading = false;
          _loadingProvider = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_l.isEn
                ? 'Registration created. Please verify your email, then sign in.'
                : '注册已创建，请先验证邮箱后再登录。'),
          ),
        );
        return;
      }
      await _onLoginSuccess(provider: 'email_password', displayName: displayName);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingProvider = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l.isEn ? e.message : '注册失败：${e.message}')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingProvider = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l.isEn ? 'Registration failed: $e' : '注册失败：$e')),
      );
    }
  }

  Future<void> _resetPassword() async {
    final email = _inputController.text.trim();
    if (email.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l.loginEmailHint)),
      );
      return;
    }
    final client = SupabaseBootstrap.clientOrNull;
    if (client == null) return;
    setState(() {
      _loading = true;
      _loadingProvider = 'password_reset';
    });
    try {
      await client.auth.resetPasswordForEmail(
        email,
        redirectTo: kIsWeb ? null : SupabaseBootstrap.authRedirectUrl,
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingProvider = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${_l.loginResetPasswordSent}\n${_l.loginResetPasswordSupabaseRedirectHint}',
          ),
          duration: const Duration(seconds: 10),
        ),
      );
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingProvider = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l.isEn ? e.message : '重置失败：${e.message}')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingProvider = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l.isEn ? 'Reset failed: $e' : '重置失败：$e')),
      );
    }
  }

  Future<void> _onLoginSuccess(
      {String provider = 'unknown', String? displayName}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(LangPrefs.loggedIn, true);
    await prefs.setString('login_provider', provider);
    if (displayName != null) {
      await prefs.setString('login_display_name', displayName);
    }
    await prefs.setBool(LangPrefs.rememberMe, _rememberMe);

    // Switch to this account's own local SQLite file namespace immediately.
    // (User-scoped path is resolved by LangDbService via current auth user id.)
    try {
      final lang = AppLangNotifier();
      await DatabaseHelper.openWithLangs(lang.targetLang, lang.nativeLang);
    } catch (_) {}

    setState(() {
      _loading = false;
      _loadingProvider = null;
    });
    if (!mounted) return;
    _completeLogin();
  }

  void _completeLogin() {
    if (widget.onComplete != null) {
      widget.onComplete!();
    } else if (Navigator.canPop(context)) {
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = _l;

    if (_showEmailRegister) {
      return _buildEmailRegisterPage(l);
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FF),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              Center(child: _appLogoBadge()),
              const SizedBox(height: 16),
              Text(
                l.loginWelcome,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A237E),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                l.loginSubtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade600,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),

              _socialBtn(
                'google',
                l.loginWithGoogle,
                Colors.white,
                Colors.black87,
                const FaIcon(FontAwesomeIcons.google,
                    size: 16, color: Color(0xFF4285F4)),
                border: Colors.grey.shade300,
                onTap: _signInGoogle,
              ),
              const SizedBox(height: 10),
              _socialBtn(
                'apple',
                l.loginWithApple,
                Colors.black,
                Colors.white,
                const FaIcon(FontAwesomeIcons.apple, size: 18, color: Colors.white),
                onTap: _signInApple,
              ),
              const SizedBox(height: 10),
              _socialBtn(
                'wechat',
                l.loginWithWechat,
                const Color(0xFF07C160),
                Colors.white,
                const FaIcon(FontAwesomeIcons.weixin, size: 16, color: Colors.white),
                onTap: _signInWeChat,
              ),

              const SizedBox(height: 20),
              Row(children: [
                Expanded(child: Divider(color: Colors.grey.shade300)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    l.loginOr,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                  ),
                ),
                Expanded(child: Divider(color: Colors.grey.shade300)),
              ]),
              const SizedBox(height: 16),

              OutlinedButton.icon(
                icon: const Icon(Icons.email_outlined, size: 20),
                label: Text(
                  l.loginWithEmailRegister,
                  style: const TextStyle(fontSize: 14),
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  side: BorderSide(color: Colors.grey.shade400),
                ),
                onPressed: _loading
                    ? null
                    : () => setState(() {
                          _showEmailRegister = true;
                          _codeSent = false;
                          _inputController.clear();
                          _codeController.clear();
                        }),
              ),

              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: Checkbox(
                      value: _rememberMe,
                      activeColor: const Color(0xFF1565C0),
                      onChanged: (v) =>
                          setState(() => _rememberMe = v ?? true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l.loginRememberMe,
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                  ),
                ],
              ),

              const SizedBox(height: 8),
              Text(
                l.loginTerms,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade400,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _socialBtn(
    String provider,
    String label,
    Color bg,
    Color fg,
    Widget icon, {
    Color? border,
    required VoidCallback onTap,
  }) {
    final isLoading = _loading && _loadingProvider == provider;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: _loading ? null : onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 50,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: border != null ? Border.all(color: border, width: 1) : null,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: provider == 'google'
                    ? Colors.transparent
                    : Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Center(child: icon),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: isLoading
                  ? Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: fg,
                        ),
                      ),
                    )
                  : Text(
                      label,
                      style: TextStyle(
                        color: fg,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildEmailRegisterPage(L10n l) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FF),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        title: Text(
          l.loginEmailRegisterTitle,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => setState(() {
            _showEmailRegister = false;
            _codeSent = false;
          }),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 32),
            const Icon(Icons.email_outlined,
                size: 56, color: Color(0xFF1565C0)),
            const SizedBox(height: 24),
            TextField(
              controller: _inputController,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                hintText: l.loginEmailHint,
                prefixIcon:
                    const Icon(Icons.email, color: Color(0xFF1565C0)),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: !_showPassword,
              decoration: InputDecoration(
                hintText: l.loginPasswordHint,
                prefixIcon:
                    const Icon(Icons.lock_outline, color: Color(0xFF1565C0)),
                suffixIcon: IconButton(
                  tooltip: _showPassword
                      ? (l.isEn ? 'Hide password' : (l.isZhTW ? '隱藏密碼' : '隐藏密码'))
                      : (l.isEn ? 'Show password' : (l.isZhTW ? '顯示密碼' : '显示密码')),
                  onPressed: () =>
                      setState(() => _showPassword = !_showPassword),
                  icon: Icon(
                    _showPassword ? Icons.visibility_off : Icons.visibility,
                    color: const Color(0xFF1565C0),
                  ),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2E7D32),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: _loading ? null : _signInWithPassword,
              child: _loading && _loadingProvider == 'password'
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2),
                    )
                  : Text(l.loginPasswordSignIn,
                      style: const TextStyle(fontSize: 15)),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: _loading ? null : _registerWithPassword,
              child: _loading && _loadingProvider == 'password_register'
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l.loginPasswordRegister,
                      style: const TextStyle(fontSize: 15)),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _loading ? null : _resetPassword,
                child: _loading && _loadingProvider == 'password_reset'
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l.loginForgotPassword),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1565C0),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: (_codeSent || _loading) ? null : _sendCode,
              child: _loading && _loadingProvider == 'code' && !_codeSent
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2),
                    )
                  : Text(l.loginSendCode, style: const TextStyle(fontSize: 15)),
            ),
            if (_codeSent) ...[
              const SizedBox(height: 20),
              TextField(
                controller: _codeController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  hintText: l.loginCodeHint,
                  prefixIcon:
                      const Icon(Icons.lock_outline, color: Color(0xFF1565C0)),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  filled: true,
                  fillColor: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1565C0),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _loading ? null : _verifyCode,
                child: _loading && _loadingProvider == 'code'
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : Text(l.loginVerify, style: const TextStyle(fontSize: 15)),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Checkbox(
                    value: _rememberMe,
                    activeColor: const Color(0xFF1565C0),
                    onChanged: (v) =>
                        setState(() => _rememberMe = v ?? true),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  l.loginRememberMe,
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
