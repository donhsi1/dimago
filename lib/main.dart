import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'practice_page.dart';
import 'dictionary_list_page.dart';
import 'add_word_page.dart';
import 'import_page.dart';
import 'settings_page.dart';
import 'database_helper.dart';
import 'notification_service.dart';
import 'language_prefs.dart';
import 'lang_db_service.dart';
import 'login_page.dart';
import 'setup_language_page.dart';
import 'api_stats_page.dart';

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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.initialize();
  await NotificationService.reschedule();
  await AppLangNotifier().load();
  // Auto-sync UI lang from device locale on each startup
  final detectedUiLang = _detectDeviceUiLang();
  await AppLangNotifier().setUiLang(detectedUiLang);
  // Open language databases only if both DB files are already valid
  final notifier = AppLangNotifier();
  final learnReady  = await LangDbService.isDownloaded(notifier.targetLang);
  final nativeReady = await LangDbService.isDownloaded(notifier.nativeLang);
  if (learnReady && nativeReady) {
    await DatabaseHelper.openWithLangs(notifier.targetLang, notifier.nativeLang);
  }
  runApp(const LangoApp());
}

class LangoApp extends StatelessWidget {
  const LangoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DIMAGO',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
        useMaterial3: true,
      ),
      home: const _StartupRouter(),
    );
  }
}

class _StartupRouter extends StatefulWidget {
  const _StartupRouter();
  @override
  State<_StartupRouter> createState() => _StartupRouterState();
}

class _StartupRouterState extends State<_StartupRouter> {
  bool _ready = false;
  bool _needSetup = false;
  bool _needLogin = false;

  @override
  void initState() {
    super.initState();
    _checkFirstRun();
  }

  Future<void> _checkFirstRun() async {
    final prefs = await SharedPreferences.getInstance();
    final setupDone = prefs.getBool(LangPrefs.setupDone) ?? false;
    final rememberMe = prefs.getBool(LangPrefs.rememberMe) ?? false;
    final loggedIn = prefs.getBool(LangPrefs.loggedIn) ?? false;

    setState(() {
      _needSetup = !setupDone;
      _needLogin = !rememberMe || !loggedIn;
      _ready = true;
    });
  }

  void _onSetupDone() {
    setState(() {
      _needSetup = false;
      // After setup always show login
      _needLogin = true;
    });
  }

  void _onLoginDone() {
    setState(() {
      _needLogin = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        backgroundColor: Color(0xFF1565C0),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('L', style: TextStyle(color: Colors.white, fontSize: 64, fontWeight: FontWeight.bold)),
              SizedBox(height: 24),
              CircularProgressIndicator(color: Colors.white),
            ],
          ),
        ),
      );
    }

    if (_needSetup) {
      return SetupLanguagePage(onComplete: _onSetupDone);
    }

    if (_needLogin) {
      return LoginPage(fromSetup: false, onComplete: _onLoginDone);
    }

    return const _AppShell();
  }
}

// ════════════════════════════════════════════════════════════════
// Main shell
// ════════════════════════════════════════════════════════════════
class _AppShell extends StatefulWidget {
  const _AppShell();
  @override
  State<_AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<_AppShell> {
  final _practiceKey = GlobalKey<PracticePageState>();
  final _langNotifier = AppLangNotifier();

  @override
  void initState() {
    super.initState();
    _langNotifier.addListener(_onLangChanged);
  }

  @override
  void dispose() {
    _langNotifier.removeListener(_onLangChanged);
    super.dispose();
  }

  void _onLangChanged() => setState(() {});

  Widget _buildAppBarTitle(AppLangNotifier n) {
    return const Text('DimaGo',
        style: TextStyle(
            fontWeight: FontWeight.bold, fontSize: 18, color: Colors.white));
  }

  void _navigate(BuildContext context, String value) {

    switch (value) {
      case 'dictionary':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const DictionaryListPage()))
            .then((_) => _practiceKey.currentState?.reload());
        break;
      case 'add_word':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const AddWordPage()))
            .then((_) => _practiceKey.currentState?.reload());
        break;
      case 'import':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const ImportPage()))
            .then((_) => _practiceKey.currentState?.reload());
        break;
      case 'settings':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage()));
        break;
      case 'show_api':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const ApiStatsPage()));
        break;
      case 'login':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginPage()));
        break;
      case 'exit':
        SystemNavigator.pop();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n(_langNotifier.uiLang);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        title: _buildAppBarTitle(_langNotifier),
        actions: [
          PopupMenuButton<String>(
            tooltip: l.settings,
            icon: const Icon(Icons.menu),
            onSelected: (value) => _navigate(context, value),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'dictionary', child: Row(children: [const Icon(Icons.menu_book, color: Color(0xFF1565C0)), const SizedBox(width: 8), Text(l.menuDictionary)])),
              PopupMenuItem(value: 'add_word', child: Row(children: [const Icon(Icons.add_circle_outline, color: Color(0xFF2E7D32)), const SizedBox(width: 8), Text(l.menuAddWord)])),
              const PopupMenuDivider(),
              PopupMenuItem(value: 'settings', child: Row(children: [const Icon(Icons.settings, color: Colors.teal), const SizedBox(width: 8), Text(l.menuSettings)])),
              PopupMenuItem(value: 'show_api', child: Row(children: [const Icon(Icons.bar_chart, color: Colors.deepPurple), const SizedBox(width: 8), const Text('Show API')])),
              PopupMenuItem(value: 'login', child: Row(children: [const Icon(Icons.account_circle_outlined, color: Colors.indigo), const SizedBox(width: 8), Text(l.menuLogin)])),
              PopupMenuItem(
                value: 'import',
                child: Row(children: [
                  const Icon(Icons.upload_file, color: Colors.deepOrange),
                  const SizedBox(width: 8),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(l.menuImport),
                    Text(l.menuImportSub, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  ]),
                ]),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(value: 'exit', child: Row(children: [const Icon(Icons.exit_to_app, color: Colors.red), const SizedBox(width: 8), Text(l.menuExit)])),
            ],
          ),
        ],
      ),
      body: PracticePage(key: _practiceKey, embedded: true),
    );
  }
}
