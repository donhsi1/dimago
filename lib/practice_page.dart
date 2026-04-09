import 'dart:async';
import 'dart:math';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'database_helper.dart';
import 'translate_service.dart';
import 'gemini_service.dart';
import 'edge_tts_service.dart';
import 'language_prefs.dart';
import 'settings_page.dart';
import 'sound_feedback_service.dart';
import 'practice_widgets.dart';
import 'lesson_picker_dialog.dart';
import 'talk_asr_service.dart';
import 'talk_accuracy_score.dart';
import 'community_service.dart';
import 'supabase_bootstrap.dart';
import 'user_feedback.dart';

// ── 练习页偏好设→key ─────────────────────────────────────────
class _PracticePrefs {
  static const modeKey      = 'practice_mode';       // 0 = 泰→→ 1 = 中→→'
  static const hideRomanKey = 'practice_hide_roman'; // bool: hide romanization

  /// Index into the ordered practice pool (`word.id` ascending) per category.
  static String seqIndexKey(int? categoryId) => categoryId == null
      ? 'practice_seq_idx_all'
      : 'practice_seq_idx_cat_$categoryId';
}

// ── 练习模式 ──────────────────────────────────────────────────
enum _PracticeMode {
  thaiToChinese, // translateToNative: 显示 nameTranslate，选 nameNative（模式 A）
  chineseToThai, // nativeToTranslate: 显示 nameNative，选 nameTranslate（模式 B）
}

// ── 单道题的选项数据 ───────────────────────────────────────────
class _QuizOption {
  final String srcText;  // 源语言（学习语言→'
  final String dstText;  // 翻译语言
  final bool isCorrect;
  AnswerState state = AnswerState.idle;
  String? romanization; // 源语言罗马拼音（模式B使用→'
  String? romanTranslate;

  /// 模式 A 例句选项：界面显示母语，朗读用翻译语文本；词模式可与 [srcText] 相同。
  final String? translateTtsText;
  /// 用于读/写 audio_translate 或 sampleN_translate_audio
  final int? audioWordId;
  /// null = 词条级 audio_translate；非 null = sample1_translate_audio のみ使用
  final int? audioPhraseSlot;

  _QuizOption({
    required this.srcText,
    required this.dstText,
    required this.isCorrect,
    this.translateTtsText,
    this.audioWordId,
    this.audioPhraseSlot,
  });

  /// 翻译语言朗读用文本
  String get lineForTranslateTts =>
      (translateTtsText != null && translateTtsText!.isNotEmpty)
          ? translateTtsText!
          : srcText;
}

class PracticePage extends StatefulWidget {
  /// embedded=true：不渲染外层 Scaffold（供主页直接嵌入→'
  final bool embedded;
  /// Called whenever the selected category changes, with the display name.
  final void Function(String categoryName)? onCategoryChanged;
  const PracticePage({super.key, this.embedded = false, this.onCategoryChanged});

  @override
  State<PracticePage> createState() => PracticePageState();
}

class PracticePageState extends State<PracticePage> {
  final ScrollController _contentScrollController =
      ScrollController(keepScrollOffset: false);
  String? _lastTopAnchorSignature;
  /// 从外部（如词→添加词典 pop 后）调用，重新加载词典数→'
  Future<void> reload() => _loadPrefsAndData();

  /// Current lesson/category display name (used by AppBar).
  String get currentCategoryName {
    if (_selectedCategoryId == null) return 'DimaGo';
    final cat = _categories.firstWhere(
      (c) => c.id == _selectedCategoryId,
      orElse: () => CategoryEntry(nameNative: 'DimaGo'),
    );
    return cat.nameNative.isNotEmpty ? cat.nameNative : 'DimaGo';
  }

  /// Public getter for current category id (used by LessonPage in main.dart).
  int? get selectedCategoryId => _selectedCategoryId;

  /// Called from LessonPage to change the active lesson/category.
  Future<void> setCategory(int? id) async {
    await _onCategoryChanged(id);
  }

