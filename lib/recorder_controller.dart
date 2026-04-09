import 'package:flutter/foundation.dart';
import 'package:flutter_screen_recording/flutter_screen_recording.dart';

/// Global controller for screen recording lifecycle.
class RecorderController {
  RecorderController._();

  static final ValueNotifier<bool> isRecording = ValueNotifier<bool>(false);
  static Future<String>? _stopInFlight;

  static void markStarted() {
    isRecording.value = true;
  }

  /// Single-flight stop: avoids double native stop calls (empty path / errors).
  static Future<String> stopRecording() {
    final existing = _stopInFlight;
    if (existing != null) return existing;
    final f = _stopOnce();
    _stopInFlight = f;
    f.whenComplete(() {
      if (_stopInFlight == f) {
        _stopInFlight = null;
      }
    });
    return f;
  }

  static Future<String> _stopOnce() async {
    try {
      final path = await FlutterScreenRecording.stopRecordScreen;
      isRecording.value = false;
      return path;
    } catch (_) {
      isRecording.value = false;
      return '';
    }
  }
}
