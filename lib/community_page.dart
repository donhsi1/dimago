import 'package:flutter/material.dart';

import 'challenge_progress_table.dart';
import 'circular_score.dart';
import 'community_service.dart';
import 'language_prefs.dart';
import 'supabase_bootstrap.dart';

// ── Helpers ──────────────────────────────────────────────────────

String _langFlag(String code) {
  final opt = kAllLanguages.firstWhere(
    (o) => o.code == code,
    orElse: () => const LangOption(code: '', label: '', flag: '🌐'),
  );
  return opt.flag;
}

String _langShort(String code) {
  final opt = kAllLanguages.firstWhere(
    (o) => o.code == code,
    orElse: () => LangOption(code: code, label: code, flag: '🌐'),
  );
  return opt.label.split(' / ').first;
}

Color _scoreColor(int score) {
  if (score >= 40) return Colors.green.shade600;
  if (score >= 10) return const Color(0xFFF57C00);
  return Colors.grey.shade400;
}

// ── Community page ────────────────────────────────────────────────

class CommunityPage extends StatefulWidget {
  const CommunityPage({super.key});

  @override
  State<CommunityPage> createState() => _CommunityPageState();
}

class _CommunityPageState extends State<CommunityPage> {
  List<CommunityUser> _users = [];
  bool _loading = true;
  String? _error;
  bool _loadingMore = false;
  bool _hasMore = true;

  String? _filterTranslateLang;
  String? _filterNativeLang;
  String? _filterCountry;
  List<String> _countries = [];

  static bool _profileSyncedThisSession = false;

  L10n get _l => L10n(AppLangNotifier().uiLang);

  @override
  void initState() {
    super.initState();
    _syncProfile();
    _load();
    _loadCountries();
  }

  // Upsert the signed-in user's profile row once per session.
  Future<void> _syncProfile() async {
    if (_profileSyncedThisSession) return;
    final client = SupabaseBootstrap.clientOrNull;
    final user = client?.auth.currentUser;
    if (user == null) return;
    _profileSyncedThisSession = true;
    final meta = user.userMetadata ?? {};
    final langNotifier = AppLangNotifier();
    await CommunityService.upsertProfile(
      userId: user.id,
      translateLang: langNotifier.targetLang,
      nativeLang: langNotifier.nativeLang,
      nickName: (meta['full_name'] as String?) ??
          (meta['name'] as String?) ??
          (user.email?.split('@').first ?? ''),
      avatarUrl: meta['avatar_url'] as String?,
    );
  }

