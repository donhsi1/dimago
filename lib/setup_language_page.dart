import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'language_prefs.dart';
import 'lang_db_service.dart';

class SetupLanguagePage extends StatefulWidget {
  /// Called when setup is complete. If null, uses Navigator.pop.
  final VoidCallback? onComplete;
  const SetupLanguagePage({super.key, this.onComplete});

  @override
  State<SetupLanguagePage> createState() => _SetupLanguagePageState();
}

class _SetupLanguagePageState extends State<SetupLanguagePage> {
  String _uiLang = 'en_US';
  String _learnLang = 'th';
  String _transLang = 'zh_CN';
  bool _saving = false;

  L10n get _l => L10n(_uiLang);

  Widget _appLogoBadge() {
    return Container(
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1565C0).withOpacity(0.3),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Image.asset(
          'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png',
          fit: BoxFit.cover,
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _uiLang = _detectDeviceUiLang();
  }

  String _detectDeviceUiLang() {
    final locale = Platform.localeName;
    if (locale.startsWith('zh_TW') || locale.startsWith('zh_HK') || locale.startsWith('zh_MO')) {
      return 'zh_TW';
    } else if (locale.startsWith('zh')) {
      return 'zh_CN';
    } else if (locale.startsWith('th')) {
      return 'th';
    } else if (locale.startsWith('fr')) {
      return 'fr';
    } else if (locale.startsWith('de')) {
      return 'de';
    } else if (locale.startsWith('it')) {
      return 'it';
    } else if (locale.startsWith('es')) {
      return 'es';
    } else if (locale.startsWith('ja')) {
      return 'ja';
    } else if (locale.startsWith('ko')) {
      return 'ko';
    } else if (locale.startsWith('my')) {
      return 'my';
    } else if (locale.startsWith('he')) {
      return 'he';
    } else if (locale.startsWith('ru')) {
      return 'ru';
    } else if (locale.startsWith('uk')) {
      return 'uk';
    }
    return 'en_US';
  }

  Widget _buildDropdown({
    required List<LangOption> options,
    required String value,
    required ValueChanged<String> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      value: value,
      isExpanded: true,
      decoration: InputDecoration(
        filled: true,
        fillColor: Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide:
              const BorderSide(color: Color(0xFF1565C0), width: 2),
        ),
      ),
      items: options
          .map((opt) => DropdownMenuItem<String>(
                value: opt.code,
                child: Row(
                  children: [
                    Text(opt.flag,
                        style: const TextStyle(fontSize: 20)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(opt.label,
                          style: const TextStyle(fontSize: 14)),
                    ),
                  ],
                ),
              ))
          .toList(),
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }

  Future<void> _finish() async {
    setState(() => _saving = true);

    final notifier = AppLangNotifier();
    await notifier.setUiLang(_uiLang);
    await notifier.setTargetLang(_learnLang);
    await notifier.setNativeLang(_transLang);

    setState(() => _saving = false);
    if (!mounted) return;

    final ok = await showLangDbDownloadDialog(
      context,
      learnLang: _learnLang,
      nativeLang: _transLang,
    );
    if (!mounted) return;
    if (!ok) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(LangPrefs.setupDone, true);
    if (!mounted) return;

    if (widget.onComplete != null) {
      widget.onComplete!();
    } else {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = _l;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FF),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          children: [
            // ── Logo + welcome ──────────────────────────────────
            Center(
              child: _appLogoBadge(),
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                l.setupWelcome,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A237E),
                ),
              ),
            ),
            const SizedBox(height: 32),

            // ── Learning language ───────────────────────────────
            _SetupCard(
              icon: Icons.language,
              title: l.langTarget,
              subtitle: l.langTargetNote,
              child: _buildDropdown(
                options: kTargetLangOptions,
                value: _learnLang,
                onChanged: (v) => setState(() => _learnLang = v),
              ),
            ),

            const SizedBox(height: 16),

            // ── Translation language ────────────────────────────
            _SetupCard(
              icon: Icons.person,
              title: l.langNative,
              subtitle: l.langNativeNote,
              child: _buildDropdown(
                options: kNativeLangOptions,
                value: _transLang,
                onChanged: (v) => setState(() => _transLang = v),
              ),
            ),

            const SizedBox(height: 32),

            // ── Confirm button ──────────────────────────────────
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1565C0),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _saving ? null : _finish,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2),
                    )
                  : Text(
                      l.setupStart,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                    ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

// ── Setup section card (same style as SettingsLanguagePage) ───
class _SetupCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  const _SetupCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: const Color(0xFF1565C0)),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade500)),
                  ],
                ),
              ],
            ),
            const Divider(),
            child,
          ],
        ),
      ),
    );
  }
}
