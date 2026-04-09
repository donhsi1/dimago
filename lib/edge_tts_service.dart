import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'database_helper.dart';
import 'user_feedback.dart';

/// Thrown when SQLite has no audio BLOB for the requested word/phrase.
class TtsNoBlobException implements Exception {
  final String message;
  TtsNoBlobException([this.message = EdgeTTSService.missingAudioMessage]);
  @override
  String toString() => message;
}

/// Local MP3 playback from SQLite BLOBs only — no network TTS.
class EdgeTTSService {
  static const String missingAudioMessage = 'no tts found';

  static void _notifyMissingAudio([String message = missingAudioMessage]) {
    UserFeedback.showSnack(message);
  }

  /// Start local file playback; do not await [AudioPlayer.play] to completion.
  void _startPlaybackFromFile(String path, void Function()? onDone) {
    late StreamSubscription<void> sub;
    var finished = false;
    void doneOnce() {
      if (finished) return;
      finished = true;
      _isPlaying = false;
      sub.cancel();
      onDone?.call();
    }

    sub = _player.onPlayerComplete.listen((_) => doneOnce());
    unawaited(_player.play(DeviceFileSource(path)).catchError((_, __) => doneOnce()));
  }

  static final Map<String, String> _pathCache = {};

  /// Built MP3 path for a DB translate BLOB (avoids re-reading SQLite on every tap).
  static final Map<String, String> _translateBlobDiskCache = {};

  static void _pathCacheTrim() {
    while (_pathCache.length > 256) {
      _pathCache.remove(_pathCache.keys.first);
    }
  }

  static void _translateBlobCacheTrim() {
    while (_translateBlobDiskCache.length > 320) {
      _translateBlobDiskCache.remove(_translateBlobDiskCache.keys.first);
    }
  }

  final AudioPlayer _player = AudioPlayer();
  bool _isPlaying = false;

  bool get isPlaying => _isPlaying;

