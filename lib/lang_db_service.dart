import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'language_prefs.dart';
import 'database_helper.dart';
import 'talk_asr_service.dart';
import 'supabase_vocab_hydrator.dart';
import 'supabase_bootstrap.dart';

// ── Language code → DB filename ──────────────────────────────
class LangDbService {
  /// GitHub raw base URL for dict files
  static const _baseUrl =
      'https://raw.githubusercontent.com/donhsi1/dimago/main';

  /// Raw GitHub often returns 403/429 without a browser-like User-Agent.
  static void _browserLikeHeaders(http.BaseRequest request) {
    request.headers['User-Agent'] =
        'Dimago/1.0 (Flutter; vocabulary; +https://github.com/donhsi1/dimago)';
    request.headers['Accept'] = '*/*';
  }

  /// Map language code → 2-letter uppercase code used in combined filenames
  static String _code(String langCode) {
    const map = <String, String>{
      'th':    'TH',
      'zh_CN': 'CN',
      'zh_TW': 'TW',
      'en_US': 'EN',
      'fr':    'FR',
      'de':    'DE',
      'it':    'IT',
      'es':    'ES',
      'ja':    'JA',
      'ko':    'KO',
      'my':    'MY',
      'he':    'HE',
      'ru':    'RU',
      'uk':    'UK',
    };
    return map[langCode] ?? langCode.toUpperCase();
  }

  /// Combined DB filename for a language pair.
  /// e.g. dbFileNamePair('th', 'zh_CN') → 'dict_TH_CN.db'
  static String dbFileNamePair(String translateLang, String nativeLang) {
    return 'dict_${_code(translateLang)}_${_code(nativeLang)}.db';
  }

  /// Stable, filesystem-safe user key for namespacing local DB files.
  /// Requires a signed-in Supabase user.
  static String currentDbUserKey() {
    final uid = SupabaseBootstrap.clientOrNull?.auth.currentUser?.id;
    if (uid == null || uid.trim().isEmpty) {
      throw StateError(
        'Signed-in user required for local DB path. '
        'Complete credential login before opening/downloading SQLite.',
      );
    }
    final safe = uid.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return safe;
  }

  /// User-scoped DB filename for a language pair.
  /// Example: `dict_TH_CN__u_8f2d....db`
  static String dbFileNamePairForCurrentUser(
      String translateLang, String nativeLang) {
    final base = dbFileNamePair(translateLang, nativeLang);
    final userKey = currentDbUserKey();
    return base.replaceFirst('.db', '__u_$userKey.db');
  }

  /// Single-language DB filename (legacy / deprecated).
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

  static String downloadUrlPair(String translateLang, String nativeLang) =>
      '$_baseUrl/${dbFileNamePair(translateLang, nativeLang)}';

  // ── Photo DB ──────────────────────────────────────────────────
  static const _photoDbName = 'dict_photo.db';
  static String get photoDbUrl => '$_baseUrl/$_photoDbName';

  // ── Photo image sandbox ───────────────────────────────────────
  static const _photoImgBase =
      'https://raw.githubusercontent.com/donhsi1/dimago/main/photo';

  static Future<Directory> photoSandboxDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'photo_cache'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static Future<File> photoLocalFile(String englishName) async {
    final dir = await photoSandboxDir();
    final safeName = englishName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return File(p.join(dir.path, '$safeName.png'));
  }

