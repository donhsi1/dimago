import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_log_service.dart';
import 'settings_page.dart'; // TtsPrefs 常量

/// Google Translate TTS 服务（免费，无需 API Key→'
/// 语言：th（泰语）
/// 本地 MP3 缓存：避免重复请→'
/// 支持→SharedPreferences 读取声音性别和减慢速度
class EdgeTTSService {
  static const _lang = 'th';

  // ── In-memory path cache (survives hot restart within session) ──
  // key: "learn:{wordId}:{cacheKey}" or "native:{wordId}:{lang}|{text}"
  static final Map<String, String> _pathCache = {};

  final AudioPlayer _player = AudioPlayer();
  bool _isPlaying = false;

  bool get isPlaying => _isPlaying;

  // ── 从设定读取参→─────────────────────────────────────────────

  /// 读取语速（ttsspeed = 1.0 - speedPercent/100→'
  /// 例如 speedPercent=20 →ttsspeed=0.80
  static Future<double> _getTtsSpeed() async {
    final prefs = await SharedPreferences.getInstance();
    final pct = prefs.getInt(TtsPrefs.speedPercent) ?? TtsPrefs.defaultSpeedPercent;
    final speed = 1.0 - pct / 100.0;
    return speed.clamp(0.5, 1.0); // 至少保留 0.5 的速度
  }

