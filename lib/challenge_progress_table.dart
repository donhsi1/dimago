import 'package:flutter/material.dart';

import 'circular_score.dart';
import 'language_prefs.dart';

/// Eight fixed rows matching challenge-mapping: one digit per segment of
/// [category.challenge] (see [circularScoreDigits]).
class ChallengeProgressTable extends StatelessWidget {
  const ChallengeProgressTable({
    super.key,
    required this.challenge,
    this.scores = const [null, null, null, null, null, null, null, null],
    this.onSegmentAction,
  });

  final int challenge;
  /// Elapsed seconds per segment (score1..score8). Null = never completed.
  final List<int?> scores;
  /// Segment index 0..7; reserved for future wiring per row.
  final void Function(int segmentIndex)? onSegmentAction;

  static const double _headerH = 36;
  static const double _rowH = 34;
  static const double _padV = 6;

  /// Table block only (no lesson title bar).
  static double get tableBlockHeight =>
      _padV * 2 + _headerH + 8 * _rowH;

  static const List<({bool translate, bool word, bool talk})> _rows = [
    (translate: true,  word: true,  talk: true),
    (translate: true,  word: true,  talk: false),
    (translate: true,  word: false, talk: true),
    (translate: true,  word: false, talk: false),
    (translate: false, word: true,  talk: true),
    (translate: false, word: true,  talk: false),
    (translate: false, word: false, talk: true),
    (translate: false, word: false, talk: false),
  ];

  // Badge colors matching practice-page toggle buttons
  static const _colorDirTranslate = Color(0xFF2E7D32); // green
  static const _colorDirNative    = Color(0xFF1B5E20); // dark green
  static const _colorWord         = Color(0xFF7E57C2); // purple
  static const _colorPhrase       = Color(0xFF6A1B9A); // dark purple
  static const _colorChoice       = Color(0xFFE53935); // red
  static const _colorTalk         = Color(0xFFB71C1C); // dark red

  static Widget _badge(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final l = L10n(AppLangNotifier().uiLang);

    Widget cell(Widget child, {bool header = false}) => Container(
          height: header ? _headerH : _rowH,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: child,
        );

    Text hdr(String t) => Text(
          t,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 11,
            color: Colors.grey.shade900,
          ),
        );

    final headerRow = TableRow(
      decoration: BoxDecoration(color: Colors.grey.shade300),
      children: [
        cell(hdr(l.challengeTableColDirection), header: true),
        cell(hdr(l.challengeTableColUnit), header: true),
        cell(hdr(l.challengeTableColMode), header: true),
        cell(hdr(l.challengeTableColScore), header: true),
        cell(hdr(l.challengeTableColAction), header: true),
      ],
    );

    TableRow dataRow(int i) {
      final spec = _rows[i];
      final elapsedSecs = i < scores.length ? scores[i] : null;

      final dirLabel = spec.translate
          ? l.challengeTableTranslateDir
          : l.challengeTableNativeDir;
      final dirColor = spec.translate ? _colorDirTranslate : _colorDirNative;

      final unitLabel = spec.word ? l.challengeTableWord : l.challengeTablePhrase;
      final unitColor = spec.word ? _colorWord : _colorPhrase;

      final modeLabel = spec.talk ? l.challengeTableModeTalk : l.challengeTableModeChoice;
      final modeColor = spec.talk ? _colorTalk : _colorChoice;

      // Score cell: show elapsed number if completed, dash otherwise.
      final scoreText = elapsedSecs != null ? '$elapsedSecs' : '—';
      final scoreColor = elapsedSecs != null ? const Color(0xFF1565C0) : Colors.grey.shade400;

      return TableRow(
        decoration: BoxDecoration(
          color: i.isEven ? Colors.grey.shade50 : Colors.white,
        ),
        children: [
          cell(_badge(dirLabel, dirColor)),
          cell(_badge(unitLabel, unitColor)),
          cell(_badge(modeLabel, modeColor)),
          cell(
            Text(
              scoreText,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: scoreColor,
              ),
            ),
          ),
          cell(
            GestureDetector(
              onTap: () => onSegmentAction?.call(i),
              child: Container(
                width: 28,
                height: 28,
                decoration: const BoxDecoration(
                  color: Color(0xFFB71C1C),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.play_arrow,
                    color: Colors.white, size: 18),
              ),
            ),
          ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: _padV),
      child: Table(
        border: TableBorder.all(color: Colors.grey.shade500, width: 1),
        columnWidths: const {
          0: FlexColumnWidth(1),
          1: FlexColumnWidth(1),
          2: FlexColumnWidth(1),
          3: FixedColumnWidth(42),
          4: FlexColumnWidth(1),
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          headerRow,
          ...List.generate(8, dataRow),
        ],
      ),
    );
  }
}