  static Future<Uint8List?> resolvePhotoImage(String englishName) async {
    try {
      final local = await photoLocalFile(englishName);
      if (local.existsSync()) {
        final bytes = await local.readAsBytes();
        if (bytes.isNotEmpty) return bytes;
      }
      final safeName = englishName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final url = '$_photoImgBase/$safeName.png';
      final response = await http.get(Uri.parse(url)).timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        return null;
      }
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
    final candidates = <String>[
      photoDbUrl,
      'https://cdn.jsdelivr.net/gh/donhsi1/dimago@main/$_photoDbName',
    ];

    http.StreamedResponse? response;
    for (final url in candidates) {
      final req = http.Request('GET', Uri.parse(url));
      _browserLikeHeaders(req);
      final resp = await http.Client().send(req);
      if (resp.statusCode == 200) {
        response = resp;
        break;
      }
      await resp.stream.drain<void>();
    }

    if (response == null) {
      throw Exception(
        'Failed to download dict_photo.db after ${candidates.length} sources.\n'
        'Check network or try again later (optional file).',
      );
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
    await _verifySqliteFile(destPath, 'photo');
    return destPath;
  }

  // ── Combined-DB path helpers ─────────────────────────────────

  /// Local path for the combined language-pair DB.
  static Future<String> localPathPair(
      String translateLang, String nativeLang) async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(
      dir.path,
      dbFileNamePairForCurrentUser(translateLang, nativeLang),
    );
  }

  /// Check if the combined DB file is already downloaded and valid.
  static Future<bool> isDownloadedPair(
      String translateLang, String nativeLang) async {
    final path = await localPathPair(translateLang, nativeLang);
    return _isSqliteFile(path);
  }

  /// Download the combined language-pair DB.
  static Future<String> downloadPair(
    String translateLang,
    String nativeLang, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final destPath = await localPathPair(translateLang, nativeLang);
    final base = dbFileNamePair(translateLang, nativeLang);

    final candidates = <String>{
      '$_baseUrl/$base',
      '$_baseUrl/${base.toLowerCase()}',
    }.toList();

    http.StreamedResponse? response;
    for (final url in candidates) {
      final req = http.Request('GET', Uri.parse(url));
      _browserLikeHeaders(req);
      final resp = await http.Client().send(req);
      if (resp.statusCode == 200) {
        response = resp;
        break;
      }
      await resp.stream.drain<void>();
    }

    if (response == null) {
      throw Exception(
          'No combined database found for "$translateLang"/"$nativeLang".\n'
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
    await _verifySqliteFile(destPath, '$translateLang/$nativeLang');
    return destPath;
  }

  // ── Legacy single-lang helpers (backward compat) ─────────────

  static Future<String> localPath(String langCode) async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, dbFileName(langCode));
  }

  static Future<bool> isDownloaded(String langCode) async {
    final path = await localPath(langCode);
    return _isSqliteFile(path);
  }

