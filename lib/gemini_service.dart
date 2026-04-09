import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Google Gemini API service — used for word definitions and sample sentences
/// when the free Google Translate corpus has no result.
class GeminiService {
  static const _apiKey = 'AIzaSyCn48uC-eLmhw-ISQ1a4rDeVw6nwk4ahWs';
  static const _model  = 'gemini-2.0-flash';

  // ── Core generate ──────────────────────────────────────────────
  static Future<String?> _generate(String prompt) async {
    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$_model'
      ':generateContent?key=$_apiKey',
    );
    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt}
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0.3,
        'maxOutputTokens': 200,
      },
    });

    try {
      final response = await http
          .post(url,
              headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final text = data['candidates']?[0]?['content']?['parts']?[0]?['text']
          as String?;
      return text?.trim().isEmpty == true ? null : text?.trim();
    } catch (_) {
      return null;
    }
  }

  // ── Language name helper ───────────────────────────────────────
  static String _langName(String code) {
    const map = <String, String>{
      'th':    'Thai',
      'zh_CN': 'Simplified Chinese',
      'zh_TW': 'Traditional Chinese',
      'en_US': 'English',
      'fr':    'French',
      'de':    'German',
      'it':    'Italian',
      'es':    'Spanish',
      'ja':    'Japanese',
      'ko':    'Korean',
      'my':    'Burmese',
      'he':    'Hebrew',
      'ru':    'Russian',
      'uk':    'Ukrainian',
    };
    return map[code] ?? code;
  }

  // ── Public API ─────────────────────────────────────────────────

  /// Returns a concise definition of [word] written in [langCode].
  /// e.g. langCode='th' → Thai word defined in Thai.
  static Future<String?> getDefinition(String word, String langCode) async {
    if (word.trim().isEmpty) return null;
    final lang = _langName(langCode);
    return _generate(
      'Define the $lang word or phrase "$word" in $lang. '
      'Write a concise 1–2 sentence definition in $lang only. '
      'Do not translate. Do not include the word itself in the output. '
      'Reply with the definition only.',
    );
  }

  /// Returns one very short, simple example sentence using [word], written in [langCode].
  /// Uses beginner-level vocabulary and grammar (A1/A2), max ~8 words.
  static Future<String?> getSampleSentence(String word, String langCode) async {
    if (word.trim().isEmpty) return null;
    final lang = _langName(langCode);
    return _generate(
      'Write one very short example sentence in $lang using the word or phrase "$word". '
      'Rules: use only common everyday words, beginner A1 level, '
      'maximum 8 words, simple sentence structure, no complex grammar. '
      'Reply with the sentence in $lang only. No explanation, no translation.',
    );
  }

  /// Transcribes learner speech from [audioBytes] and returns only recognized text.
  static Future<String?> transcribeSpeech(
    Uint8List audioBytes, {
    required String mimeType,
    required String langCode,
  }) async {
    if (audioBytes.isEmpty) return null;
    final lang = _langName(langCode);
    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$_model'
      ':generateContent?key=$_apiKey',
    );

    Map<String, dynamic> makeBody(String mt) => {
          'contents': [
            {
              'parts': [
                {
                  'text':
                      'Transcribe this learner pronunciation audio to plain $lang text only. '
                      'Return only the transcript. No explanations, no punctuation notes.'
                },
                {
                  'inlineData': {
                    'mimeType': mt,
                    'data': base64Encode(audioBytes),
                  }
                },
              ]
            }
          ],
          'generationConfig': {
            'temperature': 0.0,
            'maxOutputTokens': 120,
          },
        };

    try {
      final mimes = <String>[
        mimeType,
        if (mimeType != 'audio/mp4') 'audio/mp4',
        if (mimeType != 'audio/m4a') 'audio/m4a',
        if (mimeType != 'audio/aac') 'audio/aac',
        if (mimeType != 'audio/wav') 'audio/wav',
      ];
      for (final mt in mimes) {
        final body = jsonEncode(makeBody(mt));
        final response = await http
            .post(url, headers: {'Content-Type': 'application/json'}, body: body)
            .timeout(const Duration(seconds: 30));
        if (response.statusCode != 200) continue;
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final text = data['candidates']?[0]?['content']?['parts']?[0]?['text']
            as String?;
        final out = text?.trim();
        if (out != null && out.isNotEmpty) return out;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
