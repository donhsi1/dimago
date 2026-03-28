import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'language_prefs.dart';
import 'database_helper.dart';

// ── Language code →DB filename ───────────────────────────────
class LangDbService {
  /// GitHub raw base URL for dict_xx.db files
  static const _baseUrl =
      'https://raw.githubusercontent.com/donhsi1/dimago/main/dict';

  /// Map language code →dict filename (canonical casing)
  static String dbFileName(String langCode) {
    const map = <String, String>{
      'th':    'dict_TH.db',
      'zh_CN': 'dict_CN.db',
      'zh_TW': 'dict_TW.db',
      'en_US': 'dict_EN.db',
      'fr':    'dict_FR.db',
      'de':    'dict_DE.db',
      'it':    'dict_IT.db',
      'es':    'dict_ES.db',
      'ja':    'dict_JA.db',
      'ko':    'dict_KO.db',
      'my':    'dict_MY.db',
      'he':    'dict_HE.db',
      'ru':    'dict_RU.db',
      'uk':    'dict_UK.db',
    };
    return map[langCode] ?? 'dict_${langCode.toUpperCase()}.db';
  }

  static String downloadUrl(String langCode) =>
      '$_baseUrl/${dbFileName(langCode)}';

  // ── Photo DB ──────────────────────────────────────────────────
  static const _photoDbName = 'dict_photo.db';
  static String get photoDbUrl => '$_baseUrl/$_photoDbName';

  // ── Photo image sandbox ───────────────────────────────────────
  /// GitHub raw base URL for individual photo PNG files
  static const _photoImgBase =
      'https://raw.githubusercontent.com/donhsi1/dimago/main/photo';

  /// Local sandbox directory where downloaded PNG images are stored.
  static Future<Directory> photoSandboxDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'photo_cache'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Returns the local File for a given English photo name (without extension).
  static Future<File> photoLocalFile(String englishName) async {
    final dir = await photoSandboxDir();
    final safeName = englishName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return File(p.join(dir.path, '$safeName.png'));
  }

  /// Resolves a photo PNG for [englishName]:
  /// 1. If local file exists →returns its bytes immediately.
  /// 2. Otherwise downloads from GitHub dimago/photo/<englishName>.png,
  ///    saves to sandbox, and returns bytes.
  /// Returns null on any error (not found, network failure, etc.).
  static Future<Uint8List?> resolvePhotoImage(String englishName) async {
    try {
      final local = await photoLocalFile(englishName);
      if (local.existsSync()) {
        final bytes = await local.readAsBytes();
        if (bytes.isNotEmpty) return bytes;
      }

      // Download from GitHub
      final safeName = englishName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final url = '$_photoImgBase/$safeName.png';
      final response = await http.get(Uri.parse(url)).timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        return null;
      }
      // Save to sandbox
      await local.writeAsBytes(response.bodyBytes);
      return response.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  static Future<String> photoDbLocalPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, _photoDbName);
  }

  static Future<bool> isPhotoDbDownloaded() async {
    final path = await photoDbLocalPath();
    final file = File(path);
    if (!file.existsSync()) return false;
    try {
      final bytes = await file.readAsBytes();
      if (bytes.length < 100) return false;
      return String.fromCharCodes(bytes.sublist(0, 15))
          .startsWith('SQLite format 3');
    } catch (_) {
      return false;
    }
  }

  static Future<String> downloadPhotoDb({
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final destPath = await photoDbLocalPath();
    final req = http.Request('GET', Uri.parse(photoDbUrl));
    final resp = await http.Client().send(req);
    if (resp.statusCode != 200) {
      await resp.stream.drain<void>();
      throw Exception('Failed to download dict_photo.db (${resp.statusCode})');
    }
    final total = resp.contentLength ?? -1;
    int received = 0;
    final sink = File(destPath).openWrite();
    await for (final chunk in resp.stream) {
      if (cancelToken?.isCancelled == true) {
        await sink.close();
        try { File(destPath).deleteSync(); } catch (_) {}
        throw Exception('cancelled');
      }
      sink.add(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }
    await sink.close();
    await _verifySqliteFile(destPath, 'photo');
    return destPath;
  }

  /// Local path where a downloaded DB file is stored.
  /// Always uses the canonical (uppercase) filename.
  static Future<String> localPath(String langCode) async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, dbFileName(langCode));
  }

  /// Check if local DB file already exists AND is a valid SQLite database with content.
  static Future<bool> isDownloaded(String langCode) async {
    final path = await localPath(langCode);
    final file = File(path);
    if (!file.existsSync()) return false;
    // Must be a valid SQLite file (starts with SQLite magic header) and > 100 bytes
    try {
      final bytes = await file.readAsBytes();
      if (bytes.length < 100) return false;
      final magic = String.fromCharCodes(bytes.sublist(0, 15));
      return magic.startsWith('SQLite format 3');
    } catch (_) {
      return false;
    }
  }

  /// Download a DB file with progress callback.
  /// Tries uppercase, lowercase, and mixed-case variants to be case-insensitive.
  /// After download, verifies the file is a valid SQLite database.
  /// Returns local file path on success, throws on failure.
  static Future<String> download(
    String langCode, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final destPath = await localPath(langCode);
    final base = dbFileName(langCode);

    // Build candidate URLs: canonical, lowercase, uppercase
    final candidates = <String>{
      '$_baseUrl/$base',
      '$_baseUrl/${base.toLowerCase()}',
      '$_baseUrl/${base.toUpperCase()}',
    }.toList();

    http.StreamedResponse? response;
    for (final url in candidates) {
      final req = http.Request('GET', Uri.parse(url));
      final resp = await http.Client().send(req);
      if (resp.statusCode == 200) {
        response = resp;
        break;
      }
      await resp.stream.drain<void>();
    }

    if (response == null) {
      throw Exception(
          'No database found for language "$langCode".\n'
          'Tried: ${candidates.join(', ')}');
    }

    final total = response.contentLength ?? -1;
    int received = 0;

    final sink = File(destPath).openWrite();
    await for (final chunk in response.stream) {
      if (cancelToken?.isCancelled == true) {
        await sink.close();
        try { File(destPath).deleteSync(); } catch (_) {}
        throw Exception('cancelled');
      }
      sink.add(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }
    await sink.close();

    // Verify the downloaded file is a valid SQLite database
    await _verifySqliteFile(destPath, langCode);

    return destPath;
  }

  /// Checks the SQLite magic header bytes.
  /// Deletes the file and throws if invalid.
  static Future<void> _verifySqliteFile(String path, String langCode) async {
    final file = File(path);
    final bytes = await file.readAsBytes();
    if (bytes.length < 100) {
      await file.delete();
      throw Exception(
          'Database for "$langCode" is too small →possibly empty or corrupt.');
    }
    final magic = String.fromCharCodes(bytes.sublist(0, 15));
    if (!magic.startsWith('SQLite format 3')) {
      await file.delete();
      throw Exception(
          'Downloaded file for "$langCode" is not a valid SQLite database.');
    }
  }
}