  Future<void> _load({bool reset = true}) async {
    if (!CommunityService.isAvailable) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (reset && mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _hasMore = true;
      });
    }
    try {
      final users = await CommunityService.fetchUsers(
        translateLang: _filterTranslateLang,
        nativeLang: _filterNativeLang,
        country: _filterCountry,
        offset: 0,
      );
      if (!mounted) return;
      setState(() {
        _users = users;
        _loading = false;
        _hasMore = users.length >= 50;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final more = await CommunityService.fetchUsers(
        translateLang: _filterTranslateLang,
        nativeLang: _filterNativeLang,
        country: _filterCountry,
        offset: _users.length,
      );
      if (!mounted) return;
      setState(() {
        _users.addAll(more);
        _loadingMore = false;
        _hasMore = more.length >= 50;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _loadCountries() async {
    final c = await CommunityService.fetchCountries();
    if (mounted) setState(() => _countries = c);
  }

  void _applyFilter({
    required String? translateLang,
    required String? nativeLang,
    required String? country,
  }) {
    setState(() {
      _filterTranslateLang = translateLang;
      _filterNativeLang = nativeLang;
      _filterCountry = country;
    });
    _load();
  }

  // ── Filter bottom sheet ──────────────────────────────────────

  Future<String?> _pickLangCode(BuildContext context, String? current) async {
    return showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const SizedBox(height: 8),
            ListTile(
              title: Text(_l.communityFilterAll,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              trailing: current == null
                  ? const Icon(Icons.check, color: Color(0xFF1565C0))
                  : null,
              onTap: () => Navigator.of(ctx).pop('__all__'),
            ),
            const Divider(height: 0),
            ...kAllLanguages.map((o) => ListTile(
                  leading: Text(o.flag, style: const TextStyle(fontSize: 22)),
                  title: Text(o.label.split(' / ').first),
                  trailing: o.code == current
                      ? const Icon(Icons.check, color: Color(0xFF1565C0))
                      : null,
                  onTap: () => Navigator.of(ctx).pop(o.code),
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<String?> _pickCountryValue(BuildContext context) async {
    return showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const SizedBox(height: 8),
            ListTile(
              title: Text(_l.communityFilterAll,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              trailing: _filterCountry == null
                  ? const Icon(Icons.check, color: Color(0xFF1565C0))
                  : null,
              onTap: () => Navigator.of(ctx).pop('__all__'),
            ),
            const Divider(height: 0),
            ..._countries.map((c) => ListTile(
                  title: Text(c),
                  trailing: c == _filterCountry
                      ? const Icon(Icons.check, color: Color(0xFF1565C0))
                      : null,
                  onTap: () => Navigator.of(ctx).pop(c),
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _onTapLearningFilter(BuildContext context) async {
    final picked = await _pickLangCode(context, _filterTranslateLang);
    if (picked == null) return;
    _applyFilter(
      translateLang: picked == '__all__' ? null : picked,
      nativeLang: _filterNativeLang,
      country: _filterCountry,
    );
  }

  Future<void> _onTapNativeFilter(BuildContext context) async {
    final picked = await _pickLangCode(context, _filterNativeLang);
    if (picked == null) return;
    _applyFilter(
      translateLang: _filterTranslateLang,
      nativeLang: picked == '__all__' ? null : picked,
      country: _filterCountry,
    );
  }

  Future<void> _onTapCountryFilter(BuildContext context) async {
    final picked = await _pickCountryValue(context);
    if (picked == null) return;
    _applyFilter(
      translateLang: _filterTranslateLang,
      nativeLang: _filterNativeLang,
      country: picked == '__all__' ? null : picked,
    );
  }

  // ── Filter bar ───────────────────────────────────────────────

  Widget _filterChip(String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF1565C0) : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(20),
          border: active ? null : Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: active ? Colors.white : Colors.grey.shade800,
              ),
            ),
            const SizedBox(width: 3),
            Icon(
              Icons.arrow_drop_down,
              size: 16,
              color: active ? Colors.white : Colors.grey.shade600,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterBar(BuildContext context) {
    final l = _l;

    final tLabel = _filterTranslateLang != null
        ? '${_langFlag(_filterTranslateLang!)} ${_langShort(_filterTranslateLang!)}'
        : '${l.communityFilterLearning}: ${l.communityFilterAll}';

    final nLabel = _filterNativeLang != null
        ? '${_langFlag(_filterNativeLang!)} ${_langShort(_filterNativeLang!)}'
        : '${l.communityFilterNative}: ${l.communityFilterAll}';

    final cLabel = _filterCountry ?? '${l.communityFilterCountry}: ${l.communityFilterAll}';

    return Container(
      color: Colors.grey.shade100,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _filterChip(tLabel, _filterTranslateLang != null,
                () => _onTapLearningFilter(context)),
            const SizedBox(width: 8),
            _filterChip(nLabel, _filterNativeLang != null,
                () => _onTapNativeFilter(context)),
            if (_countries.isNotEmpty) ...[
              const SizedBox(width: 8),
              _filterChip(cLabel, _filterCountry != null,
                  () => _onTapCountryFilter(context)),
            ],
          ],
        ),
      ),
    );
  }

  // ── User card ────────────────────────────────────────────────

  Widget _userCard(BuildContext context, CommunityUser user) {
    final displayName =
        user.nickName.isNotEmpty ? user.nickName : _l.communityAnonymous;
    final initial =
        displayName.isNotEmpty ? displayName[0].toUpperCase() : '?';
    final langLine =
        '${_langFlag(user.translateLang)} ${_langShort(user.translateLang)}'
        '  →  '
        '${_langFlag(user.nativeLang)} ${_langShort(user.nativeLang)}';

    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: const Color(0xFF1565C0),
        backgroundImage: user.avatarUrl != null && user.avatarUrl!.isNotEmpty
            ? NetworkImage(user.avatarUrl!)
            : null,
        child: (user.avatarUrl == null || user.avatarUrl!.isEmpty)
            ? Text(initial,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold))
            : null,
      ),
      title: Text(displayName,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
      subtitle: Text(
        user.country.isNotEmpty ? '$langLine  ·  ${user.country}' : langLine,
        style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
      ),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: _scoreColor(user.totalScore),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          '${user.totalScore}',
          style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 14),
        ),
      ),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => CommunityUserDetailPage(user: user),
      )),
    );
  }

  // ── Build ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l = _l;

    if (!CommunityService.isAvailable) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            l.communityNotConfigured,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600, height: 1.5),
          ),
        ),
      );
    }

    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade700)),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: Text(l.lessonTabRetry)),
            ],
          ),
        ),
      );
    } else if (_users.isEmpty) {
      body = Center(
        child: Text(l.communityNoUsers,
            style: TextStyle(color: Colors.grey.shade600)),
      );
    } else {
      body = RefreshIndicator(
        onRefresh: () => _load(),
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n is ScrollEndNotification && n.metrics.extentAfter < 200) {
              _loadMore();
            }
            return false;
          },
          child: ListView.separated(
            itemCount: _users.length + (_loadingMore ? 1 : 0),
            separatorBuilder: (_, __) =>
                Divider(height: 0, color: Colors.grey.shade200),
            itemBuilder: (ctx, i) {
              if (i >= _users.length) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator(),
                  ),
                );
              }
              return _userCard(ctx, _users[i]);
            },
          ),
        ),
      );
    }

    return Column(
      children: [
        _buildFilterBar(context),
        Expanded(child: body),
      ],
    );
  }
}

