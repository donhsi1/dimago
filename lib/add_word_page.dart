import 'package:flutter/material.dart';
import 'database_helper.dart';
import 'translate_service.dart';
import 'edge_tts_service.dart';
import 'language_prefs.dart';
import 'recording_dialog.dart';

class AddWordPage extends StatefulWidget {
  const AddWordPage({super.key});

  @override
  State<AddWordPage> createState() => _AddWordPageState();
}

class _AddWordPageState extends State<AddWordPage> {
  final TextEditingController _chineseCtrl = TextEditingController();
  final TextEditingController _thaiCtrl    = TextEditingController();

  bool _translating = false;
  bool _saving      = false;
  String? _statusMsg;
  bool _statusOk    = false;

  // TTS
  final EdgeTTSService _tts = EdgeTTSService();
  bool _playing = false;

  // 类别
  List<CategoryEntry> _categories     = [];
  int?                _selectedCategoryId;
  final TextEditingController _newCatCtrl = TextEditingController();
  bool _addingNewCat = false;

  // 音频路径
  String? _audioTranslationPath;
  String? _audioNativePath;

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    final cats = await DatabaseHelper.getAllCategories();
    if (mounted) {
      setState(() {
        _categories = cats;
        if (_selectedCategoryId == null && cats.isNotEmpty) {
          _selectedCategoryId = cats.first.id;
        }
      });
    }
  }

  // ── 翻译 ────────────────────────────────────────────────────
  Future<void> _translate() async {
    final l    = L10n(AppLangNotifier().uiLang);
    final isEn = l.isEn;
    final isTW = l.isZhTW;
    final text = _chineseCtrl.text.trim();
    if (text.isEmpty) {
      _setStatus(
        isEn ? 'Please enter text first'
             : (isTW ? '請先輸入文字' : '请先输入文字'),
        ok: false,
      );
      return;
    }
    setState(() {
      _translating = true;
      _statusMsg   = isEn ? 'Translating…' : (isTW ? '翻譯中…' : '翻译中…');
      _thaiCtrl.clear();
      _playing = false;
    });
    await _tts.stop();

    final result = await TranslateService.chineseToThai(text);
    setState(() {
      _translating = false;
      if (result != null) {
        _thaiCtrl.text = result;
        _statusMsg     = null;
      } else {
        _statusMsg = isEn ? 'Translation failed. Check network.'
                          : (isTW ? '翻譯失敗，請檢查網路' : '翻译失败，请检查网络');
        _statusOk  = false;
      }
    });

    if (result != null && result.isNotEmpty) await _speakThai(result);
  }

  // ── TTS ─────────────────────────────────────────────────────
  Future<void> _speakThai(String text) async {
    if (text.isEmpty) return;
    await _tts.stop();
    setState(() => _playing = true);
    await _tts.speak(text, onDone: () {
      if (mounted) setState(() => _playing = false);
    });
  }

  Future<void> _togglePlay() async {
    final text = _thaiCtrl.text.trim();
    if (text.isEmpty) return;
    if (_playing) {
      await _tts.stop();
      setState(() => _playing = false);
    } else {
      await _speakThai(text);
    }
  }

  // ── 录音 ─────────────────────────────────────────────────────
  Future<void> _recordTranslation() async {
    final l    = L10n(AppLangNotifier().uiLang);
    final isEn = l.isEn;
    final path = await showRecordingDialog(
      context,
      title: isEn ? 'Record Translation Audio' : '录制翻译发音',
    );
    if (path != null && mounted) {
      setState(() => _audioTranslationPath = path);
      _setStatus(
        isEn ? '✓ Translation audio saved' : '✓ 翻译发音已保存',
        ok: true,
      );
    }
  }

  Future<void> _recordNative() async {
    final l    = L10n(AppLangNotifier().uiLang);
    final isEn = l.isEn;
    final path = await showRecordingDialog(
      context,
      title: '',
    );
    if (path != null && mounted) {
      setState(() => _audioNativePath = path);
      _setStatus(
        isEn ? '✓ Native audio saved' : '✓ 母语发音已保存',
        ok: true,
      );
    }
  }

  // ── 类别 ─────────────────────────────────────────────────────
  Future<void> _createNewCategory() async {
    final name = _newCatCtrl.text.trim();
    if (name.isEmpty) return;

    // Translate category name to learn language via Google Translate
    final learnLang = AppLangNotifier().targetLang;
    String learnTranslation = name;
    try {
      final translated = await TranslateService.translate(
          name, targetLang: learnLang);
      if (translated != null && translated.isNotEmpty) {
        learnTranslation = translated;
      }
    } catch (_) {}

    final id = await DatabaseHelper.insertCategoryWithTranslation(
        name, learnTranslation);

    if (id > 0) {
      await _loadCategories();
      setState(() {
        _selectedCategoryId = id;
        _addingNewCat       = false;
        _newCatCtrl.clear();
      });
    } else {
      final existing = _categories.firstWhere(
        (c) => c.name.toLowerCase() == name.toLowerCase(),
        orElse: () => _categories.first,
      );
      setState(() {
        _selectedCategoryId = existing.id;
        _addingNewCat       = false;
        _newCatCtrl.clear();
      });
    }
  }

  // ── 保存 ─────────────────────────────────────────────────────
  Future<void> _addToDictionary() async {
    final l       = L10n(AppLangNotifier().uiLang);
    final isEn    = l.isEn;
    final isTW    = l.isZhTW;
    final chinese = _chineseCtrl.text.trim(); // native lang text
    final thai    = _thaiCtrl.text.trim();    // learn lang text

    if (chinese.isEmpty || thai.isEmpty) {
      _setStatus(
        isEn ? 'Both fields are required'
             : (isTW ? '兩個欄位均不能為空' : '两个字段均不能为空'),
        ok: false,
      );
      return;
    }

    // Resolve category name for duplicate check
    String catNameForCheck = '';
    if (_selectedCategoryId != null) {
      final cat = _categories.firstWhere(
        (c) => c.id == _selectedCategoryId,
        orElse: () => CategoryEntry(name: ''),
      );
      catNameForCheck = cat.name;
    }

    final dup = await DatabaseHelper.exists(thai, chinese, catNameForCheck);
    if (dup) {
      _setStatus(
        isEn ? 'This entry already exists'
             : (isTW ? '該組合已存在' : '该组合已存在'),
        ok: false,
      );
      return;
    }

    setState(() => _saving = true);
    final id = await DatabaseHelper.insert(
      thai,   // word = learn lang
      chinese, // translation = native lang
      nativeCategoryId:  _selectedCategoryId,
      learnCategoryId:   _selectedCategoryId,
      audioTranslation:  _audioTranslationPath,
      audioNative:       _audioNativePath,
    );

    setState(() {
      _saving = false;
      if (id > 0) {
        _setStatus(
          isEn ? '✓ Added to dictionary'
               : (isTW ? '✓ 已新增到詞典' : '✓ 已添加到词典'),
          ok: true,
        );
        _chineseCtrl.clear();
        _thaiCtrl.clear();
        _audioTranslationPath = null;
        _audioNativePath      = null;
        _playing              = false;
      } else {
        _setStatus(
          isEn ? 'Entry already exists'
               : (isTW ? '該記錄已存在' : '该记录已存在'),
          ok: false,
        );
      }
    });

    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _statusMsg = null);
    });
  }

  void _setStatus(String msg, {bool ok = false}) =>
      setState(() { _statusMsg = msg; _statusOk = ok; });

  @override
  void dispose() {
    _tts.dispose();
    _chineseCtrl.dispose();
    _thaiCtrl.dispose();
    _newCatCtrl.dispose();
    super.dispose();
  }

  // ── 录音指示器 ────────────────────────────────────────────────
  Widget _recordIndicator(String? path, String label) {
    if (path == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          const Icon(Icons.fiber_manual_record, size: 10, color: Colors.green),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(fontSize: 11, color: Colors.green)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l    = L10n(AppLangNotifier().uiLang);
    final isEn = l.isEn;
    final isTW = l.isZhTW;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        title: Text(l.addWordTitle,
            style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [

            // ── 母语输入行 ──────────────────────────────────────
            Text(isEn ? 'Native (Chinese)' : (isTW ? '母語（中文）' : '母语（中文）'),
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _chineseCtrl,
                    decoration: InputDecoration(
                      hintText: isEn ? 'Enter text…' : (isTW ? '輸入文字…' : '输入文字…'),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 14),
                    ),
                    onSubmitted: (_) => _translate(),
                  ),
                ),
                const SizedBox(width: 8),
                // 翻译按钮
                SizedBox(
                  width: 48,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _translating ? null : _translate,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1565C0),
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    child: _translating
                        ? const SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Text('›',
                            style: TextStyle(
                                fontSize: 26, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 8),
                // 母语录音按钮
                SizedBox(
                  width: 48,
                  height: 50,
                  child: Tooltip(
                    message: isEn ? 'Record native audio' : '录制母语发音',
                    child: ElevatedButton(
                      onPressed: _recordNative,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _audioNativePath != null
                            ? Colors.green
                            : const Color(0xFF546E7A),
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: Icon(
                        _audioNativePath != null
                            ? Icons.mic_rounded
                            : Icons.mic_none_rounded,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            _recordIndicator(
              _audioNativePath,
              isEn ? 'Native audio recorded' : '已录制母语发音',
            ),

            const SizedBox(height: 16),

            // ── 翻译结果行（可编辑）─────────────────────────────
            Text(isEn ? 'Translation (Thai)' : 'ภาษาไทย (แปล)',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _thaiCtrl,
                    // ★ 可编辑
                    decoration: InputDecoration(
                      hintText: isEn
                          ? 'Translation result (editable)…'
                          : (isTW ? '翻譯結果（可編輯）…' : '翻译结果（可编辑）…'),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 14),
                    ),
                    style: const TextStyle(
                        fontSize: 18, color: Color(0xFF1565C0)),
                  ),
                ),
                const SizedBox(width: 8),
                // TTS 播放按钮
                SizedBox(
                  width: 48,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _thaiCtrl.text.isNotEmpty ? _togglePlay : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _playing
                          ? const Color(0xFFB71C1C)
                          : const Color(0xFF2E7D32),
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.zero,
                      shape: const CircleBorder(),
                      elevation: 2,
                    ),
                    child: Icon(
                      _playing ? Icons.stop_rounded : Icons.volume_up_rounded,
                      size: 22, color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // 翻译录音按钮
                SizedBox(
                  width: 48,
                  height: 50,
                  child: Tooltip(
                    message: isEn ? 'Record translation audio' : '录制翻译发音',
                    child: ElevatedButton(
                      onPressed: _recordTranslation,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _audioTranslationPath != null
                            ? Colors.green
                            : const Color(0xFF546E7A),
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: Icon(
                        _audioTranslationPath != null
                            ? Icons.mic_rounded
                            : Icons.mic_none_rounded,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            _recordIndicator(
              _audioTranslationPath,
              isEn ? 'Translation audio recorded' : '已录制翻译发音',
            ),

            // ── 状态提示 ──────────────────────────────────────
            if (_statusMsg != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _statusMsg!,
                  style: TextStyle(
                    color: _statusOk ? Colors.green : Colors.redAccent,
                    fontSize: 14,
                  ),
                ),
              ),

            const SizedBox(height: 16),

            // ── 确定按钮（整行）──────────────────────────────
            SizedBox(
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _addToDictionary,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2E7D32),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                icon: _saving
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.check_rounded, size: 20),
                label: Text(
                  isEn ? 'Confirm' : (isTW ? '確認' : '确认'),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
            ),

            const SizedBox(height: 20),

            // ── 类别选择 ─────────────────────────────────────
            Text(isEn ? 'Category' : (isTW ? '類別' : '类别'),
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            if (!_addingNewCat)
              Row(
                children: [
                  Expanded(
                    child: _categories.isEmpty
                        ? Text(
                            isEn ? 'No categories'
                                 : (isTW ? '暫無類別' : '暂无类别'),
                            style: const TextStyle(color: Colors.grey),
                          )
                        : DropdownButtonFormField<int>(
                            value: _selectedCategoryId,
                            decoration: InputDecoration(
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8)),
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 12),
                            ),
                            items: _categories
                                .map((c) => DropdownMenuItem(
                                      value: c.id,
                                      child: Text(c.name),
                                    ))
                                .toList(),
                            onChanged: (v) =>
                                setState(() => _selectedCategoryId = v),
                          ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () => setState(() => _addingNewCat = true),
                    icon: const Icon(Icons.add_circle_outline,
                        color: Color(0xFF1565C0)),
                    label: Text(
                      isEn ? 'New' : (isTW ? '新建' : '新建'),
                      style: const TextStyle(color: Color(0xFF1565C0)),
                    ),
                  ),
                ],
              )
            else
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _newCatCtrl,
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: isEn ? 'New category name…'
                                       : (isTW ? '輸入新類別名稱…' : '输入新类别名称…'),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8)),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 12),
                      ),
                      onSubmitted: (_) => _createNewCategory(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _createNewCategory,
                    child: Text(l.confirm,
                        style:
                            const TextStyle(color: Color(0xFF1565C0))),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      _addingNewCat = false;
                      _newCatCtrl.clear();
                    }),
                    child: Text(l.cancel,
                        style: const TextStyle(color: Colors.grey)),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
