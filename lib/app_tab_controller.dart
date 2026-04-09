import 'package:flutter/foundation.dart';

/// Global tab switch requests for the app shell.
class AppTabController {
  AppTabController._();

  /// Emits requested tab index (0..4). Null means no pending request.
  static final ValueNotifier<int?> requestedTab = ValueNotifier<int?>(null);

  static void jumpTo(int index) {
    requestedTab.value = index;
  }

  static void clear() {
    requestedTab.value = null;
  }
}
