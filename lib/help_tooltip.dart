import 'package:flutter/material.dart';

import 'system_prefs_notifier.dart';

class HelpTooltip extends StatelessWidget {
  final String message;
  final Widget child;

  const HelpTooltip({
    super.key,
    required this.message,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: SystemPrefsNotifier(),
      builder: (context, _) {
        if (!SystemPrefsNotifier().showHelpTooltips) return child;
        return Tooltip(
          message: message,
          child: child,
        );
      },
    );
  }
}

