import 'package:flutter/material.dart';
import 'api_log_service.dart';
import 'whisper_asr_service.dart';

/// Displays cumulative API call counts.
/// Accessible from the app's main menu under "Show API".
class ApiStatsPage extends StatefulWidget {
  const ApiStatsPage({super.key});

  @override
  State<ApiStatsPage> createState() => _ApiStatsPageState();
}

class _ApiStatsPageState extends State<ApiStatsPage> {
  List<ApiCallStat> _stats = [];
  bool _loading = true;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final stats = await ApiLogService.getAllCounts();
    final total = stats.fold<int>(0, (sum, s) => sum + s.count);
    setState(() {
      _stats  = stats;
      _total  = total;
      _loading = false;
    });
  }

  Future<void> _confirmReset() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset counters?'),
        content: const Text('All API call counts will be cleared. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:
                  const Text('Reset', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm == true) {
      await ApiLogService.resetAll();
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        title: const Text('API Call Statistics'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Reset all counters',
            onPressed: _confirmReset,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _stats.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!WhisperAsrService.isApiKeyConfigured) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Material(
                            color: Colors.orange.shade50,
                            borderRadius: BorderRadius.circular(8),
                            child: const Padding(
                              padding: EdgeInsets.all(12),
                              child: Text(
                                'Talk / Whisper: OPENAI_API_KEY is empty in this build. '
                                'Release APKs from scripts/build_android_release.ps1 embed the key; '
                                'debug runs need --dart-define=OPENAI_API_KEY=...',
                                style: TextStyle(fontSize: 13, height: 1.35),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      const Icon(Icons.bar_chart, size: 64, color: Colors.black26),
                      const SizedBox(height: 12),
                      const Text('No API calls recorded yet.',
                          style: TextStyle(color: Colors.black45)),
                    ],
                  ),
                )
              : Column(
                  children: [
                    if (!WhisperAsrService.isApiKeyConfigured)
                      Container(
                        width: double.infinity,
                        color: Colors.orange.shade100,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        child: const Text(
                          'Whisper: OPENAI_API_KEY missing in this build — '
                          'successful transcriptions will not be counted and Talk scores stay at 0.',
                          style: TextStyle(fontSize: 12, height: 1.35),
                        ),
                      ),
                    // ── Summary banner ────────────────────────────
                    Container(
                      width: double.infinity,
                      color: const Color(0xFF1565C0),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                      child: Row(
                        children: [
                          const Icon(Icons.cloud_outlined,
                              color: Colors.white70, size: 18),
                          const SizedBox(width: 8),
                          Text(
                            'Total external API calls: $_total',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                    // ── Per-API list ──────────────────────────────
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _stats.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1, indent: 72),
                        itemBuilder: (_, i) {
                          final s = _stats[i];
                          final pct = _total > 0
                              ? s.count / _total
                              : 0.0;
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor:
                                  const Color(0xFF1565C0).withOpacity(0.12),
                              child: Text(
                                '${i + 1}',
                                style: const TextStyle(
                                    color: Color(0xFF1565C0),
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                            title: Text(
                              s.name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600),
                            ),
                            subtitle: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: pct,
                                minHeight: 6,
                                backgroundColor: Colors.grey.shade200,
                                valueColor:
                                    const AlwaysStoppedAnimation<Color>(
                                        Color(0xFF1565C0)),
                              ),
                            ),
                            trailing: Column(
                              mainAxisAlignment:
                                  MainAxisAlignment.center,
                              crossAxisAlignment:
                                  CrossAxisAlignment.end,
                              children: [
                                Text(
                                  '${s.count}',
                                  style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF1565C0)),
                                ),
                                Text(
                                  '${(pct * 100).toStringAsFixed(1)}%',
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.black45),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}
