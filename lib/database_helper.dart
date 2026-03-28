import 'dart:io';
import 'dart:typed_data';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;
import 'lang_db_service.dart';

// ── Category 模型 ──────────────────────────────────────────────
class CategoryEntry {
  final int? id;
  final String name;

  CategoryEntry({this.id, required this.name});

  factory CategoryEntry.fromMap(Map<String, dynamic> map) => CategoryEntry(
        id: map['id'] as int?,
        name: map['name'] as String,
      );
}

// ── DictionaryEntry 模型 ───────────────────────────────────────
/// Adapts to the actual GitHub DB schema:
///   table `word` (id, word, roman, audio_translation, audio_native,
///                 category TEXT, user_id, date_created, date_modified,
///                 use_count, is_favorite)
class DictionaryEntry {
  final int? id;
  final String word;         // 学习语言词汇
  final String translation;  // roman / 拼音 (maps to `roman` column)
  final String? createdAt;
  final String? lastUsedAt;
  final int correctCount;
  final int useCount;
  final int? categoryId;     // not in DB →derived at runtime
  final String? categoryName; // maps to `category` TEXT column
  final bool isFavorite;
  final String? audioTranslation;
  final String? audioNative;

  DictionaryEntry({
    this.id,
    required this.word,
    required this.translation,
    this.createdAt,
    this.lastUsedAt,
    this.correctCount = 0,
    this.useCount = 0,
    this.categoryId,
    this.categoryName,
    this.isFavorite = false,
    this.audioTranslation,
    this.audioNative,
  });

  // Legacy accessors for compatibility
  String get thai    => word;
  String get chinese => translation;

  /// Build from a row of the `word` table.
  /// When called from getAll/getByCategory, `translation` key is pre-injected
  /// with the native-language word from nativeDb. Falls back to `roman` only
  /// when no translation is available.
  factory DictionaryEntry.fromMap(Map<String, dynamic> map) {
    // Prefer explicitly injected 'translation' (native word), then roman
    final trans = (map['translation'] as String?);
    final roman = (map['roman'] as String?) ?? '';
    return DictionaryEntry(
      id: map['id'] as int?,
      word: (map['word'] as String?) ?? '',
      translation: (trans != null && trans.isNotEmpty) ? trans : roman,
      createdAt: (map['date_created'] as String?) ??
          (map['created_at'] as String?),
      lastUsedAt: (map['date_modified'] as String?) ??
          (map['last_used_at'] as String?),
      correctCount: (map['correct_count'] as int?) ?? 0,
      useCount: (map['use_count'] as int?) ?? 0,
      categoryId: map['category_id'] as int?,
      categoryName: (map['category_name'] as String?) ??
          (map['category'] as String?),
      isFavorite: ((map['is_favorite'] as int?) ?? 0) == 1,
      audioTranslation: map['audio_translation'] as String?,
      audioNative: map['audio_native'] as String?,
    );
  }

  String srcText(String targetLang) => word;
  String dstText(String nativeLang) => translation;
}

// ── DatabaseHelper ─────────────────────────────────────────────
/// Dual-database architecture using the actual GitHub DB schema:
///  - table `word` (instead of `dictionary`)
///  - table `category` (instead of `categories`)
///  - `roman` column for transliteration
///  - `category` TEXT column for category name (not FK)
class DatabaseHelper {
  static Database? _learnDb;
  static Database? _nativeDb;
  static Database? _photoDb;

  static String _learnLang = 'th';
  static String _nativeLang = 'zh_CN';

  // ── Initialise from downloaded files ─────────────────────────
  static Future<void> openWithLangs(
      String learnLang, String nativeLang) async {
    _learnLang = learnLang;
    _nativeLang = nativeLang;
    await _closeAll();
    _learnDb = await _openLangDb(learnLang);
    _nativeDb = await _openLangDb(nativeLang);
    // Open photo db if available (non-fatal)
    try {
      final photoPath = await LangDbService.photoDbLocalPath();
      if (File(photoPath).existsSync()) {
        _photoDb = await _openOrCreateDb(photoPath);
      }
    } catch (_) {}
  }

  static Future<void> _closeAll() async {
    try { await _learnDb?.close(); } catch (_) {}
    try { await _nativeDb?.close(); } catch (_) {}
    try { await _photoDb?.close(); } catch (_) {}
    _learnDb = null;
    _nativeDb = null;
    _photoDb = null;
  }

  /// Public alias used when language changes require DB file replacement.
  static Future<void> closeAll() => _closeAll();

