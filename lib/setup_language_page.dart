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
  final _controller = PageController();
  int _page = 0;

  // UI lang is auto-detected from device locale, not shown to user
  late String _uiLang;
  String _learnLang = 'th';
  String _transLang = 'zh_CN';

  L10n get _l => L10n(_uiLang);

  @override
  void initState() {
    super.initState();
    _uiLang = _detectDeviceUiLang();
  }

  /// Map device locale to a supported UI language code.
  String _detectDeviceUiLang() {
    final locale = Platform.localeName; // e.g. "zh_CN", "en_US", "th_TH"
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

  void _next() {
    if (_page < 1) {
      _controller.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
      setState(() => _page++);
    } else {
      _finish();
    }
  }

  void _back() {
    if (_page > 0) {
      _controller.previousPage(duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
      setState(() => _page--);
    }
  }

  Future<void> _finish() async {
    final notifier = AppLangNotifier();
    await notifier.setUiLang(_uiLang);
    await notifier.setTargetLang(_learnLang);
    await notifier.setNativeLang(_transLang);

    if (!mounted) return;

    // Show download dialog
    final ok = await showLangDbDownloadDialog(
      context,
      learnLang: _learnLang,
      nativeLang: _transLang,
    );
    if (!mounted) return;
    if (!ok) return; // user cancelled or error →don't proceed

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
        child: Column(
          children: [
            const SizedBox(height: 32),
            // Logo
            Container(
              width: 72, height: 72,
              decoration: BoxDecoration(
                color: const Color(0xFF1565C0),
                borderRadius: BorderRadius.circular(18),
                boxShadow: [BoxShadow(color: const Color(0xFF1565C0).withOpacity(0.3), blurRadius: 14, offset: const Offset(0, 5))],
              ),
              child: const Center(child: Text('L', style: TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.bold, height: 1))),
            ),
            const SizedBox(height: 12),
            Text(l.setupWelcome, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF1A237E))),
            const SizedBox(height: 24),
            // Step indicators (2 steps)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(2, (i) => AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: _page == i ? 28 : 10, height: 10,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: _page >= i ? const Color(0xFF1565C0) : Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(5),
                ),
              )),
            ),
            const SizedBox(height: 20),
            // Pages
            Expanded(
              child: PageView(
                controller: _controller,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _buildLangList(l.setupSelectLearnLang, _learnLang, (v) => setState(() => _learnLang = v)),
                  _buildLangList(l.setupSelectTransLang, _transLang, (v) => setState(() => _transLang = v)),
                ],
              ),
            ),
            // Buttons
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Row(
                children: [
                  if (_page > 0)
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          side: const BorderSide(color: Color(0xFF1565C0)),
                        ),
                        onPressed: _back,
                        child: Text(l.setupBack, style: const TextStyle(fontSize: 16, color: Color(0xFF1565C0))),
                      ),
                    ),
                  if (_page > 0) const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF1565C0),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _next,
                      child: Text(_page == 1 ? l.setupStart : l.setupNext, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildLangList(String title, String selected, ValueChanged<String> onSelect) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Color(0xFF37474F))),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: kAllLanguages.length,
            itemBuilder: (ctx, i) {
              final lang = kAllLanguages[i];
              final isSelected = lang.code == selected;
              return Card(
                elevation: isSelected ? 3 : 0.5,
                color: isSelected ? const Color(0xFFE3F2FD) : Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: isSelected ? const BorderSide(color: Color(0xFF1565C0), width: 2) : BorderSide.none,
                ),
                child: ListTile(
                  leading: Text(lang.flag, style: const TextStyle(fontSize: 28)),
                  title: Text(lang.label, style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.normal, color: isSelected ? const Color(0xFF1565C0) : Colors.black87)),
                  trailing: isSelected ? const Icon(Icons.check_circle, color: Color(0xFF1565C0)) : null,
                  onTap: () => onSelect(lang.code),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
