import 'dart:convert';
import 'package:http/http.dart' as http;

class TranslateService {
  // Map our lang codes to Google Translate language codes
  static String _toGoogleLang(String code) {
    const map = <String, String>{
      'zh_CN': 'zh-CN',
      'zh_TW': 'zh-TW',
      'en_US': 'en',
      'th':    'th',
      'fr':    'fr',
      'de':    'de',
      'it':    'it',
      'es':    'es',
      'ja':    'ja',
      'ko':    'ko',
      'my':    'my',
      'he':    'iw',
      'ru':    'ru',
      'uk':    'uk',
    };
    return map[code] ?? code;
  }

  /// Generic translate: auto-detect source, translate to [targetLang] code.
  static Future<String?> translate(String text,
      {required String targetLang, String sourceLang = 'auto'}) async {
    if (text.trim().isEmpty) return null;
    final tl = _toGoogleLang(targetLang);
    final sl = sourceLang == 'auto' ? 'auto' : _toGoogleLang(sourceLang);

    final uri = Uri.https(
      'translate.googleapis.com',
      '/translate_a/single',
      {
        'client': 'gtx',
        'sl': sl,
        'tl': tl,
        'dt': 't',
        'q': text,
      },
    );

    try {
      final response =
          await http.get(uri).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as List<dynamic>;
      final buffer = StringBuffer();
      for (final segment in data[0] as List<dynamic>) {
        final s = segment as List<dynamic>;
        if (s.isNotEmpty && s[0] is String) buffer.write(s[0] as String);
      }
      final result = buffer.toString().trim();
      return result.isEmpty ? null : result;
    } catch (_) {
      return null;
    }
  }

  /// 使用 Google Translate 免费 API 将中文翻译为泰语
  static Future<String?> chineseToThai(String text) =>
      translate(text, targetLang: 'th', sourceLang: 'zh_CN');

  /// Fetch a sample sentence containing [word] from Google Translate's
  /// example corpus (dt=ex). Returns the first source-language example with
  /// HTML tags stripped, or null if none found.
  static Future<String?> getSampleSentence(String word,
      {String sourceLang = 'th'}) async {
    if (word.trim().isEmpty) return null;
    final sl = _toGoogleLang(sourceLang);

    final uri = Uri.https(
      'translate.googleapis.com',
      '/translate_a/single',
      {
        'client': 'gtx',
        'sl': sl,
        'tl': 'en', // target lang is required; source examples are in sl regardless
        'dt': 'ex',
        'q': word,
      },
    );

    try {
      final response =
          await http.get(uri).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body);
      if (data is! List || data.length <= 13) return null;
      final exBlock = data[13];
      if (exBlock is! List || exBlock.isEmpty) return null;
      final exList = exBlock[0];
      if (exList is! List || exList.isEmpty) return null;
      final firstEx = exList[0];
      if (firstEx is! List || firstEx.isEmpty) return null;
      final raw = firstEx[0];
      if (raw is! String) return null;
      // Strip HTML tags (<b>, </b>, etc.) left by Google
      final clean = raw.replaceAll(RegExp(r'<[^>]*>'), '').trim();
      return clean.isEmpty ? null : clean;
    } catch (_) {
      return null;
    }
  }
}

