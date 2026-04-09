import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_bootstrap.dart';

// ── Models ───────────────────────────────────────────────────────

class CommunityUser {
  final String id;
  final String nickName;
  final String country;
  final String translateLang;
  final String nativeLang;
  final String? avatarUrl;
  final int totalScore; // Σ over lessons of (score1+…+score8) in user_lesson_scores

  List<UserLessonScore> lessonScores; // populated on demand

  CommunityUser({
    required this.id,
    required this.nickName,
    required this.country,
    required this.translateLang,
    required this.nativeLang,
    this.avatarUrl,
    this.totalScore = 0,
    List<UserLessonScore>? lessonScores,
  }) : lessonScores = lessonScores ?? [];

  factory CommunityUser.fromMap(Map<String, dynamic> m, {int totalScore = 0}) =>
      CommunityUser(
        id: m['id'] as String,
        nickName: (m['nick_name'] as String?) ?? '',
        country: (m['country'] as String?) ?? '',
        translateLang: (m['translate_lang'] as String?) ?? 'th',
        nativeLang: (m['native_lang'] as String?) ?? 'zh_CN',
        avatarUrl: m['avatar_url'] as String?,
        totalScore: totalScore,
      );
}

class UserLessonScore {
  final int lessonId;
  final String translateLang;
  final String nativeLang;
  final String lessonName;
  final int challenge; // same 8-digit encoding as category.challenge
  final List<int?> scores; // score1..score8: elapsed seconds per segment

  const UserLessonScore({
    required this.lessonId,
    required this.translateLang,
    required this.nativeLang,
    required this.lessonName,
    required this.challenge,
    this.scores = const [null, null, null, null, null, null, null, null],
  });

  factory UserLessonScore.fromMap(Map<String, dynamic> m) => UserLessonScore(
        lessonId: (m['lesson_id'] as num).toInt(),
        translateLang: (m['translate_lang'] as String?) ?? '',
        nativeLang: (m['native_lang'] as String?) ?? '',
        lessonName: (m['lesson_name'] as String?) ?? '',
        challenge: (m['challenge'] as num?)?.toInt() ?? 0,
        scores: List.generate(
          8,
          (i) => (m['score${i + 1}'] as num?)?.toInt(),
        ),
      );

  /// Sum of [scores] (segment elapsed seconds); matches DB columns score1…score8.
  int get scoresSum => scores.fold<int>(0, (a, s) => a + (s ?? 0));
}

// ── Service ──────────────────────────────────────────────────────
//
// Required Supabase tables (run in SQL editor):
//
//   CREATE TABLE user_profiles (
//     id             uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
//     nick_name      text NOT NULL DEFAULT '',
//     country        text NOT NULL DEFAULT '',
//     translate_lang text NOT NULL DEFAULT 'th',
//     native_lang    text NOT NULL DEFAULT 'zh_CN',
//     avatar_url     text,
//     updated_at     timestamptz DEFAULT now()
//   );
//   ALTER TABLE user_profiles ENABLE ROW LEVEL SECURITY;
//   CREATE POLICY "public_read"  ON user_profiles FOR SELECT USING (true);
//   CREATE POLICY "owner_write"  ON user_profiles FOR ALL    USING (auth.uid() = id);
//
//   CREATE TABLE user_lesson_scores (
//     user_id        uuid        REFERENCES auth.users(id) ON DELETE CASCADE,
//     lesson_id      integer     NOT NULL,
//     translate_lang text        NOT NULL DEFAULT 'th',
//     native_lang    text        NOT NULL DEFAULT 'zh_CN',
//     lesson_name    text        NOT NULL DEFAULT '',
//     challenge      bigint      NOT NULL DEFAULT 0,
//     score1         integer,
//     score2         integer,
//     score3         integer,
//     score4         integer,
//     score5         integer,
//     score6         integer,
//     score7         integer,
//     score8         integer,
//     updated_at     timestamptz DEFAULT now(),
//     PRIMARY KEY (user_id, lesson_id, translate_lang, native_lang)
//   );
//   ALTER TABLE user_lesson_scores ENABLE ROW LEVEL SECURITY;
//   CREATE POLICY "public_read"  ON user_lesson_scores FOR SELECT USING (true);
//   CREATE POLICY "owner_write"  ON user_lesson_scores FOR ALL    USING (auth.uid() = user_id);

class CommunityService {
  static const _pageSize = 50;

  static SupabaseClient? get _client => SupabaseBootstrap.clientOrNull;

  static bool get isAvailable => _client != null;

