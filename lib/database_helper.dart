import 'dart:io';
import 'dart:typed_data';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;
import 'lang_db_service.dart';

// ═══════════════════════════════════════════════════════════════
// DIMAGO Database Schema  (dict_<translate>_<native>.db)
// Mirrors schema.sql exactly.
// ═══════════════════════════════════════════════════════════════
//
// TABLE: category
//   id              INTEGER PK AUTOINCREMENT
//   name_native     TEXT NOT NULL
//   name_translate  TEXT NOT NULL
//   name_EN         TEXT NOT NULL
//   lesson_id       INTEGER DEFAULT 0
//   user_id         INTEGER DEFAULT 0
//   language_tag    TEXT
//   access          INTEGER DEFAULT 0
//   difficulty      INTEGER DEFAULT 0
//   date_created    TEXT
//   date_modified   TEXT
//   count           INTEGER DEFAULT 0
//   challenge       INTEGER DEFAULT 0
//   photo           TEXT    SVG graphics file
//   is_favorite     INTEGER DEFAULT 0
//
// TABLE: word
//   id                       INTEGER PK
//   name_native              TEXT NOT NULL
//   name_translate           TEXT NOT NULL
//   name_EN                  TEXT NOT NULL
//   roman_native             TEXT
//   roman_translate          TEXT
//   audio_translate          BLOB    TTS audio for translate language
//   audio_native             BLOB    TTS audio for native language
//   definition_native        TEXT
//   action_native            TEXT
//   definition_translate     TEXT
//   action_translate         TEXT
//   sample1_native           TEXT
//   sample1_translate        TEXT
//   sample1_translate_roman  TEXT
//   sample1_native_audio     BLOB
//   sample1_translate_audio  BLOB
//   category_index           INTEGER FK → category.id
//   photo                    TEXT    SVG graphics file
//   user_id                  INTEGER DEFAULT 0
//   date_created             TEXT
//   date_modified            TEXT
//   use_count                INTEGER DEFAULT 0
//   is_favorite              INTEGER DEFAULT 0
// ═══════════════════════════════════════════════════════════════

// ── CategoryEntry model ────────────────────────────────────────
class CategoryEntry {
  final int? id;
  final String nameNative;      // display name (native language)
  final String nameTranslate;   // name in translate language
  final int challenge;
  final int practiceType;       // 0=word, 1=phrase, 2=photo
  final int countDown;          // challenge countdown seconds (default 5)
  /// Elapsed seconds per segment (score1..score8). Null = never completed.
  final List<int?> scores;

  // Keep .name for compatibility → returns nameNative
  String get name => nameNative;

  CategoryEntry({
    this.id,
    required this.nameNative,
    String? nameTranslate,
    this.challenge = 0,
    this.practiceType = 0,
    this.countDown = 5,
    List<int?>? scores,
  })  : nameTranslate = nameTranslate ?? nameNative,
        scores = scores ?? List.filled(8, null);

  factory CategoryEntry.fromMap(Map<String, dynamic> map) {
    // Support both new schema (name_native / name_translate) and old schema (name)
    final nameN = (map['name_native'] as String?) ??
        (map['name'] as String?) ?? '';
    final nameT = (map['name_translate'] as String?) ??
        (map['name'] as String?) ?? nameN;
    return CategoryEntry(
      id: map['id'] as int?,
      nameNative: nameN,
      nameTranslate: nameT,
      challenge: (map['challenge'] as int?) ?? 0,
      practiceType: (map['practice_type'] as int?) ?? 0,
      countDown: (map['count_down'] as int?) ?? 5,
      scores: List.generate(8, (i) => (map['score${i + 1}'] as num?)?.toInt()),
    );
  }
}

// ── DictionaryEntry model ──────────────────────────────────────
class DictionaryEntry {
  final int? id;
  final String nameTranslate;   // word in translate language
  final String nameNative;      // word in native language
  final String? romanTranslate; // romanization in translate language
  final String? romanNative;    // romanization in native language
  final int? categoryIdx;       // FK to category.id
  final String? categoryNameNative;
  final String? categoryNameTranslate;
  final bool isFavorite;
  final int correctCount;
  final int useCount;
  final String? createdAt;
  final String? lastUsedAt;
  /// Legacy shape `[sample1, null, null]` — only index 0 is used.
  final List<String?> samplesNative;
  final List<String?> samplesTranslate;
  final List<String?> samplesTranslateRoman;

