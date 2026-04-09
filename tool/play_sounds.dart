/// Standalone script: generates all 3 feedback WAVs and plays them in sequence.
/// Run with: dart tool/play_sounds.dart
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

Uint8List buildWav(List<double> samples, int sampleRate) {
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

Uint8List dingWav() {
  const rate = 22050; const hz = 880.0; const ms = 450;
  final n = rate * ms ~/ 1000;
  final s = List<double>.generate(n, (i) {
    final t = i / rate;
    final env = i < (rate * 0.012).round() ? i / (rate * 0.012) : exp(-t * 9.0);
    return sin(2 * pi * hz * t) * env * 0.85;
  });
  return buildWav(s, rate);
}

Uint8List wrongWav() {
  const rate = 22050; const ms = 550;
  final n = rate * ms ~/ 1000;
  final s = List<double>.generate(n, (i) {
    final progress = i / n;
    final hz = 380.0 - 290.0 * progress;
    final t = i / rate;
    final wave = sin(2 * pi * hz * t) * 0.60
               + sin(2 * pi * 3 * hz * t) * 0.25
               + sin(2 * pi * 5 * hz * t) * 0.10
               + sin(2 * pi * 7 * hz * t) * 0.05;
    final attack = (i < 80) ? i / 80.0 : 1.0;
    final tail = progress > 0.85 ? (1.0 - (progress - 0.85) / 0.15) : 1.0;
    return (wave * attack * tail).clamp(-1.0, 1.0) * 0.92;
  });
  return buildWav(s, rate);
}

Uint8List congratsWav() {
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
  return buildWav(all, rate);
}

Future<void> playWav(String path) async {
  if (Platform.isWindows) {
    await Process.run('powershell', [
      '-c',
      '(New-Object Media.SoundPlayer "$path").PlaySync()'
    ]);
  } else if (Platform.isMacOS) {
    await Process.run('afplay', [path]);
  } else {
    await Process.run('aplay', [path]);
  }
}

Future<void> main() async {
  final tmp = Directory.systemTemp.path;
  final sounds = {
    '1_correct_ding.wav': dingWav(),
    '2_wrong_buzzer.wav': wrongWav(),
    '3_congrats_arpeggio.wav': congratsWav(),
  };

  for (final entry in sounds.entries) {
    final path = '$tmp/${entry.key}';
    File(path).writeAsBytesSync(entry.value);
    stdout.write('Playing ${entry.key} ... ');
    await playWav(path);
    stdout.writeln('done');
    await Future.delayed(const Duration(milliseconds: 300));
  }
}