  /// Jump to Practice tab challenge for [categoryId] at challenge segment [segmentIndex] (0–7).
  Future<void> startChallengeForSegment(int categoryId, int segmentIndex) async {
    await _onCategoryChanged(categoryId);
    if (!mounted) return;
    void begin() {
      if (!mounted || _poolEntries.isEmpty) return;
      _applySegmentMode(segmentIndex);
      _challengeStopwatch.reset();
      _pickNext();
    }

    if (_poolEntries.isNotEmpty) {
      begin();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => begin());
    }
  }

  void _notifyCategoryName() {
    widget.onCategoryChanged?.call(currentCategoryName);
  }

  List<DictionaryEntry> _allEntries = [];
  List<DictionaryEntry> _poolEntries = [];
  List<CategoryEntry> _categories = [];
  int? _selectedCategoryId;
  bool _loading = true;

  // 练习模式
  _PracticeMode _mode = _PracticeMode.thaiToChinese;

  // 练习历史（可回退→'
  final List<DictionaryEntry> _history = [];
  int _historyIndex = -1;

  // 当前题选项
  List<_QuizOption> _options = [];
  bool _answered = false;
  bool _firstAttempt = true;

  // 罗马拼音（仅模式 A 使用→'
  String? _romanization;
  bool _loadingRoman = false;
  bool _hideRomanization = false; // toggle: hide roman in both mode A display and mode B tiles

  // ── 底部 Tab 面板（word 模式：释义 / 动作 / 例句）────────────────
  // 0 = Definition, 1 = Actions, 2 = Example
  int _activeTab = 0;

  // 释义（nativeDb.word.definition）
  // null = not yet loaded; '' = loaded but no content; other = actual text
  String? _definitionNative;
  bool _loadingDefinition = false;

  // Actions 内容（nativeDb.word.action）
  String? _actionContent;

  // 例句: word.sample1_* のみ使用
  String? _sample1Translate;
  String? _sample1Native;
  bool _loadingSample = false;
  bool _playingSample = false;

  // TTS
  final EdgeTTSService _tts = EdgeTTSService();
  bool _playing = false;
  // 记录当前正在播放哪个选项（模→B 专用），null = 未播→'
  int? _playingOptionIndex;

  // Quiz mode
  bool _quizMode = false;
  // Sequential correct-answer set: resets on every wrong answer
  final Set<int> _quizAnsweredIds = {};
  // Elapsed time (thinking time only — paused during TTS playback)
  final Stopwatch _challengeStopwatch = Stopwatch();

  // Practice type: 0=word, 1=phrase, 2=photo
  int _practiceType = 0;
  // Phrase mode: question text shown in main display area (null = word mode)
  String? _phraseQuestionText;
  String? _phraseQuestionRoman;

  // Talk mode (press-and-hold recording + pronunciation score)
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _talkPlaybackPlayer = AudioPlayer();
  bool _talkMode = false;
  bool _talkRecording = false;
  bool _talkScoring = false;
  bool _talkButtonPressed = false;
  /// When true, release sends audio to ASR and updates [_talkScorePercent].
  /// Default OFF: user must explicitly opt in.
  bool _talkAccuracyEnabled = false;
  String? _talkRecordPath;
  int? _talkScorePercent;
  /// Whisper/API diagnosis (shown when accuracy is on or in challenge mode).
  String? _talkAsrHint;
  int _talkRecordSeconds = 0;
  int _talkRecordGeneration = 0;
  Stopwatch? _talkHoldWatch;
  /// True while the user is physically holding the talk surface (pointer down).
  bool _talkPointerDown = false;
  /// Ignores extra fingers while one talk press is active.
  int? _talkActivePointer;
  /// Completer completed when reference / talk-back playback ends or is interrupted.
  Completer<void>? _talkPlaybackDone;

  /// OpenAI rejects very short clips; quick tap also races the recorder.
  static const int _kMinTalkHoldMs = 900;

  final Random _rng = Random();

  @override
  void initState() {
    super.initState();
    _loadPrefsAndData();
  }

  Future<void> _loadPrefsAndData() async {
    // 先读取持久化设置
    final prefs = await SharedPreferences.getInstance();
    final modeIndex = prefs.getInt(_PracticePrefs.modeKey) ?? 0;
    final savedHideRoman = prefs.getBool(_PracticePrefs.hideRomanKey) ?? false;
    final catId = await SharedCategoryPrefs.load();
    if (mounted) setState(() {
      _hideRomanization = savedHideRoman;
    });

    final list = await DatabaseHelper.getAll();
    final cats = await DatabaseHelper.getAllCategories();

      if (mounted) {
      setState(() {
        _allEntries = list;
        _categories = cats;
        _mode = modeIndex == 1
            ? _PracticeMode.chineseToThai
            : _PracticeMode.thaiToChinese;
        // 验证保存的 catId 是否仍有效（类别可能已被删除；-999 等无效 id 会回落）
        if (catId != null && cats.any((c) => c.id == catId)) {
          _selectedCategoryId = catId;
        } else {
          _selectedCategoryId = cats.isNotEmpty ? cats.first.id : null;
        }
        _practiceType = _categoryPracticeType(_selectedCategoryId, cats);
        _loading = false;
        _updatePool();
      });
      _notifyCategoryName();
      if (_poolEntries.isNotEmpty) {
        await _restoreSequentialFromPrefs(autoPlay: false);
      } else {
        setState(() { _definitionNative = null; _loadingDefinition = false; _actionContent = null; _sample1Translate = null; _sample1Native = null; _loadingSample = false; _playingSample = false; });
      }
    }
  }

  void _updatePool() {
    List<DictionaryEntry> raw;
    if (_selectedCategoryId == null) {
      raw = List.of(_allEntries);
    } else {
      raw = _allEntries
          .where((e) => e.categoryId == _selectedCategoryId)
          .toList();
    }
    raw.sort((a, b) {
      final ia = a.id ?? 0;
      final ib = b.id ?? 0;
      if (ia != ib) return ia.compareTo(ib);
      return a.nameTranslate.compareTo(b.nameTranslate);
    });
    _poolEntries = raw;
  }

  String get _seqIndexPrefsKey => _PracticePrefs.seqIndexKey(_selectedCategoryId);

  int _poolIndexInPool(DictionaryEntry entry) {
    if (entry.id != null) {
      final i = _poolEntries.indexWhere((e) => e.id == entry.id);
      if (i >= 0) return i;
    }
    return _poolEntries.indexWhere((e) => identical(e, entry));
  }

  int _poolIndexOfCurrent() {
    final c = _current;
    if (c == null) return -1;
    return _poolIndexInPool(c);
  }

  Future<void> _persistPracticeSeqIndex(int index) async {
    if (index < 0 || index >= _poolEntries.length) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_seqIndexPrefsKey, index);
  }

  Future<void> _persistPracticeSeqIndexForEntry(DictionaryEntry entry) async {
    final idx = _poolIndexInPool(entry);
    if (idx >= 0) await _persistPracticeSeqIndex(idx);
  }

  /// Next word in [id] order after [startAfterIdx] (-1 = before first) that is not in [_quizAnsweredIds].
  DictionaryEntry? _nextUnansweredInPoolOrder(int startAfterIdx) {
    final full = _poolEntries;
    if (full.isEmpty) return null;
    for (var step = 1; step <= full.length; step++) {
      final i = (startAfterIdx + step) % full.length;
      final e = full[i];
      if (e.id == null || !_quizAnsweredIds.contains(e.id)) return e;
    }
    return null;
  }

  DictionaryEntry _pickSequentialNextWord() {
    final full = _poolEntries;
    if (full.isEmpty) {
      throw StateError('practice pool empty');
    }
    final curIdx = _poolIndexOfCurrent();

    if (_quizMode && _quizAnsweredIds.isNotEmpty) {
      final next = _nextUnansweredInPoolOrder(curIdx);
      if (next != null) return next;
      for (final e in full) {
        if (e.id == null || !_quizAnsweredIds.contains(e.id)) return e;
      }
      return full[0];
    }

    if (full.length == 1) return full[0];
    if (curIdx < 0) return full[0];
    return full[(curIdx + 1) % full.length];
  }

  Future<void> _restoreSequentialFromPrefs({required bool autoPlay}) async {
    if (_poolEntries.isEmpty || !mounted) return;
    final prefs = await SharedPreferences.getInstance();
    var idx = prefs.getInt(_seqIndexPrefsKey) ?? 0;
    idx = idx.clamp(0, _poolEntries.length - 1);
    final entry = _poolEntries[idx];
    setState(() {
      _history
        ..clear()
        ..add(entry);
      _historyIndex = 0;
    });
    _buildOptions(entry);
    _startWordAndTimer(autoPlay: autoPlay);
    if (_mode == _PracticeMode.thaiToChinese &&
        _practiceType == 0 &&
        entry.id != null) {
      _fetchRomanization(entry.id);
    }
    _loadWordExtras(entry.id);
  }

  DictionaryEntry? get _current =>
      (_history.isEmpty || _historyIndex < 0) ? null : _history[_historyIndex];

  // ── 罗马拼音（仅 `word.roman_translate`，不调用网络）──────────────
  Future<void> _fetchRomanization(int? wordId) async {
    if (wordId == null) {
      setState(() {
        _romanization = '';
        _loadingRoman = false;
      });
      UserFeedback.showSnack(UserFeedback.missingRomanizationMessage);
      return;
    }
    final fromEntry = _current?.id == wordId
        ? _current?.romanTranslate?.trim()
        : null;
    if (fromEntry != null && fromEntry.isNotEmpty) {
      setState(() {
        _romanization = fromEntry;
        _loadingRoman = false;
      });
      return;
    }
    setState(() {
      _romanization = null;
      _loadingRoman = true;
    });
    final roman = await DatabaseHelper.getWordRomanTranslate(wordId);
    if (!mounted) return;
    if (roman != null && roman.isNotEmpty) {
      setState(() {
        _romanization = roman;
        _loadingRoman = false;
      });
    } else {
      UserFeedback.showSnack(UserFeedback.missingRomanizationMessage);
      setState(() {
        _romanization = '';
        _loadingRoman = false;
      });
    }
  }

  // ── 词条扩展字段加载（释义 / 例句 / 动作）──────────────────────
  /// Called when a new word is shown. Loads definition, sample1, and action from DB.
  Future<void> _loadWordExtras(int? wordId) async {
    if (!mounted) return;
    setState(() {
      _definitionNative = null;
      _loadingDefinition = false;
      _actionContent = null;
      _sample1Translate = null;
      _sample1Native = null;
      _loadingSample = false;
      _playingSample = false;
    });
    if (wordId == null) return;
    // Parallel: definition + sample1 + action
    final results = await Future.wait([
      DatabaseHelper.getWordDefinition(wordId),
      DatabaseHelper.getWordSample1(wordId),
      DatabaseHelper.getWordAction(wordId),
    ]);
    if (mounted) {
      final defMap = results[0] as Map<String, String?>;
      final s1 = results[1] as Map<String, String?>;
      final actionVal = results[2] as String?;
      setState(() {
        _definitionNative = defMap['native'];
        _actionContent = actionVal;
        _sample1Translate = s1['translate'];
        _sample1Native = s1['native'];
      });
      final t = _sample1Translate;
      final n = _sample1Native;
      if (t?.isNotEmpty == true && (n == null || n.isEmpty)) {
        _translateNativeSamples(wordId);
      }
    }
  }

  /// Lazily fetch & persist word definition via Gemini, then translate to native.
  Future<void> _fetchAndSaveDefinition(int wordId, String learnWord) async {
    if (_loadingDefinition) return;
    setState(() => _loadingDefinition = true);
    try {
      final targetLang = AppLangNotifier().targetLang;
      final nativeLang = AppLangNotifier().nativeLang;

      // 1. Get definition in learn language via Gemini
      final learnDef = await GeminiService.getDefinition(learnWord, targetLang);

      if (learnDef == null || learnDef.isEmpty) {
        if (mounted) setState(() { _definitionNative = ''; _loadingDefinition = false; });
        return;
      }

      // 2. Translate definition to native language
      final nativeDef = await TranslateService.translate(
          learnDef, targetLang: nativeLang, sourceLang: targetLang);

      // 3. Persist to both DBs
      await DatabaseHelper.updateDefinition(wordId,
          learnDefinition: learnDef, nativeDefinition: nativeDef ?? '');

      if (mounted) {
        setState(() {
          _definitionNative = nativeDef ?? '';
          _loadingDefinition = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() { _definitionNative = ''; _loadingDefinition = false; });
    }
  }

  /// Fills sample1_native when translate exists but native is empty.
  Future<void> _translateNativeSamples(int wordId) async {
    final nativeLang = AppLangNotifier().nativeLang;
    final targetLang = AppLangNotifier().targetLang;
    final translateSample = _sample1Translate;
    final native = _sample1Native;
    if (translateSample == null || translateSample.isEmpty) return;
    if (native != null && native.isNotEmpty) return;
    final translated = await TranslateService.translate(
        translateSample, targetLang: nativeLang, sourceLang: targetLang);
    if (translated == null || translated.isEmpty) return;
    await DatabaseHelper.updateNativeSampleSlot(wordId, 1, translated);
    if (mounted) setState(() => _sample1Native = translated);
  }

  /// Lazily fetch & persist sample1 via Gemini when missing.
  Future<void> _fetchAndSaveSample(int wordId, String learnWord) async {
    if (_loadingSample) return;
    setState(() => _loadingSample = true);
    try {
      final targetLang = AppLangNotifier().targetLang;
      final nativeLang = AppLangNotifier().nativeLang;

      // 1. DB is pre-populated for known words; call Gemini only when sample is missing
      final learnSample = await GeminiService.getSampleSentence(learnWord, targetLang);

      if (learnSample == null || learnSample.isEmpty) {
        if (mounted) setState(() { _sample1Translate = ''; _sample1Native = ''; _loadingSample = false; });
        return;
      }

      // 2. Translate to native language
      final nativeSample = await TranslateService.translate(
          learnSample, targetLang: nativeLang, sourceLang: targetLang);

      // 3. Persist to sample1 slot in single DB
      await DatabaseHelper.updateSample1(wordId,
          translateSample: learnSample, nativeSample: nativeSample ?? '');

      if (mounted) {
        setState(() {
          _sample1Translate = learnSample;
          _sample1Native = nativeSample ?? '';
          _loadingSample = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() { _sample1Translate = ''; _loadingSample = false; });
    }
  }

  // ── 生成选项 ───────────────────────────────────────────────────
  void _buildOptions(DictionaryEntry correct) {
    if (_practiceType == 1) {
      _buildPhraseOptions(correct);
    } else {
      _buildWordOptions(correct);
    }
  }

  void _buildWordOptions(DictionaryEntry correct) {
    final correctSrc = correct.nameTranslate;
    final correctDst = correct.nameNative;

    final wrongEntries = <DictionaryEntry>[];

    if (_poolEntries.length >= 3) {
      final pool = _poolEntries.where((e) => e.id != correct.id).toList()
        ..shuffle(_rng);
      for (final e in pool) {
        if (!wrongEntries.any((w) => w.nameNative == e.nameNative) &&
            e.nameNative != correctDst) {
          wrongEntries.add(e);
          if (wrongEntries.length == 2) break;
        }
      }
    }

    if (wrongEntries.length < 2) {
      final pool = _allEntries.where((e) => e.id != correct.id).toList()
        ..shuffle(_rng);
      for (final e in pool) {
        if (!wrongEntries.any((w) => w.nameNative == e.nameNative) &&
            e.nameNative != correctDst) {
          wrongEntries.add(e);
          if (wrongEntries.length == 2) break;
        }
      }
    }

    while (wrongEntries.length < 2) {
      wrongEntries.add(DictionaryEntry(nameTranslate: '', nameNative: '—'));
    }

    final correctOpt = _QuizOption(
      srcText: correctSrc,
      dstText: correctDst,
      isCorrect: true,
      audioWordId: correct.id,
      audioPhraseSlot: null,
    );
    correctOpt.romanTranslate = correct.romanTranslate;

    final wrongOpt0 = _QuizOption(
      srcText: wrongEntries[0].nameTranslate,
      dstText: wrongEntries[0].nameNative,
      isCorrect: false,
      audioWordId: wrongEntries[0].id,
      audioPhraseSlot: null,
    );
    wrongOpt0.romanTranslate = wrongEntries[0].romanTranslate;

    final wrongOpt1 = _QuizOption(
      srcText: wrongEntries[1].nameTranslate,
      dstText: wrongEntries[1].nameNative,
      isCorrect: false,
      audioWordId: wrongEntries[1].id,
      audioPhraseSlot: null,
    );
    wrongOpt1.romanTranslate = wrongEntries[1].romanTranslate;

    final options = [
      correctOpt,
      wrongOpt0,
      wrongOpt1,
    ]..shuffle(_rng);

    setState(() {
      _options = options;
      _answered = false;
      _firstAttempt = true;
      _playingOptionIndex = null;
      _phraseQuestionText = null;
      _phraseQuestionRoman = null;
      if (_talkMode) _talkScorePercent = null;
    });

    // 模式 B：异步获取每个选项的罗马拼音（仅当源语言是泰语时→'
    if (_mode == _PracticeMode.chineseToThai) {
      _fetchOptionRomanizations(options);
    }
  }

  void _buildPhraseOptions(DictionaryEntry correct) {
    final isModeA = _mode == _PracticeMode.thaiToChinese;

    // Phrase MCQ: sample1_translate / sample1_native only
    final phraseT = correct.samplesTranslate[0];
    final phraseN = correct.samplesNative[0];
    if (phraseT?.isNotEmpty != true || phraseN?.isNotEmpty != true) {
      _buildWordOptions(correct);
      return;
    }

    final phraseTRoman = correct.samplesTranslateRoman[0];
    final String phraseT0 = phraseT!;
    final String phraseN0 = phraseN!;

    // A: translate→native — question = sample1_translate, answers = sample1_native.
    // B: native→translate — question = sample1_native, answers = sample1_translate.
    final questionText = isModeA ? phraseT0 : phraseN0;

    const phraseSlot = 0;

    final seen = <String>{isModeA ? phraseN0 : phraseT0};
    final wrongDisplay = <String>[];
    final wrongRomans = <String?>[];
    final wrongNativeTexts = <String>[];
    final wrongTranslateTts = <String>[];
    final wrongWordIds = <int?>[];

    void tryEntry(DictionaryEntry e) {
      if (wrongDisplay.length >= 2) return;
      final tNative = e.samplesNative[0];
      final tTrans = e.samplesTranslate[0];
      if (isModeA) {
        if (tNative?.isNotEmpty == true &&
            tTrans?.isNotEmpty == true &&
            !seen.contains(tNative)) {
          wrongDisplay.add(tNative!);
          wrongRomans.add(e.samplesTranslateRoman[0]);
          wrongNativeTexts.add('');
          wrongTranslateTts.add(tTrans!);
          wrongWordIds.add(e.id);
          seen.add(tNative);
        }
      } else {
        if (tTrans?.isNotEmpty == true &&
            tNative?.isNotEmpty == true &&
            !seen.contains(tTrans)) {
          wrongDisplay.add(tTrans!);
          wrongRomans.add(e.samplesTranslateRoman[0]);
          wrongNativeTexts.add(tNative!);
          wrongTranslateTts.add(tTrans);
          wrongWordIds.add(e.id);
          seen.add(tTrans);
        }
      }
    }

    final shuffledPool = _poolEntries.where((e) => e.id != correct.id).toList()
      ..shuffle(_rng);
    for (final e in shuffledPool) {
      tryEntry(e);
    }

    if (wrongDisplay.length < 2) {
      final shuffledAll = _allEntries.where((e) => e.id != correct.id).toList()
        ..shuffle(_rng);
      for (final e in shuffledAll) {
        tryEntry(e);
      }
    }

    if (wrongDisplay.length < 2) {
      _buildWordOptions(correct);
      return;
    }

    _QuizOption makeOpt(
      String primaryText,
      String? romanTranslateLine,
      String secondaryText,
      bool isCorrect, {
      required String translateTtsLine,
      required int? wordId,
      required int phraseSlot,
      String? modeBRomanization,
    }) {
      if (isModeA) {
        final o = _QuizOption(
          srcText: '',
          dstText: primaryText,
          isCorrect: isCorrect,
          translateTtsText: translateTtsLine,
          audioWordId: wordId,
          audioPhraseSlot: phraseSlot,
        );
        o.romanTranslate = romanTranslateLine;
        return o;
      }
      final o = _QuizOption(
        srcText: primaryText,
        dstText: secondaryText,
        isCorrect: isCorrect,
        translateTtsText: translateTtsLine,
        audioWordId: wordId,
        audioPhraseSlot: phraseSlot,
      );
      o.romanization = modeBRomanization;
      return o;
    }

    late final _QuizOption correctOpt;
    if (isModeA) {
      correctOpt = makeOpt(
        phraseN0,
        null,
        '',
        true,
        translateTtsLine: phraseT0,
        wordId: correct.id,
        phraseSlot: phraseSlot,
      );
    } else {
      correctOpt = makeOpt(
        phraseT0,
        null,
        phraseN0,
        true,
        translateTtsLine: phraseT0,
        wordId: correct.id,
        phraseSlot: phraseSlot,
        modeBRomanization: phraseTRoman,
      );
    }

    final wrong0 = isModeA
        ? makeOpt(
            wrongDisplay[0],
            wrongRomans[0],
            '',
            false,
            translateTtsLine: wrongTranslateTts[0],
            wordId: wrongWordIds[0],
            phraseSlot: phraseSlot,
          )
        : makeOpt(
            wrongDisplay[0],
            null,
            wrongNativeTexts[0],
            false,
            translateTtsLine: wrongTranslateTts[0],
            wordId: wrongWordIds[0],
            phraseSlot: phraseSlot,
            modeBRomanization: wrongRomans[0],
          );
    final wrong1 = isModeA
        ? makeOpt(
            wrongDisplay[1],
            wrongRomans[1],
            '',
            false,
            translateTtsLine: wrongTranslateTts[1],
            wordId: wrongWordIds[1],
            phraseSlot: phraseSlot,
          )
        : makeOpt(
            wrongDisplay[1],
            null,
            wrongNativeTexts[1],
            false,
            translateTtsLine: wrongTranslateTts[1],
            wordId: wrongWordIds[1],
            phraseSlot: phraseSlot,
            modeBRomanization: wrongRomans[1],
          );

    final options = [correctOpt, wrong0, wrong1]..shuffle(_rng);

    setState(() {
      _options = options;
      _answered = false;
      _firstAttempt = true;
      _playingOptionIndex = null;
      _phraseQuestionText = questionText;
      _phraseQuestionRoman = isModeA ? phraseTRoman : null;
      if (_talkMode) _talkScorePercent = null;
    });

    if (isModeA && AppLangNotifier().targetLang == 'th' && correct.id != null) {
      final hasRoman = (_phraseQuestionRoman?.trim().isNotEmpty ?? false);
      if (!hasRoman) {
        unawaited(_loadPhraseQuestionRomanFromDb(
            correct.id!, phraseT0, phraseTRoman));
      }
    }

    if (!isModeA && AppLangNotifier().targetLang == 'th') {
      _fetchOptionRomanizations(options);
    }
  }

  /// Phrase prompt Thai line: `sample1_translate_roman` only.
  Future<void> _loadPhraseQuestionRomanFromDb(
    int wordId,
    String phraseT0,
    String? phraseTRomanFromEntry,
  ) async {
    if (AppLangNotifier().targetLang != 'th') return;
    if (phraseTRomanFromEntry != null &&
        phraseTRomanFromEntry.trim().isNotEmpty) {
      return;
    }
    if (_loadingRoman) return;
    setState(() => _loadingRoman = true);
    final s1 = await DatabaseHelper.getWordSample1(wordId);
    if (!mounted) return;
    final raw = s1['roman']?.trim();
    if (raw != null && raw.isNotEmpty) {
      setState(() {
        _phraseQuestionRoman = raw;
        _loadingRoman = false;
      });
    } else {
      UserFeedback.showSnack(UserFeedback.missingRomanizationMessage);
      setState(() {
        _phraseQuestionRoman = '';
        _loadingRoman = false;
      });
    }
  }

  /// Mode B tiles: headword `roman_translate` or phrase `sample1_translate_roman`.
  Future<void> _fetchOptionRomanizations(List<_QuizOption> opts) async {
    if (AppLangNotifier().targetLang != 'th') return;
    var reportedMissing = false;
    for (int i = 0; i < opts.length; i++) {
      final opt = opts[i];
      if (opt.srcText.isEmpty) continue;
      final wid = opt.audioWordId;
      if (wid == null) continue;

      String? raw;
      if (opt.audioPhraseSlot != null) {
        final s1 = await DatabaseHelper.getWordSample1(wid);
        final r = s1['roman']?.trim();
        raw = (r != null && r.isNotEmpty) ? r : null;
      } else {
        raw = await DatabaseHelper.getWordRomanTranslate(wid);
      }

      if (!mounted) return;
      if (_options.length > i && _options[i] == opt) {
        if (raw != null && raw.isNotEmpty) {
          setState(() => _options[i].romanization = raw);
        } else {
          if (!reportedMissing) {
            UserFeedback.showSnack(UserFeedback.missingRomanizationMessage);
            reportedMissing = true;
          }
          setState(() => _options[i].romanization = '');
        }
      }
    }
  }

  /// Uses DB BLOBs (`audio_translate`, `sample1_translate_audio`, `audio_native`) when present.
  Future<void> _speakPracticeText(String text, {void Function()? onDone}) async {
    final id = _current?.id;
    if (id == null || text.isEmpty) {
      onDone?.call();
      return;
    }
    final t0 = _current!.samplesTranslate[0];
    final n0 = _current!.samplesNative[0];
    if (_practiceType == 1 &&
        t0 != null &&
        n0 != null &&
        t0.isNotEmpty &&
        n0.isNotEmpty) {
      if (text == t0) {
        await _tts.speakTranslateFromDbOrFetch(
          text,
          appTargetLangCode: AppLangNotifier().targetLang,
          wordId: id,
          phraseSlot: 0,
          onDone: onDone,
        );
        return;
      }
      if (text == n0) {
        await _tts.speakNativeLang(
          text,
          AppLangNotifier().nativeLang,
          wordId: id,
          phraseSlot: 0,
          onDone: onDone,
        );
        return;
      }
    }
    await _tts.speak(text, wordId: id, onDone: onDone);
  }

  // ── 自动播放当前源语言（仅模式 A）─────────────────────────────
  Future<void> _autoPlay() async {
    if (_mode == _PracticeMode.chineseToThai) return; // 模式 B 不自动播
    if (_current == null) return;
    // In phrase mode, play the phrase question text; in word mode play the word
    final text = _phraseQuestionText ?? _current!.nameTranslate;
    if (text.isEmpty) return;
    await _tts.stop();
    setState(() => _playing = true);
    await _speakPracticeText(text, onDone: () {
      if (mounted) setState(() => _playing = false);
    });
  }

  /// In challenge mode B (native→translate): speak all 3 option texts sequentially.
  /// Calls [onFinished] after TTS ends (or immediately when no playable text).
  Future<void> _playChallengeTTS({void Function()? onFinished}) async {
    if (_current == null || !mounted) return;
    final toPlay = <({int idx, String text})>[];
    for (int i = 0; i < _options.length; i++) {
      if (_options[i].srcText.isNotEmpty) {
        toPlay.add((idx: i, text: _options[i].srcText));
      }
    }
    if (toPlay.isEmpty) {
      onFinished?.call();
      return;
    }

    await _tts.stop();
    if (!mounted) return;
    setState(() => _playing = true);

    void finishPlaying() {
      if (mounted) {
        setState(() {
          _playing = false;
          _playingOptionIndex = null;
        });
      }
      onFinished?.call();
    }

    void playAt(int k) {
      if (!mounted || _answered) {
        finishPlaying();
        return;
      }
      if (k >= toPlay.length) {
        finishPlaying();
        return;
      }
      final item = toPlay[k];
      setState(() => _playingOptionIndex = item.idx);
      final opt = _options[item.idx];
      void afterOption() {
        if (!mounted) return;
        setState(() => _playingOptionIndex = null);
        if (_answered) {
          finishPlaying();
          return;
        }
        if (k < toPlay.length - 1) {
          Future.delayed(const Duration(milliseconds: 300), () => playAt(k + 1));
        } else {
          finishPlaying();
        }
      }

      if (_practiceType == 1 &&
          opt.audioPhraseSlot != null &&
          opt.audioWordId != null) {
        _tts.speakTranslateFromDbOrFetch(
          item.text,
          appTargetLangCode: AppLangNotifier().targetLang,
          wordId: opt.audioWordId,
          phraseSlot: opt.audioPhraseSlot,
          onDone: afterOption,
        );
      } else {
        _tts.speak(item.text, wordId: opt.audioWordId, onDone: afterOption);
      }
    }

    playAt(0);
  }

  /// In challenge mode A (translate→native): auto-play the question word/phrase.
  /// Calls [onFinished] after TTS ends (or immediately if no playable text).
  Future<void> _autoPlayThenTimer({void Function()? onFinished}) async {
    if (_current == null) {
      onFinished?.call();
      return;
    }
    final text = _phraseQuestionText ?? _current!.nameTranslate;
    if (text.isEmpty) {
      onFinished?.call();
      return;
    }
    await _tts.stop();
    if (!mounted) {
      onFinished?.call();
      return;
    }
    setState(() => _playing = true);
    unawaited(_speakPracticeText(text, onDone: () {
      if (mounted) setState(() => _playing = false);
      onFinished?.call();
    }));
  }

  /// Challenge: pause elapsed stopwatch during TTS; resume after TTS finishes
  /// (or immediately in Talk + native→translate, where options TTS is skipped).
  void _startWordAndTimer({bool autoPlay = true}) {
    if (_quizMode) {
      _cancelQuizTimer(); // pause stopwatch while TTS plays
      if (!autoPlay) {
        _startQuizTimer();
      } else if (_talkMode && _mode == _PracticeMode.chineseToThai) {
        if (mounted && _quizMode && !_answered) _startQuizTimer();
      } else if (_mode == _PracticeMode.chineseToThai) {
        _playChallengeTTS(onFinished: () {
          if (mounted && _quizMode && !_answered) _startQuizTimer();
        });
      } else {
        _autoPlayThenTimer(onFinished: () {
          if (mounted && _quizMode && !_answered) _startQuizTimer();
        });
      }
      return;
    }
    if (autoPlay) {
      _autoPlay();
    }
  }

  // ── 下一→─────────────────────────────────────────────────────
  void _pickNext({bool autoPlay = true}) {
    if (_poolEntries.isEmpty) return;

    if (_historyIndex < _history.length - 1) {
      setState(() => _historyIndex++);
      final entry = _history[_historyIndex];
      _buildOptions(entry);
      _startWordAndTimer(autoPlay: autoPlay);
      if (_mode == _PracticeMode.thaiToChinese &&
          _practiceType == 0 &&
          entry.id != null) {
        _fetchRomanization(entry.id);
      }
      _loadWordExtras(entry.id);
      unawaited(_persistPracticeSeqIndexForEntry(entry));
      return;
    }

    final next = _pickSequentialNextWord();

    setState(() {
      _history.add(next);
      _historyIndex = _history.length - 1;
    });
    _buildOptions(next);
    _startWordAndTimer(autoPlay: autoPlay);
    if (_mode == _PracticeMode.thaiToChinese &&
        _practiceType == 0 &&
        next.id != null) {
      _fetchRomanization(next.id);
    }
    _loadWordExtras(next.id);
    unawaited(_persistPracticeSeqIndexForEntry(next));
  }

  // ── 上一─────────────────────────────────────────────────────
  void _pickPrev() {
    if (_historyIndex <= 0) return;
    setState(() => _historyIndex--);
    final entry = _history[_historyIndex];
    _buildOptions(entry);
    _startWordAndTimer(autoPlay: true);
    if (_mode == _PracticeMode.thaiToChinese &&
        _practiceType == 0 &&
        entry.id != null) {
      _fetchRomanization(entry.id);
    }
    _loadWordExtras(entry.id);
    unawaited(_persistPracticeSeqIndexForEntry(entry));
  }

  bool get _canGoPrev => _historyIndex > 0;
  bool get _canGoNext => _poolEntries.isNotEmpty;

  int get _challengeRemainingCount =>
      _quizMode
          ? (_poolEntries.length - _quizAnsweredIds.length).clamp(0, _poolEntries.length)
          : _poolEntries.length;

  // ── 播放/停止（模式 A 主显示区按钮）─────────────────────────
  Future<void> _togglePlay() async {
    if (_current == null) return;
    if (_playing) {
      await _tts.stop();
      setState(() => _playing = false);
    } else {
      final text = _phraseQuestionText ?? _current!.nameTranslate;
      if (text.isEmpty) return;
      setState(() => _playing = true);
      await _speakPracticeText(text, onDone: () {
        if (mounted) setState(() => _playing = false);
      });
    }
  }

  // ── 选项旁播放：模式 A = 翻译语 BLOB/API；模式 B = 原逻辑（学习语 TTS）──
  Future<void> _playOption(int index) async {
    final opt = _options[index];
    final line = opt.lineForTranslateTts;
    if (line.isEmpty) return;

    await _tts.stop();

    if (_playingOptionIndex == index) {
      setState(() => _playingOptionIndex = null);
      return;
    }

    setState(() => _playingOptionIndex = index);
    if (_mode == _PracticeMode.thaiToChinese) {
      await _tts.speakTranslateFromDbOrFetch(
        line,
        appTargetLangCode: AppLangNotifier().targetLang,
        wordId: opt.audioWordId,
        phraseSlot: opt.audioPhraseSlot,
        onDone: () {
          if (mounted) setState(() => _playingOptionIndex = null);
        },
      );
    } else {
      if (opt.audioPhraseSlot != null && opt.audioWordId != null) {
        await _tts.speakTranslateFromDbOrFetch(
          line,
          appTargetLangCode: AppLangNotifier().targetLang,
          wordId: opt.audioWordId,
          phraseSlot: opt.audioPhraseSlot,
          onDone: () {
            if (mounted) setState(() => _playingOptionIndex = null);
          },
        );
      } else {
        await _tts.speak(line, wordId: opt.audioWordId, onDone: () {
          if (mounted) setState(() => _playingOptionIndex = null);
        });
      }
    }
  }

  // ── 选择答案 ───────────────────────────────────────────────────
  void _selectOption(int index) async {
    if (_answered) return;

    final chosen = _options[index];
    if (chosen.isCorrect) {
      await _tts.stop();
      _cancelQuizTimer();
      setState(() {
        _answered = true;
        chosen.state = AnswerState.correct;
        _playingOptionIndex = null;
        _playing = false;
      });

      // Translate→native (practice):
      // When Talk is OFF, we do NOT replay the translate word/phrase after a correct tap.
      // The Talk flow (when enabled) handles playback after recording.

      // Play cheerful ding (both normal and quiz mode)
      SoundFeedbackService.playCorrect();

      if (_firstAttempt && _current != null && _current!.id != null) {
        await DatabaseHelper.incrementCorrectCount(_current!.id!);
        if (_quizMode) {
          _quizAnsweredIds.add(_current!.id!);
          final poolIds = _poolEntries.where((e) => e.id != null).map((e) => e.id!).toSet();
          if (poolIds.isNotEmpty && _quizAnsweredIds.containsAll(poolIds)) {
            // Show red check for 1 second, then congratulations
            await Future.delayed(const Duration(seconds: 1));
            if (mounted) _showQuizCongrats();
            return;
          }
        }
      }
      // Show red check for 1 second, then advance
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) _pickNext();
    } else {
      // Cancel timer before any await to prevent race with _pickNext().
      _cancelQuizTimer();
      if (_tts.isPlaying) await _tts.stop();

      HapticFeedback.heavyImpact();
      setState(() {
        _firstAttempt = false;
        chosen.state = AnswerState.wrong;
        _answered = true;
        _quizAnsweredIds.clear();
        _playingOptionIndex = null;
        _playing = false;
      });
      if (_quizMode) {
        // Challenge: translate→native → wrong translate audio; native→translate → wrong native phrase audio.
        if (_mode == _PracticeMode.thaiToChinese) {
          final line = chosen.lineForTranslateTts;
          if (line.isNotEmpty) {
            setState(() => _playing = true);
            final done = Completer<void>();
            _tts.speakTranslateFromDbOrFetch(
              line,
              appTargetLangCode: AppLangNotifier().targetLang,
              wordId: chosen.audioWordId,
              phraseSlot: chosen.audioPhraseSlot,
              onDone: () {
                if (mounted) setState(() => _playing = false);
                if (!done.isCompleted) done.complete();
              },
            );
            await done.future;
          }
        } else if (_mode == _PracticeMode.chineseToThai) {
          final nativeLine = chosen.dstText;
          if (nativeLine.isNotEmpty && chosen.audioWordId != null) {
            setState(() => _playing = true);
            final done = Completer<void>();
            _tts.speakNativeLang(
              nativeLine,
              AppLangNotifier().nativeLang,
              wordId: chosen.audioWordId,
              phraseSlot: chosen.audioPhraseSlot,
              onDone: () {
                if (mounted) setState(() => _playing = false);
                if (!done.isCompleted) done.complete();
              },
            );
            await done.future;
          }
        }
        SoundFeedbackService.playWrong();
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) _pickNext();
      } else {
        // Practice: translate→native → translate lang (always synth for correct language);
        // native→translate → native line TTS.
        setState(() => _playing = true);
        if (_mode == _PracticeMode.thaiToChinese) {
          final line = chosen.lineForTranslateTts;
          if (line.isNotEmpty) {
            final done = Completer<void>();
            _tts.speakTranslateFromDbOrFetch(
              line,
              appTargetLangCode: AppLangNotifier().targetLang,
              wordId: chosen.audioWordId,
              phraseSlot: chosen.audioPhraseSlot,
              onDone: () {
                if (mounted) setState(() => _playing = false);
                if (!done.isCompleted) done.complete();
              },
            );
            await done.future;
          } else {
            setState(() => _playing = false);
          }
        } else {
          final nativeLine = chosen.dstText;
          if (nativeLine.isNotEmpty) {
            final done = Completer<void>();
            _tts.speakNativeLang(
              nativeLine,
              AppLangNotifier().nativeLang,
              wordId: chosen.audioWordId,
              phraseSlot: chosen.audioPhraseSlot,
              onDone: () {
                if (mounted) setState(() => _playing = false);
                if (!done.isCompleted) done.complete();
              },
            );
            await done.future;
          } else {
            setState(() => _playing = false);
          }
        }
        if (mounted) setState(() => _answered = false);
      }
    }
  }

  String _categoryLabel(int? catId, L10n l) {
    if (catId == null) {
      return '${l.practiceAll} (${_poolCountForCat(null)})';
    }
    final cat = _categories.firstWhere(
      (c) => c.id == catId,
      orElse: () => CategoryEntry(nameNative: ''),
    );
    if (cat.nameNative.isEmpty) return '${l.practiceAll} (${_poolCountForCat(null)})';
    final count = _allEntries.where((e) => e.categoryId == catId).length;
    return '${l.translateCategory(cat.nameNative)} ($count)';
  }

  int _poolCountForCat(int? catId) {
    if (catId == null) return _allEntries.length;
    return _allEntries.where((e) => e.categoryId == catId).length;
  }


  void _toggleHideRomanization() async {
    final next = !_hideRomanization;
    setState(() => _hideRomanization = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_PracticePrefs.hideRomanKey, next);
  }

  void _toggleMode() async {
    stopQuizMode();

    final newMode = _mode == _PracticeMode.thaiToChinese
        ? _PracticeMode.chineseToThai
        : _PracticeMode.thaiToChinese;

    // 持久化保存模→'
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_PracticePrefs.modeKey,
        newMode == _PracticeMode.chineseToThai ? 1 : 0);

    setState(() {
      _mode = newMode;
      // 切换模式时重置当前题（重新生成选项，不清空历史→'
      _romanization = null;
      _playing = false;
      _playingOptionIndex = null;
      _phraseQuestionText = null;
      _phraseQuestionRoman = null;
    });
    _scrollContentToTop();
    _tts.stop();
    _cancelQuizTimer();
    if (_current != null) {
      _buildOptions(_current!);
      if (_mode == _PracticeMode.thaiToChinese &&
          _practiceType == 0 &&
          _current!.id != null) {
        _fetchRomanization(_current!.id);
      }
    }
    await _forceScrollTopAfterStateSettles();
  }

  // ── Challenge stopwatch (thinking time only, paused during TTS) ──
  void _startQuizTimer() {
    // Resume elapsed-time stopwatch after TTS finishes.
    if (_quizMode) _challengeStopwatch.start();
  }

  void _cancelQuizTimer() {
    // Pause elapsed-time stopwatch (called before each TTS play and on stop).
    _challengeStopwatch.stop();
  }

  Future<void> _toggleQuizMode() async {
    if (_quizMode) {
      setState(() {
        _quizMode = false;
        _quizAnsweredIds.clear();
      });
      _cancelQuizTimer();
      _challengeStopwatch.reset();
    } else {
      setState(() {
        _quizMode = true;
        _quizAnsweredIds.clear();
      });
      _challengeStopwatch.reset();
      _pickNext();
    }
  }

  void stopQuizMode() {
    if (!_quizMode) return;
    setState(() {
      _quizMode = false;
      _quizAnsweredIds.clear();
    });
    _cancelQuizTimer();
    _challengeStopwatch.reset();
  }

  /// Maps current practice mode → segment index 0–7 in [category.challenge].
  int _currentSegmentIndex() {
    final isTranslate = _mode == _PracticeMode.thaiToChinese;
    final isWord = _practiceType != 1; // 1=phrase; 0=word, 2=photo treated as word
    final base     = isTranslate ? 0 : 4;
    final unitOff  = isWord ? 0 : 2;
    final modeOff  = _talkMode ? 0 : 1;
    return base + unitOff + modeOff;
  }

  /// Uploads the current lesson score + user profile to Supabase (fire-and-forget).
  void _syncToSupabase(List<CategoryEntry> updatedCats,
      {int? segmentIndex, int? elapsedSeconds}) {
    final client = SupabaseBootstrap.clientOrNull;
    final uid = client?.auth.currentUser?.id;
    if (uid == null || _selectedCategoryId == null) return;

    final cat = updatedCats.firstWhere(
      (c) => c.id == _selectedCategoryId,
      orElse: () => CategoryEntry(nameNative: ''),
    );
    if (cat.id == null) return;

    final langs = AppLangNotifier();
    final meta  = client!.auth.currentUser?.userMetadata ?? {};

    // Build sparse score list — only the completed segment is non-null.
    final scores = List<int?>.filled(8, null);
    if (segmentIndex != null && elapsedSeconds != null) {
      scores[segmentIndex] = elapsedSeconds;
    }

    CommunityService.uploadLessonScore(
      userId: uid,
      lessonId: _selectedCategoryId!,
      translateLang: langs.targetLang,
      nativeLang: langs.nativeLang,
      lessonName: cat.nameNative,
      challenge: cat.challenge,
      scores: scores,
    );

    CommunityService.upsertProfile(
      userId: uid,
      translateLang: langs.targetLang,
      nativeLang: langs.nativeLang,
      nickName: (meta['full_name'] as String?) ??
          (meta['name'] as String?) ??
          (client.auth.currentUser?.email?.split('@').first ?? ''),
      avatarUrl: meta['avatar_url'] as String?,
    );
  }

  Future<void> _showQuizCongrats() async {
    _cancelQuizTimer();
    final elapsedSeconds = _challengeStopwatch.elapsed.inSeconds;
    _challengeStopwatch.reset();

    setState(() {
      _quizMode = false;
      _quizAnsweredIds.clear();
    });

    final seg = _currentSegmentIndex();

    // Write completion digit (5 = challenge passed) to challenge column.
    if (_selectedCategoryId != null) {
      await DatabaseHelper.updateChallengeSegment(_selectedCategoryId!, seg, 5);
    }
    // Write elapsed seconds to score column.
    if (_selectedCategoryId != null) {
      await DatabaseHelper.updateScoreSegment(_selectedCategoryId!, seg, elapsedSeconds);
    }

    final updatedCats = await DatabaseHelper.getAllCategories();
    if (mounted) setState(() => _categories = updatedCats);

    _syncToSupabase(updatedCats,
        segmentIndex: seg, elapsedSeconds: elapsedSeconds);

    if (!mounted) return;
    SoundFeedbackService.playCongrats();

    await _showChallengeResultDialog(elapsedSeconds, updatedCats);
  }

  Future<void> _showChallengeResultDialog(
    int elapsedSeconds,
    List<CategoryEntry> updatedCats,
  ) async {
    final l = L10n(AppLangNotifier().uiLang);
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(l.challengeResultTitle),
        content: Text(l.challengeResultMsg(elapsedSeconds)),
        actions: [
          // a. Try again (same lesson, restart challenge)
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              setState(() {
                _quizMode = true;
                _quizAnsweredIds.clear();
              });
              _challengeStopwatch.reset();
              _pickNext();
            },
            child: Text(l.challengeTryAgain),
          ),
          // b. Next challenge (same lesson; jump to lowest-score segment)
          OutlinedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _startNextPracticeFromLowestScore(updatedCats);
            },
            child: Text(l.challengeNextChallenge),
          ),
          // c. Skip (exit challenge, stay on lesson)
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l.challengeSkip),
          ),
        ],
      ),
    );
  }

  int _lowestScoreSegment(CategoryEntry cat) {
    var bestIdx = 0;
    var bestScore = 1 << 30;
    for (var i = 0; i < 8; i++) {
      final s = (i < cat.scores.length) ? cat.scores[i] : null;
      final score = s ?? 0;
      if (score < bestScore) {
        bestScore = score;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  void _applySegmentMode(int segmentIndex) {
    final normalized = segmentIndex.clamp(0, 7);
    final isTranslate = normalized < 4;
    final inBlock = normalized % 4;
    final isPhrase = inBlock >= 2;
    final isTalk = normalized.isEven;

    setState(() {
      _mode = isTranslate
          ? _PracticeMode.thaiToChinese
          : _PracticeMode.chineseToThai;
      _practiceType = isPhrase ? 1 : 0;
      _talkMode = isTalk;
      _quizMode = true;
      _quizAnsweredIds.clear();
      _talkScoring = false;
      _talkScorePercent = null;
      _talkAsrHint = null;
      _talkPointerDown = false;
      _talkActivePointer = null;
      _talkButtonPressed = false;
    });
  }

  void _startNextPracticeFromLowestScore(List<CategoryEntry> updatedCats) {
    if (_selectedCategoryId == null) return;
    final cat = updatedCats.firstWhere(
      (c) => c.id == _selectedCategoryId,
      orElse: () => CategoryEntry(nameNative: ''),
    );
    if (cat.id == null) return;

    final seg = _lowestScoreSegment(cat);
    _applySegmentMode(seg);
    _challengeStopwatch.reset();
    _pickNext();
  }

  // ── 切换类别 ───────────────────────────────────────────────────
  Future<void> _onCategoryChanged(int? catId) async {
    await SharedCategoryPrefs.save(catId);

    setState(() {
      _selectedCategoryId = catId;
      _practiceType = _categoryPracticeType(catId, _categories);
      _updatePool();
      _history.clear();
      _historyIndex = -1;
      _options = [];
      _romanization = null;
      _playing = false;
      _playingOptionIndex = null;
      _phraseQuestionText = null;
      _definitionNative = null;
      _loadingDefinition = false;
      _actionContent = null;
      _sample1Translate = null;
      _sample1Native = null;
      _loadingSample = false;
      _playingSample = false;
      _quizAnsweredIds.clear();
    });
    _tts.stop();
    _cancelQuizTimer();
    _notifyCategoryName();
    if (mounted && _poolEntries.isNotEmpty) {
      await _restoreSequentialFromPrefs(autoPlay: false);
    }
  }

  // ── Practice type helpers ──────────────────────────────────────
  int _categoryPracticeType(int? catId, List<CategoryEntry> cats) {
    if (catId == null) return 0;
    final cat = cats.firstWhere((c) => c.id == catId,
        orElse: () => CategoryEntry(nameNative: ''));
    return cat.practiceType;
  }

  Future<void> _togglePracticeType() async {
    stopQuizMode();

    final newType = _practiceType == 0 ? 1 : 0;
    setState(() => _practiceType = newType);
    _scrollContentToTop();
    if (_selectedCategoryId != null) {
      await DatabaseHelper.updateCategoryPracticeType(_selectedCategoryId!, newType);
    }
    // Rebuild options with new type
    if (_current != null) {
      _buildOptions(_current!);
      if (newType == 0 &&
          _mode == _PracticeMode.thaiToChinese &&
          _current!.id != null) {
        _fetchRomanization(_current!.id);
      }
    }
    await _forceScrollTopAfterStateSettles();
  }

  void _scrollContentToTop() {
    if (_contentScrollController.hasClients) {
      _contentScrollController.jumpTo(0);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_contentScrollController.hasClients) return;
      _contentScrollController.jumpTo(0);
    });
  }

  Future<void> _forceScrollTopAfterStateSettles() async {
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
      if (_contentScrollController.hasClients) {
        _contentScrollController.jumpTo(0);
      }
    }
  }

  // ── Lesson picker popup ───────────────────────────────────────
  void _showLessonPicker() {
    showDialog(
      context: context,
      builder: (ctx) => LessonPickerDialog(
        categories: _categories,
        selectedId: _selectedCategoryId,
        challengeBgColor: challengeBgColor,
        challengeTextColor: challengeTextColor,
        onSelected: (id) {
          Navigator.of(ctx).pop();
          _onCategoryChanged(id);
        },
      ),
    );
  }

  /// Lesson picker that starts a fresh regular challenge on the selected lesson.
  void _showLessonPickerForChallenge() {
    showDialog(
      context: context,
      builder: (ctx) => LessonPickerDialog(
        categories: _categories,
        selectedId: _selectedCategoryId,
        challengeBgColor: challengeBgColor,
        challengeTextColor: challengeTextColor,
        onSelected: (id) {
          Navigator.of(ctx).pop();
          _onCategoryChanged(id);
          // Pool updates synchronously in _onCategoryChanged; start quiz after frame.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _poolEntries.isNotEmpty) {
              setState(() {
                _quizMode = true;
                _quizAnsweredIds.clear();
              });
              _challengeStopwatch.reset();
              _pickNext();
            }
          });
        },
      ),
    );
  }

  // ── Go to next lesson ─────────────────────────────────────────
  void _goToNextLesson() {
    if (_categories.isEmpty) return;
    final idx = _categories.indexWhere((c) => c.id == _selectedCategoryId);
    final nextIdx = (idx + 1) % _categories.length;
    _onCategoryChanged(_categories[nextIdx].id);
  }

  @override
  void dispose() {
    _cancelQuizTimer();
    _talkPlaybackDone?.complete();
    _talkPlaybackDone = null;
    _tts.dispose();
    _recorder.dispose();
    _talkPlaybackPlayer.dispose();
    _contentScrollController.dispose();
    super.dispose();
  }

  // ── 单词/例句切换按钮 ──────────────────────────────────────────
  Widget _buildWordPhraseToggle() {
    final l = L10n(AppLangNotifier().uiLang);
    final isPhrase = _practiceType == 1;
    final wordPurple = const Color(0xFF7E57C2);
    final phrasePurple = const Color(0xFF6A1B9A);
    return GestureDetector(
      onTap: _togglePracticeType,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isPhrase ? phrasePurple : wordPurple,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.swap_horiz,
                color: Color(0xFFEDE7F6), size: 13),
            const SizedBox(width: 4),
            Text(
              isPhrase ? l.practiceTogglePhrase : l.practiceToggleWord,
              style: TextStyle(
                color: isPhrase
                    ? const Color(0xFFF3E5F5)
                    : const Color(0xFFEDE7F6),
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTalkToggleButton() {
    final l = L10n(AppLangNotifier().uiLang);
    final modeLabel = _talkMode ? l.practiceToggleChoice : l.practiceToggleTalk;
    return GestureDetector(
      onTap: () async {
        if (_talkRecording) {
          await _stopTalkAndScore();
        }
        stopQuizMode();
        setState(() {
          _talkPointerDown = false;
          _talkActivePointer = null;
          _talkButtonPressed = false;
          _talkMode = !_talkMode;
          if (!_talkMode) {
            _talkScoring = false;
            _talkScorePercent = null;
            _talkAsrHint = null;
          }
        });
        _scrollContentToTop();
        await _forceScrollTopAfterStateSettles();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: _talkMode ? const Color(0xFFB71C1C) : const Color(0xFFEF9A9A),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _talkMode ? const Color(0xFFFFCDD2) : const Color(0xFFD32F2F),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.swap_horiz,
                size: 13,
                color: _talkMode ? Colors.white : const Color(0xFFB71C1C)),
            const SizedBox(width: 4),
            Text(
              modeLabel,
              style: TextStyle(
                color: _talkMode ? Colors.white : const Color(0xFFB71C1C),
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _expectedTalkText() {
    // Native→translate + Talk: score against the learn-language line (same as TTS would read).
    if (_talkMode && _mode == _PracticeMode.chineseToThai) {
      if (_practiceType == 1) {
        for (final o in _options) {
          if (o.isCorrect && o.srcText.trim().isNotEmpty) {
            return o.srcText.trim();
          }
        }
      }
      return (_current?.nameTranslate ?? '').trim();
    }

    // Translate→native + Talk: user speaks the translate (learn) line shown
    // as the prompt — Thai for Thai→Chinese data — not the native answer text.
    if (_talkMode && _mode == _PracticeMode.thaiToChinese) {
      if (_practiceType == 1) {
        final q = (_phraseQuestionText ?? '').trim();
        if (q.isNotEmpty) return q;
        for (final o in _options) {
          if (o.isCorrect) {
            final line = o.lineForTranslateTts.trim();
            if (line.isNotEmpty) return line;
          }
        }
      }
      return (_current?.nameTranslate ?? '').trim();
    }

    if (_practiceType == 1 && _phraseQuestionText != null && _phraseQuestionText!.isNotEmpty) {
      return _phraseQuestionText!;
    }
    return _mode == _PracticeMode.thaiToChinese
        ? (_current?.nameTranslate ?? '')
        : (_current?.nameNative ?? '');
  }

  String _talkLangCode() {
    if (_talkMode && _mode == _PracticeMode.chineseToThai) {
      return AppLangNotifier().targetLang;
    }
    if (_talkMode && _mode == _PracticeMode.thaiToChinese) {
      return AppLangNotifier().targetLang;
    }
    return _mode == _PracticeMode.thaiToChinese ? AppLangNotifier().targetLang : AppLangNotifier().nativeLang;
  }

  bool get _uiIsChinese => AppLangNotifier().uiLang.startsWith('zh');
  String get _talkPushLabel => _uiIsChinese ? '按住说话' : 'Push to talk';
  String get _talkReleaseLabel => _uiIsChinese ? '松开结束' : 'Release';

  /// User-visible hint when Whisper fails, or "Heard: …" when score is 0% but text exists.
  String? _whisperUiHint({
    required WhisperTranscribeResult result,
    required int score,
  }) {
    if (!result.ok) {
      final parts = <String>[];
      if (result.httpStatus != null) {
        parts.add('HTTP ${result.httpStatus}');
      }
      if (result.errorSummary != null && result.errorSummary!.trim().isNotEmpty) {
        parts.add(result.errorSummary!.trim());
      }
      return parts.isEmpty ? 'Transcription failed' : parts.join(' · ');
    }
    final t = result.text!.trim();
    if (t.isEmpty) {
      return 'Empty transcript';
    }
    if (score == 0) {
      final short = t.length > 72 ? '${t.substring(0, 72)}…' : t;
      return 'Heard: $short';
    }
    return null;
  }

  Future<void> _interruptPlaybackForTalk() async {
    _talkPlaybackDone?.complete();
    _talkPlaybackDone = null;
    await _tts.stop();
    await _talkPlaybackPlayer.stop();
    if (!mounted) return;
    setState(() {
      _playing = false;
      _playingOptionIndex = null;
    });
  }

  void _onTalkPointerDown(PointerDownEvent e) {
    if (!_talkMode || _talkRecording || _talkScoring) return;
    if (_talkActivePointer != null) return;
    _talkActivePointer = e.pointer;
    _talkPointerDown = true;
    if (mounted) setState(() => _talkButtonPressed = true);
    unawaited(_startTalkRecording());
  }

  void _onTalkPointerUp(PointerEvent e) {
    if (e.pointer != _talkActivePointer) return;
    _talkPointerDown = false;
    _talkActivePointer = null;
    if (mounted) setState(() => _talkButtonPressed = false);
    unawaited(_stopTalkAndScore());
  }

  Future<void> _startTalkRecording() async {
    if (!_talkMode || _talkRecording || _talkScoring) return;
    await _interruptPlaybackForTalk();
    if (!mounted || !_talkPointerDown) return;
    final hasPerm = await _recorder.hasPermission();
    if (!hasPerm || !mounted || !_talkPointerDown) return;
    if (_quizMode && _talkMode) {
      _cancelQuizTimer();
    }
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/talk_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );
    // Pointer released before native start finished: stop immediately so we never get a "zombie" session.
    if (!mounted || !_talkPointerDown) {
      await _recorder.stop();
      return;
    }
    _talkHoldWatch = Stopwatch()..start();
    if (!mounted) return;
    setState(() {
      _talkRecordPath = path;
      _talkRecording = true;
      _talkButtonPressed = true;
      _talkScorePercent = null;
      _talkAsrHint = null;
      _talkRecordSeconds = 0;
    });
    final gen = ++_talkRecordGeneration;
    unawaited(Future<void>(() async {
      while (mounted && _talkRecording && gen == _talkRecordGeneration) {
        await Future.delayed(const Duration(seconds: 1));
        if (!mounted || !_talkRecording || gen != _talkRecordGeneration) break;
        setState(() => _talkRecordSeconds++);
      }
    }));
  }

  Future<void> _playBackTalkRecording(String path) async {
    await _talkPlaybackPlayer.stop();
    _talkPlaybackDone = Completer<void>();
    final gate = _talkPlaybackDone!;
    late StreamSubscription<void> sub;
    sub = _talkPlaybackPlayer.onPlayerComplete.listen((_) {
      if (!gate.isCompleted) gate.complete();
    });
    try {
      await _talkPlaybackPlayer.play(DeviceFileSource(path));
      await gate.future.timeout(
        const Duration(minutes: 2),
        onTimeout: () {
          if (!gate.isCompleted) gate.complete();
        },
      );
    } finally {
      await sub.cancel();
      if (_talkPlaybackDone == gate) {
        _talkPlaybackDone = null;
      }
    }
  }

  /// Practice, Native→Translate: play model pronunciation for the expected translate line
  /// (word or phrase), using DB audio when available (same as option speaker).
  Future<void> _playExpectedTranslateReferenceTts() async {
    if (!mounted || _current == null) return;
    final targetLang = AppLangNotifier().targetLang;

    Future<void> playLine(
      String line, {
      int? wordId,
      int? phraseSlot,
    }) async {
      if (line.isEmpty) return;
      await _tts.stop();
      if (!mounted) return;
      setState(() => _playing = true);
      final done = Completer<void>();
      await _tts.speakTranslateFromDbOrFetch(
        line,
        appTargetLangCode: targetLang,
        wordId: wordId,
        phraseSlot: phraseSlot,
        onDone: () {
          if (mounted) setState(() => _playing = false);
          if (!done.isCompleted) done.complete();
        },
      );
      await done.future;
    }

    if (_practiceType == 1) {
      _QuizOption? correct;
      for (final o in _options) {
        if (o.isCorrect) {
          correct = o;
          break;
        }
      }
      final line = correct?.lineForTranslateTts ?? '';
      await playLine(
        line,
        wordId: correct?.audioWordId,
        phraseSlot: correct?.audioPhraseSlot,
      );
      return;
    }

    await playLine(
      (_current!.nameTranslate).trim(),
      wordId: _current!.id,
      phraseSlot: null,
    );
  }

  /// Practice Native→Translate + Talk: play / stop reference translate audio (same as post-record TTS).
  Future<void> _togglePlayTranslateReference() async {
    if (_current == null || _talkRecording || _talkScoring) return;
    if (_playing || _tts.isPlaying) {
      await _tts.stop();
      if (mounted) {
        setState(() {
          _playing = false;
          _playingOptionIndex = null;
        });
      }
      return;
    }
    await _playExpectedTranslateReferenceTts();
  }

  Future<void> _stopTalkAndScore() async {
    _talkRecordGeneration++;
    final uiRecording = _talkRecording;
    final nativeRecording = await _recorder.isRecording();
    if (!uiRecording && !nativeRecording) return;

    final path = await _recorder.stop();
    final holdMs = _talkHoldWatch?.elapsedMilliseconds ?? 0;
    _talkHoldWatch?.stop();
    _talkHoldWatch = null;
    if (!mounted) return;
    setState(() {
      _talkRecording = false;
      _talkButtonPressed = false;
    });

    if (holdMs < _kMinTalkHoldMs) {
      final msg = _uiIsChinese
          ? '请按住约 1 秒再松开（太短会被拒绝，无法打分）'
          : 'Hold about 1s before release — audio was too short for transcription.';
      if (mounted) {
        setState(() {
          _talkScorePercent = null;
          _talkAsrHint = msg;
        });
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 4)),
        );
      }
      if (_quizMode && _talkMode && mounted) {
        await _applyTalkChallengeOutcome(0);
      }
      return;
    }

    if (!mounted) return;
    setState(() {
      _talkScoring = true;
      _talkScorePercent = null;
      _talkAsrHint = null;
    });

    int? talkChallengeScore;
    try {
      final p = path ?? _talkRecordPath;
      if (p == null || p.isEmpty) {
        if (mounted) setState(() => _talkScorePercent = null);
        if (_quizMode && _talkMode) {
          talkChallengeScore = 0;
        }
      } else {
        final practiceNativeTalk =
            !_quizMode && _talkMode && _mode == _PracticeMode.chineseToThai;
        final practiceTranslateTalk =
            !_quizMode && _talkMode && _mode == _PracticeMode.thaiToChinese;
        final skipChallengePlayback =
            _quizMode && _talkMode && _mode == _PracticeMode.chineseToThai;

        final useAsr = _talkAccuracyEnabled;
        // For practice (non-quiz), start ASR only after we finish any audio
        // playback sequence to avoid any file-lock / race issues on-device.
        Future<WhisperTranscribeResult>? asrFuture;
        final startAsrEarly = _quizMode;
        if (useAsr && startAsrEarly) {
          asrFuture = TalkAsrService.transcribeFileDetailed(
            p,
            appLangCode: _talkLangCode(),
          );
        }

        // Challenge + Talk without accuracy: hear recording, then model TTS, then advance.
        if (_quizMode && _talkMode && !useAsr) {
          await _tts.stop();
          if (!mounted) return;
          await _playBackTalkRecording(p);
          if (!mounted) return;
          await _playExpectedTranslateReferenceTts();
          if (!mounted) return;
          talkChallengeScore = QuizPrefs.maxAccuracyThreshold;
        } else if (practiceNativeTalk) {
          await _tts.stop();
          if (!mounted) return;
          await _playBackTalkRecording(p);
          if (!mounted) return;
          await _playExpectedTranslateReferenceTts();
          if (!mounted) return;
        } else if (practiceTranslateTalk) {
          await _tts.stop();
          if (!mounted) return;
          await _playBackTalkRecording(p);
          if (!mounted) return;
          await _playExpectedTranslateReferenceTts();
          if (!mounted) return;
        } else if (!skipChallengePlayback) {
          unawaited(_playBackTalkRecording(p));
        }

        if (!useAsr) {
          if (mounted) setState(() => _talkScorePercent = null);
        } else {
          final expected = _expectedTalkText();
          final result = await (asrFuture ??
              TalkAsrService.transcribeFileDetailed(
                p,
                appLangCode: _talkLangCode(),
              ));
          final transcript = result.text ?? '';
          final score = talkAccuracyPercent(expected, transcript);
          final hint = _whisperUiHint(result: result, score: score);
          if (mounted) {
            setState(() {
              _talkScorePercent = score;
              _talkAsrHint = hint;
            });
          }
          if (!result.ok && mounted) {
            final msg = hint ?? 'Whisper transcription failed';
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              SnackBar(
                content: Text(msg),
                duration: const Duration(seconds: 6),
              ),
            );
          }
          if (_quizMode && _talkMode) {
            talkChallengeScore = score;
          }
        }
      }
    } catch (_) {
      if (mounted) setState(() => _talkScorePercent = 0);
      if (_quizMode && _talkMode) {
        talkChallengeScore = 0;
      }
    } finally {
      if (mounted) setState(() => _talkScoring = false);
    }
    if (_quizMode && _talkMode && talkChallengeScore != null && mounted) {
      await _applyTalkChallengeOutcome(talkChallengeScore);
    }

    // Note: for Translate→Native practice + Talk, we do NOT auto-jump after ASR.
  }

  Future<void> _applyTalkChallengeOutcome(int score) async {
    final prefs = await SharedPreferences.getInstance();
    final th = (prefs.getInt(QuizPrefs.accuracyThresholdKey) ??
            QuizPrefs.defaultAccuracyThreshold)
        .clamp(QuizPrefs.minAccuracyThreshold, QuizPrefs.maxAccuracyThreshold);
    if (score >= th) {
      await _onTalkChallengePass();
    } else {
      await _onTalkChallengeFail();
    }
  }

  Future<void> _onTalkChallengePass() async {
    if (!mounted) return;
    await _tts.stop();
    _cancelQuizTimer();
    setState(() {
      _answered = true;
      _playingOptionIndex = null;
      _playing = false;
    });
    SoundFeedbackService.playCorrect();
    if (_firstAttempt && _current != null && _current!.id != null) {
      await DatabaseHelper.incrementCorrectCount(_current!.id!);
      if (!mounted) return;
      final id = _current!.id!;
      setState(() {
        _quizAnsweredIds.add(id);
      });
      final poolIds =
          _poolEntries.where((e) => e.id != null).map((e) => e.id!).toSet();
      if (poolIds.isNotEmpty && _quizAnsweredIds.containsAll(poolIds)) {
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) _showQuizCongrats();
        return;
      }
    }
    await Future.delayed(const Duration(seconds: 1));
    if (mounted) _pickNext();
  }

  Future<void> _onTalkChallengeFail() async {
    if (!mounted) return;
    await _tts.stop();
    _cancelQuizTimer();
    HapticFeedback.heavyImpact();
    setState(() {
      _firstAttempt = false;
      _answered = true;
      _quizAnsweredIds.clear();
      _playingOptionIndex = null;
      _playing = false;
    });
    SoundFeedbackService.playWrong();
    await Future.delayed(const Duration(seconds: 1));
    if (mounted) _pickNext();
  }

  Color _talkPhoneticScoreColor(int? scorePercent) {
    if (scorePercent == null) return Colors.grey;
    if (scorePercent >= 80) return Colors.green.shade700;
    if (scorePercent >= 50) return Colors.orange.shade700;
    return Colors.red.shade700;
  }

  String _talkPhoneticQualitativeLabel(int score, L10n l) {
    if (score >= 95) return l.talkAccuracyLabelExcellent;
    if (score >= 80) return l.talkAccuracyLabelGood;
    if (score >= 60) return l.talkAccuracyLabelFair;
    if (score >= 40) return l.talkAccuracyLabelPoor;
    return l.talkAccuracyLabelVeryPoor;
  }

  /// Same layout as [tts_test] Whisper accuracy feedback (circular + linear + labels).
  Widget _buildTalkAccuracyTtsCard(
    L10n l, {
    EdgeInsetsGeometry margin = const EdgeInsets.fromLTRB(4, 12, 4, 4),
  }) {
    final score = _talkScorePercent;
    final loading = _talkScoring;

    Color cardTint() {
      if (loading || score == null) return Colors.grey.shade100;
      if (score >= 80) return Colors.green.shade50;
      if (score >= 50) return Colors.orange.shade50;
      return Colors.red.shade50;
    }

    final stroke = _talkPhoneticScoreColor(loading ? null : score);

    return Card(
      margin: margin,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      color: cardTint(),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 20),
        child: Row(
          children: [
            SizedBox(
              width: 72,
              height: 72,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox.expand(
                    child: CircularProgressIndicator(
                      value: loading ? null : (score! / 100).clamp(0.0, 1.0),
                      strokeWidth: 7,
                      backgroundColor: Colors.grey.shade300,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        loading ? Colors.grey : stroke,
                      ),
                    ),
                  ),
                  Text(
                    loading ? '…' : '${score!}%',
                    style: TextStyle(
                      fontSize: loading ? 16 : 18,
                      fontWeight: FontWeight.bold,
                      color: loading ? Colors.grey : stroke,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.talkPhoneticMatchTitle,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: loading ? Colors.grey.shade700 : stroke,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    loading
                        ? l.talkAccuracyCalculating
                        : (score != null
                            ? _talkPhoneticQualitativeLabel(score, l)
                            : l.talkAccuracyCalculating),
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  if (!loading && score != null) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: (score / 100).clamp(0.0, 1.0),
                        minHeight: 6,
                        backgroundColor: Colors.grey.shade300,
                        valueColor: AlwaysStoppedAnimation<Color>(stroke),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTalkPanel() {
    final l = L10n(AppLangNotifier().uiLang);
    final canToggleAccuracy = !_talkRecording && !_talkScoring;
    final asrActive = _talkAccuracyEnabled;

    Widget leftAccuracyControls() {
      return Align(
        alignment: Alignment.topLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              height: 32,
              width: 32,
              child: Checkbox(
                value: _talkAccuracyEnabled,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                onChanged: canToggleAccuracy
                    ? (v) => setState(() => _talkAccuracyEnabled = v ?? false)
                    : null,
              ),
            ),
            Flexible(
              child: GestureDetector(
                onTap: canToggleAccuracy
                    ? () => setState(() => _talkAccuracyEnabled = !_talkAccuracyEnabled)
                    : null,
                child: Text(
                  l.talkAccuracyLabel,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: canToggleAccuracy ? Colors.grey.shade800 : Colors.grey.shade500,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          Center(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _onTalkPointerDown,
              onPointerUp: _onTalkPointerUp,
              onPointerCancel: _onTalkPointerUp,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 80),
                width: 110,
                height: 110,
                transform: Matrix4.translationValues(0, _talkButtonPressed ? 3 : 0, 0),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: _talkRecording
                        ? const [Color(0xFFFF5252), Color(0xFFB71C1C)]
                        : const [Color(0xFFE53935), Color(0xFF8E0000)],
                  ),
                  border: Border.all(
                    color: const Color(0xFFFFCDD2),
                    width: _talkButtonPressed ? 1.0 : 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF4E0A0A).withOpacity(0.45),
                      blurRadius: _talkButtonPressed ? 5 : 12,
                      offset: Offset(0, _talkButtonPressed ? 1 : 6),
                    ),
                  ],
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _talkRecording ? Icons.pan_tool_alt_rounded : Icons.arrow_downward_rounded,
                        color: Colors.white,
                        size: 26,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _talkRecording ? _talkReleaseLabel : _talkPushLabel,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_talkRecording)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                'Recording ${_talkRecordSeconds}s...',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFFD50000),
                ),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 150,
                child: leftAccuracyControls(),
              ),
              const Expanded(child: SizedBox.shrink()),
            ],
          ),
          if (_talkAsrHint != null &&
              asrActive &&
              !_talkRecording &&
              !_talkScoring) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  border: Border.all(color: Colors.red.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _talkAsrHint!,
                  style: TextStyle(color: Colors.red.shade800, fontSize: 13, height: 1.35),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Bottom inset so scroll content stays above the fixed challenge strip.
  double get _practiceScrollBottomPadding => _quizMode ? 140 : 88;

  // ── Challenge 区域（按钮 + 剩余词数 chip）──────────────────────
  Widget _buildChallengeArea() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        QuizModeButton(
          active: _quizMode,
          onToggle: _toggleQuizMode,
        ),
        if (_quizMode) ...[
          const SizedBox(width: 8),
          ChallengeCounter(
            value: _challengeRemainingCount,
            icon: Icons.format_list_numbered,
            color: const Color(0xFF1565C0),
          ),
        ],
      ],
    );
  }

  // ── 构建主内→─────────────────────────────────────────────────
  Widget _buildContent() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_allEntries.isEmpty) {
      final l = L10n(AppLangNotifier().uiLang);
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            l.practiceEmpty,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, color: Colors.grey),
          ),
        ),
      );
    }

    final isModeB = _mode == _PracticeMode.chineseToThai;
    final l = L10n(AppLangNotifier().uiLang);
    final topAnchorSignature = '${_mode.index}-${_practiceType}-${_talkMode ? 1 : 0}';
    if (_lastTopAnchorSignature != topAnchorSignature) {
      _lastTopAnchorSignature = topAnchorSignature;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_contentScrollController.hasClients) {
          _contentScrollController.jumpTo(0);
        }
      });
    }

    final scroll = ListView(
      controller: _contentScrollController,
      primary: false,
      padding: EdgeInsets.fromLTRB(20, 12, 20, _practiceScrollBottomPadding),
      children: [
        // ── 词条不足提示 ──────────────────────────────────────
        if (_poolEntries.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              l.practiceCatEmpty,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.orange.shade700, fontSize: 14),
            ),
          ),

        // ── 选择题区 ─────────────────────────────────────────
        if (!_talkMode && _options.isNotEmpty) ...[
          const SizedBox(height: 4),
          ..._options.asMap().entries.map((entry) {
            final i = entry.key;
            final opt = entry.value;
            if (isModeB) {
              // 模式 B：显示泰语选项 + 右侧播放按钮
              return ThaiOptionTile(
                thai: opt.srcText,
                romanization: opt.romanization,
                hideRomanization: _hideRomanization,
                state: opt.state,
                isPlayingThis: _playingOptionIndex == i,
                onTap: _answered ? null : () => _selectOption(i),
                onPlay: () => _playOption(i),
              );
            } else {
              // 模式 A：中文选项 + 翻译语朗读（BLOB / Google）
              return ChineseOptionTile(
                chinese: opt.dstText,
                state: opt.state,
                romanTranslate: opt.romanTranslate,
                romanBelowNativeWhenWrong: _practiceType == 1,
                isPlayingThis: _playingOptionIndex == i,
                onTap: _answered ? null : () => _selectOption(i),
                onPlay:
                    opt.lineForTranslateTts.isEmpty ? null : () => _playOption(i),
              );
            }
          }),
        ],

        // ── 底部三选项卡面板（word practice only; hide in Talk+word）────
        if (_practiceType == 0 && !_quizMode && !_talkMode) ...[
          const SizedBox(height: 14),
          _buildBottomTabPanel(l),
        ],

        if (_talkMode) _buildTalkPanel(),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── 固定顶部：三个切换按钮左对齐，不随内容滚动 ──────────
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ModeToggle(isModeB: isModeB, onToggle: _toggleMode),
              const SizedBox(width: 8),
              _buildWordPhraseToggle(),
              const SizedBox(width: 8),
              _buildTalkToggleButton(),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: isModeB
              ? _buildChineseDisplay()
              : _buildThaiDisplay(),
        ),
        const SizedBox(height: 12),
        // ── 可滚动内容 + 底部挑战按钮 ──────────────────────────
        Expanded(
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.bottomCenter,
            children: [
              scroll,
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: _buildChallengeArea(),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── 底部 Tab 面板构建 ──────────────────────────────────────────
  Widget _buildBottomTabPanel(L10n l) {
    const tabLabels = [0, 1, 2];
    final tabIcons = [
      Icons.menu_book_outlined,
      Icons.touch_app_outlined,
      Icons.format_quote_outlined,
    ];
    final tabTitles = [l.tabDefinition, l.tabActions, l.tabExample];
    /// ~3 lines at fontSize 13, height 1.5
    const tabBodyHeight = 58.0;
    final safeTab = min(2, max(0, _activeTab));

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Tab header bar ──────────────────────────────────
          Container(
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
            ),
            child: Row(
              children: tabLabels.map((i) {
                final active = safeTab == i;
                return Expanded(
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _activeTab = i);
                      // Lazy-fetch when switching to Definition tab
                      if (i == 0 && _definitionNative == null && !_loadingDefinition && _current?.id != null) {
                        _fetchAndSaveDefinition(_current!.id!, _current!.nameTranslate);
                      }
                      // Lazy-fetch when switching to Example tab (only if sample1 is empty)
                      if (i == 2 &&
                          _sample1Translate == null &&
                          !_loadingSample &&
                          _current?.id != null) {
                        _fetchAndSaveSample(_current!.id!, _current!.nameTranslate);
                      }
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: active ? Colors.white : Colors.transparent,
                        border: Border(
                          bottom: BorderSide(
                            color: active ? const Color(0xFF1565C0) : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        borderRadius: i == 0
                            ? const BorderRadius.only(topLeft: Radius.circular(12))
                            : i == 2
                                ? const BorderRadius.only(topRight: Radius.circular(12))
                                : BorderRadius.zero,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            tabIcons[i],
                            size: 16,
                            color: active ? const Color(0xFF1565C0) : Colors.grey.shade500,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            tabTitles[i],
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: active ? FontWeight.bold : FontWeight.normal,
                              color: active ? const Color(0xFF1565C0) : Colors.grey.shade500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),

          // ── Tab content ─────────────────────────────────────
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: KeyedSubtree(
              key: ValueKey(safeTab),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                child: SizedBox(
                  height: tabBodyHeight,
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: safeTab == 0
                        ? _buildDefinitionTab(l)
                        : safeTab == 1
                            ? _buildActionsTab(l)
                            : _buildExampleTab(l),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Definition tab ───────────────────────────────────────────
  Widget _buildDefinitionTab(L10n l) {
    if (_loadingDefinition) {
      return Row(children: [
        const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5)),
        const SizedBox(width: 8),
        Text(l.definitionLoading, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      ]);
    }
    final hasNative = _definitionNative?.isNotEmpty == true;
    if (!hasNative) {
      return Text(l.definitionNone,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade400, fontStyle: FontStyle.italic));
    }
    return Text(
      _definitionNative!,
      style: TextStyle(fontSize: 13, color: Colors.grey.shade800, height: 1.5),
    );
  }

  // ── Actions tab ──────────────────────────────────────────────
  Widget _buildActionsTab(L10n l) {
    final content = _actionContent;
    if (content == null || content.isEmpty) {
      return Text(
        l.definitionNone,
        style: TextStyle(fontSize: 12, color: Colors.grey.shade400, fontStyle: FontStyle.italic),
      );
    }
    return Text(
      content,
      style: TextStyle(fontSize: 13, color: Colors.grey.shade800, height: 1.5),
    );
  }

  // ── Example tab ──────────────────────────────────────────────
  Widget _buildExampleTab(L10n l) {
    if (_loadingSample) {
      return Row(children: [
        const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5)),
        const SizedBox(width: 8),
        Text(l.sampleLoading, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      ]);
    }

    final translateText = _sample1Translate;
    final nativeText = _sample1Native;
    final hasTranslate = translateText != null && translateText.isNotEmpty;
    final hasNative = nativeText != null && nativeText.isNotEmpty;
    final wordId = _current?.id;

    if (!hasTranslate) {
      return Text(l.sampleNone,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade400, fontStyle: FontStyle.italic));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                translateText,
                style: const TextStyle(fontSize: 13, height: 1.45),
              ),
            ),
            SizedBox(
              width: 30,
              height: 30,
              child: IconButton(
                padding: EdgeInsets.zero,
                iconSize: 18,
                icon: Icon(
                  _playingSample ? Icons.stop_circle_outlined : Icons.volume_up_outlined,
                  color: const Color(0xFF1565C0),
                ),
                onPressed: () async {
                  if (_playingSample) {
                    await _tts.stop();
                    setState(() => _playingSample = false);
                  } else {
                    setState(() => _playingSample = true);
                    await _tts.speakTranslateFromDbOrFetch(
                      translateText,
                      appTargetLangCode: AppLangNotifier().targetLang,
                      wordId: wordId,
                      phraseSlot: 0,
                      onDone: () {
                        if (mounted) setState(() => _playingSample = false);
                      },
                    );
                  }
                },
              ),
            ),
          ],
        ),
        if (hasNative) ...[
          const SizedBox(height: 8),
          Divider(color: Colors.grey.shade200, height: 1),
          const SizedBox(height: 8),
          Text(
            nativeText,
            style: const TextStyle(fontSize: 13, height: 1.45),
          ),
        ],
      ],
    );
  }

  // ── 模式 A 主显示区（源语言 + 拼音）→按钮在上，文字框全宽 ──
  Widget _buildThaiDisplay() {
    // When Talk is enabled in Translate→Native practice, show the native line under the translate line.
    final nativeBelow = (!_quizMode && _talkMode && _current != null)
        ? (_practiceType == 1
            ? (() {
                for (final o in _options) {
                  if (o.isCorrect && o.dstText.trim().isNotEmpty) return o.dstText.trim();
                }
                return (_current?.nameNative ?? '').trim();
              })()
            : (_current?.nameNative ?? '').trim())
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── 按钮行：« / 播放 / » ────────────────────────────────
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            NavButton(
              isPrev: true,
              enabled: _canGoPrev,
              onPressed: _canGoPrev ? _pickPrev : null,
            ),
            const SizedBox(width: 16),
            PlayButton(
              playing: _playing,
              onPressed: _current != null ? _togglePlay : null,
            ),
            const SizedBox(width: 16),
            NavButton(
              isPrev: false,
              enabled: _canGoNext,
              onPressed: _canGoNext ? _pickNext : null,
            ),
          ],
        ),
        const SizedBox(height: 10),
        // ── 源语言文字框（全宽）──────────────────────────────────
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF1565C0).withOpacity(0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: const Color(0xFF1565C0).withOpacity(0.25)),
          ),
          child: Text(
            _phraseQuestionText ?? _current?.nameTranslate ?? '—',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: _phraseQuestionText != null ? 16 : 26,
              color: const Color(0xFF1565C0),
              fontWeight: FontWeight.w600,
              letterSpacing: _phraseQuestionText != null ? 0.5 : 1.5,
              height: 1.4,
            ),
          ),
        ),
        if (nativeBelow != null && nativeBelow.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF00695C).withOpacity(0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFF00695C).withOpacity(0.25),
              ),
            ),
            child: Text(
              nativeBelow,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                color: Color(0xFF00695C),
                fontWeight: FontWeight.w700,
                height: 1.4,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        // ── 拼音 + 显隐切換 (word + phrase mode) ─────────────────
        if (_practiceType == 0 || _practiceType == 1)
          SizedBox(
            height: 22,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (!_hideRomanization)
                  _loadingRoman
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 1.5))
                      : Text(
                          _practiceType == 1
                              ? (_phraseQuestionRoman ?? '')
                              : (_romanization ?? ''),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade600,
                            fontStyle: FontStyle.italic,
                            letterSpacing: 0.5,
                          ),
                        ),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: _toggleHideRomanization,
                  child: Icon(
                    _hideRomanization
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 15,
                    color: Colors.grey.shade400,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // ── 模式 B 主显示区（翻译语言）→按钮在上，文字框全宽 ────────
  Widget _buildChineseDisplay() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── 按钮行：« / » ──────────────────────────────────────
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            NavButton(
              isPrev: true,
              enabled: _canGoPrev,
              onPressed: _canGoPrev ? _pickPrev : null,
            ),
            const SizedBox(width: 32),
            NavButton(
              isPrev: false,
              enabled: _canGoNext,
              onPressed: _canGoNext ? _pickNext : null,
            ),
          ],
        ),
        const SizedBox(height: 10),
        // ── 翻译语言文字框（全宽）──────────────────────────────
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          decoration: BoxDecoration(
            color: const Color(0xFF00695C).withOpacity(0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: const Color(0xFF00695C).withOpacity(0.25)),
          ),
          child: Text(
            _phraseQuestionText ?? _current?.nameNative ?? '—',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: _phraseQuestionText != null ? 16 : 28,
              color: const Color(0xFF00695C),
              fontWeight: FontWeight.w700,
              letterSpacing: _phraseQuestionText != null ? 0.5 : 2,
              height: 1.4,
            ),
          ),
        ),
        if (!_quizMode && _talkMode) ...[
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              PlayButton(
                playing: _playing,
                onPressed: (_current != null && !_talkRecording && !_talkScoring)
                    ? _togglePlayTranslateReference
                    : null,
              ),
            ],
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) return _buildContent();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        title: Text(
          L10n(AppLangNotifier().uiLang).appTitle,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: _buildContent(),
    );
  }
}

// (Widget classes moved to practice_widgets.dart and lesson_picker_dialog.dart)

