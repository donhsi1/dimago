import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';

/// Show the recording dialog.
/// Returns: null = cancelled, non-null = file path of recording.
Future<String?> showRecordingDialog(BuildContext context,
    {String title = 'Record'}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _RecordingDialog(title: title),
  );
}

// ──────────────────────────────────────────────────────────────
class _RecordingDialog extends StatefulWidget {
  final String title;
  const _RecordingDialog({required this.title});

  @override
  State<_RecordingDialog> createState() => _RecordingDialogState();
}

enum _RecState { idle, recording, stopped, playing }

class _RecordingDialogState extends State<_RecordingDialog>
    with SingleTickerProviderStateMixin {
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();

  _RecState _state = _RecState.idle;
  String? _filePath;

  // Recording timer
  int _recSeconds = 0;
  Timer? _recTimer;

  // Waveform
  final List<double> _waveform = List.filled(40, 0.0);
  Timer? _waveTimer;
  final _rand = Random();

  // Playback progress
  Duration _playDuration = Duration.zero;
  Duration _playPosition = Duration.zero;
  StreamSubscription? _posSub;
  StreamSubscription? _durSub;
  StreamSubscription? _stateSub;

  // Mic pulse animation
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _pulseAnim = Tween<double>(begin: 0.85, end: 1.15).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
    // Do NOT auto-start recording →wait for user to press Record
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _waveTimer?.cancel();
    _recTimer?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  // ── Recording ───────────────────────────────────────────────
  Future<void> _startRecording() async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission required')),
        );
        Navigator.pop(context, null);
      }
      return;
    }

    // Stop any existing playback
    await _player.stop();
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _waveTimer?.cancel();
    _recTimer?.cancel();
    _pulseCtrl.stop();

    setState(() {
      _state = _RecState.recording;
      _recSeconds = 0;
      _playPosition = Duration.zero;
      _playDuration = Duration.zero;
      for (int i = 0; i < _waveform.length; i++) {
        _waveform[i] = 0.0;
      }
    });

    final dir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    // Record as WAV (PCM) so we can trim silence in Dart
    _filePath = '${dir.path}/rec_$timestamp.wav';

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 44100,
        numChannels: 1,
      ),
      path: _filePath!,
    );

    _pulseCtrl.repeat(reverse: true);
    _startWaveAnimation();
    _startRecordingTimer();
  }

  void _startWaveAnimation() {
    _waveTimer?.cancel();
    _waveTimer = Timer.periodic(const Duration(milliseconds: 80), (_) {
      if (!mounted) return;
      setState(() {
        for (int i = 0; i < _waveform.length; i++) {
          _waveform[i] = _rand.nextDouble();
        }
      });
    });
  }

  void _startRecordingTimer() {
    _recTimer?.cancel();
    _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _recSeconds++);
    });
  }

  Future<void> _stopRecording() async {
    _waveTimer?.cancel();
    _recTimer?.cancel();
    _pulseCtrl.stop();
    // Stop the waveform so bars stay frozen (visual feedback)
    final stoppedWaveform = List<double>.from(_waveform);

    final rawPath = await _recorder.stop();
    if (rawPath != null) _filePath = rawPath;

    if (mounted) {
      setState(() {
        _state = _RecState.stopped;
        // Keep the frozen waveform bars for visual display
        for (int i = 0; i < _waveform.length; i++) {
          _waveform[i] = stoppedWaveform[i];
        }
      });
    }
  }

  // ── Playback ─────────────────────────────────────────────────
  Future<void> _playback() async {
    if (_filePath == null) return;
    await _player.stop();
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();

    _durSub = _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _playDuration = d);
    });
    _posSub = _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _playPosition = p);
    });
    _stateSub = _player.onPlayerStateChanged.listen((s) {
      if (s == PlayerState.completed) {
        if (mounted) {
          setState(() {
            _state = _RecState.stopped;
            _playPosition = Duration.zero;
          });
        }
      }
    });

    setState(() => _state = _RecState.playing);
    await _player.play(DeviceFileSource(_filePath!));
  }

  Future<void> _stopPlayback() async {
    await _player.stop();
    setState(() {
      _state = _RecState.stopped;
      _playPosition = Duration.zero;
    });
  }

  // ── Confirm / Cancel ─────────────────────────────────────────
  void _confirm() {
    Navigator.pop(context, _filePath);
  }

  void _cancel() {
    _waveTimer?.cancel();
    _recTimer?.cancel();
    _pulseCtrl.stop();
    _recorder.stop();
    _player.stop();
    if (_filePath != null) {
      try { File(_filePath!).deleteSync(); } catch (_) {}
    }
    Navigator.pop(context, null);
  }

  // ── Helpers ──────────────────────────────────────────────────
  // Recording: plain seconds "5s"
  String _fmtRecSec(int s) => '${s}s';

  // Playback: "m:ss" (e.g. "0:07", "1:23")
  String _fmtDur(Duration d) {
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ── Waveform ─────────────────────────────────────────────────
  Widget _buildWaveform() {
    final isPlaying = _state == _RecState.playing;
    final progress = (_playDuration.inMilliseconds > 0)
        ? _playPosition.inMilliseconds / _playDuration.inMilliseconds
        : 0.0;

    return SizedBox(
      height: 56,
      child: CustomPaint(
        size: const Size(double.infinity, 56),
        painter: _WaveformPainter(
          bars: _waveform,
          progress: isPlaying ? progress.clamp(0.0, 1.0) : null,
          activeColor: _state == _RecState.recording
              ? Colors.redAccent
              : const Color(0xFF1565C0),
          inactiveColor: Colors.grey.shade300,
        ),
      ),
    );
  }

  // ── Status icon area ─────────────────────────────────────────
  Widget _buildStatusIcon() {
    switch (_state) {
      case _RecState.idle:
        return Icon(Icons.mic_none_rounded, size: 48, color: Colors.grey.shade400);
      case _RecState.recording:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ScaleTransition(
              scale: _pulseAnim,
              child: const Icon(Icons.mic_rounded, size: 48, color: Colors.redAccent),
            ),
            const SizedBox(height: 4),
            Text(_fmtRecSec(_recSeconds),
                style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.redAccent,
                    fontFeatures: [FontFeature.tabularFigures()])),
          ],
        );
      case _RecState.stopped:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.stop_circle_outlined, size: 48, color: Color(0xFF1565C0)),
            const SizedBox(height: 4),
            Text(_fmtRecSec(_recSeconds),
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1565C0))),
          ],
        );
      case _RecState.playing:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.play_circle_outline_rounded, size: 48, color: Color(0xFF2E7D32)),
            const SizedBox(height: 4),
            Text('${_fmtDur(_playPosition)} / ${_fmtDur(_playDuration)}',
                style: const TextStyle(fontSize: 12, color: Color(0xFF2E7D32))),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isRecording = _state == _RecState.recording;
    final isStopped   = _state == _RecState.stopped;
    final isPlaying   = _state == _RecState.playing;
    final isIdle      = _state == _RecState.idle;

    final canRecord = isIdle || isStopped;
    final canStop   = isRecording || isPlaying;
    final canPlay   = isStopped;
    final canOk     = isStopped;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Title (hidden if empty)
            if (widget.title.isNotEmpty) ...[
              Text(widget.title,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
            ],

            // Status icon + counter
            _buildStatusIcon(),
            const SizedBox(height: 12),

            // Waveform (only show when active)
            if (isRecording || isPlaying || isStopped) ...[
              _buildWaveform(),
              const SizedBox(height: 4),
              // Play position row (only when playing)
              if (isPlaying)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_fmtDur(_playPosition),
                        style: const TextStyle(fontSize: 10, color: Colors.grey)),
                    Text(_fmtDur(_playDuration),
                        style: const TextStyle(fontSize: 10, color: Colors.grey)),
                  ],
                ),
            ] else
              const SizedBox(height: 40), // placeholder when idle

            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 12),

            // ── Bottom icon button row ───────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Cancel
                _IconBtn(
                  icon: Icons.cancel_outlined,
                  label: 'Cancel',
                  color: Colors.grey,
                  enabled: true,
                  onTap: _cancel,
                ),
                // Record
                _IconBtn(
                  icon: Icons.fiber_manual_record,
                  label: 'Record',
                  color: Colors.redAccent,
                  enabled: canRecord,
                  onTap: canRecord ? _startRecording : null,
                ),
                // Stop
                _IconBtn(
                  icon: Icons.stop_rounded,
                  label: 'Stop',
                  color: Colors.orange,
                  enabled: canStop,
                  onTap: isRecording
                      ? _stopRecording
                      : isPlaying
                          ? _stopPlayback
                          : null,
                ),
                // Play
                _IconBtn(
                  icon: Icons.play_arrow_rounded,
                  label: 'Play',
                  color: const Color(0xFF1565C0),
                  enabled: canPlay,
                  onTap: canPlay ? _playback : null,
                ),
                // OK
                _IconBtn(
                  icon: Icons.check_circle_outline_rounded,
                  label: 'OK',
                  color: const Color(0xFF2E7D32),
                  enabled: canOk,
                  onTap: canOk ? _confirm : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Icon button ────────────────────────────────────────────────
class _IconBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool enabled;
  final VoidCallback? onTap;

  const _IconBtn({
    required this.icon,
    required this.label,
    required this.color,
    required this.enabled,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = enabled ? color : Colors.grey.shade300;
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: effectiveColor),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                    fontSize: 10,
                    color: effectiveColor,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

// ── Waveform Painter ──────────────────────────────────────────
class _WaveformPainter extends CustomPainter {
  final List<double> bars;
  final double? progress;
  final Color activeColor;
  final Color inactiveColor;

  _WaveformPainter({
    required this.bars,
    required this.activeColor,
    required this.inactiveColor,
    this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final n = bars.length;
    if (n == 0) return;
    final barW = size.width / (n * 2 - 1);
    final maxH = size.height;
    final midY = size.height / 2;
    final progressX = progress != null ? size.width * progress! : null;

    for (int i = 0; i < n; i++) {
      final x = i * barW * 2;
      final barH = (bars[i] * maxH * 0.85).clamp(4.0, maxH);
      final paint = Paint()
        ..color = (progressX != null && x <= progressX)
            ? activeColor
            : (progress != null ? inactiveColor : activeColor)
        ..style = PaintingStyle.fill;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: Offset(x + barW / 2, midY),
              width: barW,
              height: barH),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.bars != bars || old.progress != progress;
}
