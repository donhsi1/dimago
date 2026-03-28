import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'database_helper.dart';
import 'lang_db_service.dart';
import 'translate_service.dart';
import 'edge_tts_service.dart';
import 'language_prefs.dart';

// ── 练习页偏好设→key ─────────────────────────────────────────
class _PracticePrefs {
  static const modeKey = 'practice_mode'; // 0 = 泰→→ 1 = 中→→'
}

// ── 练习模式 ──────────────────────────────────────────────────
enum _PracticeMode {
  thaiToChinese, // 显示泰语，选中文（模式 A，原有）
  chineseToThai, // 显示中文，选泰语（模式 B，新增）
}

// ── 每道题选项状→─────────────────────────────────────────────
enum _AnswerState { idle, correct, wrong }

// ── 单道题的选项数据 ───────────────────────────────────────────
class _QuizOption {
  final String srcText;  // 源语言（学习语言→'
  final String dstText;  // 翻译语言
  final bool isCorrect;
  _AnswerState state = _AnswerState.idle;
  String? romanization; // 源语言罗马拼音（模式B使用→'

  _QuizOption({
    required this.srcText,
    required this.dstText,
    required this.isCorrect,
  });
}

class PracticePage extends StatefulWidget {
  /// embedded=true：不渲染外层 Scaffold（供主页直接嵌入→'
  final bool embedded;
  const PracticePage({super.key, this.embedded = false});

  @override
  State<PracticePage> createState() => PracticePageState();
}

class PracticePageState extends State<PracticePage> {
  /// 从外部（如词→添加词典 pop 后）调用，重新加载词典数→'
  Future<void> reload() => _loadPrefsAndData();
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

  // 图片（当前词条对应的英文名称，来→dict_photo.db→'
  String? _wordPhotoName;   // English name →used to find/download <name>.png
  Uint8List? _wordPhotoBytes; // resolved bytes (null until image button clicked)
  bool _showPhoto = false;  // whether photo is shown
  bool _photoLoading = false; // downloading in progress

  // 提示文字（来→learnDb.word.hint→'
  String? _hintText;        // hint text for current word
  bool _showHint = false;   // whether hint text box is expanded

  // TTS
  final EdgeTTSService _tts = EdgeTTSService();
  bool _playing = false;
  // 记录当前正在播放哪个选项（模→B 专用），null = 未播→'
  int? _playingOptionIndex;

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
    final catId = await SharedCategoryPrefs.load();

    final list = await DatabaseHelper.getAll();
    final cats = await DatabaseHelper.getAllCategories();

