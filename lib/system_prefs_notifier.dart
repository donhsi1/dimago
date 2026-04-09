import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'system_prefs.dart';

class SystemPrefsNotifier extends ChangeNotifier {
  SystemPrefsNotifier._();

  static final SystemPrefsNotifier _instance = SystemPrefsNotifier._();
  factory SystemPrefsNotifier() => _instance;

  bool _showHelpTooltips = SystemPrefs.defaultShowHelpTooltips;

  bool get showHelpTooltips => _showHelpTooltips;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _showHelpTooltips =
        prefs.getBool(SystemPrefs.showHelpTooltipsKey) ??
            SystemPrefs.defaultShowHelpTooltips;
    notifyListeners();
  }

  Future<void> setShowHelpTooltips(bool v) async {
    _showHelpTooltips = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(SystemPrefs.showHelpTooltipsKey, v);
  }
}

