import 'package:shared_preferences/shared_preferences.dart';

/// Tracks total API call counts, persisted across app restarts.
/// Usage:
///   await ApiLogService.increment(ApiName.googleTtsThai);
///   final counts = await ApiLogService.getAllCounts();
class ApiLogService {
  ApiLogService._();

  static const String _prefix = 'api_count_';

  /// Increment the call counter for [name] by 1.
  static Future<void> increment(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_prefix$name';
    final current = prefs.getInt(key) ?? 0;
    await prefs.setInt(key, current + 1);
  }

  /// Get the current count for [name].
  static Future<int> getCount(String name) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('$_prefix$name') ?? 0;
  }

  /// Get all recorded API names and their counts.
  /// Returns a list sorted by count descending.
  static Future<List<ApiCallStat>> getAllCounts() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith(_prefix)).toList();
    final stats = keys.map((k) {
      final name = k.substring(_prefix.length);
      final count = prefs.getInt(k) ?? 0;
      return ApiCallStat(name: name, count: count);
    }).toList();
    stats.sort((a, b) => b.count.compareTo(a.count));
    return stats;
  }

  /// Reset all counters (for testing / admin use).
  static Future<void> resetAll() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith(_prefix)).toList();
    for (final k in keys) {
      await prefs.remove(k);
    }
  }
}

/// Immutable data class for a single API call statistic.
class ApiCallStat {
  const ApiCallStat({required this.name, required this.count});
  final String name;
  final int count;
}

/// Well-known API name constants used throughout the app.
class ApiName {
  ApiName._();

  /// Google Translate TTS →Thai (tl=th)
  static const googleTtsThai   = 'Google TTS (th)';

  /// Google Translate TTS →Chinese (tl=zh-CN)
  static const googleTtsChinese = 'Google TTS (zh-CN)';
}