  // Keep legacy accessors for compatibility
  String get word => nameTranslate;
  String get translation => nameNative;
  String get thai => nameTranslate;
  String get chinese => nameNative;

  // categoryId compat alias
  int? get categoryId => categoryIdx;
  String? get categoryName => categoryNameNative;

  DictionaryEntry({
    this.id,
    required this.nameTranslate,
    required this.nameNative,
    this.romanTranslate,
    this.romanNative,
    this.categoryIdx,
    this.categoryNameNative,
    this.categoryNameTranslate,
    this.isFavorite = false,
    this.correctCount = 0,
    this.useCount = 0,
    this.createdAt,
    this.lastUsedAt,
    List<String?>? sampleNativeList,
    List<String?>? sampleTranslateList,
    List<String?>? sampleTranslateRomanList,
  })  : samplesNative = sampleNativeList ?? [null, null, null],
        samplesTranslate = sampleTranslateList ?? [null, null, null],
        samplesTranslateRoman = sampleTranslateRomanList ?? [null, null, null];

  factory DictionaryEntry.fromMap(Map<String, dynamic> map) {
    // Support new schema columns first, then fall back to old columns
    final nameT = (map['name_translate'] as String?) ??
        (map['word'] as String?) ?? '';
    final nameN = (map['name_native'] as String?) ??
        (map['translation'] as String?) ??
        (map['roman'] as String?) ?? '';
    final romanT = (map['roman_translate'] as String?) ??
        (map['roman'] as String?);
    final romanN = (map['roman_native'] as String?);

    return DictionaryEntry(
      id: map['id'] as int?,
      nameTranslate: nameT,
      nameNative: nameN,
      romanTranslate: romanT,
      romanNative: romanN,
      categoryIdx: (map['category_index'] as int?) ??
          (map['category_id'] as int?),
      categoryNameNative: (map['category_name_native'] as String?) ??
          (map['category_name'] as String?) ??
          (map['category'] as String?),
      categoryNameTranslate: (map['category_name_translate'] as String?),
      isFavorite: ((map['is_favorite'] as int?) ?? 0) == 1,
      correctCount: (map['correct_count'] as int?) ?? 0,
      useCount: (map['use_count'] as int?) ?? 0,
      createdAt: (map['date_created'] as String?) ??
          (map['created_at'] as String?),
      lastUsedAt: (map['date_modified'] as String?) ??
          (map['last_used_at'] as String?),
      sampleNativeList: [
        map['sample1_native'] as String?,
        null,
        null,
      ],
      sampleTranslateList: [
        map['sample1_translate'] as String?,
        null,
        null,
      ],
      sampleTranslateRomanList: [
        map['sample1_translate_roman'] as String?,
        null,
        null,
      ],
    );
  }

  // Legacy srcText/dstText accessors for any remaining callers
  String srcText(String targetLang) => nameTranslate;
  String dstText(String nativeLang) => nameNative;
}

// ── DatabaseHelper ─────────────────────────────────────────────
class DatabaseHelper {
  static Database? _db;

  static String _translateLang = 'th';
  static String _nativeLang    = 'zh_CN';

  // ── Open single combined DB ───────────────────────────────────
  static Future<void> openWithLangs(
      String translateLang, String nativeLang) async {
    _translateLang = translateLang;
    _nativeLang    = nativeLang;
    await _closeAll();
    final path = await _localDbPath(translateLang, nativeLang);
    _db = await _openOrCreateDb(path);
  }

  static Future<void> _closeAll() async {
    try { await _db?.close(); } catch (_) {}
    _db = null;
  }

  static Future<void> closeAll() => _closeAll();

  // Backward-compat aliases
  static Future<Database> get learnDb async {
    if (_db != null) return _db!;
    await _initDefaults();
    return _db!;
  }

  static Future<Database> get nativeDb async {
    if (_db != null) return _db!;
    await _initDefaults();
    return _db!;
  }

  static Future<Database> get database => learnDb;

  // ── Default initialisation ────────────────────────────────────
  static Future<void> _initDefaults() async {
    if (_db != null) return;
    final path = await _localDbPath(_translateLang, _nativeLang);
    _db = await _openOrCreateDb(path);
  }

