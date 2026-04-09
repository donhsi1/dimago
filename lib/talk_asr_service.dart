import 'whisper_asr_service.dart';

export 'whisper_asr_service.dart' show WhisperTranscribeResult;

/// Talk transcription via **OpenAI Whisper** (`whisper-1`) when `OPENAI_API_KEY`
/// is set at build time (`--dart-define=OPENAI_API_KEY=...`).
class TalkAsrService {
  static Future<WhisperTranscribeResult> transcribeFileDetailed(
    String audioPath, {
    required String appLangCode,
  }) {
    return WhisperAsrService.transcribeFileDetailed(
      audioPath,
      appLangCode: appLangCode,
    );
  }

  static Future<String?> transcribeFile(
    String audioPath, {
    required String appLangCode,
  }) {
    return WhisperAsrService.transcribeFile(
      audioPath,
      appLangCode: appLangCode,
    );
  }

  /// No-op hook (previously warmed remote ASR models alongside language DB download).
  static Future<void> warmupForLanguages(Iterable<String> _) async {}
}
