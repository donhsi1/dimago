import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'language_prefs.dart';

// ── Encoding: category.challenge as decimal digits (pad to 8) ─────────────
// Segment i (0..7) uses digit i (MSD first):
// 0: translate → word → talk
// 1: translate → word → choice
// 2: translate → phrase → talk
// 3: translate → phrase → choice
// 4: native → word → talk
// 5: native → word → choice
// 6: native → phrase → talk
// 7: native → phrase → choice
//
// Even segments (0,2,4,6) = talk  → light green palette
// Odd  segments (1,3,5,7) = choice → light orange palette
// Digit pairs [0-1]→shade 0, [2-3]→1, [4-5]→2, [6-7]→3, [8-9]→4

/// Eight digits (0–9 each) from [challenge], left-padded with zeros to length 8.
List<int> circularScoreDigits(int challenge) {
  final raw = challenge.abs().toString();
  final buf = StringBuffer();
  if (raw.length < 8) {
    buf.write('0' * (8 - raw.length));
    buf.write(raw);
  } else if (raw.length > 8) {
    buf.write(raw.substring(raw.length - 8));
  } else {
    buf.write(raw);
  }
  final s = buf.toString();
  return List<int>.generate(8, (i) {
    final ch = s.codeUnitAt(i);
    if (ch >= 0x30 && ch <= 0x39) return ch - 0x30;
    return 0;
  });
}

/// 5-level shade for a segment: green (talk) or orange (choice).
/// Digit pairs: [0-1]=0, [2-3]=1, [4-5]=2, [6-7]=3, [8-9]=4.
Color segmentColor(int digit, {required bool isTalk}) {
  final d = digit.clamp(0, 9);
  final level = d <= 1 ? 0 : d <= 3 ? 1 : d <= 5 ? 2 : d <= 7 ? 3 : 4;
  if (isTalk) {
    const shades = <int>[
      0xFFE8F5E9, // level 0 – barely tinted
      0xFFA5D6A7, // level 1
      0xFF66BB6A, // level 2
      0xFF388E3C, // level 3
      0xFF1B5E20, // level 4 – full
    ];
    return Color(shades[level]);
  } else {
    const shades = <int>[
      0xFFFFF3E0, // level 0 – barely tinted
      0xFFFFCC80, // level 1
      0xFFFFA726, // level 2
      0xFFF57C00, // level 3
      0xFFE65100, // level 4 – full
    ];
    return Color(shades[level]);
  }
}

/// Legacy single-arg helper kept for external callers.
Color circularScoreDigitColor(int digit) => segmentColor(digit, isTalk: true);

String _shortLangCode(String code) {
  final i = code.indexOf('_');
  if (i > 0) return code.substring(0, i);
  return code.length > 4 ? code.substring(0, 4) : code;
}

Path _annulusSector(
  Offset c,
  double rInner,
  double rOuter,
  double startRad,
  double sweepRad,
) {
  final path = Path();
  final x0 = c.dx + rInner * math.cos(startRad);
  final y0 = c.dy + rInner * math.sin(startRad);
  final x1 = c.dx + rOuter * math.cos(startRad);
  final y1 = c.dy + rOuter * math.sin(startRad);
  path.moveTo(x0, y0);
  path.lineTo(x1, y1);
  path.arcTo(
    Rect.fromCircle(center: c, radius: rOuter),
    startRad,
    sweepRad,
    false,
  );
  final end = startRad + sweepRad;
  path.lineTo(
    c.dx + rInner * math.cos(end),
    c.dy + rInner * math.sin(end),
  );
  path.arcTo(
    Rect.fromCircle(center: c, radius: rInner),
    end,
    -sweepRad,
    false,
  );
  path.close();
  return path;
}

void _paintLabel(
  Canvas canvas,
  String text,
  Offset c,
  double r,
  double angleRad,
  TextStyle style,
) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  final x = c.dx + r * math.cos(angleRad) - tp.width / 2;
  final y = c.dy + r * math.sin(angleRad) - tp.height / 2;
  tp.paint(canvas, Offset(x, y));
}

/// Donut chart: center = lang codes, middle ring = word/phrase quadrants,
/// outer ring = 8 segments (talk/choice × …) colored by [digits].
class CircularScorePainter extends CustomPainter {
  CircularScorePainter({
    required this.digits,
    required this.translateLangCode,
    required this.nativeLangCode,
    this.drawLegendLabels = true,
    this.compactIcon = false,
    this.pressedSegment,
  }) : assert(digits.length == 8);

  final List<int> digits;
  final String translateLangCode;
  final String nativeLangCode;
  final bool drawLegendLabels;
  /// List-row miniature: no inner lang text; lighter middle ring.
  final bool compactIcon;
  /// Index 0–7 of the outer ring segment currently being pressed, or null.
  final int? pressedSegment;

