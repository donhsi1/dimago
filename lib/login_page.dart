import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'language_prefs.dart';
import 'settings_language_page.dart';

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
  bool _showPhoneLogin = false;
  bool _showEmailLogin = false;
  bool _codeSent = false;

  final _inputController = TextEditingController();
  final _codeController = TextEditingController();

  L10n get _l => L10n(AppLangNotifier().uiLang);

  @override
  void dispose() {
    _inputController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  // ── Google Sign-In ──────────────────────────────────────────
  Future<void> _signInGoogle() async {
    // Google Sign-In requires SHA-1 fingerprint + OAuth Client ID in
    // google-services.json. Show a prompt until properly configured.
    _showNotConfiguredDialog('Google');
  }

  // ── OAuth via browser (TikTok, Facebook, Instagram, iCloud, WeChat) ───
  Future<void> _signInOAuth(String provider) async {
    // WeChat requires a real AppID registered at open.weixin.qq.com.
    // Show a clear prompt instead of crashing with "appid 参数错误".
    if (provider == 'wechat') {
      _showNotConfiguredDialog('WeChat / 微信');
      return;
    }

    setState(() { _loading = true; _loadingProvider = provider; });
    final urls = {
      'tiktok': 'https://www.tiktok.com/auth/authorize/',
      'facebook': 'https://www.facebook.com/dialog/oauth',
      'instagram': 'https://api.instagram.com/oauth/authorize',
      'icloud': 'https://appleid.apple.com/auth/authorize',
    };
    final url = urls[provider];
    if (url != null) {
      final uri = Uri.parse(url);
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
    // Simulate login success for demo (replace with real callback handling)
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    await _onLoginSuccess(provider: provider);
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
              : '$providerName 登录需要已注册→AppID。\n\n请先在开发者后台配→AppID 后再使用此登录方式→',
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

  Future<void> _signIn(String provider) async {
    if (provider == 'google') {
      await _signInGoogle();
    } else {
      await _signInOAuth(provider);
    }
  }

  Future<void> _sendCode() async {
    final input = _inputController.text.trim();
    if (input.isEmpty) return;
    setState(() => _codeSent = true);
    // TODO: call backend to send real SMS/email code
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l.loginCodeSent), duration: const Duration(seconds: 2)),
      );
    }
  }

  Future<void> _verifyCode() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;
    setState(() { _loading = true; _loadingProvider = 'code'; });
    // TODO: verify with backend
    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    await _onLoginSuccess(provider: _showPhoneLogin ? 'phone' : 'email');
  }

  Future<void> _onLoginSuccess({String provider = 'unknown', String? displayName}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(LangPrefs.loggedIn, true);
    await prefs.setString('login_provider', provider);
    if (displayName != null) await prefs.setString('login_display_name', displayName);
    if (_rememberMe) await prefs.setBool(LangPrefs.rememberMe, true);

    setState(() { _loading = false; _loadingProvider = null; });
    if (!mounted) return;

    // Navigate to language settings after login
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsLanguagePage(fromSetup: true)),
    );

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

  void _continueAsGuest() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(LangPrefs.loggedIn, true);
    if (_rememberMe) await prefs.setBool(LangPrefs.rememberMe, true);
    if (!mounted) return;
    _completeLogin();
  }

  @override
  Widget build(BuildContext context) {
    final l = _l;

    if (_showPhoneLogin || _showEmailLogin) {
      return _buildCodeLoginPage(l);
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
              // Logo
              Center(
                child: Container(
                  width: 76, height: 76,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1565C0),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [BoxShadow(color: const Color(0xFF1565C0).withOpacity(0.3), blurRadius: 16, offset: const Offset(0, 6))],
                  ),
                  child: const Center(child: Text('L', style: TextStyle(color: Colors.white, fontSize: 42, fontWeight: FontWeight.bold, height: 1))),
                ),
              ),
              const SizedBox(height: 16),
              Text(l.loginWelcome, textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF1A237E))),
              const SizedBox(height: 6),
              Text(l.loginSubtitle, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Colors.grey.shade600, height: 1.4)),
              const SizedBox(height: 24),

              // Social login buttons
              _socialBtn('google',    l.loginWithGoogle,    Colors.white,            Colors.black87,          'G',  border: Colors.grey.shade300),
              const SizedBox(height: 10),
              _socialBtn('facebook',  l.loginWithFacebook,  const Color(0xFF1877F2), Colors.white,            'f'),
              const SizedBox(height: 10),
              _socialBtn('tiktok',    l.loginWithTiktok,    const Color(0xFF010101), Colors.white,            '→'),
              const SizedBox(height: 10),
              _socialBtn('instagram', l.loginWithInstagram, const Color(0xFFE1306C), Colors.white,            'IG'),
              const SizedBox(height: 10),
              _socialBtn('icloud',    l.loginWithIcloud,    const Color(0xFF3693F5), Colors.white,            '→'),
              const SizedBox(height: 10),
              _socialBtn('wechat',    l.loginWithWechat,    const Color(0xFF07C160), Colors.white,            '→'),

              const SizedBox(height: 20),
              Row(children: [
                Expanded(child: Divider(color: Colors.grey.shade300)),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(l.loginOr, style: TextStyle(fontSize: 12, color: Colors.grey.shade500))),
                Expanded(child: Divider(color: Colors.grey.shade300)),
              ]),
              const SizedBox(height: 16),

              // Phone & Email
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.phone_android, size: 18),
                    label: Text(l.loginWithPhone, style: const TextStyle(fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      side: BorderSide(color: Colors.grey.shade400),
                    ),
                    onPressed: _loading ? null : () => setState(() { _showPhoneLogin = true; _codeSent = false; _inputController.clear(); _codeController.clear(); }),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.email_outlined, size: 18),
                    label: Text(l.loginWithEmail, style: const TextStyle(fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      side: BorderSide(color: Colors.grey.shade400),
                    ),
                    onPressed: _loading ? null : () => setState(() { _showEmailLogin = true; _codeSent = false; _inputController.clear(); _codeController.clear(); }),
                  ),
                ),
              ]),

              const SizedBox(height: 16),
              // Remember me
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                SizedBox(
                  width: 24, height: 24,
                  child: Checkbox(value: _rememberMe, activeColor: const Color(0xFF1565C0), onChanged: (v) => setState(() => _rememberMe = v ?? true)),
                ),
                const SizedBox(width: 8),
                Text(l.loginRememberMe, style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
              ]),

              const SizedBox(height: 12),
              TextButton(
                onPressed: _loading ? null : _continueAsGuest,
                child: Text(l.loginGuest, style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
              ),
              const SizedBox(height: 8),
              Text(l.loginTerms, textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Colors.grey.shade400, height: 1.4)),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _socialBtn(String provider, String label, Color bg, Color fg, String iconText, {Color? border}) {
    final isLoading = _loading && _loadingProvider == provider;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: _loading ? null : () => _signIn(provider),
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
              width: 26, height: 26,
              decoration: BoxDecoration(
                color: provider == 'google' ? Colors.transparent : Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Center(child: Text(iconText, style: TextStyle(
                color: provider == 'google' ? const Color(0xFF4285F4) : fg,
                fontSize: provider == 'icloud' ? 18 : 14,
                fontWeight: FontWeight.bold,
              ))),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: isLoading
                  ? Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: fg)))
                  : Text(label, style: TextStyle(color: fg, fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildCodeLoginPage(L10n l) {
    final isPhone = _showPhoneLogin;
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FF),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        title: Text(isPhone ? l.loginWithPhone : l.loginWithEmail, style: const TextStyle(fontWeight: FontWeight.bold)),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => setState(() { _showPhoneLogin = false; _showEmailLogin = false; })),
      ),
      body: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 32),
            Icon(isPhone ? Icons.phone_android : Icons.email_outlined, size: 56, color: const Color(0xFF1565C0)),
            const SizedBox(height: 24),
            TextField(
              controller: _inputController,
              keyboardType: isPhone ? TextInputType.phone : TextInputType.emailAddress,
              decoration: InputDecoration(
                hintText: isPhone ? l.loginPhoneHint : l.loginEmailHint,
                prefixIcon: Icon(isPhone ? Icons.phone : Icons.email, color: const Color(0xFF1565C0)),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true, fillColor: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1565C0),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _codeSent ? null : _sendCode,
              child: Text(l.loginSendCode, style: const TextStyle(fontSize: 15)),
            ),
            if (_codeSent) ...[
              const SizedBox(height: 20),
              TextField(
                controller: _codeController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  hintText: l.loginCodeHint,
                  prefixIcon: const Icon(Icons.lock_outline, color: Color(0xFF1565C0)),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  filled: true, fillColor: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1565C0),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _loading ? null : _verifyCode,
                child: _loading && _loadingProvider == 'code'
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : Text(l.loginVerify, style: const TextStyle(fontSize: 15)),
              ),
            ],
            const SizedBox(height: 20),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              SizedBox(width: 24, height: 24, child: Checkbox(value: _rememberMe, activeColor: const Color(0xFF1565C0), onChanged: (v) => setState(() => _rememberMe = v ?? true))),
              const SizedBox(width: 8),
              Text(l.loginRememberMe, style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
            ]),
          ],
        ),
      ),
    );
  }
}
