import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'database_helper.dart';
import 'edge_tts_service.dart';
import 'settings_page.dart'; // DictPrefs
import 'language_prefs.dart';

// ── 排序枚举 ──────────────────────────────────────────────────
enum SortField { correctCount, createdAt, lastUsedAt }

enum SortDir { desc, asc }

// ── 筛选模式（category id: null=全部, -999=收藏）─────────────
const _kFavoriteId = -999;

// ── SharedPreferences keys（仅排序，category →SharedCategoryPrefs）──
const _kSortField = 'dict_sort_field';
const _kSortDir = 'dict_sort_dir';

class DictionaryListPage extends StatefulWidget {
  const DictionaryListPage({super.key});

  @override
  State<DictionaryListPage> createState() => _DictionaryListPageState();
}

class _DictionaryListPageState extends State<DictionaryListPage> {
  List<DictionaryEntry> _allEntries = [];
  List<DictionaryEntry> _filtered = [];
  List<CategoryEntry> _categories = [];

  // null = 全部, _kFavoriteId = 收藏, 正整→'= 具体类别
  int? _selectedCategoryId; // null 表示全部，_kFavoriteId 表示收藏

  String _searchText = '';
  bool _loading = true;

  // ── 排序（带持久化）──────────────────────────────────────────
  SortField _sortField = SortField.correctCount;
  SortDir _sortDir = SortDir.desc;

  // ── 热度满格基准 ──────────────────────────────────────────────
  int _maxCorrectCount = DictPrefs.defaultMaxCorrectCount;

  final TextEditingController _searchCtrl = TextEditingController();

