import 'package:flutter/material.dart';
import 'challenge_progress_table.dart';
import 'database_helper.dart';
import 'dictionary_list_page.dart';
import 'language_prefs.dart';
import 'lesson_picker_dialog.dart' show challengeBgColor, challengeTextColor;

class LessonPage extends StatefulWidget {
  /// Called when the user selects a category (to update practice page state).
  final void Function(int? categoryId) onCategorySelected;
  /// Currently selected category id — used to highlight the active row.
  final int? selectedCategoryId;
  /// Called when the user taps a row's action button in the progress table.
  final void Function(int categoryId, int segmentIndex)? onSegmentChallenge;

  const LessonPage({
    super.key,
    required this.onCategorySelected,
    required this.selectedCategoryId,
    this.onSegmentChallenge,
  });

  @override
  State<LessonPage> createState() => LessonPageState();
}

class LessonPageState extends State<LessonPage> {
  List<CategoryEntry> _categories = [];
  Set<int> _categoryIdsWithWords = {};
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Reload categories and which lessons have word rows locally (e.g. after on-demand download).
  Future<void> reload() => _load();

  Future<void> _load({bool showFullScreenLoader = true}) async {
    if (showFullScreenLoader) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      final cats = await DatabaseHelper.getAllCategories();
      final withWords = await DatabaseHelper.categoryIdsWithWordsLoaded();
      if (!mounted) return;
      setState(() {
        _categories = cats;
        _categoryIdsWithWords = withWords;
        if (showFullScreenLoader) _loading = false;
        _loadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (showFullScreenLoader) _loading = false;
        _loadError = e.toString();
        if (showFullScreenLoader) {
          _categories = [];
          _categoryIdsWithWords = {};
        }
      });
    }
  }

  /// True when this lesson has at least one word row in local DB (downloaded content).
  bool _contentLoaded(int? categoryId) =>
      categoryId != null && _categoryIdsWithWords.contains(categoryId);

  Widget _tile({
    required CategoryEntry cat,
    required bool isSelected,
    required bool contentLoaded,
  }) {
    final id = cat.id;
    final label =
        cat.nameNative.isNotEmpty ? cat.nameNative : cat.nameTranslate;
    final bg = challengeBgColor(cat.challenge);
    final fg = challengeTextColor(cat.challenge);
    final rowBg = contentLoaded ? bg : Colors.grey.shade300;
    final rowFg = contentLoaded ? fg : Colors.grey.shade600;
    final iconDim = contentLoaded ? 1.0 : 0.45;

    return Container(
      color: rowBg,
      child: InkWell(
        onTap: contentLoaded ? () => widget.onCategorySelected(id) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(
                isSelected ? Icons.check_circle : Icons.circle_outlined,
                color: isSelected ? rowFg : rowFg.withValues(alpha: 0.4),
                size: 22,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 16,
                    color: rowFg,
                    fontWeight:
                        isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Opacity(
                opacity: iconDim,
                child: Icon(Icons.account_circle_outlined,
                    size: 26, color: rowFg.withValues(alpha: 0.6)),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: contentLoaded && id != null
                    ? () {
                        Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                DictionaryListPage(initialCategoryId: id),
                          ),
                        );
                      }
                    : null,
                child: Icon(
                  Icons.visibility_outlined,
                  size: 26,
                  color: contentLoaded
                      ? rowFg.withValues(alpha: 0.6)
                      : Colors.grey.shade500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Title bar + fixed-height challenge mapping table (replaces circular chart).
  static const double _challengePanelTitleBar = 52;

  Widget _buildBottomPanel(BuildContext context, CategoryEntry cat, int lessonNum) {
    final l = L10n(AppLangNotifier().uiLang);
    final digitSum = cat.scores.fold<int>(0, (a, s) => a + (s ?? 0));

    final fixedH = 1 +
        _challengePanelTitleBar +
        ChallengeProgressTable.tableBlockHeight;

    return SizedBox(
      height: fixedH,
      child: Material(
        color: Colors.grey.shade50,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Divider(height: 1, thickness: 1, color: Colors.grey.shade400),
            SizedBox(
              height: _challengePanelTitleBar,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l.lessonProgressTotalScoreHeader(lessonNum, digitSum),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade900,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
            ChallengeProgressTable(
              challenge: cat.challenge,
              scores: cat.scores,
              onSegmentAction: cat.id != null
                  ? (i) => widget.onSegmentChallenge?.call(cat.id!, i)
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sel = widget.selectedCategoryId;
    final l = L10n(AppLangNotifier().uiLang);
    final surface = Theme.of(context).colorScheme.surface;

    if (_loading) {
      return Scaffold(
        backgroundColor: surface,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_loadError != null) {
      return Scaffold(
        backgroundColor: surface,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l.lessonTabLoadError,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _loadError!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => reload(),
                  child: Text(l.lessonTabRetry),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_categories.isEmpty) {
      return Scaffold(
        backgroundColor: surface,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              l.lessonTabEmpty,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade700, height: 1.4),
            ),
          ),
        ),
      );
    }

    CategoryEntry? panelCat;
    var lessonNum = 0;
    if (sel != null && _contentLoaded(sel)) {
      for (var i = 0; i < _categories.length; i++) {
        if (_categories[i].id == sel) {
          panelCat = _categories[i];
          lessonNum = i + 1;
          break;
        }
      }
    }

    final list = RefreshIndicator(
      onRefresh: () => _load(showFullScreenLoader: false),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 8),
        children: [
          ..._categories.asMap().entries.expand((e) {
            final cat = e.value;
            final loaded = _contentLoaded(cat.id);
            return [
              _tile(
                cat: cat,
                isSelected: sel == cat.id,
                contentLoaded: loaded,
              ),
              const Divider(height: 0, thickness: 0.5),
            ];
          }),
        ],
      ),
    );

    if (panelCat == null) {
      return Scaffold(
        backgroundColor: surface,
        body: list,
      );
    }

    return Scaffold(
      backgroundColor: surface,
      body: Column(
        children: [
          Expanded(child: list),
          _buildBottomPanel(context, panelCat, lessonNum),
        ],
      ),
    );
  }
}