// ── Simple cancellation token ─────────────────────────────────
class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

// ── Download Progress Dialog ──────────────────────────────────
/// Shows a dialog that downloads both learn-lang and native-lang databases.
/// Returns true when both are downloaded and verified successfully.
Future<bool> showLangDbDownloadDialog(
  BuildContext context, {
  required String learnLang,
  required String nativeLang,
  bool forceRedownload = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _LangDbDownloadDialog(
      learnLang: learnLang,
      nativeLang: nativeLang,
      forceRedownload: forceRedownload,
    ),
  );
  return result == true;
}

class _LangDbDownloadDialog extends StatefulWidget {
  final String learnLang;
  final String nativeLang;
  final bool forceRedownload;
  const _LangDbDownloadDialog({
    required this.learnLang,
    required this.nativeLang,
    this.forceRedownload = false,
  });
  @override
  State<_LangDbDownloadDialog> createState() => _LangDbDownloadDialogState();
}

enum _DownloadStatus { idle, downloading, done, error }

class _LangDbDownloadDialogState extends State<_LangDbDownloadDialog> {
  _DownloadStatus _status = _DownloadStatus.idle;
  String _message = '';
  double _progress1 = 0; // learn lang
  double _progress2 = 0; // native lang
  double _progress3 = 0; // photo db
  String _errorMsg = '';
  final CancelToken _cancel = CancelToken();

  @override
  void initState() {
    super.initState();
    _startDownload();
  }

  String _langLabel(String code) {
    final opt = kAllLanguages.firstWhere(
      (o) => o.code == code,
      orElse: () => LangOption(code: code, label: code, flag: ''),
    );
    return opt.label;
  }