  static Future<Database> get learnDb async {
    if (_learnDb != null) return _learnDb!;
    await _initDefaults();
    return _learnDb!;
  }

  static Future<Database> get nativeDb async {
    if (_nativeDb != null) return _nativeDb!;
    await _initDefaults();
    return _nativeDb!;
  }

  static Future<Database> get database => learnDb;

  // ── Default initialisation ──────────────────────────────────
  static Future<void> _initDefaults() async {
    if (_learnDb != null && _nativeDb != null) return;
    final learnPath  = await _localDbPath(_learnLang);
    final nativePath = await _localDbPath(_nativeLang);
    _learnDb  = await _openOrCreateDb(learnPath);
    _nativeDb = await _openOrCreateDb(nativePath);
    // Open photo db if available (non-fatal)
    if (_photoDb == null) {
      try {
        final photoPath = await LangDbService.photoDbLocalPath();
        if (File(photoPath).existsSync()) {
          _photoDb = await _openOrCreateDb(photoPath);
        }
      } catch (_) {}
    }
  }

  static Future<String> _localDbPath(String langCode) async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      return p.join(Directory.current.path, LangDbService.dbFileName(langCode));
    }
    return LangDbService.localPath(langCode);
  }

  static Future<Database> _openLangDb(String langCode) async {
    final path = await _localDbPath(langCode);
    return _openOrCreateDb(path);
  }

  static Future<Database> _openOrCreateDb(String dbPath) async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    return openDatabase(
      dbPath,
      onOpen: (db) async {
        await _ensureSchema(db);
      },
    );
  }

  /// Ensure the `word` and `category` tables exist with all required columns.
  /// Does NOT drop or recreate existing tables →only adds missing columns.
  static Future<void> _ensureSchema(Database db) async {
    // ── category table ──
    await db.execute('''
      CREATE TABLE IF NOT EXISTS category (
        id       INTEGER PRIMARY KEY AUTOINCREMENT,
        name     TEXT NOT NULL,
        user_id  INTEGER DEFAULT 0,
        UNIQUE(name, user_id)
      )
    ''');

    // ── word table ──
    final cols = await db.rawQuery('PRAGMA table_info(word)');
    final colNames = cols.map((c) => c['name'] as String).toSet();

    if (colNames.isEmpty) {
      // No word table →create it
      await db.execute('''
        CREATE TABLE IF NOT EXISTS word (
          id                INTEGER PRIMARY KEY,
          word              TEXT,
          roman             TEXT,
          audio_translation BLOB,
          audio_native      BLOB,
          category          TEXT,
          user_id           INTEGER DEFAULT 0,
          date_created      TEXT DEFAULT '',
          date_modified     TEXT,
          use_count         INTEGER DEFAULT 0,
          correct_count     INTEGER DEFAULT 0,
          is_favorite       INTEGER DEFAULT 0,
          hint              TEXT
        )
      ''');
      return;
    }

    // Add any missing columns
    final additions = <String, String>{
      'word':              'TEXT',
      'roman':             'TEXT',
      'audio_translation': 'BLOB',
      'audio_native':      'BLOB',
      'category':          'TEXT',
      'user_id':           'INTEGER DEFAULT 0',
      'date_created':      "TEXT DEFAULT ''",
      'date_modified':     'TEXT',
      'use_count':         'INTEGER DEFAULT 0',
      'correct_count':     'INTEGER DEFAULT 0',
      'is_favorite':       'INTEGER DEFAULT 0',
      'hint':              'TEXT',
    };
    for (final entry in additions.entries) {
      if (!colNames.contains(entry.key)) {
        try {
          await db.execute(
              'ALTER TABLE word ADD COLUMN ${entry.key} ${entry.value}');
        } catch (_) {}
      }
    }
  }

  // ── Legacy ──
  static Future<void> initDictionary() async => _initDefaults();
  static Future<void> fixNullCategories() async {}

  // ── Categories (from nativeDb `category` table) ────────────
  static Future<List<CategoryEntry>> getAllCategories() async {
    final db = await nativeDb;
    final maps = await db.query('category', orderBy: 'id ASC');
    return maps.map((m) => CategoryEntry.fromMap(m)).toList();
  }

  static Future<int> insertCategory(String name) async {
    final db = await nativeDb;
    return db.insert(
      'category',
      {'name': name.trim(), 'user_id': 0},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  static Future<int> insertCategoryWithTranslation(
      String nativeName, String learnTranslation) async {
    final nativeId = await (await nativeDb).insert(
      'category',
      {'name': nativeName.trim(), 'user_id': 0},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    try {
      await (await learnDb).insert(
        'category',
        {'name': learnTranslation.trim(), 'user_id': 0},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    } catch (_) {}
    return nativeId;
  }

  static Future<int> getOrCreateCategory(String name) async {
    final db = await nativeDb;
    final rows = await db.query('category',
        where: 'name = ?', whereArgs: [name.trim()]);
    if (rows.isNotEmpty) return rows.first['id'] as int;
    return insertCategory(name);
  }

  // ── Word operations (use `word` table) ─────────────────────

  /// Insert a word into BOTH databases.
  static Future<int> insert(
    String word,
    String translation, {
    int? nativeCategoryId,
    int? learnCategoryId,
    String? audioTranslation,
    String? audioNative,
    String? categoryName,
  }) async {
    final now = DateTime.now().toIso8601String();

    // Resolve category name if only id provided
    String? catName = categoryName;
    if (catName == null && nativeCategoryId != null) {
      final ndb = await nativeDb;
      final catRows = await ndb.query('category',
          where: 'id = ?', whereArgs: [nativeCategoryId], limit: 1);
      if (catRows.isNotEmpty) catName = catRows.first['name'] as String?;
    }

    final ldb = await learnDb;
    await ldb.insert(
      'word',
      {
        'word':              word.trim(),
        'roman':             translation.trim(),
        'date_created':      now,
        'use_count':         0,
        'correct_count':     0,
        'category':          catName ?? '',
        'is_favorite':       0,
        'audio_translation': audioTranslation,
        'audio_native':      audioNative,
        'user_id':           0,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    final ndb = await nativeDb;
    final id = await ndb.insert(
      'word',
      {
        'word':              translation.trim(),
        'roman':             word.trim(),
        'date_created':      now,
        'use_count':         0,
        'correct_count':     0,
        'category':          catName ?? '',
        'is_favorite':       0,
        'audio_translation': audioNative,
        'audio_native':      audioTranslation,
        'user_id':           0,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return id;
  }

  /// Check existence in learnDb by the three-way combination:
  /// learn-language word + native-language translation + category name.
  /// Two entries with same word/translation but different category are allowed.
  static Future<bool> exists(
      String word, String translation, String categoryName) async {
    final db = await learnDb;
    final rows = await db.query(
      'word',
      where: 'word = ? AND roman = ? AND category = ?',
      whereArgs: [word.trim(), translation.trim(), categoryName.trim()],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Build a lookup map: learnDb word id →nativeDb word text (translation).
  ///
  /// dict_TH and dict_CN share the same id space:
  ///   dict_TH.word.id == dict_CN.word.id  →same concept
  ///   dict_TH.word.word  = Thai text   (e.g. "ที→")
  ///   dict_TH.word.roman = Thai roman  (e.g. "thîi")
  ///   dict_CN.word.word  = Chinese text (e.g. "→地点")
  ///   dict_CN.word.roman = Chinese pinyin (e.g. "zài / dì diǎn")
  ///
  /// Join key: learnDb.word.id == nativeDb.word.id
  static Future<Map<int, String>> _buildNativeLookupById() async {
    final ndb = await nativeDb;
    final nativeRows = await ndb.rawQuery('SELECT id, word FROM word');
    final lookup = <int, String>{};
    for (final r in nativeRows) {
      final id  = r['id'] as int?;
      final val = (r['word'] as String? ?? '').trim();
      if (id != null && val.isNotEmpty) {
        lookup[id] = val;
      }
    }
    return lookup;
  }

  /// Get all entries, merging learnDb with nativeDb by matching word id.
  ///
  /// Category id join:
  ///   learnDb.category.name  = Thai category name  (e.g. "ไวยากรณ์")
  ///   learnDb.word.category  = Thai category name  →same string →join key
  ///   learnDb.category.id   == nativeDb.category.id (shared id space)
  ///   nativeDb.category.name = Chinese category name (e.g. "语法") →display
  static Future<List<DictionaryEntry>> getAll() async {
    final ldb = await learnDb;

    // Build category name →id map from LEARNDB category table
    // (learnDb.word.category stores Thai names, learnDb.category uses Thai names too)
    final lCatRows = await ldb.query('category');
    final learnCatNameToId = <String, int>{
      for (final r in lCatRows)
        (r['name'] as String): (r['id'] as int),
    };

    // Build lookup: nativeDb.word.id →nativeDb.word.word (Chinese translation)
    final nativeLookup = await _buildNativeLookupById();

    final maps = await ldb.rawQuery('SELECT * FROM word ORDER BY id DESC');
    return maps.map((m) {
      final wordId  = (m['id'] as int?);
      final catText = (m['category'] as String?) ?? '';
      // Use learnDb category table to resolve id (Thai name →shared id)
      final catId   = catText.isNotEmpty ? learnCatNameToId[catText] : null;
      // Join by word id to get Chinese translation
      final nativeWord = (wordId != null ? nativeLookup[wordId] : null) ?? '';
      return DictionaryEntry.fromMap({
        ...m,
        'category_id':   catId,
        'translation':   nativeWord,
        'category_name': catText,
      });
    }).toList();
  }

  /// Get entries by category id, with translation.
  /// catId is shared between learnDb and nativeDb category tables.
  static Future<List<DictionaryEntry>> getByCategory(
      int categoryId) async {
    final ldb = await learnDb;

    // Resolve category id →Thai name from learnDb.category
    final lCatRows = await ldb.query('category',
        where: 'id = ?', whereArgs: [categoryId], limit: 1);
    if (lCatRows.isEmpty) return [];
    final thaiCatName = lCatRows.first['name'] as String;

    // Query learnDb.word by Thai category name
    final maps = await ldb.rawQuery(
        'SELECT * FROM word WHERE category = ? ORDER BY id DESC', [thaiCatName]);

    // Build lookup: nativeDb.word.id →nativeDb.word.word (Chinese)
    final nativeLookup = await _buildNativeLookupById();

    return maps.map((m) {
      final wordId     = (m['id'] as int?);
      final nativeWord = (wordId != null ? nativeLookup[wordId] : null) ?? '';
      return DictionaryEntry.fromMap({
        ...m,
        'category_id': categoryId,
        'translation': nativeWord,
        'category_name': thaiCatName,
      });
    }).toList();
  }

  static Future<List<DictionaryEntry>> getFavorites() async {
    final ldb = await learnDb;
    final maps = await ldb.rawQuery('''
      SELECT * FROM word WHERE is_favorite = 1 ORDER BY id DESC
    ''');
    return maps.map((m) => DictionaryEntry.fromMap(m)).toList();
  }

  /// Increment correct_count and use_count
  static Future<void> incrementCorrectCount(int learnId) async {
    final now = DateTime.now().toIso8601String();
    final ldb = await learnDb;
    await ldb.rawUpdate('''
      UPDATE word
      SET correct_count = correct_count + 1,
          use_count     = use_count + 1,
          date_modified = ?
      WHERE id = ?
    ''', [now, learnId]);

    // Mirror in nativeDb by matching word+roman
    final rows = await ldb.query('word',
        where: 'id = ?', whereArgs: [learnId], limit: 1);
    if (rows.isNotEmpty) {
      final wordVal = rows.first['word'] as String? ?? '';
      final romanVal = rows.first['roman'] as String? ?? '';
      final ndb = await nativeDb;
      await ndb.rawUpdate('''
        UPDATE word
        SET use_count     = use_count + 1,
            date_modified = ?
        WHERE word = ? AND roman = ?
      ''', [now, romanVal, wordVal]);
    }
  }

  static Future<void> updateLastUsed(int id) async {
    final db = await learnDb;
    await db.update(
      'word',
      {'date_modified': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> updateCategoryId(int entryId, int? categoryId) async {
    // Resolve id →name, then update the TEXT column
    String? catName;
    if (categoryId != null) {
      final ndb = await nativeDb;
      final catRows = await ndb.query('category',
          where: 'id = ?', whereArgs: [categoryId], limit: 1);
      if (catRows.isNotEmpty) catName = catRows.first['name'] as String?;
    }
    final db = await learnDb;
    await db.update(
      'word',
      {'category': catName ?? ''},
      where: 'id = ?',
      whereArgs: [entryId],
    );
  }

  static Future<void> updateAudio(int id,
      {String? audioTranslation, String? audioNative}) async {
    final db = await learnDb;
    final data = <String, Object?>{};
    if (audioTranslation != null) data['audio_translation'] = audioTranslation;
    if (audioNative != null) data['audio_native'] = audioNative;
    if (data.isEmpty) return;
    await db.update('word', data, where: 'id = ?', whereArgs: [id]);
  }

  /// Fetch audio BLOB from learnDb.word:
  ///   field = 'audio_native'      →learn-language (e.g. Thai) audio
  ///   field = 'audio_translation' →native-language (e.g. Chinese) audio
  /// Returns null if no data or word not found.
  static Future<Uint8List?> getWordAudio(int wordId, String field) async {
    assert(field == 'audio_native' || field == 'audio_translation');
    final db = await learnDb;
    try {
      final rows = await db.rawQuery(
        'SELECT $field FROM word WHERE id = ? LIMIT 1',
        [wordId],
      );
      if (rows.isEmpty) return null;
      final blob = rows.first[field];
      if (blob == null) return null;
      if (blob is Uint8List) return blob;
      if (blob is List<int>) return Uint8List.fromList(blob);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Save audio BLOB back to learnDb.word.
  ///   field = 'audio_native'      →learn-language audio
  ///   field = 'audio_translation' →native-language audio
  static Future<void> saveWordAudio(
      int wordId, String field, Uint8List bytes) async {
    assert(field == 'audio_native' || field == 'audio_translation');
    final db = await learnDb;
    try {
      await db.update(
        'word',
        {field: bytes},
        where: 'id = ?',
        whereArgs: [wordId],
      );
    } catch (_) {}
  }

  static Future<bool> toggleFavorite(int id, bool current) async {
    final db = await learnDb;
    final newVal = current ? 0 : 1;
    await db.update(
      'word',
      {'is_favorite': newVal},
      where: 'id = ?',
      whereArgs: [id],
    );
    return newVal == 1;
  }

  static Future<Map<String, int>> bulkImport(
      List<Map<String, String>> rows, int nativeCategoryId) async {
    final ldb = await learnDb;
    final now = DateTime.now().toIso8601String();
    int inserted = 0;
    int skipped  = 0;

    // Resolve category name
    String catName = '';
    final ndb = await nativeDb;
    final catRows = await ndb.query('category',
        where: 'id = ?', whereArgs: [nativeCategoryId], limit: 1);
    if (catRows.isNotEmpty) catName = catRows.first['name'] as String? ?? '';

    final batch = ldb.batch();
    for (final row in rows) {
      final word  = (row['word'] ?? row['thai'] ?? '').trim();
      final trans = (row['translation'] ?? row['roman'] ?? row['chinese'] ?? '').trim();
      if (word.isEmpty || trans.isEmpty) { skipped++; continue; }
      batch.insert(
        'word',
        {
          'word':          word,
          'roman':         trans,
          'date_created':  now,
          'correct_count': 0,
          'use_count':     0,
          'category':      catName,
          'is_favorite':   0,
          'user_id':       0,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    final results = await batch.commit(noResult: false);
    for (final r in results) {
      if (r != null && (r as int) > 0) {
        inserted++;
      } else {
        skipped++;
      }
    }
    return {'inserted': inserted, 'skipped': skipped};
  }

  static Future<void> close() async => _closeAll();

  // ── Photo lookup ────────────────────────────────────────────
  /// Returns the English name (filename stem) stored in photo_dict for a word id.
  /// Table: photo_dict (rec_id, row_id, word TEXT, ...)
  /// The `word` column contains the English name used as the image filename stem.
  /// Returns null if not found or photo db not available.
  static Future<String?> getWordPhotoName(int wordId) async {
    await _initDefaults();
    final db = _photoDb;
    if (db == null) return null;
    try {
      final rows = await db.rawQuery(
        'SELECT word FROM photo_dict WHERE row_id = ? LIMIT 1',
        [wordId],
      );
      if (rows.isEmpty) return null;
      final name = rows.first['word'] as String?;
      if (name == null || name.trim().isEmpty) return null;
      return name.trim();
    } catch (_) {
      return null;
    }
  }

  // ── Hint lookup ─────────────────────────────────────────────
  /// Returns the hint text for a word id from learnDb, or null if none.
  static Future<String?> getWordHint(int wordId) async {
    await _initDefaults();
    final db = _learnDb;
    if (db == null) return null;
    try {
      final rows = await db.rawQuery(
        'SELECT hint FROM word WHERE id = ? LIMIT 1',
        [wordId],
      );
      if (rows.isEmpty) return null;
      final hint = rows.first['hint'] as String?;
      if (hint == null || hint.trim().isEmpty) return null;
      return hint.trim();
    } catch (_) {
      return null;
    }
  }

  /// Row count helpers for validation
  static Future<int> wordCount() async {
    final db = await learnDb;
    final r = await db.rawQuery('SELECT COUNT(*) as c FROM word');
    return (r.first['c'] as int?) ?? 0;
  }

  static Future<int> wordCountNative() async {
    final db = await nativeDb;
    final r = await db.rawQuery('SELECT COUNT(*) as c FROM word');
    return (r.first['c'] as int?) ?? 0;
  }
}