  static const double _twoPi = math.pi * 2;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final maxR = math.min(size.width, size.height) / 2 * 0.94;
    final r1 = maxR * 0.22;
    final r2 = maxR * 0.46;
    final r3 = maxR;

    // ── Outer ring: 8 wedges, green (talk) / orange (choice) ──────────────
    const startBase = -math.pi / 2;
    for (var i = 0; i < 8; i++) {
      final start = startBase + i * _twoPi / 8;
      final path = _annulusSector(c, r2, r3, start, _twoPi / 8);
      final isTalk = i.isEven; // even = talk, odd = choice
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.fill
          ..color = segmentColor(digits[i], isTalk: isTalk),
      );
      // Tap feedback: brighten the pressed segment
      if (pressedSegment == i) {
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.fill
            ..color = Colors.white.withValues(alpha: 0.40),
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.8, maxR * 0.008)
          ..color = Colors.white.withValues(alpha: 0.85),
      );
    }

    // ── Middle ring: 4 quadrants, white background ─────────────────────────
    final midBg = Paint()
      ..color = compactIcon
          ? const Color(0xFFEEEEEE)
          : const Color(0xFFF5F5F5);
    for (var q = 0; q < 4; q++) {
      final start = startBase + q * _twoPi / 4;
      final path = _annulusSector(c, r1, r2, start, _twoPi / 4);
      canvas.drawPath(path, midBg);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.6, maxR * 0.006)
          ..color = Colors.white.withValues(alpha: 0.9),
      );
    }

    // ── Center disk ───────────────────────────────────────────────────────
    canvas.drawCircle(c, r1, Paint()..color = const Color(0xFFFFEBEE)); // light red
    if (!compactIcon) {
      canvas.drawCircle(
        c,
        r1,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.0, maxR * 0.012)
          ..color = const Color(0xFF424242).withValues(alpha: 0.25),
      );
    }

    // ── Divider lines ─────────────────────────────────────────────────────
    if (!compactIcon) {
      final linePaint = Paint()
        ..color = Colors.grey.shade500
        ..strokeWidth = math.max(1.0, maxR * 0.018)
        ..strokeCap = StrokeCap.butt;
      // Horizontal: through core + 2nd ring
      canvas.drawLine(Offset(c.dx - r2, c.dy), Offset(c.dx + r2, c.dy), linePaint);
      // Vertical: through 2nd ring only (not the core)
      canvas.drawLine(Offset(c.dx, c.dy - r2), Offset(c.dx, c.dy - r1), linePaint);
      canvas.drawLine(Offset(c.dx, c.dy + r1), Offset(c.dx, c.dy + r2), linePaint);
    }

    // ── Center lang codes ─────────────────────────────────────────────────
    if (!compactIcon) {
      final tShort = _shortLangCode(translateLangCode).toUpperCase();
      final nShort = _shortLangCode(nativeLangCode).toUpperCase();
      final langStyle = TextStyle(
        fontSize: math.max(9, r1 * 0.40),
        fontWeight: FontWeight.w700,
        color: const Color(0xFF263238),
        height: 1.0,
      );
      final gap = math.max(2.0, maxR * 0.02);

      final tTp = TextPainter(
        text: TextSpan(text: tShort, style: langStyle),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: r1 * 2.2);
      tTp.paint(canvas, Offset(c.dx - tTp.width / 2, c.dy - gap - tTp.height));

      final nTp = TextPainter(
        text: TextSpan(text: nShort, style: langStyle),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: r1 * 2.2);
      nTp.paint(canvas, Offset(c.dx - nTp.width / 2, c.dy + gap));
    }

    // ── Digit score inside each outer-ring segment ────────────────────────
    final ro = (r2 + r3) / 2;
    for (var i = 0; i < 8; i++) {
      final d = digits[i];
      if (d == 0 && compactIcon) continue; // skip zero on tiny icon
      final mid = startBase + i * _twoPi / 8 + _twoPi / 16;
      // Light text on dark segments (level 3-4), dark text on lighter ones
      final textColor = d >= 6 ? Colors.white : const Color(0xFF37474F);
      _paintLabel(
        canvas,
        '${d + 1}',
        c,
        ro,
        mid,
        TextStyle(
          fontSize: math.max(7, maxR * 0.075) + 5,
          fontWeight: FontWeight.w700,
          color: textColor,
        ),
      );
    }

    if (!drawLegendLabels) return;

    // ── 2nd ring labels: word (upper-left + lower-right),
    //                    phrase (upper-right + lower-left) ─────────────────
    final l10n = L10n(AppLangNotifier().uiLang);
    final small = TextStyle(
      fontSize: math.max(6, maxR * 0.060) + 3,
      fontWeight: FontWeight.w600,
      color: const Color(0xFF37474F),
    );
    final rm = (r1 + r2) / 2;
    // Upper-left = angle -3π/4 ; Lower-right = angle π/4
    _paintLabel(canvas, l10n.circularScoreWord,   c, rm, -3 * math.pi / 4, small);
    _paintLabel(canvas, l10n.circularScoreWord,   c, rm,      math.pi / 4, small);
    // Upper-right = angle -π/4 ; Lower-left = angle 3π/4
    _paintLabel(canvas, l10n.circularScorePhrase, c, rm, -math.pi / 4, small);
    _paintLabel(canvas, l10n.circularScorePhrase, c, rm,  3 * math.pi / 4, small);
  }

  @override
  bool shouldRepaint(covariant CircularScorePainter oldDelegate) {
    if (oldDelegate.translateLangCode != translateLangCode ||
        oldDelegate.nativeLangCode != nativeLangCode ||
        oldDelegate.drawLegendLabels != drawLegendLabels ||
        oldDelegate.compactIcon != compactIcon ||
        oldDelegate.pressedSegment != pressedSegment) {
      return true;
    }
    for (var i = 0; i < 8; i++) {
      if (oldDelegate.digits[i] != digits[i]) return true;
    }
    return false;
  }
}

