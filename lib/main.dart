import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthChangeEvent;
import 'practice_page.dart';
import 'dictionary_list_page.dart';
import 'lesson_page.dart';
import 'add_word_page.dart';
import 'settings_page.dart';
import 'database_helper.dart';
import 'notification_service.dart';
import 'language_prefs.dart';
import 'lang_db_service.dart';
import 'login_page.dart';
import 'setup_language_page.dart';
import 'api_stats_page.dart';
import 'community_page.dart';
import 'app_tab_controller.dart';
import 'recorder_controller.dart';
import 'supabase_bootstrap.dart';
import 'supabase_vocab_hydrator.dart';
import 'whisper_asr_service.dart';
import 'system_prefs_notifier.dart';
import 'edge_tts_service.dart';
import 'user_feedback.dart';
import 'microphone_permission.dart';
import 'set_new_password_page.dart';

/// Shows TTS-missing [SnackBar]s from [EdgeTTSService] without a [BuildContext].
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

// Placeholder home page
class _HomePage extends StatelessWidget {
  const _HomePage();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text('Home', style: TextStyle(fontSize: 24)),
    );
  }
}

String _detectDeviceUiLang() {
  final locale = Platform.localeName;
  if (locale.startsWith('zh_TW') ||
      locale.startsWith('zh_HK') ||
      locale.startsWith('zh_MO')) {
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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SupabaseBootstrap.ensureInitialized();
  await WhisperAsrService.loadKeyFromAsset();
  await NotificationService.initialize();
  await NotificationService.reschedule();
  await AppLangNotifier().load();
  await SystemPrefsNotifier().load();
  // Auto-sync UI lang from device locale on each startup
  final detectedUiLang = _detectDeviceUiLang();
  await AppLangNotifier().setUiLang(detectedUiLang);
  // Open combined language DB: local SQLite file, or hydrate from Supabase first
  final notifier = AppLangNotifier();
  final hasSession = SupabaseBootstrap.clientOrNull?.auth.currentSession != null;
  if (hasSession) {
    var dbReady = await LangDbService.isDownloadedPair(
        notifier.targetLang, notifier.nativeLang);
    if (!dbReady && SupabaseVocabHydrator.isAvailable) {
      try {
        await SupabaseVocabHydrator.hydrateToLocalFile(
          translateLang: notifier.targetLang,
          nativeLang: notifier.nativeLang,
        );
        dbReady = await LangDbService.isDownloadedPair(
            notifier.targetLang, notifier.nativeLang);
      } catch (_) {
        // Missing bundle or offline — user can download via setup / settings
      }
    }
    if (dbReady) {
      await DatabaseHelper.openWithLangs(notifier.targetLang, notifier.nativeLang);
    }
  }
  UserFeedback.messengerKey = rootScaffoldMessengerKey;
  runApp(const LangoApp());
}

class LangoApp extends StatelessWidget {
  const LangoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DIMAGO',
      scaffoldMessengerKey: rootScaffoldMessengerKey,
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
  StreamSubscription? _authSub;
  bool _showingPasswordReset = false;

  @override
  void initState() {
    super.initState();
    _listenAuthRecovery();
    _checkFirstRun();
  }

  void _listenAuthRecovery() {
    final client = SupabaseBootstrap.clientOrNull;
    if (client == null) return;
    _authSub?.cancel();
    _authSub = client.auth.onAuthStateChange.listen((data) {
      if (!mounted) return;
      if (data.event != AuthChangeEvent.passwordRecovery) return;
      if (_showingPasswordReset) return;
      _showingPasswordReset = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const SetNewPasswordPage()))
            .whenComplete(() {
          _showingPasswordReset = false;
        });
      });
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  Future<void> _checkFirstRun() async {
    final prefs = await SharedPreferences.getInstance();
    final setupDone = prefs.getBool(LangPrefs.setupDone) ?? false;
    final rememberMe = prefs.getBool(LangPrefs.rememberMe) ?? false;
    final client = SupabaseBootstrap.clientOrNull;
    final hasSession = client?.auth.currentSession != null;

    // If user did not opt into "Remember me", clear any persisted session on startup.
    if (!rememberMe && hasSession) {
      try {
        await client!.auth.signOut();
      } catch (_) {}
    }

    final loggedIn = rememberMe && (client?.auth.currentSession != null);
    await prefs.setBool(LangPrefs.loggedIn, loggedIn);

    setState(() {
      _needSetup = !setupDone;
      _needLogin = !loggedIn;
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

    if (_needLogin) {
      return LoginPage(fromSetup: false, onComplete: _onLoginDone);
    }

    if (_needSetup) {
      return SetupLanguagePage(onComplete: _onSetupDone);
    }

    return const _AppShell();
  }
}

// ════════════════════════════════════════════════════════════════
// Main shell with bottom navigation
// ════════════════════════════════════════════════════════════════
class _AppShell extends StatefulWidget {
  const _AppShell();
  @override
  State<_AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<_AppShell> {
  // Tab indices:
  //   0 = Home
  //   1 = Practice (PracticePage) — default
  //   2 = Lesson (LessonPage)
  //   3 = Community
  //   4 = Settings
  int _tabIndex = 1;

  final _practiceKey = GlobalKey<PracticePageState>();
  final _lessonPageKey = GlobalKey<LessonPageState>();
  final _langNotifier = AppLangNotifier();
  String _lessonTitle = 'DimaGo';
  bool _stoppingRecording = false;

  @override
  void initState() {
    super.initState();
    _langNotifier.addListener(_onLangChanged);
    AppTabController.requestedTab.addListener(_onExternalTabRequest);
    RecorderController.isRecording.addListener(_onRecordingChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      requestMicrophonePermissionIfNeeded();
    });
  }

  @override
  void dispose() {
    AppTabController.requestedTab.removeListener(_onExternalTabRequest);
    RecorderController.isRecording.removeListener(_onRecordingChanged);
    _langNotifier.removeListener(_onLangChanged);
    super.dispose();
  }

  void _onLangChanged() => setState(() {});
  void _onRecordingChanged() => setState(() {});

  Future<void> _stopRecordingFromOverlay() async {
    if (_stoppingRecording) return;
    setState(() => _stoppingRecording = true);
    final path = await RecorderController.stopRecording();
    if (!mounted) return;
    setState(() => _stoppingRecording = false);

    final l = L10n(_langNotifier.uiLang);
    if (path.isEmpty) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(l.recorderStopFailed)),
      );
      return;
    }

    _onTabTapped(4);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsRecorderPage(initialVideoPath: path),
      ),
    );
  }

  void _onExternalTabRequest() {
    final idx = AppTabController.requestedTab.value;
    if (idx == null) return;
    _onTabTapped(idx);
    AppTabController.clear();
  }

  void _onTabTapped(int index) {
    if (index != _tabIndex) {
      _practiceKey.currentState?.stopQuizMode();
      // Leaving Lesson: close any route pushed on root stack.
      if (_tabIndex == 2) {
        Navigator.of(context).maybePop();
      }
    }
    setState(() => _tabIndex = index);
    // When switching back to Practice tab, reload in case words were added
    if (index == 1) {
      _practiceKey.currentState?.reload();
    }
    // Refresh lesson list so grey/unlock matches local word rows after downloads
    if (index == 2) {
      _lessonPageKey.currentState?.reload();
    }
  }

  void _navigate(BuildContext context, String value) {
    _practiceKey.currentState?.stopQuizMode();

    switch (value) {
      case 'add_word':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const AddWordPage()))
            .then((_) => _practiceKey.currentState?.reload());
        break;
      case 'show_api':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const ApiStatsPage()));
        break;
      case 'dictionary':
        Navigator.push(context, MaterialPageRoute(
          builder: (_) => DictionaryListPage(onWordChanged: () => _practiceKey.currentState?.reload()),
        ));
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

    final recording = RecorderController.isRecording.value;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        centerTitle: true,
        leading: recording
            ? IconButton(
                tooltip: l.recorderStop,
                onPressed: _stoppingRecording ? null : _stopRecordingFromOverlay,
                icon: _stoppingRecording
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.stop_circle_outlined),
              )
            : null,
        title: Text(
            _tabIndex == 1
                ? _lessonTitle
                : (_tabIndex == 2 ? l.lessonLabel : 'DimaGo'),
            style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 18, color: Colors.white)),
        actions: [
          PopupMenuButton<String>(
            tooltip: l.settings,
            icon: const Icon(Icons.menu),
            onSelected: (value) => _navigate(context, value),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'add_word', child: Row(children: [const Icon(Icons.add_circle_outline, color: Color(0xFF2E7D32)), const SizedBox(width: 8), Text(l.menuAddWord)])),
              const PopupMenuDivider(),
              PopupMenuItem(value: 'show_api', child: Row(children: [const Icon(Icons.bar_chart, color: Colors.deepPurple), const SizedBox(width: 8), const Text('Show API')])),
              PopupMenuItem(value: 'dictionary', child: Row(children: [const Icon(Icons.menu_book_outlined, color: Colors.teal), const SizedBox(width: 8), Text(l.menuDictionary)])),
              PopupMenuItem(value: 'login', child: Row(children: [const Icon(Icons.account_circle_outlined, color: Colors.indigo), const SizedBox(width: 8), Text(l.menuLogin)])),
              const PopupMenuDivider(),
              PopupMenuItem(value: 'exit', child: Row(children: [const Icon(Icons.exit_to_app, color: Colors.red), const SizedBox(width: 8), Text(l.menuExit)])),
            ],
          ),
        ],
      ),
      body: IndexedStack(
        index: _tabIndex,
        sizing: StackFit.expand,
        children: [
          const _HomePage(),
          PracticePage(
            key: _practiceKey,
            embedded: true,
            onCategoryChanged: (name) => setState(() => _lessonTitle = name),
          ),
          SizedBox.expand(
            child: LessonPage(
              key: _lessonPageKey,
              onCategorySelected: (id) {
                _practiceKey.currentState?.setCategory(id);
              },
              selectedCategoryId:
                  _practiceKey.currentState?.selectedCategoryId,
            ),
          ),
          const CommunityPage(),
          const SettingsPage(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tabIndex,
        onTap: _onTabTapped,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: const Color(0xFF1565C0),
        unselectedItemColor: Colors.grey,
        items: [
          const BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.school_outlined),
            activeIcon: const Icon(Icons.school),
            label: l.isEn ? 'Practice' : (l.isZhTW ? '練習' : '练习'),
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.menu_book_outlined),
            activeIcon: const Icon(Icons.menu_book),
            label: l.lessonLabel,
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.people_outlined),
            activeIcon: const Icon(Icons.people),
            label: l.isEn ? 'Community' : (l.isZhTW ? '社區' : '社区'),
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.settings_outlined),
            activeIcon: const Icon(Icons.settings),
            label: l.settings,
          ),
        ],
      ),
    );
  }
}
