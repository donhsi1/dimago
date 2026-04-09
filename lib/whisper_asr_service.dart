import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'api_log_service.dart';

/// Result of a Whisper transcription attempt (success or structured failure).
class WhisperTranscribeResult {
  final String? text;
  final int? httpStatus;
  /// Short message for UI (API error body, network error, missing key, etc.)
  final String? errorSummary;

  const WhisperTranscribeResult({
    this.text,
    this.httpStatus,
    this.errorSummary,
  });

  bool get ok => text != null && text!.trim().isNotEmpty;
}

/// OpenAI Whisper (`whisper-1`). Used by [TalkAsrService] when [OPENAI_API_KEY]
/// is non-empty at compile time (`--dart-define=OPENAI_API_KEY=...`) or loaded
/// from `assets/supabase_config.json` → `"openai_api_key"`.
class WhisperAsrService {
  static const _compiledKey = String.fromEnvironment('OPENAI_API_KEY', defaultValue: '');
  static String _assetKey = '';
  static const _endpoint = 'https://api.openai.com/v1/audio/transcriptions';

  /// Load key from asset config (called once in main before runApp).
  static Future<void> loadKeyFromAsset() async {
    if (_assetKey.isNotEmpty) return;
    try {
      final raw = await rootBundle.loadString('assets/supabase_config.json');
      final map = jsonDecode(raw);
      if (map is Map<String, dynamic>) {
        final k = map['openai_api_key'];
        if (k is String && k.trim().isNotEmpty) _assetKey = k.trim();
      }
    } catch (_) {}
  }

  static String get _apiKey =>
      _compiledKey.trim().isNotEmpty ? _compiledKey.trim() : _assetKey;

  /// True when a non-empty API key is available (compile-time or asset).
  static bool get isApiKeyConfigured => _apiKey.isNotEmpty;

  /// ISO-639-1 codes for Whisper `language` field.
  static String _whisperLangFromAppCode(String code) {
    switch (code) {
      case 'zh_CN':
      case 'zh_TW':
        return 'zh';
      case 'en_US':
        return 'en';
      case 'th':
      case 'fr':
      case 'de':
      case 'it':
      case 'es':
      case 'ja':
      case 'ko':
      case 'ru':
      case 'uk':
      case 'he':
      case 'my':
        return code.length == 2 ? code : code.split('_').first;
      default:
        return code.length == 2 ? code : code.split('_').first;
    }
  }

  static String _parseErrorBody(String body, int status) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      return 'HTTP $status (empty body)';
    }
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        final err = decoded['error'];
        if (err is Map<String, dynamic>) {
          final msg = err['message'] as String?;
          final type = err['type'] as String?;
          if (msg != null && msg.isNotEmpty) {
            return type != null && type.isNotEmpty ? '$type: $msg' : msg;
          }
        }
        final msg = decoded['message'] as String?;
        if (msg != null && msg.isNotEmpty) return msg;
      }
    } catch (_) {
      /* use raw below */
    }
    if (trimmed.length > 220) {
      return '${trimmed.substring(0, 220)}…';
    }
    return trimmed;
  }

  /// Full result with error details for debugging UI.
  static Future<WhisperTranscribeResult> transcribeFileDetailed(
    String audioPath, {
    required String appLangCode,
  }) async {
    if (_apiKey.isEmpty) {
      return const WhisperTranscribeResult(
        errorSummary:
            'OpenAI key missing. Add openai_api_key to assets/supabase_config.json or rebuild with --dart-define=OPENAI_API_KEY=...',
      );
    }
    final file = File(audioPath);
    if (!await file.exists()) {
      return WhisperTranscribeResult(
        errorSummary: 'Recording file not found: $audioPath',
      );
    }
    final size = await file.length();
    // WAV @ 16 kHz mono ≈ 32 KiB/s; reject tiny clips before OpenAI returns 400.
    if (size < 4096) {
      return WhisperTranscribeResult(
        errorSummary: 'Recording too short or empty ($size bytes)',
      );
    }

    final multipartFile = await http.MultipartFile.fromPath(
      'file',
      audioPath,
      filename: p.basename(audioPath).isNotEmpty ? p.basename(audioPath) : 'audio.wav',
    );

    final req = http.MultipartRequest('POST', Uri.parse(_endpoint))
      ..headers['Authorization'] = 'Bearer $_apiKey'
      ..fields['model'] = 'whisper-1'
      ..fields['language'] = _whisperLangFromAppCode(appLangCode)
      ..fields['response_format'] = 'json'
      ..files.add(multipartFile);

    try {
      final streamed = await req.send().timeout(const Duration(seconds: 60));
      final body = await streamed.stream.bytesToString();
      final status = streamed.statusCode;

      if (status != 200) {
        return WhisperTranscribeResult(
          httpStatus: status,
          errorSummary: _parseErrorBody(body, status),
        );
      }

      Map<String, dynamic> data;
      try {
        final decoded = jsonDecode(body);
        if (decoded is! Map<String, dynamic>) {
          return WhisperTranscribeResult(
            httpStatus: status,
            errorSummary: 'Unexpected JSON shape from Whisper',
          );
        }
        data = decoded;
      } catch (_) {
        return WhisperTranscribeResult(
          httpStatus: status,
          errorSummary: 'Invalid JSON from Whisper: ${body.length > 120 ? "${body.substring(0, 120)}…" : body}',
        );
      }

      final text = (data['text'] as String?)?.trim();
      if (text == null || text.isEmpty) {
        return WhisperTranscribeResult(
          httpStatus: status,
          errorSummary: 'Whisper returned 200 but no text (silent or unrecognized audio)',
        );
      }

      ApiLogService.increment(ApiName.openaiWhisper).catchError((_) {});
      return WhisperTranscribeResult(text: text, httpStatus: status);
    } on SocketException catch (e) {
      return WhisperTranscribeResult(
        errorSummary: 'Network error: ${e.message}',
      );
    } on TimeoutException catch (_) {
      return const WhisperTranscribeResult(
        errorSummary: 'Request timed out (60s)',
      );
    } catch (e) {
      return WhisperTranscribeResult(
        errorSummary: 'Transcription failed: $e',
      );
    }
  }

  /// Backwards-compatible: transcript text only, or `null` on any failure.
  static Future<String?> transcribeFile(
    String audioPath, {
    required String appLangCode,
  }) async {
    final r = await transcribeFileDetailed(audioPath, appLangCode: appLangCode);
    return r.ok ? r.text : null;
  }
}
