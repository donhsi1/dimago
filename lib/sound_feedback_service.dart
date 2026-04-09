import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Short feedback tones synthesised from sine waves and played via
/// DeviceFileSource — exactly the same pattern as EdgeTTSService.
class SoundFeedbackService {
  // Separate players so correct/wrong never share state
  static final AudioPlayer _correctPlayer = AudioPlayer();
  static final AudioPlayer _wrongPlayer   = AudioPlayer();
  static final AudioPlayer _congratsPlayer = AudioPlayer();

  // Pre-cached file paths (written once on first use)
  static Future<void>? _initFuture;
  static String? _correctPath;
  static String? _wrongPath;
  static String? _congratsPath;

  static Future<void> _ensureInit() => _initFuture ??= _doInit();

  static Future<void> _doInit() async {
    try {
      final dir = await getTemporaryDirectory();
      _correctPath  = '${dir.path}/sfx_correct.wav';
      _wrongPath    = '${dir.path}/sfx_wrong.wav';
      _congratsPath = '${dir.path}/sfx_congrats.wav';
      await File(_correctPath!).writeAsBytes(_dingWav(),      flush: true);
      await File(_wrongPath!).writeAsBytes(_wrongWav(),       flush: true);
      await File(_congratsPath!).writeAsBytes(_congratsWav(), flush: true);
      debugPrint('[SFX] init OK – correct=${_correctPath} wrong=${_wrongPath}');
    } catch (e) {
      debugPrint('[SFX] init error: $e');
    }
  }

  // ── WAV builder ───────────────────────────────────────────────
  static Uint8List _buildWav(List<double> samples, int sampleRate) {
    final n = samples.length;
    final dataBytes = n * 2;
    final buf = ByteData(44 + dataBytes);
    buf.setUint8(0, 0x52); buf.setUint8(1, 0x49);
    buf.setUint8(2, 0x46); buf.setUint8(3, 0x46);
    buf.setUint32(4, 36 + dataBytes, Endian.little);
    buf.setUint8(8, 0x57); buf.setUint8(9, 0x41);
    buf.setUint8(10, 0x56); buf.setUint8(11, 0x45);
    buf.setUint8(12, 0x66); buf.setUint8(13, 0x6D);
    buf.setUint8(14, 0x74); buf.setUint8(15, 0x20);
    buf.setUint32(16, 16, Endian.little);
    buf.setUint16(20, 1, Endian.little);
    buf.setUint16(22, 1, Endian.little);
    buf.setUint32(24, sampleRate, Endian.little);
    buf.setUint32(28, sampleRate * 2, Endian.little);
    buf.setUint16(32, 2, Endian.little);
    buf.setUint16(34, 16, Endian.little);
    buf.setUint8(36, 0x64); buf.setUint8(37, 0x61);
    buf.setUint8(38, 0x74); buf.setUint8(39, 0x61);
    buf.setUint32(40, dataBytes, Endian.little);
    for (int i = 0; i < n; i++) {
      final s = (samples[i].clamp(-1.0, 1.0) * 32767).round();
      buf.setInt16(44 + i * 2, s, Endian.little);
    }
    return buf.buffer.asUint8List();
  }

  // ── Tone generators ───────────────────────────────────────────

  /// Correct-answer ding: 880 Hz (A5)
  static Uint8List _dingWav() {
    const rate = 22050; const hz = 880.0; const ms = 450;
    final n = rate * ms ~/ 1000;
    final s = List<double>.generate(n, (i) {
      final t = i / rate;
      final env = i < (rate * 0.012).round() ? i / (rate * 0.012) : exp(-t * 9.0);
      return sin(2 * pi * hz * t) * env * 0.85;
    });
    return _buildWav(s, rate);
  }

  /// Wrong-answer ding: 440 Hz (A4) — one octave below correct, clearly audible
  /// on all phone speakers (330 Hz is too low for small speakers).
  static Uint8List _wrongWav() {
    const rate = 22050;
    const hz   = 440.0; // A4 — one octave below 880 Hz correct ding
    const ms   = 450;
    final n = rate * ms ~/ 1000;
    final s = List<double>.generate(n, (i) {
      final t   = i / rate;
      final env = i < (rate * 0.012).round()
          ? i / (rate * 0.012)
          : exp(-t * 9.0);
      return sin(2 * pi * hz * t) * env * 0.85;
    });
    return _buildWav(s, rate);
  }

  static Uint8List _congratsWav() {
    const rate = 22050; const noteMs = 85;
    const noteSamples = rate * noteMs ~/ 1000;
    const freqs = [523.25, 659.25, 783.99, 1046.50];
    final all = <double>[];
    for (final hz in freqs) {
      for (int i = 0; i < noteSamples; i++) {
        final t = i / rate;
        final env = i < (noteSamples * 0.08).round()
            ? i / (noteSamples * 0.08) : exp(-t * 6.0);
        all.add(sin(2 * pi * hz * t) * env * 0.80);
      }
    }
    return _buildWav(all, rate);
  }

  // ── Public API ────────────────────────────────────────────────

  static Future<void> playCorrect() async {
    try {
      await _ensureInit();
      debugPrint('[SFX] playCorrect path=$_correctPath');
      await _correctPlayer.stop();
      await _correctPlayer.play(DeviceFileSource(_correctPath!));
    } catch (e) {
      debugPrint('[SFX] playCorrect error: $e');
    }
  }

  static Future<void> playWrong() async {
    try {
      await _ensureInit();
      debugPrint('[SFX] playWrong path=$_wrongPath');
      await _wrongPlayer.play(DeviceFileSource(_wrongPath!));
    } catch (e) {
      debugPrint('[SFX] playWrong error: $e');
    }
  }

  static Future<void> playCongrats() async {
    try {
      await _ensureInit();
      debugPrint('[SFX] playCongrats path=$_congratsPath');
      await _congratsPlayer.stop();
      await _congratsPlayer.play(DeviceFileSource(_congratsPath!));
    } catch (e) {
      debugPrint('[SFX] playCongrats error: $e');
    }
  }
}