  Future<void> _startDownload() async {
    setState(() {
      _status = _DownloadStatus.downloading;
      _message = '';
      _progress1 = 0;
      _progress2 = 0;
      _progress3 = 0;
    });

    try {
      final learnLabel  = _langLabel(widget.learnLang);
      final nativeLabel = _langLabel(widget.nativeLang);

      // ── Delete existing files if force redownload ──
      if (widget.forceRedownload) {
        await DatabaseHelper.closeAll();
        for (final lang in [widget.learnLang, widget.nativeLang]) {
          try {
            final path = await LangDbService.localPath(lang);
            final f = File(path);
            if (f.existsSync()) f.deleteSync();
          } catch (_) {}
        }
      }

      // ── Download learn lang DB ──
      final learnAlreadyExists =
          await LangDbService.isDownloaded(widget.learnLang);
      if (!learnAlreadyExists) {
        setState(() => _message = 'Downloading $learnLabel...');
        await LangDbService.download(
          widget.learnLang,
          cancelToken: _cancel,
          onProgress: (r, t) {
            if (t > 0) setState(() => _progress1 = r / t);
          },
        );
      }
      setState(() => _progress1 = 1.0);

      // ── Download native lang DB ──
      final nativeAlreadyExists =
          await LangDbService.isDownloaded(widget.nativeLang);
      if (!nativeAlreadyExists) {
        setState(() => _message = 'Downloading $nativeLabel...');
        await LangDbService.download(
          widget.nativeLang,
          cancelToken: _cancel,
          onProgress: (r, t) {
            if (t > 0) setState(() => _progress2 = r / t);
          },
        );
      }
      setState(() => _progress2 = 1.0);

      // ── Download photo DB ──
      final photoAlreadyExists = await LangDbService.isPhotoDbDownloaded();
      if (!photoAlreadyExists) {
        setState(() => _message = 'Downloading photos...');
        await LangDbService.downloadPhotoDb(
          cancelToken: _cancel,
          onProgress: (r, t) {
            if (t > 0) setState(() => _progress3 = r / t);
          },
        );
      }
      setState(() => _progress3 = 1.0);

      // ── Open databases ──
      setState(() => _message = 'Loading databases...');
      await DatabaseHelper.openWithLangs(widget.learnLang, widget.nativeLang);

      // ── Verify databases have content ──
      final learnCount  = await DatabaseHelper.wordCount();
      final nativeCount = await DatabaseHelper.wordCountNative();
      if (learnCount == 0) {
        // Delete so next launch re-downloads
        final path = await LangDbService.localPath(widget.learnLang);
        try { File(path).deleteSync(); } catch (_) {}
        throw Exception(
            '$learnLabel database contains no words.\n'
            'Please upload word data to the repository.');
      }
      if (nativeCount == 0) {
        final path = await LangDbService.localPath(widget.nativeLang);
        try { File(path).deleteSync(); } catch (_) {}
        throw Exception(
            '$nativeLabel database contains no words.\n'
            'Please upload word data to the repository.');
      }

      setState(() {
        _status = _DownloadStatus.done;
        _message = 'Done!';
      });
    } catch (e) {
      // Clean up any partial/empty files so retry forces re-download
      try {
        final p1 = await LangDbService.localPath(widget.learnLang);
        if (File(p1).existsSync()) File(p1).deleteSync();
      } catch (_) {}
      try {
        final p2 = await LangDbService.localPath(widget.nativeLang);
        if (File(p2).existsSync()) File(p2).deleteSync();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _status = _DownloadStatus.error;
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n(AppLangNotifier().uiLang);
    final learnLabel  = _langLabel(widget.learnLang);
    final nativeLabel = _langLabel(widget.nativeLang);
    final isDone  = _status == _DownloadStatus.done;
    final isError = _status == _DownloadStatus.error;

    return AlertDialog(
      title: Row(children: [
        const Icon(Icons.download_rounded, color: Color(0xFF1565C0)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            isDone ? 'Download Complete' : 'Downloading Databases',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
      ]),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isError) ...[
              const Icon(Icons.error_outline, color: Colors.red, size: 40),
              const SizedBox(height: 8),
              Text(
                'Download failed:\n$_errorMsg',
                style: const TextStyle(color: Colors.red),
                textAlign: TextAlign.center,
              ),
            ] else if (isDone) ...[
              const Icon(Icons.check_circle_outline,
                  color: Color(0xFF2E7D32), size: 48),
              const SizedBox(height: 8),
              const Text('Both databases are ready.',
                  textAlign: TextAlign.center),
            ] else ...[
              _ProgressRow(label: learnLabel,  progress: _progress1),
              const SizedBox(height: 12),
              _ProgressRow(label: nativeLabel, progress: _progress2),
              const SizedBox(height: 12),
              _ProgressRow(label: 'Photos',    progress: _progress3),
              if (_message.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(_message,
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade600),
                    textAlign: TextAlign.center),
              ],
            ],
          ],
        ),
      ),
      actions: [
        if (isDone)
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1565C0)),
            child: const Text('OK'),
          ),
        if (isError)
          FilledButton(
            onPressed: _startDownload,
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: Text(l.langPackRetry),
          ),
        if (isError)
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.cancel),
          ),
      ],
    );
  }
}

class _ProgressRow extends StatelessWidget {
  final String label;
  final double progress;
  const _ProgressRow({required this.label, required this.progress});

  @override
  Widget build(BuildContext context) {
    final done = progress >= 1.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w500)),
            ),
            if (done)
              const Icon(Icons.check_circle,
                  color: Color(0xFF2E7D32), size: 16)
            else
              Text('${(progress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress > 0 ? progress : null,
            minHeight: 6,
            backgroundColor: Colors.grey.shade200,
            valueColor: AlwaysStoppedAnimation(
                done ? const Color(0xFF2E7D32) : const Color(0xFF1565C0)),
          ),
        ),
      ],
    );
  }
}