  // TTS
  final EdgeTTSService _tts = EdgeTTSService();
  int? _playingId;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  // ── 读取所有持久化设定 ─────────────────────────────────────────
  Future<void> _loadPrefs(SharedPreferences prefs) async {
    // 排序字段
    final fi = prefs.getInt(_kSortField);
    if (fi != null && fi < SortField.values.length) {
      _sortField = SortField.values[fi];
    }
    // 排序方向
    final di = prefs.getInt(_kSortDir);
    if (di != null && di < SortDir.values.length) {
      _sortDir = SortDir.values[di];
    }
    // 类别筛选：与主页面共享
    _selectedCategoryId = await SharedCategoryPrefs.load();
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kSortField, _sortField.index);
    await prefs.setInt(_kSortDir, _sortDir.index);
  }

  Future<void> _loadAll() async {
    final entries = await DatabaseHelper.getAll();
    final cats = await DatabaseHelper.getAllCategories();
    final prefs = await SharedPreferences.getInstance();
    final maxCount =
        prefs.getInt(DictPrefs.maxCorrectCount) ?? DictPrefs.defaultMaxCorrectCount;
    await _loadPrefs(prefs);

    if (mounted) {
      setState(() {
        _allEntries = entries;
        _categories = cats;
        _maxCorrectCount = maxCount;
        _loading = false;

        // Validate saved category id: if it's not in the current category list,
        // or if no entry has that categoryId (e.g. all categoryId==null),
        // fall back to "show all" to avoid a permanently blank list.
        if (_selectedCategoryId != null &&
            _selectedCategoryId != _kFavoriteId) {
          final validCatIds = cats.map((c) => c.id).toSet();
          if (!validCatIds.contains(_selectedCategoryId)) {
            _selectedCategoryId = null;
            SharedCategoryPrefs.save(null);
          }
        }

        _applyFilterAndSort();
      });
    }
  }

  void _applyFilterAndSort() {
    List<DictionaryEntry> list;

    if (_selectedCategoryId == _kFavoriteId) {
      // 收藏筛→'
      list = _allEntries.where((e) => e.isFavorite).toList();
    } else if (_selectedCategoryId != null) {
      // 具体类别
      list = _allEntries.where((e) => e.categoryId == _selectedCategoryId).toList();
      // Safety: if category filter yields nothing but entries exist, fallback to all
      if (list.isEmpty && _allEntries.isNotEmpty) {
        _selectedCategoryId = null;
        SharedCategoryPrefs.save(null);
        list = _allEntries;
      }
    } else {
      // 全部
      list = _allEntries;
    }

    // 搜索
    final q = _searchText.trim();
    if (q.isNotEmpty) {
      list = list
          .where((e) => e.chinese.contains(q) || e.thai.contains(q))
          .toList();
    }

    // 排序
    list.sort((a, b) {
      int cmp;
      switch (_sortField) {
        case SortField.createdAt:
          cmp = (a.createdAt ?? '').compareTo(b.createdAt ?? '');
        case SortField.lastUsedAt:
          cmp = (a.lastUsedAt ?? '').compareTo(b.lastUsedAt ?? '');
        case SortField.correctCount:
          cmp = a.correctCount.compareTo(b.correctCount);
      }
      return _sortDir == SortDir.desc ? -cmp : cmp;
    });

    _filtered = list;
  }

  Future<void> _speak(DictionaryEntry entry) async {
    if (_playingId == entry.id) {
      await _tts.stop();
      setState(() => _playingId = null);
      return;
    }
    await _tts.stop();
    setState(() => _playingId = entry.id);
    if (entry.id != null) await DatabaseHelper.updateLastUsed(entry.id!);
    final targetLang = AppLangNotifier().targetLang;
    // 播放源语言（学习语言）的发音
    await _tts.speak(entry.srcText(targetLang),
        wordId: entry.id, onDone: () {
      if (mounted) setState(() => _playingId = null);
    });
  }

  // ── 切换收藏 ─────────────────────────────────────────────────
  Future<void> _toggleFavorite(DictionaryEntry entry) async {
    if (entry.id == null) return;
    final newFav = await DatabaseHelper.toggleFavorite(entry.id!, entry.isFavorite);
    // 更新本地列表中的该条→'
    final idx = _allEntries.indexWhere((e) => e.id == entry.id);
    if (idx < 0) return;
    final old = _allEntries[idx];
    _allEntries[idx] = DictionaryEntry(
      id: old.id,
      word: old.word,
      translation: old.translation,
      createdAt: old.createdAt,
      lastUsedAt: old.lastUsedAt,
      correctCount: old.correctCount,
      categoryId: old.categoryId,
      categoryName: old.categoryName,
      isFavorite: newFav,
    );
    setState(() => _applyFilterAndSort());
  }

  // ── 修改类别弹窗 ─────────────────────────────────────────────
  Future<void> _showChangeCategoryDialog(DictionaryEntry entry) async {
    int? chosen = entry.categoryId;

    final result = await showDialog<int?>(
      context: context,
      builder: (ctx) {
        final l = L10n(AppLangNotifier().uiLang);
        return StatefulBuilder(
          builder: (ctx, setS) => AlertDialog(
            title: Text(l.dictChangeCat, style: const TextStyle(fontSize: 16)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: _categories
                  .map((cat) => RadioListTile<int?>(
                        dense: true,
                        title: Text(cat.name),
                        value: cat.id,
                        groupValue: chosen,
                        onChanged: (v) => setS(() => chosen = v),
                      ))
                  .toList(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: Text(l.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, chosen),
                child: Text(l.confirm),
              ),
            ],
          ),
        );
      },
    );

    if (result == null) return;
    if (result == entry.categoryId) return;
    if (entry.id == null) return;

    await DatabaseHelper.updateCategoryId(entry.id!, result);
    setState(() => _loading = true);
    await _loadAll();
  }

  // ── 进入排序页面 ──────────────────────────────────────────────
  Future<void> _openSortPage() async {
    final result = await Navigator.push<_SortResult>(
      context,
      MaterialPageRoute(
        builder: (_) => SortPage(
          currentField: _sortField,
          currentDir: _sortDir,
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _sortField = result.field;
        _sortDir = result.dir;
        _applyFilterAndSort();
      });
      _savePrefs();
    }
  }

  String _formatTime(String? iso) {
    if (iso == null || iso.isEmpty) return '→';
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)} '
          '${_pad(dt.hour)}:${_pad(dt.minute)}';
    } catch (_) {
      return iso;
    }
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

  @override
  void dispose() {
    _tts.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // 类别筛选更改时同时保存
  void _setCategory(int? catId) {
    setState(() {
      _selectedCategoryId = catId;
      _applyFilterAndSort();
    });
    SharedCategoryPrefs.save(catId);
  }

  // ── 下拉菜单构建 ──────────────────────────────────────────────
  // 下拉值：null=全部, _kFavoriteId=收藏, 正数=类别id
  String _dropdownLabel(int? id, L10n l) {
    if (id == null) {
      final count = _allEntries.length;
      return '${l.practiceAll} ($count)';
    }
    if (id == _kFavoriteId) {
      final count = _allEntries.where((e) => e.isFavorite).length;
      return '${l.practiceFavorite} ($count)';
    }
    final cat = _categories.firstWhere(
      (c) => c.id == id,
      orElse: () => CategoryEntry(name: ''),
    );
    if (cat.name.isEmpty) return l.practiceAll;
    final count = _allEntries.where((e) => e.categoryId == id).length;
    return '${l.translateCategory(cat.name)} ($count)';
  }

  @override
  Widget build(BuildContext context) {
    // 下拉选项值列表（收藏在第二位，紧随全部之后）
    final dropdownValues = <int?>[
      null, // 全部
      _kFavoriteId, // 收藏（第二位→'
      ..._categories.map((c) => c.id),
    ];
    final l = L10n(AppLangNotifier().uiLang);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        title: Row(
          children: [
            Text(l.dictPageTitle,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            if (!_loading)
              Text(
                '(${_filtered.length})',
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.normal),
              ),
          ],
        ),
        actions: [
          Tooltip(
            message:
                '${_sortFieldLabel(_sortField, l)} ${_sortDir == SortDir.desc ? "↓" : "↑"}',
            child: IconButton(
              icon: const Icon(Icons.sort_rounded),
              onPressed: _openSortPage,
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // ── 搜索→─────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      hintText: l.dictSearch,
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _searchText.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() {
                                  _searchText = '';
                                  _applyFilterAndSort();
                                });
                              },
                            )
                          : null,
                      isDense: true,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(
                          vertical: 10, horizontal: 12),
                    ),
                    onChanged: (v) {
                      setState(() {
                        _searchText = v;
                        _applyFilterAndSort();
                      });
                    },
                  ),
                ),

                // ── 类别下拉筛选栏 ──────────────────────────────
                Container(
                  color: const Color(0xFFF5F7FF),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: DropdownButton<int?>(
                          value: dropdownValues.contains(_selectedCategoryId)
                              ? _selectedCategoryId
                              : null,
                          isExpanded: true,
                          underline: const SizedBox(),
                          menuMaxHeight: 8 * 48.0, // max 8 items visible
                          style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF1565C0),
                              fontWeight: FontWeight.w500),
                          icon: const Icon(Icons.keyboard_arrow_down,
                              color: Color(0xFF1565C0)),
                          items: dropdownValues
                              .map((v) => DropdownMenuItem<int?>(
                                    value: v,
                                    child: Text(
                                      _dropdownLabel(v, l),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ))
                              .toList(),
                          onChanged: (v) => _setCategory(v),
                        ),
                      ),
                    ],
                  ),
                ),

                // ── 词条列表 ───────────────────────────────────
                Expanded(
                  child: _filtered.isEmpty
                      ? Center(
                          child: Text(
                            _searchText.isNotEmpty ? l.dictNoResult : l.dictEmpty,
                            style:
                                const TextStyle(color: Colors.grey, fontSize: 16),
                          ),
                        )
                      : ListView.separated(
                          itemCount: _filtered.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1, indent: 56),
                          itemBuilder: (_, index) {
                            final e = _filtered[index];
                            final isPlaying = _playingId == e.id;
                            return _EntryTile(
                              entry: e,
                              isPlaying: isPlaying,
                              maxCorrectCount: _maxCorrectCount,
                              categories: _categories,
                              onPlay: () => _speak(e),
                              onChangeCategory: () =>
                                  _showChangeCategoryDialog(e),
                              onToggleFavorite: () => _toggleFavorite(e),
                              formatTime: _formatTime,
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

// ── 排序字段名称 ──────────────────────────────────────────────
String _sortFieldLabel(SortField f, L10n l) {
  switch (f) {
    case SortField.correctCount:
      return l.isEn ? 'Score' : (l.isZhTW ? '熱度' : '热度');
    case SortField.createdAt:
      return l.isEn ? 'Created' : (l.isZhTW ? '生成時間' : '生成时间');
    case SortField.lastUsedAt:
      return l.isEn ? 'Last Used' : (l.isZhTW ? '訪問時間' : '访问时间');
  }
}

// ── 排序结果 ──────────────────────────────────────────────────
class _SortResult {
  final SortField field;
  final SortDir dir;
  const _SortResult(this.field, this.dir);
}

// ── 独立排序页面 ──────────────────────────────────────────────
class SortPage extends StatefulWidget {
  final SortField currentField;
  final SortDir currentDir;

  const SortPage({
    super.key,
    required this.currentField,
    required this.currentDir,
  });

  @override
  State<SortPage> createState() => _SortPageState();
}

class _SortPageState extends State<SortPage> {
  late SortField _field;
  late SortDir _dir;

  @override
  void initState() {
    super.initState();
    _field = widget.currentField;
    _dir = widget.currentDir;
  }

  static const _blue = Color(0xFF1565C0);

  // 选择字段（不自动返回，仅更新状态）
  void _selectField(SortField f) {
    setState(() => _field = f);
  }

  // 选择方向（不自动返回，仅更新状态）
  void _selectDir(SortDir d) {
    setState(() => _dir = d);
  }

  Widget _fieldTile(SortField f, String label, String subtitle) {
    final selected = _field == f;
    return InkWell(
      onTap: () => _selectField(f),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? _blue.withOpacity(0.08) : null,
          border: Border(
            left: BorderSide(
              color: selected ? _blue : Colors.transparent,
              width: 4,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: selected ? _blue : Colors.grey,
              size: 22,
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight:
                          selected ? FontWeight.bold : FontWeight.normal,
                      color: selected ? _blue : Colors.black87,
                    )),
                Text(subtitle,
                    style: const TextStyle(
                        fontSize: 12, color: Colors.black45)),
              ],
            ),
            const Spacer(),
            if (selected) Icon(Icons.check, color: _blue, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _dirTile(SortDir d, String label, IconData icon) {
    final selected = _dir == d;
    return InkWell(
      onTap: () => _selectDir(d),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? _blue.withOpacity(0.08) : null,
          border: Border(
            left: BorderSide(
              color: selected ? _blue : Colors.transparent,
              width: 4,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(icon,
                color: selected ? _blue : Colors.grey, size: 22),
            const SizedBox(width: 16),
            Text(label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight:
                      selected ? FontWeight.bold : FontWeight.normal,
                  color: selected ? _blue : Colors.black87,
                )),
            const Spacer(),
            if (selected) Icon(Icons.check, color: _blue, size: 20),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n(AppLangNotifier().uiLang);
    final sortTitle = l.isEn ? 'Sort By' : (l.isZhTW ? '排序方式' : '排序方式');
    final fieldSec = l.isEn ? 'SORT FIELD' : (l.isZhTW ? '排序欄位' : '排序字段');
    final dirSec = l.isEn ? 'DIRECTION' : (l.isZhTW ? '排序方向' : '排序方向');
    final descLabel = l.isEn ? 'High →Low / Newest first' : (l.isZhTW ? '從高到低／最新優→' : '从高到低 / 最新优→');
    final ascLabel = l.isEn ? 'Low →High / Oldest first' : (l.isZhTW ? '從低到高／最舊優→' : '从低到高 / 最旧优→');

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        title: Text(sortTitle,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        // 左上→→返回时传回当前选择
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              Navigator.pop(context, _SortResult(_field, _dir)),
        ),
      ),
      // 拦截系统返回手势，也传回当前选择
      body: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            Navigator.pop(context, _SortResult(_field, _dir));
          }
        },
        child: ListView(
          children: [
            // ── 排序字段 ──────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(fieldSec,
                  style: const TextStyle(
                      fontSize: 13,
                      color: Colors.black45,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5)),
            ),
            _fieldTile(SortField.correctCount, _sortFieldLabel(SortField.correctCount, l),
                l.isEn ? 'Sort by correct count' : (l.isZhTW ? '按答對次數排→' : '按答对次数排→')),
            _fieldTile(SortField.createdAt, _sortFieldLabel(SortField.createdAt, l),
                l.isEn ? 'Sort by creation time' : (l.isZhTW ? '按詞條建立時間排→' : '按词条创建时间排→')),
            _fieldTile(SortField.lastUsedAt, _sortFieldLabel(SortField.lastUsedAt, l),
                l.isEn ? 'Sort by last practice time' : (l.isZhTW ? '按最後練習時間排→' : '按最后练习时间排→')),

            const Divider(height: 32, indent: 20, endIndent: 20),

            // ── 排序方向 ──────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(dirSec,
                  style: const TextStyle(
                      fontSize: 13,
                      color: Colors.black45,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5)),
            ),
            _dirTile(SortDir.desc, descLabel, Icons.arrow_downward_rounded),
            _dirTile(SortDir.asc, ascLabel, Icons.arrow_upward_rounded),

            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

// ── 词条 Tile ─────────────────────────────────────────────────
class _EntryTile extends StatelessWidget {
  final DictionaryEntry entry;
  final bool isPlaying;
  final int maxCorrectCount;
  final List<CategoryEntry> categories;
  final VoidCallback onPlay;
  final VoidCallback onChangeCategory;
  final VoidCallback onToggleFavorite;
  final String Function(String?) formatTime;

  const _EntryTile({
    required this.entry,
    required this.isPlaying,
    required this.maxCorrectCount,
    required this.categories,
    required this.onPlay,
    required this.onChangeCategory,
    required this.onToggleFavorite,
    required this.formatTime,
  });

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final notifier = AppLangNotifier();
    final srcTxt = e.srcText(notifier.targetLang);
    final dstTxt = e.dstText(notifier.nativeLang);

    // 热度比例→'.0 ~ 1.0→'
    final ratio = maxCorrectCount > 0
        ? (e.correctCount / maxCorrectCount).clamp(0.0, 1.0)
        : 0.0;

    // →categoryId 查找 nativeDB category（中文）
    final nativeCatName = categories.firstWhere(
      (c) => c.id == e.categoryId,
      orElse: () => CategoryEntry(name: 'general'),
    ).name;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 播放按钮 ────────────────────────────────────────
          GestureDetector(
            onTap: onPlay,
            child: CircleAvatar(
              radius: 22,
              backgroundColor: isPlaying
                  ? const Color(0xFFB71C1C)
                  : const Color(0xFF2E7D32),
              child: Icon(
                isPlaying ? Icons.stop_rounded : Icons.volume_up_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),

          const SizedBox(width: 12),

          // ── 文字区域 ─────────────────────────────────────────
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 源语言（学习语言→'
                Text(
                  srcTxt,
                  style: TextStyle(
                    fontSize: 20,
                    color: isPlaying
                        ? const Color(0xFF1565C0)
                        : Colors.black87,
                    fontWeight: isPlaying
                        ? FontWeight.bold
                        : FontWeight.w500,
                  ),
                ),
                // 翻译语言
                Text(
                  dstTxt,
                  style: const TextStyle(
                      fontSize: 14, color: Colors.black54),
                ),
                const SizedBox(height: 4),

                // ── 热度红杠 ────────────────────────────────────
                LayoutBuilder(
                  builder: (ctx, constraints) {
                    final barWidth = constraints.maxWidth * ratio;
                    return Stack(
                      children: [
                        Container(
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.red.shade50,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        if (barWidth > 0)
                          Container(
                            height: 4,
                            width: barWidth,
                            decoration: BoxDecoration(
                              color: Colors.red.shade600,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 4),

                // 答对次数 + 时间→'
                Row(
                  children: [
                    const Icon(Icons.check_circle_outline,
                        size: 11, color: Colors.green),
                    const SizedBox(width: 3),
                    Text(
                      '${e.correctCount} →',
                      style: TextStyle(
                        fontSize: 11,
                        color: e.correctCount > 0
                            ? Colors.green.shade700
                            : Colors.grey,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.access_time,
                        size: 11, color: Colors.grey),
                    const SizedBox(width: 3),
                    Text(
                      formatTime(e.createdAt),
                      style: const TextStyle(
                          fontSize: 10, color: Colors.grey),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(width: 8),

          // ── 右侧固定区：category 按钮 + 收藏图标 ────────────
          Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // category 按钮（显→nativeDB 中文类名→'
              GestureDetector(
                onTap: onChangeCategory,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 80),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1565C0).withOpacity(0.10),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: const Color(0xFF1565C0).withOpacity(0.4),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          nativeCatName,  // 显示中文类名（来→nativeDB.category→'
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF1565C0),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 3),
                      const Icon(Icons.edit,
                          size: 10, color: Color(0xFF1565C0)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              // 收藏心形图标（固定在 category 下方，大点击区域→'
              GestureDetector(
                onTap: onToggleFavorite,
                child: SizedBox(
                  width: 44,
                  height: 36,
                  child: Icon(
                    e.isFavorite
                        ? Icons.favorite
                        : Icons.favorite_border,
                    size: 26,
                    color: e.isFavorite
                        ? Colors.red.shade400
                        : Colors.grey.shade400,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
