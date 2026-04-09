import 'package:flutter/material.dart';
import 'language_prefs.dart';
import 'help_tooltip.dart';

// ── 每道题选项状态 ─────────────────────────────────────────────
enum AnswerState { idle, correct, wrong }

// ── 模式切换 Toggle ────────────────────────────────────────────
class ModeToggle extends StatelessWidget {
  final bool isModeB;
  final VoidCallback onToggle;

  const ModeToggle({required this.isModeB, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final l = L10n(AppLangNotifier().uiLang);
    final isZh = AppLangNotifier().uiLang.startsWith('zh');
    final label = isZh
        ? (isModeB ? '中→泰' : '泰→中')
        : (isModeB ? 'CN→TH' : 'TH→CN');
    final color =
        isModeB ? const Color(0xFF1B5E20) : const Color(0xFF2E7D32);

    return HelpTooltip(
      message: isModeB ? l.modeTooltipBtoA : l.modeTooltipAtoB,
      child: GestureDetector(
        onTap: onToggle,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.swap_horiz, color: Colors.white70, size: 13),
              const SizedBox(width: 4),
              Text(
                label,
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

// ── 模式 A：中文选项 ──────────────────────────────────────────
class ChineseOptionTile extends StatelessWidget {
  final String chinese;
  final AnswerState state;
  final VoidCallback? onTap;
  final String? romanTranslate;
  final bool isPlayingThis;
  final VoidCallback? onPlay;
  /// Phrase practice: show [romanTranslate] on a second line under [chinese] when wrong.
  final bool romanBelowNativeWhenWrong;

  const ChineseOptionTile({
    required this.chinese,
    required this.state,
    required this.onTap,
    this.romanTranslate,
    this.isPlayingThis = false,
    this.onPlay,
    this.romanBelowNativeWhenWrong = false,
  });

  @override
  Widget build(BuildContext context) {
    Widget leading;
    Color borderColor;
    Color bgColor;

    switch (state) {
      case AnswerState.correct:
        leading = Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.green.shade600, width: 2.5),
          ),
        );
        borderColor = Colors.green.shade400;
        bgColor = Colors.green.shade50;
        break;
      case AnswerState.wrong:
        leading =
            Icon(Icons.close_rounded, color: Colors.grey.shade600, size: 26);
        borderColor = Colors.grey.shade400;
        bgColor = Colors.grey.shade100;
        break;
      case AnswerState.idle:
        leading = Icon(
          Icons.check_box_outline_blank_rounded,
          color: const Color(0xFF1565C0).withOpacity(0.5),
          size: 26,
        );
        borderColor = const Color(0xFF1565C0).withOpacity(0.2);
        bgColor = Colors.white;
        break;
    }

    final selected = state != AnswerState.idle;
    final mainSize = selected ? 15.0 : 14.0;
    final romanSize = selected ? 13.0 : 12.0;
    final romanColor = state == AnswerState.correct
        ? Colors.green.shade700
        : Colors.red.shade700;
    final stackRoman = romanBelowNativeWhenWrong &&
        state == AnswerState.wrong &&
        romanTranslate != null &&
        romanTranslate!.trim().isNotEmpty;

    final textBlock = stackRoman
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                chinese,
                style: TextStyle(
                  fontSize: mainSize,
                  color: state == AnswerState.wrong
                      ? Colors.red.shade700
                      : Colors.black87,
                  fontWeight:
                      selected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                romanTranslate!.trim(),
                style: TextStyle(
                  fontSize: romanSize,
                  color: romanColor,
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w500,
                  height: 1.35,
                ),
              ),
            ],
          )
        : Text(
            chinese,
            style: TextStyle(
              fontSize: mainSize,
              color: state == AnswerState.correct
                  ? Colors.green.shade700
                  : state == AnswerState.wrong
                      ? Colors.red.shade700
                      : Colors.black87,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
          );

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor, width: 1.5),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    leading,
                    const SizedBox(width: 12),
                    Expanded(child: textBlock),
                    if (!stackRoman &&
                        state != AnswerState.idle &&
                        romanTranslate != null &&
                        romanTranslate!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(
                          romanTranslate!,
                          style: TextStyle(
                            fontSize: romanSize,
                            color: romanColor,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (onPlay != null && chinese.isNotEmpty)
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
                          : const Color(0xFF1565C0),
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
      ),
    );
  }
}

// ── 模式 B：泰语选项行（含独立播放按钮）──────────────────────
class ThaiOptionTile extends StatelessWidget {
  final String thai;
  final String? romanization; // 罗马拼音（可能还在加载中）
  final bool hideRomanization;
  final AnswerState state;
  final bool isPlayingThis;
  final VoidCallback? onTap; // 点击文字 = 选择答案
  final VoidCallback onPlay; // 点击播放按钮 = 仅播放

