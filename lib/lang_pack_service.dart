import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'database_helper.dart';
import 'talk_asr_service.dart';

// ════════════════════════════════════════════════════════════════
// LangPackService
// →GitHub 下载语言→SQLite，并将词汇导入本地词典数据库
// ════════════════════════════════════════════════════════════════

/// 语言→ID，例→'th-cn'→th-tw'→th-en'
/// 对应 GitHub 上的 lango-lang-{id}.db
class LangPackService {
  static const _baseUrl =
      'https://raw.githubusercontent.com/donhsi1/lango-langs/main/db';
  static const _prefKey = 'lang_pack_installed'; // 已安装的 pack id

  /// 构造下→URL
  static String packUrl(String packId) => '$_baseUrl/lango-lang-$packId.db';

  /// 根据 targetLang + nativeLang 推导 packId
  /// 目前支持：th + zh(CN/TW) →th-cn/th-tw；th + en →th-en
  static String resolvePackId(String targetLang, String nativeLang, String uiLang) {
    if (targetLang == 'th') {
      if (nativeLang == 'en') return 'th-en';
      if (uiLang == 'zh_TW') return 'th-tw';
      return 'th-cn'; // zh_CN 或默→'
    }
    return 'th-cn';
  }

  // ── 已安装状→────────────────────────────────────────────────

  static Future<bool> isInstalled(String packId) async {
    final prefs = await SharedPreferences.getInstance();
    final installed = prefs.getStringList(_prefKey) ?? [];
    return installed.contains(packId);
  }

  static Future<void> _markInstalled(String packId) async {
    final prefs = await SharedPreferences.getInstance();
    final installed = (prefs.getStringList(_prefKey) ?? []).toSet();
    installed.add(packId);
    await prefs.setStringList(_prefKey, installed.toList());
  }

  /// Maps lango pack id → `[targetLang, nativeLang]` for ASR / Talk routing.
  static List<String> langsFromPackId(String packId) {
    switch (packId) {
      case 'th-tw':
        return const ['th', 'zh_TW'];
      case 'th-en':
        return const ['th', 'en_US'];
      case 'th-cn':
      default:
        return const ['th', 'zh_CN'];
    }
  }

  // ── 主入口：下载 + 导入 ───────────────────────────────────────

  /// [onProgress] 回调 0.0 ~ 1.0
  static Future<void> downloadAndImport({
    required String packId,
    required void Function(double progress, String status) onProgress,
  }) async {
    onProgress(0.0, '');

    // 1. 下载到临时目→'
    final url = packUrl(packId);
    final tmpDir = await getTemporaryDirectory();
    final tmpFile = File(p.join(tmpDir.path, 'lango-$packId.db'));

    final client = http.Client();
    late final Future<void> asrWarmup;
    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request);

      if (response.statusCode != 200) {
        throw Exception('Download failed: HTTP ${response.statusCode}');
      }

      asrWarmup = TalkAsrService.warmupForLanguages(langsFromPackId(packId));

      final total = response.contentLength ?? 0;
      var received = 0;
      final sink = tmpFile.openWrite();

      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress(received / total * 0.7, '');
        }
      }
      await sink.close();
    } finally {
      client.close();
    }

    onProgress(0.75, '');

    // 2. 打开下载的语言→DB，读取词→'
    final packDb = await openDatabase(tmpFile.path, readOnly: true);
    final rows = await packDb.query('words');
    await packDb.close();

    onProgress(0.85, '');

    // 3. 导入到本地词→DB
    final localDb = await DatabaseHelper.database;

    // 查找或创→"lango-system" 类别
    const catName = 'lango';
    var cats = await localDb.query('categories', where: 'name = ?', whereArgs: [catName]);
    int catId;
    if (cats.isEmpty) {
      catId = await localDb.insert('categories', {'name': catName});
    } else {
      catId = cats.first['id'] as int;
    }

    // 批量 INSERT OR IGNORE（已存在的泰→中文组合跳过→'
    final batch = localDb.batch();
    for (final row in rows) {
      batch.insert(
        'dictionary',
        {
          'thai': row['thai'],
          'chinese': row['translation'],
          'category_id': catId,
          'correct_count': 0,
          'is_favorite': 0,
          'created_at': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);

    // 4. 清理临时文件
    try { await tmpFile.delete(); } catch (_) {}

    await _markInstalled(packId);
    try {
      await asrWarmup;
    } catch (_) {}
    onProgress(1.0, '');
  }
}
