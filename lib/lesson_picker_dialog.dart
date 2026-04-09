import 'package:flutter/material.dart';
import 'language_prefs.dart';
import 'database_helper.dart';

// ── Challenge color helpers (shared by practice and dictionary pages) ──
Color challengeBgColor(int challenge) {
  if (challenge >= 3) return Colors.red.shade600;
  if (challenge == 2) return const Color(0xFFCDC700);
  if (challenge == 1) return Colors.green.shade600;
  return Colors.grey.shade300;
}

Color challengeTextColor(int challenge) {
  if (challenge == 2) return Colors.grey.shade800;
  if (challenge == 0) return Colors.black87;
  return Colors.white;
}

// ── Lesson picker dialog (used by both PracticePage and DictionaryListPage) ──
class LessonPickerDialog extends StatelessWidget {
  final List<CategoryEntry> categories;
  final int? selectedId;
  final Color Function(int challenge) challengeBgColor;
  final Color Function(int challenge) challengeTextColor;
  final void Function(int? id) onSelected;

  const LessonPickerDialog({
    super.key,
    required this.categories,
    required this.selectedId,
    required this.challengeBgColor,
    required this.challengeTextColor,
    required this.onSelected,
  });

  Widget _lessonTile(BuildContext context, {
    required int? id,
    required String label,
    required Color bg,
    required Color fg,
    bool isSelected = false,
    int stars = 0,
  }) {
    return InkWell(
      onTap: () => onSelected(id),
      child: Container(
        color: bg,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.check_circle : Icons.circle_outlined,
              color: isSelected ? fg : fg.withOpacity(0.4),
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label,
                  style: TextStyle(
                    fontSize: 15,
                    color: fg,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  )),
            ),
            if (stars > 0) ...[
              const SizedBox(width: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(
                  stars,
                  (_) => Icon(Icons.star_rounded, size: 16, color: fg.withOpacity(0.85)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n(AppLangNotifier().uiLang);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
      clipBehavior: Clip.hardEdge,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Title bar
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            color: const Color(0xFF1565C0),
            child: Text(l.selectLessonLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                )),
          ),

          // Scrollable lesson list
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: categories.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 0, thickness: 0.5),
              itemBuilder: (ctx, i) {
                final cat = categories[i];
                final bg = challengeBgColor(cat.challenge);
                final fg = challengeTextColor(cat.challenge);
                return _lessonTile(
                  ctx,
                  id: cat.id,
                  label: cat.nameNative.isNotEmpty ? cat.nameNative : cat.nameTranslate,
                  bg: bg,
                  fg: fg,
                  isSelected: selectedId == cat.id,
                  stars: cat.challenge.clamp(0, 5),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