  const ThaiOptionTile({
    required this.thai,
    this.romanization,
    this.hideRomanization = false,
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
      case AnswerState.correct:
        leading = Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.green.shade600, width: 2.5),
          ),
        );
        borderColor = Colors.green.shade400;
        bgColor = Colors.green.shade50;
        textColor = Colors.green.shade700;
        break;
      case AnswerState.wrong:
        leading =
            Icon(Icons.close_rounded, color: Colors.grey.shade600, size: 24);
        borderColor = Colors.grey.shade400;
        bgColor = Colors.grey.shade100;
        textColor = Colors.red.shade700;
        break;
      case AnswerState.idle:
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

    final answeredHere = state != AnswerState.idle;
    final emphasizeMain = answeredHere || isPlayingThis;
    final mainSize = emphasizeMain ? 15.0 : 14.0;
    final romanSize = answeredHere ? 12.0 : 11.0;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor, width: 1.5),
        ),
        child: Row(
          children: [
            // Text area — stretches to fill all space beside the play button
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 8),
                child: Row(
                  children: [
                    leading,
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            thai.isEmpty ? '（无可用选项）' : thai,
                            style: TextStyle(
                              fontSize: mainSize,
                              color: textColor,
                              fontWeight: emphasizeMain
                                  ? FontWeight.bold
                                  : FontWeight.w500,
                              letterSpacing: 1.0,
                            ),
                          ),
                          if (!hideRomanization && thai.isNotEmpty && romanization != null)
                            Text(
                              romanization!,
                              style: TextStyle(
                                fontSize: romanSize,
                                fontWeight: answeredHere
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color: textColor.withOpacity(
                                    answeredHere ? 0.85 : 0.65),
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
            // Play button — has its own tap; stops propagation to outer GestureDetector
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
      ),
    );
  }
}

// ── 导航按钮 ───────────────────────────────────────────────────
class NavButton extends StatelessWidget {
  /// isPrev=true 显示 « 图标，false 显示 » 图标
  final bool isPrev;
  final bool enabled;
  final VoidCallback? onPressed;

  const NavButton({
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

// ── Quiz 模式按钮 ──────────────────────────────────────────────
class QuizModeButton extends StatelessWidget {
  final bool active;
  final VoidCallback onToggle;

  const QuizModeButton({
    required this.active,
    required this.onToggle,
    // timeLeft kept for API compatibility but countdown is shown separately
    int? timeLeft,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onToggle,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? const Color(0xFFE65100) : Colors.grey.shade300,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              active ? Icons.timer : Icons.timer_outlined,
              color: active ? Colors.white : Colors.grey.shade600,
              size: 18,
            ),
            const SizedBox(width: 5),
            Text(
              L10n(AppLangNotifier().uiLang).challengeLabel,
              style: TextStyle(
                color: active ? Colors.white : Colors.grey.shade700,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 播放按钮（模式 A 主显示区）────────────────────────────────
class PlayButton extends StatelessWidget {
  final bool playing;
  final VoidCallback? onPressed;

  const PlayButton({
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

// ── Challenge counter chip ─────────────────────────────────────
class ChallengeCounter extends StatelessWidget {
  final int value;
  final IconData icon;
  final Color color;
  final String suffix;

  const ChallengeCounter({
    required this.value,
    required this.icon,
    required this.color,
    this.suffix = '',
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 4),
          Text(
            '$value$suffix',
            style: TextStyle(
              color: color,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