  static Future<String> download(
    String langCode, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final destPath = await localPath(langCode);
    final base = dbFileName(langCode);

    final candidates = <String>{
      '$_baseUrl/$base',
      '$_baseUrl/${base.toLowerCase()}',
      '$_baseUrl/${base.toUpperCase()}',
    }.toList();

    http.StreamedResponse? response;
    for (final url in candidates) {
      final req = http.Request('GET', Uri.parse(url));
      _browserLikeHeaders(req);
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
    await _verifySqliteFile(destPath, langCode);
    return destPath;
  }

  // ── Internal helpers ─────────────────────────────────────────

  static Future<bool> _isSqliteFile(String path) async {
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

  static Future<void> _verifySqliteFile(String path, String label) async {
    final file = File(path);
    final bytes = await file.readAsBytes();
    if (bytes.length < 100) {
      await file.delete();
      throw Exception(
          'Database for "$label" is too small — possibly empty or corrupt.');
    }
    final magic = String.fromCharCodes(bytes.sublist(0, 15));
    if (!magic.startsWith('SQLite format 3')) {
      await file.delete();
      throw Exception(
          'Downloaded file for "$label" is not a valid SQLite database.');
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
/// Shows a dialog that downloads ONE combined language-pair database.
/// Returns true when downloaded and verified successfully.
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
  double _progressDb  = 0; // combined DB
  double _progressPhoto = 0; // photo db
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
      _progressDb    = 0;
      _progressPhoto = 0;
    });

    try {
      final nativeL = L10n(widget.nativeLang);
      final learnLabel  = _langLabel(widget.learnLang);
      final nativeLabel = _langLabel(widget.nativeLang);
      final pairLabel   = '$learnLabel / $nativeLabel';

      // ── Delete existing file if force redownload ──
      if (widget.forceRedownload) {
        await DatabaseHelper.closeAll();
        try {
          final path = await LangDbService.localPathPair(
              widget.learnLang, widget.nativeLang);
          final f = File(path);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }

      final asrWarmup = TalkAsrService.warmupForLanguages(
          [widget.learnLang, widget.nativeLang]);

      // ── Download combined DB ──
      final alreadyExists = await LangDbService.isDownloadedPair(
          widget.learnLang, widget.nativeLang);
      if (!alreadyExists) {
        if (!SupabaseVocabHydrator.isAvailable) {
          throw Exception(
            'Cloud vocabulary service is not configured.\n\n'
            'Add your Supabase anon (public) key to assets/supabase_config.json '
            '("anon_key"), then rebuild — or build with '
            'scripts/flutter_build_apk_with_secrets.ps1 '
            '(or flutter run with --dart-define=SUPABASE_ANON_KEY=... / '
            'supabase_anon_key.txt for dev).',
          );
        }
        setState(() => _message = nativeL.isZhCN || nativeL.isZhTW
            ? '正从云端加载词库…'
            : 'Loading dictionary from cloud…');
        await SupabaseVocabHydrator.hydrateToLocalFile(
          translateLang: widget.learnLang,
          nativeLang: widget.nativeLang,
          onStatus: (m) {
            if (mounted) setState(() => _message = m);
          },
        );
      }
      setState(() => _progressDb = 1.0);

      // ── Download photo DB (optional; GitHub may rate-limit) ──
      final photoAlreadyExists = await LangDbService.isPhotoDbDownloaded();
      if (!photoAlreadyExists) {
        setState(() => _message = nativeL.isZhCN || nativeL.isZhTW
            ? '正在下载图片词库...'
            : 'Downloading photos database...');
        try {
          await LangDbService.downloadPhotoDb(
            cancelToken: _cancel,
            onProgress: (r, t) {
              if (t > 0) setState(() => _progressPhoto = r / t);
            },
          );
        } catch (_) {
          // Illustrated index is optional; per-word images can load from CDN paths.
          if (mounted) {
            setState(() => _message = nativeL.isZhCN || nativeL.isZhTW
                ? '图片词库跳过（可选）'
                : 'Photo index skipped (optional).');
          }
        }
      }
      setState(() => _progressPhoto = 1.0);

      // ── Open database ──
      setState(() => _message = nativeL.isZhCN || nativeL.isZhTW
          ? '正在载入词库...'
          : 'Loading database...');
      await DatabaseHelper.openWithLangs(widget.learnLang, widget.nativeLang);

      // ── Verify database has content ──
      final count = await DatabaseHelper.wordCount();
      if (count == 0) {
        final path = await LangDbService.localPathPair(
            widget.learnLang, widget.nativeLang);
        try { File(path).deleteSync(); } catch (_) {}
        throw Exception(
            '$pairLabel database contains no words.\n'
            'Please upload word data to the repository.');
      }

      try {
        await asrWarmup;
      } catch (_) {}

      setState(() {
        _status = _DownloadStatus.done;
        _message = 'Done!';
      });
    } catch (e) {
      try {
        final path = await LangDbService.localPathPair(
            widget.learnLang, widget.nativeLang);
        if (File(path).existsSync()) File(path).deleteSync();
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
    final nativeL = L10n(widget.nativeLang);
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
            isDone ? nativeL.downloadSuccess : 'Downloading Database',
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
              Text('$learnLabel / $nativeLabel database is ready.',
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              Center(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1565C0),
                  ),
                  child: Text(nativeL.continueLabel),
                ),
              ),
            ] else ...[
              _ProgressRow(
                  label: '$learnLabel / $nativeLabel',
                  progress: _progressDb),
              const SizedBox(height: 12),
              _ProgressRow(label: 'Photos', progress: _progressPhoto),
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
