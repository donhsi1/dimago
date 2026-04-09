import 'dart:io';
import 'package:flutter/material.dart';
import 'language_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'lang_db_service.dart';

class SettingsLanguagePage extends StatefulWidget {
  /// [fromSetup] = true 时显示「确认」按钮（首次登录流程→'
  final bool fromSetup;
  const SettingsLanguagePage({super.key, this.fromSetup = false});

  @override
  State<SettingsLanguagePage> createState() => _SettingsLanguagePageState();
}

class _SettingsLanguagePageState extends State<SettingsLanguagePage> {
  final _notifier = AppLangNotifier();

  String _targetLang = LangPrefs.defaultTargetLang;
  String _nativeLang = LangPrefs.defaultNativeLang;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _targetLang = _notifier.targetLang;
    _nativeLang = _notifier.nativeLang;
  }

  L10n get _l => L10n(_notifier.uiLang);

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
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
          borderSide: const BorderSide(color: Color(0xFF1565C0), width: 2),
        ),
      ),
      items: options.map((opt) => DropdownMenuItem<String>(
        value: opt.code,
        child: Row(
          children: [
            Text(opt.flag, style: const TextStyle(fontSize: 20)),
            const SizedBox(width: 10),
            Expanded(child: Text(opt.label, style: const TextStyle(fontSize: 14))),
          ],
        ),
      )).toList(),
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);

    // UI lang is auto-detected from device; update it on each save
    final detectedUiLang = _detectDeviceUiLang();
    await _notifier.setUiLang(detectedUiLang);
    await _notifier.setTargetLang(_targetLang);
    await _notifier.setNativeLang(_nativeLang);

    setState(() => _saving = false);
    if (!mounted) return;

    // Show download dialog →always force re-download so the new language
    // DB replaces the old one instead of being skipped.
    final ok = await showLangDbDownloadDialog(
      context,
      learnLang: _targetLang,
      nativeLang: _nativeLang,
      forceRedownload: true,
    );
    if (!mounted) return;

    if (widget.fromSetup) {
      if (ok) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(LangPrefs.langPackDone, true);
        if (!mounted) return;
        Navigator.of(context).pop(true);
      }
    } else {
      /// Settings → Language is one `Navigator.push` on top of [_AppShell].
      /// Popping twice would remove the shell and leave a black / empty screen.
      if (ok && mounted) {
        final nav = Navigator.of(context);
        if (nav.canPop()) {
          nav.pop();
        }
      }
    }
  }

  String _detectDeviceUiLang() {
    final locale = Platform.localeName;
    if (locale.startsWith('zh_TW') || locale.startsWith('zh_HK') || locale.startsWith('zh_MO')) {
      return 'zh_TW';
    } else if (locale.startsWith('zh')) {
      return 'zh_CN';
    } else if (locale.startsWith('th')) {
      return 'th';
    } else if (locale.startsWith('fr')) return 'fr';
    else if (locale.startsWith('de')) return 'de';
    else if (locale.startsWith('it')) return 'it';
    else if (locale.startsWith('es')) return 'es';
    else if (locale.startsWith('ja')) return 'ja';
    else if (locale.startsWith('ko')) return 'ko';
    else if (locale.startsWith('my')) return 'my';
    else if (locale.startsWith('he')) return 'he';
    else if (locale.startsWith('ru')) return 'ru';
    else if (locale.startsWith('uk')) return 'uk';
    return 'en_US';
  }

  @override
  Widget build(BuildContext context) {
    final l = _l;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        title: Text(l.langTitle, style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── 学习语言 ─────────────────────────────────────────
          _SectionCard(
            icon: Icons.language,
            title: l.langTarget,
            subtitle: l.langTargetNote,
            child: _buildDropdown(
              options: kTargetLangOptions,
              value: _targetLang,
              onChanged: (v) => setState(() => _targetLang = v),
            ),
          ),

          const SizedBox(height: 16),

          // ── 翻译语言 ─────────────────────────────────────────
          _SectionCard(
            icon: Icons.person,
            title: l.langNative,
            subtitle: l.langNativeNote,
            child: _buildDropdown(
              options: kNativeLangOptions,
              value: _nativeLang,
              onChanged: (v) => setState(() => _nativeLang = v),
            ),
          ),

          const SizedBox(height: 32),

          // ── 确认按钮 ─────────────────────────────────────────
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF1565C0),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : Text(l.confirm, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

// ── 设定卡片组件 ──────────────────────────────────────────────
class _SectionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  const _SectionCard({
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
                    Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    Text(subtitle, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
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