      if (mounted) {
      setState(() {
        _allEntries = list;
        _categories = cats;
        _mode = modeIndex == 1
            ? _PracticeMode.chineseToThai
            : _PracticeMode.thaiToChinese;
        // 验证保存→catId 是否仍有效（类别可能已被删除→999 表示收藏，始终有效）
        if (catId != null &&
            (catId == _kFavoriteId || cats.any((c) => c.id == catId))) {
          _selectedCategoryId = catId;
        } else {
          _selectedCategoryId = null;
        }
        _loading = false;
        _updatePool();
      });
      if (_poolEntries.isNotEmpty) {
        _pickNext(autoPlay: false);
      } else {
        setState(() { _wordPhotoName = null; _wordPhotoBytes = null; _showPhoto = false; _photoLoading = false; _hintText = null; _showHint = false; });
      }
    }
  }

  static const _kFavoriteId = -999; // 收藏筛选标→'

  void _updatePool() {
    List<DictionaryEntry> raw;
    if (_selectedCategoryId == _kFavoriteId) {
      raw = _allEntries.where((e) => e.isFavorite).toList();
    } else if (_selectedCategoryId == null) {
      raw = List.of(_allEntries);
    } else {
      raw = _allEntries
          .where((e) => e.categoryId == _selectedCategoryId)
          .toList();
    }
    _poolEntries = raw;
  }

  DictionaryEntry? get _current =>
      (_history.isEmpty || _historyIndex < 0) ? null : _history[_historyIndex];

  // ── 罗马拼音 ──────────────────────────────────────────────────
  Future<void> _fetchRomanization(String thai) async {
    setState(() {
      _romanization = null;
      _loadingRoman = true;
    });
    final roman = await TranslateService.getThaiRomanization(thai);
    if (mounted) {
      setState(() {
        _romanization = roman;
        _loadingRoman = false;
      });
    }
  }

  // ── 图片 & 提示加载 ───────────────────────────────────────────
  /// Called when a new word is shown. Fetches hint text (cheap) and photo name
  /// from DB. Image bytes are only downloaded when user taps the image button.
  Future<void> _loadPhoto(int? wordId) async {
    if (!mounted) return;
    setState(() {
      _wordPhotoName = null;
      _wordPhotoBytes = null;
      _showPhoto = false;
      _photoLoading = false;
      _hintText = null;
      _showHint = false;
    });
    if (wordId == null) return;
    // parallel: fetch hint text and photo name simultaneously
    final results = await Future.wait([
      DatabaseHelper.getWordHint(wordId),
      DatabaseHelper.getWordPhotoName(wordId),
    ]);
    if (mounted) {
      setState(() {
        _hintText = results[0];        // String? hint
        _wordPhotoName = results[1];   // String? photo english name
      });
    }
  }

  /// Called when user taps the photo icon button. Resolves image bytes lazily:
  /// 1. Check local sandbox file; 2. Download from GitHub if needed.
  Future<void> _onPhotoTap() async {
    if (_wordPhotoName == null) return;
    if (_showPhoto) {
      setState(() => _showPhoto = false);
      return;
    }
    if (_wordPhotoBytes != null) {
      setState(() => _showPhoto = true);
      return;
    }
    setState(() { _photoLoading = true; _showPhoto = true; });
    final bytes = await LangDbService.resolvePhotoImage(_wordPhotoName!);
    if (mounted) {
      setState(() {
        _wordPhotoBytes = bytes;
        _photoLoading = false;
        _showPhoto = bytes != null;
      });
    }
  }

  // ── 生成选项 ───────────────────────────────────────────────────
  void _buildOptions(DictionaryEntry correct) {
    final targetLang = AppLangNotifier().targetLang;
    final nativeLang = AppLangNotifier().nativeLang;
    final correctSrc = correct.srcText(targetLang);
    final correctDst = correct.dstText(nativeLang);

    final wrongEntries = <DictionaryEntry>[];

    if (_poolEntries.length >= 3) {
      final pool = _poolEntries.where((e) => e.id != correct.id).toList()
        ..shuffle(_rng);
      for (final e in pool) {
        if (!wrongEntries.any((w) => w.dstText(nativeLang) == e.dstText(nativeLang)) &&
            e.dstText(nativeLang) != correctDst) {
          wrongEntries.add(e);
          if (wrongEntries.length == 2) break;
        }
      }
    }

    if (wrongEntries.length < 2) {
      final pool = _allEntries.where((e) => e.id != correct.id).toList()
        ..shuffle(_rng);
      for (final e in pool) {
        if (!wrongEntries.any((w) => w.dstText(nativeLang) == e.dstText(nativeLang)) &&
            e.dstText(nativeLang) != correctDst) {
          wrongEntries.add(e);
          if (wrongEntries.length == 2) break;
        }
      }
    }

    while (wrongEntries.length < 2) {
      wrongEntries.add(DictionaryEntry(word: '', translation: '→'));
    }

    final options = [
      _QuizOption(srcText: correctSrc, dstText: correctDst, isCorrect: true),
      _QuizOption(srcText: wrongEntries[0].srcText(targetLang), dstText: wrongEntries[0].dstText(nativeLang), isCorrect: false),
      _QuizOption(srcText: wrongEntries[1].srcText(targetLang), dstText: wrongEntries[1].dstText(nativeLang), isCorrect: false),
    ]..shuffle(_rng);

    setState(() {
      _options = options;
      _answered = false;
      _firstAttempt = true;
      _playingOptionIndex = null;
    });

    // 模式 B：异步获取每个选项的罗马拼音（仅当源语言是泰语时→'
    if (_mode == _PracticeMode.chineseToThai) {
      _fetchOptionRomanizations(options);
    }
  }

  // 异步为模式B选项获取罗马拼音，逐个回填（仅源语言是泰语时有效→'
  Future<void> _fetchOptionRomanizations(List<_QuizOption> opts) async {
    if (AppLangNotifier().targetLang != 'th') return;
    for (int i = 0; i < opts.length; i++) {
      final opt = opts[i];
      if (opt.srcText.isEmpty) continue;
      final roman = await TranslateService.getThaiRomanization(opt.srcText);
      if (!mounted) return;
      if (_options.length > i && _options[i] == opt) {
        setState(() => _options[i].romanization = roman);
      }
    }
  }

  // ── 自动播放当前源语言（仅模式 A）─────────────────────────────
  Future<void> _autoPlay() async {
    if (_mode == _PracticeMode.chineseToThai) return; // 模式 B 不自动播→'
    if (_current == null) return;
    await _tts.stop();
    setState(() => _playing = true);
    final targetLang = AppLangNotifier().targetLang;
    await _tts.speak(_current!.srcText(targetLang),
        wordId: _current!.id, onDone: () {
      if (mounted) setState(() => _playing = false);
    });
  }

  // ── 下一→─────────────────────────────────────────────────────
  void _pickNext({bool autoPlay = true}) {
    if (_poolEntries.isEmpty) return;

    if (_historyIndex < _history.length - 1) {
      setState(() => _historyIndex++);
      final entry = _history[_historyIndex];
      _buildOptions(entry);
      if (autoPlay) _autoPlay();
      if (_mode == _PracticeMode.thaiToChinese) _fetchRomanization(entry.srcText(AppLangNotifier().targetLang));
      _loadPhoto(entry.id);
      return;
    }

    DictionaryEntry next;
    if (_poolEntries.length == 1) {
      next = _poolEntries[0];
    } else {
      do {
        next = _poolEntries[_rng.nextInt(_poolEntries.length)];
      } while (next.id == _current?.id);
    }

    setState(() {
      _history.add(next);
      _historyIndex = _history.length - 1;
    });
    _buildOptions(next);
    if (autoPlay) _autoPlay();
    if (_mode == _PracticeMode.thaiToChinese) _fetchRomanization(next.srcText(AppLangNotifier().targetLang));
    _loadPhoto(next.id);
  }

  // ── 上一→─────────────────────────────────────────────────────
  void _pickPrev() {
    if (_historyIndex <= 0) return;
    setState(() => _historyIndex--);
    final entry = _history[_historyIndex];
    _buildOptions(entry);
    _autoPlay();
    if (_mode == _PracticeMode.thaiToChinese) _fetchRomanization(entry.srcText(AppLangNotifier().targetLang));
    _loadPhoto(entry.id);
  }

  bool get _canGoPrev => _historyIndex > 0;
  bool get _canGoNext => _poolEntries.isNotEmpty;

  // ── 播放/停止（模→A 主显示区按钮）────────────────────────────
  Future<void> _togglePlay() async {
    if (_current == null) return;
    if (_playing) {
      await _tts.stop();
      setState(() => _playing = false);
    } else {
      setState(() => _playing = true);
      final targetLang = AppLangNotifier().targetLang;
      await _tts.speak(_current!.srcText(targetLang),
          wordId: _current!.id, onDone: () {
        if (mounted) setState(() => _playing = false);
      });
    }
  }

  // ── 模式 B：点击某选项旁的播放按钮──────────────────────────────
  Future<void> _playOption(int index) async {
    final src = _options[index].srcText;
    if (src.isEmpty) return;

    await _tts.stop();

    if (_playingOptionIndex == index) {
      setState(() => _playingOptionIndex = null);
      return;
    }

    setState(() => _playingOptionIndex = index);
    await _tts.speak(src, onDone: () {
      if (mounted) setState(() => _playingOptionIndex = null);
    });
  }

  // ── 选择答案 ───────────────────────────────────────────────────
  void _selectOption(int index) async {
    if (_answered) return;

    final chosen = _options[index];
    if (chosen.isCorrect) {
      // 停止正在播放的选项音频
      await _tts.stop();
      setState(() {
        _answered = true;
        chosen.state = _AnswerState.correct;
        _playingOptionIndex = null;
        _playing = false;
      });

      if (_firstAttempt && _current != null && _current!.id != null) {
        await DatabaseHelper.incrementCorrectCount(_current!.id!);
        // First attempt correct: play audio then go next after audio finishes
        final targetLang = AppLangNotifier().targetLang;
        setState(() => _playing = true);
        await _tts.speak(_current!.srcText(targetLang),
            wordId: _current!.id, onDone: () {
          if (mounted) {
            setState(() => _playing = false);
            _pickNext();
          }
        });
      } else {
        // Not first attempt: play audio then go next after audio finishes
        if (_current != null) {
          final targetLang = AppLangNotifier().targetLang;
          setState(() => _playing = true);
          await _tts.speak(_current!.srcText(targetLang),
              wordId: _current!.id, onDone: () {
            if (mounted) {
              setState(() => _playing = false);
              _pickNext();
            }
          });
        } else {
          _pickNext();
        }
      }
    } else {
      setState(() {
        _firstAttempt = false;
        chosen.state = _AnswerState.wrong;
      });

      // 模式 A 答错：播放所选错误项的源语言
      if (_mode == _PracticeMode.thaiToChinese && chosen.srcText.isNotEmpty) {
        await _tts.stop();
        setState(() => _playing = true);
        await _tts.speak(chosen.srcText, onDone: () {
          if (mounted) setState(() => _playing = false);
        });
      }
      // 模式 B 答错：播放所选错误项对应的翻译语言发音
      if (_mode == _PracticeMode.chineseToThai && chosen.dstText.isNotEmpty) {
        await _tts.speakChinese(chosen.dstText, onDone: () {
          if (mounted) setState(() => _playing = false);
        });
      }
    }
  }

  String _categoryLabel(int? catId, L10n l) {
    if (catId == null) {
      return '${l.practiceAll} (${_poolCountForCat(null)})';
    }
    if (catId == _kFavoriteId) {
      return '${l.practiceFavorite} (${_poolCountForCat(_kFavoriteId)})';
    }
    final cat = _categories.firstWhere(
      (c) => c.id == catId,
      orElse: () => CategoryEntry(name: ''),
    );
    if (cat.name.isEmpty) return '${l.practiceAll} (${_poolCountForCat(null)})';
    final count = _allEntries.where((e) => e.categoryId == catId).length;
    return '${l.translateCategory(cat.name)} ($count)';
  }

  int _poolCountForCat(int? catId) {
    if (catId == _kFavoriteId) return _allEntries.where((e) => e.isFavorite).length;
    if (catId == null) return _allEntries.length;
    return _allEntries.where((e) => e.categoryId == catId).length;
  }


  void _toggleMode() async {
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
    });
    _tts.stop();
    if (_current != null) {
      _buildOptions(_current!);
      if (_mode == _PracticeMode.thaiToChinese) {
        _autoPlay();
        _fetchRomanization(_current!.srcText(AppLangNotifier().targetLang));
      }
    }
  }

  // ── 切换类别 ───────────────────────────────────────────────────
  void _onCategoryChanged(int? catId) async {
    await SharedCategoryPrefs.save(catId);

    setState(() {
      _selectedCategoryId = catId;
      _updatePool();
      _history.clear();
      _historyIndex = -1;
      _options = [];
      _romanization = null;
      _playing = false;
      _playingOptionIndex = null;
      _wordPhotoName = null;
      _wordPhotoBytes = null;
      _showPhoto = false;
      _photoLoading = false;
      _hintText = null;
      _showHint = false;
    });
    _tts.stop();
    if (_poolEntries.isNotEmpty) _pickNext();
  }

  @override
  void dispose() {
    _tts.dispose();
    super.dispose();
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

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 顶部行：模式切换 + 类别选择 ─────────────────────────
          Row(
            children: [
              // 模式切换 toggle
              _ModeToggle(
                isModeB: isModeB,
                onToggle: _toggleMode,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButton<int?>(
                  value: _selectedCategoryId,
                  isExpanded: true,
                  underline: const SizedBox(),
                  menuMaxHeight: 8 * 48.0,
                  style: const TextStyle(
                      fontSize: 14,
                      color: Color(0xFF1565C0),
                      fontWeight: FontWeight.w500),
                  icon: const Icon(Icons.keyboard_arrow_down,
                      color: Color(0xFF1565C0)),
                  items: [
                    DropdownMenuItem<int?>(
                      value: null,
                      child: Text(
                        _categoryLabel(null, l),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DropdownMenuItem<int?>(
                      value: _kFavoriteId,
                      child: Text(
                        _categoryLabel(_kFavoriteId, l),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    ..._categories.map((c) => DropdownMenuItem<int?>(
                          value: c.id,
                          child: Text(
                            _categoryLabel(c.id, l),
                            overflow: TextOverflow.ellipsis,
                          ),
                        )),
                  ],
                  onChanged: _onCategoryChanged,
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // ── 主显示区 ──────────────────────────────────────────
          if (isModeB)
            // 模式 B：显示中→'
            _buildChineseDisplay()
          else
            // 模式 A：显示泰→'+ 拼音 + 播放
            _buildThaiDisplay(),

          const SizedBox(height: 20),

          // ── 词条不足提示 ──────────────────────────────────────
          if (_poolEntries.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                l.practiceCatEmpty,
                textAlign: TextAlign.center,
                style:
                    TextStyle(color: Colors.orange.shade700, fontSize: 14),
              ),
            ),

          // ── 选择题区 ─────────────────────────────────────────
          if (_options.isNotEmpty) ...[
            const SizedBox(height: 4),
            ..._options.asMap().entries.map((entry) {
              final i = entry.key;
              final opt = entry.value;
              if (isModeB) {
                // 模式 B：显示泰语选项 + 右侧播放按钮
                return _ThaiOptionTile(
                  thai: opt.srcText,
                  romanization: opt.romanization,
                  state: opt.state,
                  isPlayingThis: _playingOptionIndex == i,
                  onTap: _answered ? null : () => _selectOption(i),
                  onPlay: () => _playOption(i),
                );
              } else {
                // 模式 A：显示中文选项
                return _ChineseOptionTile(
                  chinese: opt.dstText,
                  state: opt.state,
                  onTap: _answered ? null : () => _selectOption(i),
                );
              }
            }),
          ],

          // ── 提示文字框（始终显示提示按钮，点击展开时显示内容）──────────────
          if (true) ...[
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.amber.shade300, width: 1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 提示文字（展开时显示）
                  AnimatedCrossFade(
                    duration: const Duration(milliseconds: 200),
                    crossFadeState: _showHint
                        ? CrossFadeState.showSecond
                        : CrossFadeState.showFirst,
                    firstChild: const SizedBox.shrink(),
                    secondChild: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                      child: Text(
                        _hintText ?? '暂无提示',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.amber.shade900,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
                  // 提示按钮行（左下角）
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 2, 6, 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: 30,
                          child: TextButton.icon(
                            onPressed: () =>
                                setState(() => _showHint = !_showHint),
                            icon: Icon(
                              _showHint
                                  ? Icons.lightbulb
                                  : Icons.lightbulb_outline,
                              size: 15,
                              color: Colors.amber.shade700,
                            ),
                            label: Text(
                              '提示',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.amber.shade800,
                              ),
                            ),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 0),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],

          // ── 图片显示区（固定窗口，按钮在左上角）
          if (_wordPhotoName != null) ...[
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (ctx, constraints) {
                final imgW = constraints.maxWidth * 0.8; // 4/5 宽度
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 图片按钮（左上角，始终可见）
                    SizedBox(
                      height: 30,
                      child: TextButton.icon(
                        onPressed: _onPhotoTap,
                        icon: _photoLoading
                            ? const SizedBox(
                                width: 13,
                                height: 13,
                                child: CircularProgressIndicator(
                                    strokeWidth: 1.5),
                              )
                            : Icon(
                                _showPhoto
                                    ? Icons.image
                                    : Icons.image_outlined,
                                size: 15,
                                color: const Color(0xFF1565C0),
                              ),
                        label: const Text(
                          '图片',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF1565C0),
                          ),
                        ),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 0),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ),
                    // 图片内容（固定窗口，始终显示容器→'
                    const SizedBox(height: 4),
                    Container(
                      width: imgW,
                      height: imgW * 0.6, // 固定高度
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: Colors.grey.shade300, width: 1),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: !_showPhoto
                          ? Center(
                              child: Text(
                                '点击上方按钮显示图片',
                                style: TextStyle(
                                  color: Colors.grey.shade400,
                                  fontSize: 12,
                                ),
                              ),
                            )
                          : _photoLoading
                              ? const Padding(
                                  padding: EdgeInsets.all(32),
                                  child: Center(
                                      child: CircularProgressIndicator()),
                                )
                              : _wordPhotoBytes != null
                                  ? Image.memory(
                                      _wordPhotoBytes!,
                                      width: imgW,
                                      fit: BoxFit.contain,
                                      gaplessPlayback: true,
                                    )
                                  : Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: Text(
                                        '图片加载失败',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                            color: Colors.grey.shade500,
                                            fontSize: 13),
                                      ),
                                    ),
                    ),
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }


  // ── 模式 A 主显示区（源语言 + 拼音）→按钮在上，文字框全宽 ──
  Widget _buildThaiDisplay() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── 按钮行：« / 播放 / » ────────────────────────────────
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _NavButton(
              isPrev: true,
              enabled: _canGoPrev,
              onPressed: _canGoPrev ? _pickPrev : null,
            ),
            const SizedBox(width: 16),
            _PlayButton(
              playing: _playing,
              onPressed: _current != null ? _togglePlay : null,
            ),
            const SizedBox(width: 16),
            _NavButton(
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
            _current?.srcText(AppLangNotifier().targetLang) ?? '→',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 26,
              color: Color(0xFF1565C0),
              fontWeight: FontWeight.w600,
              letterSpacing: 1.5,
            ),
          ),
        ),
        // ── 拼音→─────────────────────────────────────────────
        SizedBox(
          height: 22,
          child: _loadingRoman
              ? const Center(
                  child: SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.5)))
              : Text(
                  _romanization ?? '',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                    fontStyle: FontStyle.italic,
                    letterSpacing: 0.5,
                  ),
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
            _NavButton(
              isPrev: true,
              enabled: _canGoPrev,
              onPressed: _canGoPrev ? _pickPrev : null,
            ),
            const SizedBox(width: 32),
            _NavButton(
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
            _current?.dstText(AppLangNotifier().nativeLang) ?? '→',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 28,
              color: Color(0xFF00695C),
              fontWeight: FontWeight.w700,
              letterSpacing: 2,
            ),
          ),
        ),
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