// ── User detail page ──────────────────────────────────────────────

class CommunityUserDetailPage extends StatefulWidget {
  final CommunityUser user;
  const CommunityUserDetailPage({super.key, required this.user});

  @override
  State<CommunityUserDetailPage> createState() =>
      _CommunityUserDetailPageState();
}

class _CommunityUserDetailPageState extends State<CommunityUserDetailPage> {
  List<UserLessonScore>? _scores;
  bool _loading = true;

  L10n get _l => L10n(AppLangNotifier().uiLang);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final scores =
        await CommunityService.fetchUserLessonScores(widget.user.id);
    if (mounted) {
      setState(() {
        _scores = scores;
        _loading = false;
      });
    }
  }

  Widget _header() {
    final user = widget.user;
    final displayName =
        user.nickName.isNotEmpty ? user.nickName : _l.communityAnonymous;
    final initial =
        displayName.isNotEmpty ? displayName[0].toUpperCase() : '?';

    return Container(
      color: const Color(0xFF1565C0),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 32,
            backgroundColor: Colors.white.withValues(alpha: 0.2),
            backgroundImage:
                user.avatarUrl != null && user.avatarUrl!.isNotEmpty
                    ? NetworkImage(user.avatarUrl!)
                    : null,
            child: (user.avatarUrl == null || user.avatarUrl!.isEmpty)
                ? Text(initial,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.bold))
                : null,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(displayName,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold)),
                if (user.country.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(user.country,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 14)),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      '${_langFlag(user.translateLang)} ${_langShort(user.translateLang)}',
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(Icons.arrow_forward,
                          color: Colors.white.withValues(alpha: 0.7), size: 15),
                    ),
                    Text(
                      '${_langFlag(user.nativeLang)} ${_langShort(user.nativeLang)}',
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    '${_l.communityScore}: ${widget.user.totalScore}',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = _l;
    final user = widget.user;
    final displayName =
        user.nickName.isNotEmpty ? user.nickName : l.communityAnonymous;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        centerTitle: true,
        title: Text(displayName,
            style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 18, color: Colors.white)),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Text(
              l.communityLessonProgress,
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : (_scores == null || _scores!.isEmpty)
                    ? Center(
                        child: Text(l.communityNoLessons,
                            style:
                                TextStyle(color: Colors.grey.shade600)))
                    : ListView.builder(
                        itemCount: _scores!.length,
                        itemBuilder: (ctx, i) =>
                            _LessonScoreTile(score: _scores![i]),
                      ),
          ),
        ],
      ),
    );
  }
}

// ── Expandable lesson row ─────────────────────────────────────────

class _LessonScoreTile extends StatefulWidget {
  final UserLessonScore score;
  const _LessonScoreTile({required this.score});

  @override
  State<_LessonScoreTile> createState() => _LessonScoreTileState();
}

class _LessonScoreTileState extends State<_LessonScoreTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.score;
    final scoresSum = s.scoresSum;
    final name = s.lessonName.isNotEmpty ? s.lessonName : 'Lesson ${s.lessonId}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            child: Row(
              children: [
                CircularScoreListIcon(challenge: s.challenge, dimension: 30),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    name,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _scoreColor(scoresSum),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$scoresSum',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  color: Colors.grey.shade500,
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          ChallengeProgressTable(
            challenge: s.challenge,
            scores: s.scores,
            // read-only in community view: action column is non-functional
          ),
        Divider(height: 0, color: Colors.grey.shade200),
      ],
    );
  }
}