// ── Legend: two swatches (talk=green, choice=orange) ──────────────────────
/// Compact horizontal legend for the circular score chart.
class CircularScoreLegend extends StatelessWidget {
  const CircularScoreLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = L10n(AppLangNotifier().uiLang);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _swatch(segmentColor(6, isTalk: true),  l10n.circularScoreTalk),
        const SizedBox(width: 10),
        _swatch(segmentColor(6, isTalk: false), l10n.circularScoreChoice),
      ],
    );
  }

  Widget _swatch(Color color, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
          border: Border.all(color: Colors.black26, width: 0.5),
        ),
      ),
      const SizedBox(width: 3),
      Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF37474F))),
    ],
  );
}

/// Full chart for lesson detail / reuse elsewhere.
/// Outer ring segments are tappable; [onSegmentTap] fires with segment index 0–7.
class CircularScoreChart extends StatefulWidget {
  const CircularScoreChart({
    super.key,
    required this.challenge,
    required this.translateLangCode,
    required this.nativeLangCode,
    this.size,
    this.onSegmentTap,
  });

  final int challenge;
  final String translateLangCode;
  final String nativeLangCode;
  final double? size;
  /// Called with the tapped outer-ring segment index (0–7). Null = no handler.
  final void Function(int segmentIndex)? onSegmentTap;

  @override
  State<CircularScoreChart> createState() => _CircularScoreChartState();
}

class _CircularScoreChartState extends State<CircularScoreChart> {
  int? _pressedSegment;

  /// Returns the outer-ring segment index (0–7) for a tap at [local], or null.
  int? _hitTest(Offset local, double chartSize) {
    final maxR = chartSize / 2 * 0.94;
    final r2 = maxR * 0.46;
    final r3 = maxR;
    final cx = chartSize / 2;
    final cy = chartSize / 2;
    final dx = local.dx - cx;
    final dy = local.dy - cy;
    final dist = math.sqrt(dx * dx + dy * dy);
    if (dist < r2 || dist > r3) return null;
    var angle = math.atan2(dy, dx) + math.pi / 2;
    if (angle < 0) angle += 2 * math.pi;
    return (angle / (2 * math.pi / 8)).floor().clamp(0, 7);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size ?? 208; // 260 × 0.8
    final digits = circularScoreDigits(widget.challenge);
    return SizedBox(
      width: s,
      height: s,
      child: GestureDetector(
        onTapDown: (d) {
          final seg = _hitTest(d.localPosition, s);
          if (seg != null) setState(() => _pressedSegment = seg);
        },
        onTapUp: (d) {
          final seg = _pressedSegment;
          setState(() => _pressedSegment = null);
          if (seg != null) widget.onSegmentTap?.call(seg);
        },
        onTapCancel: () => setState(() => _pressedSegment = null),
        child: CustomPaint(
          painter: CircularScorePainter(
            digits: digits,
            translateLangCode: widget.translateLangCode,
            nativeLangCode: widget.nativeLangCode,
            drawLegendLabels: true,
            pressedSegment: _pressedSegment,
          ),
        ),
      ),
    );
  }
}

/// Compact colorful icon (8-segment donut) for list rows.
class CircularScoreListIcon extends StatelessWidget {
  const CircularScoreListIcon({
    super.key,
    required this.challenge,
    this.dimension = 26,
  });

  final int challenge;
  final double dimension;

  @override
  Widget build(BuildContext context) {
    final digits = circularScoreDigits(challenge);
    return SizedBox(
      width: dimension,
      height: dimension,
      child: CustomPaint(
        painter: CircularScorePainter(
          digits: digits,
          translateLangCode: '',
          nativeLangCode: '',
          drawLegendLabels: false,
          compactIcon: true,
        ),
      ),
    );
  }
}