  static Future<String> _localDbPath(
      String translateLang, String nativeLang) async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      return p.join(
          Directory.current.path,
          LangDbService.dbFileNamePairForCurrentUser(
              translateLang, nativeLang));
    }
    return LangDbService.localPathPair(translateLang, nativeLang);
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

  /// Ensure tables exist with all required new-schema columns.
  /// Handles migration of old-schema DBs via ALTER TABLE.
  static Future<void> _ensureSchema(Database db) async {
    // ── category table ──
    await db.execute('''
      CREATE TABLE IF NOT EXISTS category (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        name_native    TEXT NOT NULL DEFAULT '',
        name_translate TEXT NOT NULL DEFAULT '',
        name_EN        TEXT NOT NULL DEFAULT '',
        lesson_id      INTEGER DEFAULT 0,
        user_id        INTEGER DEFAULT 0,
        language_tag   TEXT,
        lang_translate TEXT,
        lang_native    TEXT,
        access         INTEGER DEFAULT 0,
        difficulty     INTEGER DEFAULT 0,
        date_created   TEXT,
        date_modified  TEXT,
        count          INTEGER DEFAULT 0,
        challenge      INTEGER DEFAULT 0,
        photo          TEXT,
        is_favorite    INTEGER DEFAULT 0,
        practice_type  INTEGER DEFAULT 0,
        count_down     INTEGER DEFAULT 5,
        score1         INTEGER,
        score2         INTEGER,
        score3         INTEGER,
        score4         INTEGER,
        score5         INTEGER,
        score6         INTEGER,
        score7         INTEGER,
        score8         INTEGER,
        UNIQUE(name_native)
      )
    ''');

    // Migrate old category table: add missing columns then ALWAYS backfill
    final catCols = await db.rawQuery('PRAGMA table_info(category)');
    final catColNames = catCols.map((c) => c['name'] as String).toSet();

    // Add any missing category columns
    final catAdditions = <String, String>{
      'name_native':   "TEXT NOT NULL DEFAULT ''",
      'name_translate':"TEXT NOT NULL DEFAULT ''",
      'name_EN':       "TEXT NOT NULL DEFAULT ''",
      'lesson_id':     'INTEGER DEFAULT 0',
      'user_id':       'INTEGER DEFAULT 0',
      'language_tag':  'TEXT',
      'lang_translate': 'TEXT',
      'lang_native':   'TEXT',
      'access':        'INTEGER DEFAULT 0',
      'difficulty':    'INTEGER DEFAULT 0',
      'date_created':  'TEXT',
      'date_modified': 'TEXT',
      'count':         'INTEGER DEFAULT 0',
      'challenge':     'INTEGER DEFAULT 0',
      'photo':         'TEXT',
      'is_favorite':   'INTEGER DEFAULT 0',
      'practice_type': 'INTEGER DEFAULT 0',
      'count_down':    'INTEGER DEFAULT 5',
      'score1': 'INTEGER',
      'score2': 'INTEGER',
      'score3': 'INTEGER',
      'score4': 'INTEGER',
      'score5': 'INTEGER',
      'score6': 'INTEGER',
      'score7': 'INTEGER',
      'score8': 'INTEGER',
    };
    for (final entry in catAdditions.entries) {
      if (!catColNames.contains(entry.key)) {
        try { await db.execute('ALTER TABLE category ADD COLUMN ${entry.key} ${entry.value}'); } catch (_) {}
      }
    }

    // ALWAYS backfill empty name_native from old 'name' column (safe – WHERE guards)
    if (catColNames.contains('name')) {
      try {
        await db.rawUpdate(
          "UPDATE category SET name_native = name WHERE (name_native IS NULL OR name_native = '') AND name IS NOT NULL AND name != ''");
      } catch (_) {}
    }
    // ALWAYS backfill empty name_translate from name_native
    try {
      await db.rawUpdate(
        "UPDATE category SET name_translate = name_native WHERE (name_translate IS NULL OR name_translate = '') AND name_native IS NOT NULL AND name_native != ''");
    } catch (_) {}

    // ── word table ──
    final cols = await db.rawQuery('PRAGMA table_info(word)');
    final colNames = cols.map((c) => c['name'] as String).toSet();

    if (colNames.isEmpty) {
      // Create fresh new-schema word table matching schema.sql exactly
      await db.execute('''
        CREATE TABLE IF NOT EXISTS word (
          id                       INTEGER PRIMARY KEY AUTOINCREMENT,
          name_native              TEXT    NOT NULL DEFAULT '',
          name_translate           TEXT    NOT NULL DEFAULT '',
          name_EN                  TEXT    NOT NULL DEFAULT '',
          roman_native             TEXT,
          roman_translate          TEXT,
          audio_translate          BLOB,
          audio_native             BLOB,
          definition_native        TEXT,
          action_native            TEXT,
          definition_translate     TEXT,
          action_translate         TEXT,
          sample1_native           TEXT,
          sample1_translate        TEXT,
          sample1_translate_roman  TEXT,
          sample1_native_audio     BLOB,
          sample1_translate_audio  BLOB,
          category_index           INTEGER DEFAULT 0,
          photo                    TEXT,
          user_id                  INTEGER DEFAULT 0,
          date_created             TEXT,
          date_modified            TEXT,
          use_count                INTEGER DEFAULT 0,
          is_favorite              INTEGER DEFAULT 0
        )
      ''');
      return;
    }

    // Migrate existing word table: add any missing columns (matches schema.sql)
    final additions = <String, String>{
      'name_native':               "TEXT DEFAULT ''",
      'name_translate':            "TEXT DEFAULT ''",
      'name_EN':                   "TEXT DEFAULT ''",
      'roman_native':              'TEXT',
      'roman_translate':           'TEXT',
      'audio_translate':           'BLOB',
      'audio_native':              'BLOB',
      'definition_native':         'TEXT',
      'action_native':             'TEXT',
      'definition_translate':      'TEXT',
      'action_translate':          'TEXT',
      'sample1_native':            'TEXT',
      'sample1_translate':         'TEXT',
      'sample1_translate_roman':   'TEXT',
      'sample1_native_audio':        'BLOB',
      'sample1_translate_audio':     'BLOB',
      'category_index':            'INTEGER DEFAULT 0',
      'photo':                     'TEXT',
      'user_id':                   'INTEGER DEFAULT 0',
      'date_created':              'TEXT',
      'date_modified':             'TEXT',
      'use_count':                 'INTEGER DEFAULT 0',
      'is_favorite':               'INTEGER DEFAULT 0',
      // Legacy columns kept for backward compat with old DBs
      'correct_count':             'INTEGER DEFAULT 0',
      'hint':                      'TEXT',
    };
    for (final entry in additions.entries) {
      if (!colNames.contains(entry.key)) {
        try {
          await db.execute(
              'ALTER TABLE word ADD COLUMN ${entry.key} ${entry.value}');
        } catch (_) {}
      }
    }

    // Migrate data: if old schema had 'word'/'roman' columns, copy to new columns
    if (colNames.contains('word') && !colNames.contains('name_translate_migrated')) {
      try {
        await db.execute(
            'UPDATE word SET name_translate = word WHERE name_translate = \'\' OR name_translate IS NULL');
      } catch (_) {}
    }
    if (colNames.contains('roman') && !colNames.contains('roman_translate')) {
      // roman_translate was just added above via ALTER TABLE
      try {
        await db.execute(
            'UPDATE word SET roman_translate = roman WHERE roman_translate IS NULL');
      } catch (_) {}
    }
    // Migrate category TEXT column → category_index.
    // Note: colNames is pre-ALTER-TABLE snapshot, so we only check for the OLD
    // 'category' column; category_index was just added (or already exists).
    if (colNames.contains('category')) {
      try {
        await db.execute('''
          UPDATE word SET category_index = (
            SELECT c.id FROM category c
            WHERE c.name_native = word.category
               OR c.name_translate = word.category
            LIMIT 1
          )
          WHERE (category_index IS NULL OR category_index = 0)
            AND category IS NOT NULL AND category != ''
        ''');
      } catch (_) {}
    }
    // Migrate old sample columns
    if (colNames.contains('sample1')) {
      try {
        await db.execute('UPDATE word SET sample1_translate = sample1 WHERE sample1_translate IS NULL AND sample1 IS NOT NULL');
      } catch (_) {}
    }

    // Migrate old definition column
    if (colNames.contains('definition')) {
      try {
        await db.execute('UPDATE word SET definition_native = definition WHERE definition_native IS NULL AND definition IS NOT NULL');
      } catch (_) {}
    }
    // Migrate old action column
    if (colNames.contains('action')) {
      try {
        await db.execute('UPDATE word SET action_native = action WHERE action_native IS NULL AND action IS NOT NULL');
      } catch (_) {}
    }
    // audio_translate is the canonical column name (per schema.sql)
  }

  // ── Legacy ───────────────────────────────────────────────────
  static Future<void> initDictionary() async => _initDefaults();
  static Future<void> fixNullCategories() async {}

  // ── Categories ────────────────────────────────────────────────
  static Future<List<CategoryEntry>> getAllCategories() async {
    final db = await learnDb;
    final maps = await db.query('category', orderBy: 'id ASC');
    return maps.map((m) => CategoryEntry.fromMap(m)).toList();
  }

  /// [category.id] values that have at least one word row locally (on-demand content loaded).
  static Future<Set<int>> categoryIdsWithWordsLoaded() async {
    final db = await learnDb;
    final rows = await db.rawQuery('''
      SELECT DISTINCT category_index AS c FROM word
      WHERE category_index IS NOT NULL AND category_index > 0
    ''');
    final out = <int>{};
    for (final r in rows) {
      final v = r['c'];
      if (v is int) {
        out.add(v);
      } else if (v is num) {
        out.add(v.toInt());
      }
    }
    return out;
  }

  static Future<int> insertCategory(String name) async {
    final db = await learnDb;
    return db.insert(
      'category',
      {'name_native': name.trim(), 'name_translate': name.trim()},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  static Future<int> insertCategoryWithTranslation(
      String nativeName, String translateName) async {
    final db = await learnDb;
    return db.insert(
      'category',
      {
        'name_native':    nativeName.trim(),
        'name_translate': translateName.trim(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  static Future<int> getOrCreateCategory(String name) async {
    final db = await learnDb;
    final rows = await db.query('category',
        where: 'name_native = ?', whereArgs: [name.trim()]);
    if (rows.isNotEmpty) return rows.first['id'] as int;
    return insertCategory(name);
  }

  // ── Word operations ──────────────────────────────────────────

  /// Insert a word into the single combined DB.
  static Future<int> insert(
    String nameTranslate,
    String nameNative, {
    int? nativeCategoryId,
    int? learnCategoryId,
    String? audioTranslation,
    String? audioNative,
    String? categoryName,
  }) async {
    final db = await learnDb;
    final now = DateTime.now().toIso8601String();
    final catId = learnCategoryId ?? nativeCategoryId;

    final id = await db.insert(
      'word',
      {
        'name_translate':  nameTranslate.trim(),
        'name_native':     nameNative.trim(),
        'date_created':    now,
        'use_count':       0,
        'category_index':  catId ?? 0,
        'is_favorite':         0,
        'audio_translate':     audioTranslation,
        'audio_native':        audioNative,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return id;
  }

  /// Check if a word already exists in the DB.
  static Future<bool> exists(
      String nameTranslate, String nameNative, String categoryName) async {
    final db = await learnDb;
    // Try new schema first
    final rows = await db.query(
      'word',
      where: 'name_translate = ? AND name_native = ?',
      whereArgs: [nameTranslate.trim(), nameNative.trim()],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Get all entries with category join.
  static Future<List<DictionaryEntry>> getAll() async {
    final db = await learnDb;
    final maps = await db.rawQuery('''
      SELECT word.*,
             category.name_native    AS category_name_native,
             category.name_translate AS category_name_translate
      FROM word
      LEFT JOIN category ON word.category_index = category.id
                         AND word.category_index > 0
      ORDER BY word.id DESC
    ''');
    return maps.map((m) => DictionaryEntry.fromMap(m)).toList();
  }

  /// Get entries by category id.
  static Future<List<DictionaryEntry>> getByCategory(int categoryId) async {
    final db = await learnDb;
    final maps = await db.rawQuery('''
      SELECT word.*,
             category.name_native    AS category_name_native,
             category.name_translate AS category_name_translate
      FROM word
      LEFT JOIN category ON word.category_index = category.id
      WHERE word.category_index = ?
      ORDER BY word.id DESC
    ''', [categoryId]);
    return maps.map((m) => DictionaryEntry.fromMap(m)).toList();
  }

  static Future<List<DictionaryEntry>> getFavorites() async {
    final db = await learnDb;
    final maps = await db.rawQuery('''
      SELECT word.*,
             category.name_native    AS category_name_native,
             category.name_translate AS category_name_translate
      FROM word
      LEFT JOIN category ON word.category_index = category.id
      WHERE word.is_favorite = 1
      ORDER BY word.id DESC
    ''');
    return maps.map((m) => DictionaryEntry.fromMap(m)).toList();
  }

  /// Increment correct_count and use_count
  static Future<void> incrementCorrectCount(int id) async {
    final now = DateTime.now().toIso8601String();
    final db = await learnDb;
    await db.rawUpdate('''
      UPDATE word
      SET correct_count = correct_count + 1,
          use_count     = use_count + 1,
          date_modified = ?
      WHERE id = ?
    ''', [now, id]);
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
    final db = await learnDb;
    await db.update(
      'word',
      {'category_index': categoryId ?? 0},
      where: 'id = ?',
      whereArgs: [entryId],
    );
  }

  static Future<void> updateAudio(int id,
      {String? audioTranslation, String? audioNative}) async {
    final db = await learnDb;
    final data = <String, Object?>{};
    if (audioTranslation != null) data['audio_translate'] = audioTranslation;
    if (audioNative != null)      data['audio_native']      = audioNative;
    if (data.isEmpty) return;
    await db.update('word', data, where: 'id = ?', whereArgs: [id]);
  }

  /// Fetch audio BLOB.
  ///   field = 'audio_native'          → headword native audio
  ///   field = 'sample1_native_audio'  → phrase sample 1 native audio
  ///   field = 'audio_translate'       → translate-language audio
  ///   field = 'audio_translation'     → legacy alias, maps to audio_translate
  static Future<Uint8List?> getWordAudio(int wordId, String field) async {
    // Normalise legacy callers: audio_translation → audio_translate
    final col = (field == 'audio_translation') ? 'audio_translate' : field;
    final db = await learnDb;
    try {
      final rows = await db.rawQuery(
        'SELECT $col FROM word WHERE id = ? LIMIT 1',
        [wordId],
      );
      if (rows.isEmpty) return null;
      final blob = rows.first[col];
      if (blob == null) return null;
      if (blob is Uint8List) return blob;
      if (blob is List<int>) return Uint8List.fromList(blob);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Save audio BLOB.
  static Future<void> saveWordAudio(
      int wordId, String field, Uint8List bytes) async {
    // Normalise legacy callers: audio_translation → audio_translate
    final col = (field == 'audio_translation') ? 'audio_translate' : field;
    final db = await learnDb;
    try {
      await db.update('word', {col: bytes},
          where: 'id = ?', whereArgs: [wordId]);
    } catch (_) {}
  }

  static Future<bool> toggleFavorite(int id, bool current) async {
    final db = await learnDb;
    final newVal = current ? 0 : 1;
    await db.update('word', {'is_favorite': newVal},
        where: 'id = ?', whereArgs: [id]);
    return newVal == 1;
  }

  static Future<void> close() async => _closeAll();

  /// Decodes [challenge] into 8 digits (index 0 = MSD), matching the circular-score encoding.
  static List<int> _challengeDigits(int challenge) {
    final raw = challenge.abs().toString();
    final s = raw.length < 8
        ? '0' * (8 - raw.length) + raw
        : raw.substring(raw.length - 8);
    return List<int>.generate(8, (i) {
      final ch = s.codeUnitAt(i);
      return (ch >= 0x30 && ch <= 0x39) ? ch - 0x30 : 0;
    });
  }

  /// Re-encodes 8 digits (index 0 = MSD) back into the challenge integer.
  static int _encodeChallenge(List<int> digits) {
    var v = 0;
    for (final d in digits) {
      v = v * 10 + d.clamp(0, 9);
    }
    return v;
  }

  /// Sets digit [segmentIndex] (0–7, 0 = MSD) of [category.challenge] to [score] (0–9).
  /// Segment mapping matches challenge-mapping.txt:
  ///   0 translate→word→talk    1 translate→word→choice
  ///   2 translate→phrase→talk  3 translate→phrase→choice
  ///   4 native→word→talk       5 native→word→choice
  ///   6 native→phrase→talk     7 native→phrase→choice
  static Future<void> updateChallengeSegment(
      int categoryId, int segmentIndex, int score) async {
    assert(segmentIndex >= 0 && segmentIndex < 8);
    final db = await learnDb;
    try {
      final rows = await db.rawQuery(
        'SELECT challenge FROM category WHERE id = ? LIMIT 1', [categoryId]);
      if (rows.isEmpty) return;
      final current = (rows.first['challenge'] as int?) ?? 0;
      final digits = _challengeDigits(current);
      digits[segmentIndex] = score.clamp(0, 9);
      await db.rawUpdate(
        'UPDATE category SET challenge = ? WHERE id = ?',
        [_encodeChallenge(digits), categoryId],
      );
    } catch (_) {}
  }

  /// Saves elapsed challenge seconds into score[segmentIndex+1] column (0-based segment).
  static Future<void> updateScoreSegment(
      int categoryId, int segmentIndex, int elapsedSeconds) async {
    assert(segmentIndex >= 0 && segmentIndex < 8);
    final col = 'score${segmentIndex + 1}';
    final db = await learnDb;
    try {
      await db.rawUpdate(
        'UPDATE category SET $col = ? WHERE id = ?',
        [elapsedSeconds, categoryId],
      );
    } catch (_) {}
  }

  /// Legacy: increments category.challenge by 1 (capped at 5). Kept for backward compat.
  static Future<void> incrementCategoryChallenge(int categoryId) async {
    final db = await learnDb;
    try {
      await db.rawUpdate(
        'UPDATE category SET challenge = MIN(COALESCE(challenge, 0) + 1, 5) WHERE id = ?',
        [categoryId],
      );
    } catch (_) {}
  }

  static Future<void> updateCategoryPracticeType(int id, int type) async {
    final db = await learnDb;
    try {
      await db.update('category', {'practice_type': type},
          where: 'id = ?', whereArgs: [id]);
    } catch (_) {}
  }

  static Future<void> updateCategoryCountDown(int id, int seconds) async {
    final db = await learnDb;
    try {
      await db.update('category', {'count_down': seconds},
          where: 'id = ?', whereArgs: [id]);
    } catch (_) {}
  }

  // ── Photo lookup ─────────────────────────────────────────────
  /// Photo DB is no longer bundled; always returns null.
  static Future<String?> getWordPhotoName(int wordId) async => null;

  // ── Hint lookup ──────────────────────────────────────────────
  static Future<String?> getWordHint(int wordId) async {
    await _initDefaults();
    if (_db == null) return null;
    try {
      final rows = await _db!.rawQuery(
        'SELECT hint FROM word WHERE id = ? LIMIT 1', [wordId]);
      if (rows.isEmpty) return null;
      final hint = (rows.first['hint'] as String?)?.trim();
      return (hint != null && hint.isNotEmpty) ? hint : null;
    } catch (_) {
      return null;
    }
  }

  // ── Sample sentences ─────────────────────────────────────────
  /// Headword romanization in translate language (`roman_translate`).
  static Future<String?> getWordRomanTranslate(int wordId) async {
    final db = await learnDb;
    try {
      final rows = await db.rawQuery(
        'SELECT roman_translate FROM word WHERE id = ? LIMIT 1',
        [wordId],
      );
      if (rows.isEmpty) return null;
      final v = rows.first['roman_translate'] as String?;
      if (v == null) return null;
      final t = v.trim();
      return t.isEmpty ? null : t;
    } catch (_) {
      return null;
    }
  }

  /// Sample1 fields: `translate`, `native`, `roman` (= `sample1_translate_roman`).
  static Future<Map<String, String?>> getWordSample1(int wordId) async {
    final db = await learnDb;
    final rows = await db.rawQuery(
      'SELECT sample1_translate, sample1_native, sample1_translate_roman '
      'FROM word WHERE id = ? LIMIT 1',
      [wordId],
    );
    if (rows.isEmpty) {
      return {'translate': null, 'native': null, 'roman': null};
    }
    final m = rows.first;
    return {
      'translate': m['sample1_translate'] as String?,
      'native': m['sample1_native'] as String?,
      'roman': m['sample1_translate_roman'] as String?,
    };
  }

  static Future<Map<String, List<String?>>> getWordAllSamples(int wordId) async {
    await _initDefaults();
    final translate = <String?>[null, null, null];
    final native = <String?>[null, null, null];

    if (_db != null) {
      try {
        final rows = await _db!.rawQuery(
          'SELECT sample1_translate, sample1_native FROM word WHERE id = ? LIMIT 1',
          [wordId],
        );
        if (rows.isNotEmpty) {
          final vt = (rows.first['sample1_translate'] as String?)?.trim();
          if (vt != null && vt.isNotEmpty) translate[0] = vt;
          final vn = (rows.first['sample1_native'] as String?)?.trim();
          if (vn != null && vn.isNotEmpty) native[0] = vn;
        }
      } catch (_) {}
    }
    return {'translate': translate, 'native': native};
  }

  /// Clears sample_native columns for ALL words (used after fresh DB download).
  static Future<void> clearNativeSamples() async {
    await _initDefaults();
    if (_db == null) return;
    try {
      await _db!.rawUpdate('UPDATE word SET sample1_native = NULL');
    } catch (_) {}
  }

  /// Saves sample1_native only (legacy API kept for callers passing slot 1).
  static Future<void> updateNativeSampleSlot(
      int wordId, int slot, String value) async {
    assert(slot == 1);
    await _initDefaults();
    if (_db == null) return;
    try {
      await _db!.rawUpdate(
        'UPDATE word SET sample1_native = ? WHERE id = ?',
        [value, wordId],
      );
    } catch (_) {}
  }

  /// Saves sample1 translate and/or native for the given word id.
  static Future<void> updateSample1(int wordId,
      {String? translateSample, String? nativeSample,
       // legacy param names
       String? learnSample}) async {
    await _initDefaults();
    if (_db == null) return;
    final t = translateSample ?? learnSample;
    if (t != null) {
      try {
        await _db!.rawUpdate(
            'UPDATE word SET sample1_translate = ? WHERE id = ?', [t, wordId]);
      } catch (_) {}
    }
    if (nativeSample != null) {
      try {
        await _db!.rawUpdate(
            'UPDATE word SET sample1_native = ? WHERE id = ?',
            [nativeSample, wordId]);
      } catch (_) {}
    }
  }

  // ── Definition ────────────────────────────────────────────────
  /// Returns {'native': String?} for word.definition_native.
  static Future<Map<String, String?>> getWordDefinition(int wordId) async {
    await _initDefaults();
    String? native;
    if (_db != null) {
      try {
        final rows = await _db!.rawQuery(
            'SELECT definition_native FROM word WHERE id = ? LIMIT 1', [wordId]);
        if (rows.isNotEmpty) {
          final v = (rows.first['definition_native'] as String?)?.trim();
          if (v != null && v.isNotEmpty) native = v;
        }
      } catch (_) {}
    }
    return {'native': native};
  }

  /// Saves definition text to the single DB.
  static Future<void> updateDefinition(int wordId,
      {String? nativeDefinition,
       // legacy param
       String? learnDefinition}) async {
    await _initDefaults();
    if (_db == null) return;
    if (nativeDefinition != null) {
      try {
        await _db!.rawUpdate(
            'UPDATE word SET definition_native = ? WHERE id = ?',
            [nativeDefinition, wordId]);
      } catch (_) {}
    }
  }

  // ── Action content ────────────────────────────────────────────
  /// Returns the action_native text for the given word id, or null.
  static Future<String?> getWordAction(int wordId) async {
    await _initDefaults();
    if (_db == null) return null;
    try {
      final rows = await _db!.rawQuery(
        'SELECT action_native FROM word WHERE id = ? LIMIT 1', [wordId]);
      if (rows.isEmpty) return null;
      final v = (rows.first['action_native'] as String?)?.trim();
      return (v != null && v.isNotEmpty) ? v : null;
    } catch (_) {
      return null;
    }
  }

  // ── Photo (SVG) ──────────────────────────────────────────────
  /// Returns the SVG text stored in word.photo (TEXT column), or null if empty.
  static Future<String?> getWordPhoto(int wordId) async {
    await _initDefaults();
    if (_db == null) return null;
    try {
      final rows = await _db!.rawQuery(
        'SELECT photo FROM word WHERE id = ? LIMIT 1', [wordId]);
      if (rows.isEmpty) return null;
      final raw = (rows.first['photo'] as String?)?.trim();
      return (raw == null || raw.isEmpty) ? null : raw;
    } catch (_) {}
    return null;
  }

  // ── Row count helpers ─────────────────────────────────────────
  static Future<int> wordCount() async {
    final db = await learnDb;
    final r = await db.rawQuery('SELECT COUNT(*) as c FROM word');
    return (r.first['c'] as int?) ?? 0;
  }

  /// Backward-compat alias — same DB, same count.
  static Future<int> wordCountNative() async => wordCount();
}
