import 'dart:math';

/// OpenAI Whisper returns **text only** — no accuracy or confidence. The app
/// compares that transcript to the expected line **on device** using
/// normalized [Levenshtein](https://en.wikipedia.org/wiki/Levenshtein_distance).
///
/// When either side contains **Thai script**, the score is **100%** from
/// Levenshtein on a **consonant skeleton** (vowels, tone marks, and leading
/// vowel letters stripped) — a practical phonetic proxy without IPA/G2P.
/// Otherwise (e.g. Chinese-only) the score uses full normalized graphemes only.

final RegExp _keepForScore = RegExp(
  r'[a-z0-9\u0E00-\u0E7F\u4E00-\u9FFF\u3400-\u4DBF\uF900-\uFAFF\u3040-\u30FF\uAC00-\uD7AF]',
);

/// Thai vowel marks, leading vowel letters, tones, and related marks (not consonants).
final RegExp _thaiVowelToneStrip = RegExp(
  r'[\u0E30-\u0E3A\u0E40-\u0E46\u0E47-\u0E4E]',
);

bool _containsThaiScript(String s) {
  for (final r in s.runes) {
    if (r >= 0x0E00 && r <= 0x0E7F) return true;
  }
  return false;
}

String normalizeForTalkScore(String s) {
  final lowered = s.toLowerCase();
  final buf = StringBuffer();
  for (final rune in lowered.runes) {
    final ch = String.fromCharCode(rune);
    if (_keepForScore.hasMatch(ch)) buf.write(ch);
  }
  return buf.toString();
}

/// Thai consonant skeleton for phonetic-ish comparison (Levenshtein on this string).
String thaiConsonantSkeleton(String normalizedLowercase) {
  final buf = StringBuffer();
  for (final rune in normalizedLowercase.runes) {
    if (rune >= 0x0E00 && rune <= 0x0E7F) {
      final ch = String.fromCharCode(rune);
      if (!_thaiVowelToneStrip.hasMatch(ch)) buf.write(ch);
    } else {
      buf.write(String.fromCharCode(rune));
    }
  }
  return buf.toString();
}

int levenshtein(String a, String b) {
  final m = a.length;
  final n = b.length;
  if (m == 0) return n;
  if (n == 0) return m;
  final dp = List.generate(m + 1, (_) => List<int>.filled(n + 1, 0));
  for (var i = 0; i <= m; i++) {
    dp[i][0] = i;
  }
  for (var j = 0; j <= n; j++) {
    dp[0][j] = j;
  }
  for (var i = 1; i <= m; i++) {
    for (var j = 1; j <= n; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      dp[i][j] = min(
        dp[i - 1][j] + 1,
        min(dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost),
      );
    }
  }
  return dp[m][n];
}

int _percentFromDistance(int dist, int maxLen) {
  if (maxLen <= 0) return 0;
  return ((1 - dist / maxLen) * 100).round().clamp(0, 100);
}

/// 0–100: **Thai** → consonant-skeleton Levenshtein only; else full-string Levenshtein.
int talkAccuracyPercent(String expected, String actual) {
  var e = normalizeForTalkScore(expected);
  var a = normalizeForTalkScore(actual);

  final expectedTrim = expected.trim();
  final actualTrim = actual.trim();
  if (e.isEmpty && expectedTrim.isNotEmpty) e = expectedTrim.toLowerCase();
  if (a.isEmpty && actualTrim.isNotEmpty) a = actualTrim.toLowerCase();
  if (e.isEmpty || a.isEmpty) return 0;

  final distFull = levenshtein(e, a);
  final maxFull = max(e.length, a.length);
  final fullPct = _percentFromDistance(distFull, maxFull);

  final thaiHere = _containsThaiScript(e) || _containsThaiScript(a);
  if (!thaiHere) return fullPct;

  final eSk = thaiConsonantSkeleton(e);
  final aSk = thaiConsonantSkeleton(a);
  if (eSk.isEmpty || aSk.isEmpty) return fullPct;

  final distSk = levenshtein(eSk, aSk);
  final maxSk = max(eSk.length, aSk.length);
  return _percentFromDistance(distSk, maxSk);
}
