import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'lang_db_service.dart';
import 'supabase_bootstrap.dart';

/// Fetches [vocabulary_bundles], [lessons], and [words] from Supabase and
/// writes a local SQLite file compatible with [DatabaseHelper].
///
/// Needs [Supabase.initialize] (via [SupabaseBootstrap.ensureInitialized]) and
/// RLS `SELECT` on those tables for the anon key.
class SupabaseVocabHydrator {
  SupabaseVocabHydrator._();

  static const _pageSize = 500;

  static Future<String> targetPath(String translateLang, String nativeLang) async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return p.join(
        Directory.current.path,
        LangDbService.dbFileNamePairForCurrentUser(translateLang, nativeLang),
      );
    }
    return LangDbService.localPathPair(translateLang, nativeLang);
  }

  static Uint8List? _decodeBytea(dynamic value) {
    if (value == null) return null;
    if (value is Uint8List) return value;
    if (value is List) {
      try {
        return Uint8List.fromList(
          value.map((e) => (e as num).toInt()).toList(),
        );
      } catch (_) {
        return null;
      }
    }
    if (value is String) {
      final s = value;
      if (s.startsWith(r'\x') || s.startsWith('\\x')) {
        final hex = s.startsWith(r'\x') ? s.substring(2) : s.substring(3);
        if (hex.length.isOdd) return null;
        final out = Uint8List(hex.length ~/ 2);
        for (var i = 0; i < hex.length; i += 2) {
          out[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
        }
        return out;
      }
      try {
        return base64Decode(s);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static int? _asInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE category (
        id             INTEGER PRIMARY KEY,
        name_native    TEXT NOT NULL DEFAULT '',
        name_translate TEXT NOT NULL DEFAULT '',
        name_EN        TEXT NOT NULL DEFAULT '',
        lesson_id      INTEGER DEFAULT 0,
        user_id        INTEGER DEFAULT 0,
        language_tag   TEXT,
        access         INTEGER DEFAULT 0,
        difficulty     INTEGER DEFAULT 0,
        date_created   TEXT,
        date_modified  TEXT,
        count          INTEGER DEFAULT 0,
        challenge      INTEGER DEFAULT 0,
        photo          TEXT,
        is_favorite    INTEGER DEFAULT 0,
        practice_type  INTEGER DEFAULT 0,
        count_down     INTEGER DEFAULT 5
      )
    ''');
    await db.execute('''
      CREATE TABLE word (
        id                       INTEGER PRIMARY KEY,
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
        is_favorite              INTEGER DEFAULT 0,
        correct_count            INTEGER DEFAULT 0,
        hint                     TEXT
      )
    ''');
  }

  /// Downloads vocabulary into the same path [DatabaseHelper] uses.
  static Future<String> hydrateToLocalFile({
    required String translateLang,
    required String nativeLang,
    void Function(String message)? onStatus,
  }) async {
    final client = Supabase.instance.client;

    onStatus?.call('Looking up cloud bundle…');
    final bundleRow = await client
        .from('vocabulary_bundles')
        .select()
        .eq('translate_lang', translateLang)
        .eq('native_lang', nativeLang)
        .maybeSingle();

    if (bundleRow == null) {
      throw Exception(
        'No vocabulary_bundles row for $translateLang / $nativeLang in Supabase.',
      );
    }

    final bundleId = bundleRow['id'];
    if (bundleId == null) {
      throw Exception('Invalid vocabulary_bundles row (missing id).');
    }

    final lessons = <Map<String, dynamic>>[];
    var off = 0;
    while (true) {
      onStatus?.call('Loading lessons ${lessons.length}…');
      final chunk = await client
          .from('lessons')
          .select()
          .eq('bundle_id', bundleId)
          .order('legacy_category_id', ascending: true)
          .range(off, off + _pageSize - 1);
      final list = List<Map<String, dynamic>>.from(chunk);
      if (list.isEmpty) break;
      lessons.addAll(list);
      if (list.length < _pageSize) break;
      off += _pageSize;
    }

    int? firstCategoryId;
    for (final lesson in lessons) {
      final lid = _asInt(lesson['legacy_category_id']);
      if (lid == null) continue;
      final prev = firstCategoryId;
      firstCategoryId = prev == null || lid < prev ? lid : prev;
    }

    final words = <Map<String, dynamic>>[];
    if (firstCategoryId != null) {
      off = 0;
      while (true) {
        onStatus?.call('Loading words for first lesson ($firstCategoryId): ${words.length}…');
        final chunk = await client
            .from('words')
            .select()
            .eq('bundle_id', bundleId)
            .eq('legacy_category_index', firstCategoryId)
            .order('id', ascending: true)
            .range(off, off + _pageSize - 1);
        final list = List<Map<String, dynamic>>.from(chunk);
        if (list.isEmpty) break;
        words.addAll(list);
        if (list.length < _pageSize) break;
        off += _pageSize;
      }
    }

    final path = await targetPath(translateLang, nativeLang);
    final f = File(path);
    if (f.existsSync()) {
      try {
        f.deleteSync();
      } catch (_) {}
    }

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    onStatus?.call(
      'Writing local database (${lessons.length} lessons, ${words.length} words)…',
    );
    final db = await openDatabase(
      path,
      version: 1,
      singleInstance: false,
      onCreate: (db, version) => _createSchema(db),
    );

    try {
      await db.transaction((txn) async {
        final b = txn.batch();
        for (final lesson in lessons) {
          final lid = _asInt(lesson['legacy_category_id']);
          if (lid == null) continue;
          b.insert('category', {
            'id': lid,
            'name_native': lesson['name_native'] ?? '',
            'name_translate': lesson['name_translate'] ?? '',
            'name_EN': lesson['name_en'] ?? '',
            'lesson_id': _asInt(lesson['lesson_id']) ?? 0,
            'user_id': _asInt(lesson['user_id']) ?? 0,
            'language_tag': lesson['language_tag'],
            'access': _asInt(lesson['access']) ?? 0,
            'difficulty': _asInt(lesson['difficulty']) ?? 0,
            'date_created': lesson['date_created']?.toString(),
            'date_modified': lesson['date_modified']?.toString(),
            'count': _asInt(lesson['count']) ?? 0,
            'challenge': _asInt(lesson['challenge']) ?? 0,
            'photo': lesson['photo']?.toString(),
            'is_favorite': _asInt(lesson['is_favorite']) ?? 0,
            'practice_type': _asInt(lesson['practice_type']) ?? 0,
            'count_down': _asInt(lesson['count_down']) ?? 5,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }

        for (final w in words) {
          final wid = _asInt(w['legacy_word_id']);
          if (wid == null) continue;
          b.insert('word', {
            'id': wid,
            'name_native': w['name_native'] ?? '',
            'name_translate': w['name_translate'] ?? '',
            'name_EN': w['name_en'] ?? '',
            'roman_native': w['roman_native']?.toString(),
            'roman_translate': w['roman_translate']?.toString(),
            'audio_translate': _decodeBytea(w['audio_translate']),
            'audio_native': _decodeBytea(w['audio_native']),
            'definition_native': w['definition_native']?.toString(),
            'action_native': w['action_native']?.toString(),
            'definition_translate': w['definition_translate']?.toString(),
            'action_translate': w['action_translate']?.toString(),
            'sample1_native': w['sample1_native']?.toString(),
            'sample1_translate': w['sample1_translate']?.toString(),
            'sample1_translate_roman': w['sample1_translate_roman']?.toString(),
            'sample1_native_audio': _decodeBytea(w['sample1_native_audio']),
            'sample1_translate_audio':
                _decodeBytea(w['sample1_translate_audio']),
            'category_index': _asInt(w['legacy_category_index']) ?? 0,
            'photo': w['photo']?.toString(),
            'user_id': _asInt(w['user_id']) ?? 0,
            'date_created': w['date_created']?.toString(),
            'date_modified': w['date_modified']?.toString(),
            'use_count': _asInt(w['use_count']) ?? 0,
            'is_favorite': _asInt(w['is_favorite']) ?? 0,
            'correct_count': _asInt(w['correct_count']) ?? 0,
            'hint': w['hint']?.toString(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await b.commit(noResult: true);
      });
    } finally {
      await db.close();
    }

    if (words.isEmpty) {
      throw Exception(
        firstCategoryId == null
            ? 'Supabase bundle has no lessons with legacy_category_id, or first lesson has no words.'
            : 'Supabase bundle has no words for the first lesson (category $firstCategoryId).',
      );
    }
    return path;
  }

  /// True when Supabase was initialized with an anon key.
  static bool get isAvailable => SupabaseBootstrap.clientOrNull != null;
}
