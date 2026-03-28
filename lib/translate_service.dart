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

  /// 获取泰语的罗马拼音（romanization→'
  static Future<String?> getThaiRomanization(String thaiText) async {
    if (thaiText.trim().isEmpty) return null;

    final uri = Uri.https(
      'translate.googleapis.com',
      '/translate_a/single',
      {
        'client': 'gtx',
        'sl': 'th',
        'tl': 'en',
        'dt': 'rm',
        'q': thaiText,
      },
    );

    try {
      final response =
          await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body);
      if (data is List && data.isNotEmpty && data[0] is List) {
        final buffer = StringBuffer();
        for (final seg in data[0] as List) {
          if (seg is List && seg.length > 3 && seg[3] is String) {
            buffer.write(seg[3]);
          }
        }
        final result = buffer.toString().trim();
        if (result.isNotEmpty) return result;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 使用 Google Translate 免费 API 将中文翻译为泰语
  static Future<String?> chineseToThai(String text) =>
      translate(text, targetLang: 'th', sourceLang: 'zh_CN');
}