  /// 读取声音性别（Google Translate TTS 泰语暂仅支持女声，此处保留设定供将来扩展→'
  static Future<String> _getVoiceGender() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(TtsPrefs.voiceGender) ?? TtsPrefs.defaultGender;
  }

  // ── 缓存 ──────────────────────────────────────────────────────

  static Future<Directory> _cacheDir() async {
    final base = await getApplicationCacheDirectory();
    final dir = Directory('${base.path}/gtts_cache');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 缓存 key 包含速度和性别，设定变化后会重新合→'
  static String _cacheKey(String text, double speed, String gender) {
    final speedStr = speed.toStringAsFixed(2);
    final raw = '$_lang|$speedStr|$gender|$text';
    return '${md5.convert(utf8.encode(raw))}.mp3';
  }

  // ── Google Translate TTS 请求 ─────────────────────────────────

  static Future<Uint8List> _synthesize(String text, double speed) async {
    // 文本过长时分段（Google TTS 限制→200 字符→'
    final segments = _splitText(text, 200);
    final allBytes = BytesBuilder();

    for (final seg in segments) {
      final uri = Uri.https(
        'translate.googleapis.com',
        '/translate_tts',
        {
          'ie': 'UTF-8',
          'q': seg,
          'tl': _lang,
          'client': 'tw-ob',
          'ttsspeed': speed.toStringAsFixed(2),
        },
      );

      final response = await http
          .get(
            uri,
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                  'AppleWebKit/537.36 (KHTML, like Gecko) '
                  'Chrome/120.0.0.0 Safari/537.36',
              'Referer': 'https://translate.google.com/',
            },
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        allBytes.add(response.bodyBytes);
        ApiLogService.increment(ApiName.googleTtsThai).catchError((_) {});
      } else {
        throw Exception('Google TTS 请求失败: ${response.statusCode}');
      }
    }

    return allBytes.toBytes();
  }

  /// 将文本按最大长度分→'
  static List<String> _splitText(String text, int maxLen) {
    if (text.length <= maxLen) return [text];
    final segments = <String>[];
    var remaining = text;
    while (remaining.length > maxLen) {
      var cutAt = maxLen;
      for (var i = maxLen; i > maxLen ~/ 2; i--) {
        final c = remaining[i];
        if (c == ' ' || c == ',' || c == '.' || c == '\u0e00') {
          cutAt = i + 1;
          break;
        }
      }
      segments.add(remaining.substring(0, cutAt).trim());
      remaining = remaining.substring(cutAt).trim();
    }
    if (remaining.isNotEmpty) segments.add(remaining);
    return segments;
  }

  // ── 合成并缓存（学习语言，如泰语）────────────────────────────

  static Future<String> _getOrSynthesize(String text) async {
    final speed = await _getTtsSpeed();
    final gender = await _getVoiceGender();
    final dir = await _cacheDir();
    final file = File('${dir.path}/${_cacheKey(text, speed, gender)}');
    if (await file.exists()) return file.path;

    final bytes = await _synthesize(text, speed);
    await file.writeAsBytes(bytes);
    return file.path;
  }

  /// 合成并缓存中文音频（固定 tl=zh-CN，不受速度/性别设定影响→'
  static Future<String> _getOrSynthesizeChinese(String text) async {
    const lang = 'zh-CN';
    final raw = '$lang|$text';
    final key = '${md5.convert(utf8.encode(raw))}.mp3';
    final dir = await _cacheDir();
    final file = File('${dir.path}/$key');
    if (await file.exists()) return file.path;

    // 直接→tl=zh-CN 请求 Google Translate TTS
    final segments = _splitText(text, 200);
    final allBytes = BytesBuilder();
    for (final seg in segments) {
      final uri = Uri.https(
        'translate.googleapis.com',
        '/translate_tts',
        {
          'ie': 'UTF-8',
          'q': seg,
          'tl': lang,
          'client': 'tw-ob',
        },
      );
      final response = await http
          .get(
            uri,
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                  'AppleWebKit/537.36 (KHTML, like Gecko) '
                  'Chrome/120.0.0.0 Safari/537.36',
              'Referer': 'https://translate.google.com/',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        allBytes.add(response.bodyBytes);
        ApiLogService.increment(ApiName.googleTtsChinese).catchError((_) {});
      } else {
        throw Exception('Google TTS (zh-CN) 请求失败: ${response.statusCode}');
      }
    }
    await file.writeAsBytes(allBytes.toBytes());
    return file.path;
  }

  // ── 解析音频路径（文件缓→'+ 内存缓存）────────────────────────
  // DB BLOB 路径已移除：文件缓存（gtts_cache/）已足够持久→'
  // 读取→BLOB 会阻→SQLite 并导→UI 卡顿→'

  /// 获取学习语言（如泰语）音频路径→'
  static Future<String> _resolveLearnAudio(
      String text, int? wordId) async {
    final speed = await _getTtsSpeed();
    final gender = await _getVoiceGender();
    final cacheMapKey = 'learn:${wordId ?? text}:${_cacheKey(text, speed, gender)}';
    if (_pathCache.containsKey(cacheMapKey)) {
      return _pathCache[cacheMapKey]!;
    }
    final path = await _getOrSynthesize(text);
    _pathCache[cacheMapKey] = path;
    return path;
  }

  /// 获取母语（如中文）音频路径→'
  static Future<String> _resolveNativeAudio(
      String text, int? wordId) async {
    final raw = 'zh-CN|$text';
    final cacheMapKey = 'native:${wordId ?? text}:$raw';
    if (_pathCache.containsKey(cacheMapKey)) {
      return _pathCache[cacheMapKey]!;
    }
    final path = await _getOrSynthesizeChinese(text);
    _pathCache[cacheMapKey] = path;
    return path;
  }

  // ── 公开 API ─────────────────────────────────────────────────

  /// 播放学习语言（如泰语）文字，播放完毕后调→[onDone]→'
  Future<void> speak(String text,
      {void Function()? onDone, int? wordId}) async {
    await stop();
    _isPlaying = true;

    try {
      final path = await _resolveLearnAudio(text, wordId);
      late StreamSubscription sub;
      sub = _player.onPlayerComplete.listen((_) {
        _isPlaying = false;
        sub.cancel();
        onDone?.call();
      });
      await _player.play(DeviceFileSource(path));
    } catch (e) {
      _isPlaying = false;
      onDone?.call();
    }
  }

  /// 播放母语（如中文）文字（tl=zh-CN），播放完毕后调→[onDone]→'
  Future<void> speakChinese(String text,
      {void Function()? onDone, int? wordId}) async {
    await stop();
    _isPlaying = true;
    try {
      final path = await _resolveNativeAudio(text, wordId);
      late StreamSubscription sub;
      sub = _player.onPlayerComplete.listen((_) {
        _isPlaying = false;
        sub.cancel();
        onDone?.call();
      });
      await _player.play(DeviceFileSource(path));
    } catch (e) {
      _isPlaying = false;
      onDone?.call();
    }
  }

  /// 停止播放
  Future<void> stop() async {
    await _player.stop();
    _isPlaying = false;
  }

  /// 释放资源（页→dispose 时调用）
  Future<void> dispose() async {
    await _player.dispose();
  }

  /// 清空本地 MP3 缓存（设定改变后可调用）
  static Future<void> clearCache() async {
    final dir = await _cacheDir();
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}