  /// Paginated user list with aggregated total scores.
  static Future<List<CommunityUser>> fetchUsers({
    String? translateLang,
    String? nativeLang,
    String? country,
    int offset = 0,
  }) async {
    final client = _client;
    if (client == null) return [];

    var q = client.from('user_profiles').select();
    if (translateLang != null) q = q.eq('translate_lang', translateLang);
    if (nativeLang != null) q = q.eq('native_lang', nativeLang);
    if (country != null && country.isNotEmpty) q = q.eq('country', country);

    final rows = List<Map<String, dynamic>>.from(
      await q.order('updated_at', ascending: false).range(offset, offset + _pageSize - 1),
    );
    if (rows.isEmpty) return [];

    final userIds = rows.map((r) => r['id'] as String).toList();
    final scoreRows = List<Map<String, dynamic>>.from(
      await client
          .from('user_lesson_scores')
          .select(
            'user_id, lesson_id, '
            'score1, score2, score3, score4, score5, score6, score7, score8',
          )
          .inFilter('user_id', userIds),
    );

    int rowSecondsSum(Map<String, dynamic> r) {
      var s = 0;
      for (var i = 1; i <= 8; i++) {
        final v = r['score$i'];
        if (v is num) s += v.toInt();
      }
      return s;
    }

    // Per (user_id, lesson_id): sum score1…score8 for that lesson row.
    final totalsByUserLesson = <String, int>{};
    for (final r in scoreRows) {
      final uid = r['user_id'] as String;
      final lessonId = (r['lesson_id'] as num?)?.toInt();
      if (lessonId == null) continue;
      final key = '$uid|$lessonId';
      totalsByUserLesson[key] = (totalsByUserLesson[key] ?? 0) + rowSecondsSum(r);
    }

    // Community tally per user = sum of all matched (user_id + lesson_id) rows.
    final totalsByUser = <String, int>{};
    for (final e in totalsByUserLesson.entries) {
      final sep = e.key.indexOf('|');
      final uid = sep >= 0 ? e.key.substring(0, sep) : e.key;
      totalsByUser[uid] = (totalsByUser[uid] ?? 0) + e.value;
    }

    return rows.map((r) {
      final uid = r['id'] as String;
      return CommunityUser.fromMap(
        r,
        totalScore: totalsByUser[uid] ?? 0,
      );
    }).toList();
  }

  /// All lesson scores for a single user, ordered by lesson_id.
  static Future<List<UserLessonScore>> fetchUserLessonScores(
      String userId) async {
    final client = _client;
    if (client == null) return [];
    final rows = await client
        .from('user_lesson_scores')
        .select()
        .eq('user_id', userId)
        .order('lesson_id', ascending: true);
    return List<Map<String, dynamic>>.from(rows)
        .map(UserLessonScore.fromMap)
        .toList();
  }

  /// Distinct non-empty country values for the country filter.
  static Future<List<String>> fetchCountries() async {
    final client = _client;
    if (client == null) return [];
    try {
      final rows = await client
          .from('user_profiles')
          .select('country')
          .neq('country', '');
      final out = <String>{};
      for (final r in List<Map<String, dynamic>>.from(rows)) {
        final c = r['country'] as String?;
        if (c != null && c.isNotEmpty) out.add(c);
      }
      return out.toList()..sort();
    } catch (_) {
      return [];
    }
  }

  /// Upsert this user's challenge score for one lesson (fire-and-forget).
  static Future<void> uploadLessonScore({
    required String userId,
    required int lessonId,
    required String translateLang,
    required String nativeLang,
    required String lessonName,
    required int challenge,
    List<int?> scores = const [null, null, null, null, null, null, null, null],
  }) async {
    final client = _client;
    if (client == null) return;
    try {
      final row = <String, dynamic>{
        'user_id': userId,
        'lesson_id': lessonId,
        'translate_lang': translateLang,
        'native_lang': nativeLang,
        'lesson_name': lessonName,
        'challenge': challenge,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      for (var i = 0; i < 8; i++) {
        if (scores.length > i && scores[i] != null) {
          row['score${i + 1}'] = scores[i];
        }
      }
      await client.from('user_lesson_scores').upsert(
        row,
        onConflict: 'user_id,lesson_id,translate_lang,native_lang',
      );
    } catch (_) {}
  }

  /// Upsert the signed-in user's public profile row.
  static Future<void> upsertProfile({
    required String userId,
    required String translateLang,
    required String nativeLang,
    String nickName = '',
    String country = '',
    String? avatarUrl,
  }) async {
    final client = _client;
    if (client == null) return;
    try {
      await client.from('user_profiles').upsert({
        'id': userId,
        'nick_name': nickName,
        'country': country,
        'translate_lang': translateLang,
        'native_lang': nativeLang,
        if (avatarUrl != null) 'avatar_url': avatarUrl,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {}
  }
}