// ── 模式切换 Toggle ────────────────────────────────────────────
class _ModeToggle extends StatelessWidget {
  final bool isModeB;
  final VoidCallback onToggle;

  const _ModeToggle({required this.isModeB, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final l = L10n(AppLangNotifier().uiLang);
    return Tooltip(
      message: isModeB ? l.modeTooltipBtoA : l.modeTooltipAtoB,
      child: GestureDetector(
        onTap: onToggle,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: isModeB
                ? const Color(0xFF00695C)
                : const Color(0xFF1565C0),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isModeB ? 'CN' : 'TH',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 2),
                child: Icon(Icons.arrow_forward,
                    color: Colors.white70, size: 12),
              ),
              Text(
                isModeB ? 'TH' : 'CN',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── 模式 A：中文选项→─────────────────────────────────────────
class _ChineseOptionTile extends StatelessWidget {
  final String chinese;
  final _AnswerState state;
  final VoidCallback? onTap;

  const _ChineseOptionTile({
    required this.chinese,
    required this.state,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    Widget leading;
    Color borderColor;
    Color bgColor;

    switch (state) {
      case _AnswerState.correct:
        leading = Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.red.shade600, width: 2.5),
          ),
        );
        borderColor = Colors.red.shade400;
        bgColor = Colors.red.shade50;
        break;
      case _AnswerState.wrong:
        leading =
            Icon(Icons.close_rounded, color: Colors.grey.shade600, size: 26);
        borderColor = Colors.grey.shade400;
        bgColor = Colors.grey.shade100;
        break;
      case _AnswerState.idle:
        leading = Icon(
          Icons.check_box_outline_blank_rounded,
          color: const Color(0xFF1565C0).withOpacity(0.5),
          size: 26,
        );
        borderColor = const Color(0xFF1565C0).withOpacity(0.2);
        bgColor = Colors.white;
        break;
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor, width: 1.5),
        ),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                chinese,
                style: TextStyle(
                  fontSize: 14,
                  color: state == _AnswerState.correct
                      ? Colors.red.shade700
                      : state == _AnswerState.wrong
                          ? Colors.grey.shade600
                          : Colors.black87,
                  fontWeight: state == _AnswerState.correct
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 模式 B：泰语选项行（含独立播放按钮）──────────────────────
class _ThaiOptionTile extends StatelessWidget {
  final String thai;
  final String? romanization; // 罗马拼音（可能还在加载中→'
  final _AnswerState state;
  final bool isPlayingThis;
  final VoidCallback? onTap; // 点击文字→'= 选择答案
  final VoidCallback onPlay; // 点击播放按钮 = 仅播→'

  const _ThaiOptionTile({
    required this.thai,
    this.romanization,
    required this.state,
    required this.isPlayingThis,
    required this.onTap,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    Widget leading;
    Color borderColor;
    Color bgColor;
    Color textColor;

    switch (state) {
      case _AnswerState.correct:
        leading = Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.red.shade600, width: 2.5),
          ),
        );
        borderColor = Colors.red.shade400;
        bgColor = Colors.red.shade50;
        textColor = Colors.red.shade700;
        break;
      case _AnswerState.wrong:
        leading =
            Icon(Icons.close_rounded, color: Colors.grey.shade600, size: 24);
        borderColor = Colors.grey.shade400;
        bgColor = Colors.grey.shade100;
        textColor = Colors.grey.shade600;
        break;
      case _AnswerState.idle:
        leading = Icon(
          Icons.check_box_outline_blank_rounded,
          color: const Color(0xFF00695C).withOpacity(0.5),
          size: 24,
        );
        borderColor = const Color(0xFF00695C).withOpacity(0.2);
        bgColor = Colors.white;
        textColor = const Color(0xFF00695C);
        break;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor, width: 1.5),
      ),
      child: Row(
        children: [
          // 点击文字区域 = 选择答案
          Expanded(
            child: GestureDetector(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 14),
                child: Row(
                  children: [
                    leading,
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            thai.isEmpty ? '（无可用选项→' : thai,
                            style: TextStyle(
                              fontSize: 14,
                              color: textColor,
                              fontWeight: state == _AnswerState.correct
                                  ? FontWeight.bold
                                  : FontWeight.w500,
                              letterSpacing: 1.0,
                            ),
                          ),
                          if (thai.isNotEmpty && romanization != null)
                            Text(
                              romanization!,
                              style: TextStyle(
                                fontSize: 11,
                                color: textColor.withOpacity(0.65),
                                letterSpacing: 0.5,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 播放按钮（仅→thai 非空时显示）
          if (thai.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: SizedBox(
                width: 38,
                height: 38,
                child: ElevatedButton(
                  onPressed: onPlay,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isPlayingThis
                        ? const Color(0xFFB71C1C)
                        : const Color(0xFF2E7D32),
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.zero,
                    shape: const CircleBorder(),
                    elevation: 1,
                  ),
                  child: Icon(
                    isPlayingThis
                        ? Icons.stop_rounded
                        : Icons.volume_up_rounded,
                    size: 20,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── 导航按钮 ───────────────────────────────────────────────────
class _NavButton extends StatelessWidget {
  /// isPrev=true 显示 « 图标，false 显示 » 图标
  final bool isPrev;
  final bool enabled;
  final VoidCallback? onPressed;

  const _NavButton({
    required this.isPrev,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      height: 52,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor:
              enabled ? const Color(0xFF1565C0) : Colors.grey.shade300,
          foregroundColor:
              enabled ? Colors.white : Colors.grey.shade500,
          padding: EdgeInsets.zero,
          elevation: enabled ? 2 : 0,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: Icon(
          isPrev ? Icons.chevron_left : Icons.chevron_right,
          size: 28,
          color: enabled ? Colors.white : Colors.grey.shade500,
        ),
      ),
    );
  }
}

// ── 播放按钮（模→A 主显示区）────────────────────────────────
class _PlayButton extends StatelessWidget {
  final bool playing;
  final VoidCallback? onPressed;

  const _PlayButton({
    required this.playing,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 52,
      height: 52,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor:
              playing ? const Color(0xFFB71C1C) : const Color(0xFF2E7D32),
          foregroundColor: Colors.white,
          padding: EdgeInsets.zero,
          shape: const CircleBorder(),
          elevation: 2,
        ),
        child: Icon(
          playing ? Icons.stop_rounded : Icons.volume_up_rounded,
          size: 26,
          color: Colors.white,
        ),
      ),
    );
  }
}
