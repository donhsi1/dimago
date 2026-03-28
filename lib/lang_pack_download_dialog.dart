import 'package:flutter/material.dart';
import 'lang_pack_service.dart';
import 'language_prefs.dart';

// ════════════════════════════════════════════════════════════════
// 语言包下载进度弹→'
// 使用方式→'
//   final ok = await LangPackDownloadDialog.show(context, packId: 'th-cn', l: l);
// 返回 true 表示成功，false 表示取消或失→'
// ════════════════════════════════════════════════════════════════
class LangPackDownloadDialog extends StatefulWidget {
  final String packId;
  final L10n l;

  const LangPackDownloadDialog({
    super.key,
    required this.packId,
    required this.l,
  });

  static Future<bool> show(
    BuildContext context, {
    required String packId,
    required L10n l,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => LangPackDownloadDialog(packId: packId, l: l),
    );
    return result ?? false;
  }

  @override
  State<LangPackDownloadDialog> createState() => _LangPackDownloadDialogState();
}

class _LangPackDownloadDialogState extends State<LangPackDownloadDialog> {
  double _progress = 0.0;
  String _status = '';
  bool _done = false;
  bool _error = false;
  String _errorMsg = '';

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      await LangPackService.downloadAndImport(
        packId: widget.packId,
        onProgress: (progress, status) {
          if (!mounted) return;
          setState(() {
            _progress = progress;
            _status = status;
            _done = progress >= 1.0;
          });
        },
      );
      if (mounted) {
        await Future.delayed(const Duration(milliseconds: 600));
        if (mounted) Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = true;
          _errorMsg = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.l;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          const Icon(Icons.download_rounded, color: Color(0xFF1565C0)),
          const SizedBox(width: 8),
          Text(
            l.langPackDownloading,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ],
      ),
      content: SizedBox(
        width: 280,
        child: _error
            ? _buildError()
            : _buildProgress(),
      ),
      actions: _error
          ? [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(l.cancel),
              ),
              FilledButton(
                onPressed: () {
                  setState(() {
                    _error = false;
                    _progress = 0;
                    _status = '';
                  });
                  _start();
                },
                child: Text(l.langPackRetry),
              ),
            ]
          : null,
    );
  }

  Widget _buildProgress() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: _progress > 0 ? _progress : null,
          minHeight: 8,
          borderRadius: BorderRadius.circular(4),
          backgroundColor: Colors.grey.shade200,
          valueColor: const AlwaysStoppedAnimation(Color(0xFF1565C0)),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _status,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
            if (_progress > 0)
              Text(
                '${(_progress * 100).toInt()}%',
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1565C0)),
              ),
          ],
        ),
        if (_done) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.green, size: 20),
              const SizedBox(width: 6),
              Text(
                'Done!',
                style: TextStyle(color: Colors.green.shade700, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildError() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline, color: Colors.red, size: 40),
        const SizedBox(height: 12),
        Text(
          widget.l.langPackError,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          _errorMsg,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
