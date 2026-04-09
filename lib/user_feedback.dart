import 'package:flutter/material.dart';

/// App-wide snackbars without a [BuildContext]. Set [messengerKey] from [MaterialApp.scaffoldMessengerKey].
class UserFeedback {
  static GlobalKey<ScaffoldMessengerState>? messengerKey;

  static void showSnack(
    String message, {
    Duration duration = const Duration(seconds: 3),
  }) {
    messengerKey?.currentState?.showSnackBar(
      SnackBar(content: Text(message), duration: duration),
    );
  }

  static const String missingRomanizationMessage = 'no romanization found';
}