  static Future<Directory> _cacheDir() async {
    final base = await getApplicationCacheDirectory();
    final dir = Directory('${base.path}/tts_blob_cache');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<String> _resolveLearnAudio(String text, int? wordId) async {
    if (wordId == null) throw TtsNoBlobException();
    final cacheMapKey = 'learn:$wordId';
    if (_pathCache.containsKey(cacheMapKey)) {
      final hit = _pathCache[cacheMapKey]!;
      if (await File(hit).exists()) return hit;
    }

    final bytes = await DatabaseHelper.getWordAudio(wordId, 'audio_translate');
    if (bytes == null || bytes.isEmpty) throw TtsNoBlobException();

    final dir = await _cacheDir();
    final path = p.join(dir.path, 'word_${wordId}_audio_translate.mp3');
    await File(path).writeAsBytes(bytes, flush: true);
    _pathCache[cacheMapKey] = path;
    _pathCacheTrim();
    return path;
  }

  static Future<String> _resolveNativeAudio(String text, int? wordId) async {
    if (wordId == null) throw TtsNoBlobException();
    final cacheMapKey = 'native:$wordId';
    if (_pathCache.containsKey(cacheMapKey)) {
      final hit = _pathCache[cacheMapKey]!;
      if (await File(hit).exists()) return hit;
    }

    final bytes = await DatabaseHelper.getWordAudio(wordId, 'audio_native');
    if (bytes == null || bytes.isEmpty) throw TtsNoBlobException();

    final dir = await _cacheDir();
    final path = p.join(dir.path, 'word_${wordId}_audio_native.mp3');
    await File(path).writeAsBytes(bytes, flush: true);
    _pathCache[cacheMapKey] = path;
    _pathCacheTrim();
    return path;
  }

  static String _nativeAudioColumn({int? phraseSlot}) {
    if (phraseSlot == null) return 'audio_native';
    return 'sample1_native_audio';
  }

  static Future<String> _resolveNativeLangAudio(
    String text,
    String appNativeCode,
    int? wordId, {
    int? phraseSlot,
  }) async {
    if (wordId == null) throw TtsNoBlobException();
    final col = _nativeAudioColumn(phraseSlot: phraseSlot);
    final cacheMapKey = phraseSlot != null
        ? 'natphrase:$wordId:$col'
        : 'natlang:${md5.convert(utf8.encode('$appNativeCode|$wordId')).toString()}';
    if (_pathCache.containsKey(cacheMapKey)) {
      final hit = _pathCache[cacheMapKey]!;
      if (await File(hit).exists()) return hit;
    }

    final bytes = await DatabaseHelper.getWordAudio(wordId, col);
    if (bytes == null || bytes.isEmpty) throw TtsNoBlobException();

    final dir = await _cacheDir();
    final path = p.join(dir.path, 'word_${wordId}_$col.mp3');
    await File(path).writeAsBytes(bytes, flush: true);
    _pathCache[cacheMapKey] = path;
    _pathCacheTrim();
    return path;
  }

  static String _translateAudioColumn({int? phraseSlot}) {
    if (phraseSlot == null) return 'audio_translate';
    return 'sample1_translate_audio';
  }

  // ── 公开 API ─────────────────────────────────────────────────

  Future<void> speak(String text,
      {void Function()? onDone, int? wordId}) async {
    await stop();
    _isPlaying = true;

    try {
      final path = await _resolveLearnAudio(text, wordId);
      _startPlaybackFromFile(path, onDone);
    } on TtsNoBlobException catch (_) {
      _isPlaying = false;
      _notifyMissingAudio();
      onDone?.call();
    } catch (_) {
      _isPlaying = false;
      _notifyMissingAudio();
      onDone?.call();
    }
  }

  Future<void> speakChinese(String text,
      {void Function()? onDone, int? wordId}) async {
    await stop();
    _isPlaying = true;
    try {
      final path = await _resolveNativeAudio(text, wordId);
      _startPlaybackFromFile(path, onDone);
    } on TtsNoBlobException catch (_) {
      _isPlaying = false;
      _notifyMissingAudio();
      onDone?.call();
    } catch (_) {
      _isPlaying = false;
      _notifyMissingAudio();
      onDone?.call();
    }
  }

  /// Translate-language line: [audio_translate] or [sample1_translate_audio] only.
  Future<void> speakTranslateFromDbOrFetch(
    String text, {
    required String appTargetLangCode,
    int? wordId,
    int? phraseSlot,
    void Function()? onDone,
  }) async {
    if (text.isEmpty) {
      onDone?.call();
      return;
    }
    await stop();
    _isPlaying = true;

    try {
      final col = _translateAudioColumn(phraseSlot: phraseSlot);
      final textDigest = md5.convert(utf8.encode(text)).toString();
      final String? diskCacheKey =
          wordId != null ? '$wordId|$col|$textDigest' : null;

      if (diskCacheKey != null) {
        final hit = _translateBlobDiskCache[diskCacheKey];
        if (hit != null && await File(hit).exists()) {
          _startPlaybackFromFile(hit, onDone);
          return;
        }
      }

      Uint8List? bytes;
      if (wordId != null) {
        bytes = await DatabaseHelper.getWordAudio(wordId, col);
      }

      if (bytes == null || bytes.isEmpty) {
        _isPlaying = false;
        _notifyMissingAudio();
        onDone?.call();
        return;
      }

      final dir = await _cacheDir();
      final cacheName = 'db_${wordId ?? 0}_${col}_$textDigest.mp3';
      final file = File('${dir.path}/$cacheName');
      await file.writeAsBytes(bytes, flush: true);

      if (diskCacheKey != null) {
        _translateBlobDiskCache[diskCacheKey] = file.path;
        _translateBlobCacheTrim();
      }

      _startPlaybackFromFile(file.path, onDone);
    } on TtsNoBlobException catch (_) {
      _isPlaying = false;
      _notifyMissingAudio();
      onDone?.call();
    } catch (_) {
      _isPlaying = false;
      _notifyMissingAudio();
      onDone?.call();
    }
  }

  /// [phraseSlot] non-null → read `sample1_native_audio`; else `audio_native`.
  Future<void> speakNativeLang(String text, String appNativeLangCode,
      {void Function()? onDone, int? wordId, int? phraseSlot}) async {
    if (text.isEmpty) {
      onDone?.call();
      return;
    }
    await stop();
    _isPlaying = true;
    try {
      final path = await _resolveNativeLangAudio(
        text,
        appNativeLangCode,
        wordId,
        phraseSlot: phraseSlot,
      );
      _startPlaybackFromFile(path, onDone);
    } on TtsNoBlobException catch (_) {
      _isPlaying = false;
      _notifyMissingAudio();
      onDone?.call();
    } catch (_) {
      _isPlaying = false;
      _notifyMissingAudio();
      onDone?.call();
    }
  }

  Future<void> stop() async {
    await _player.stop();
    _isPlaying = false;
  }

  Future<void> dispose() async {
    await _player.dispose();
  }

  static Future<void> clearCache() async {
    final dir = await _cacheDir();
    if (await dir.exists()) await dir.delete(recursive: true);
    _pathCache.clear();
    _translateBlobDiskCache.clear();
  }
}
