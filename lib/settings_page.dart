import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_service.dart';
import 'language_prefs.dart';
import 'settings_language_page.dart';

// ── TTS 设定 Key 常量 ─────────────────────────────────────────
class TtsPrefs {
  static const voiceGender = 'tts_voice_gender'; // 'female' | 'male'
  static const speedPercent = 'tts_speed_percent'; // 0→0，默→20（减→20%→'

  static const defaultGender = 'female';
  static const defaultSpeedPercent = 20;
}

// ── 词典显示设定 Key 常量 ─────────────────────────────────────
class DictPrefs {
  static const maxCorrectCount = 'dict_max_correct_count';
  static const defaultMaxCorrectCount = 100;
}

// ════════════════════════════════════════════════════════════════
// 设定入口导航页（StatefulWidget，监听语言变化自动刷新→'
// ════════════════════════════════════════════════════════════════
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _langNotifier = AppLangNotifier();

  @override
  void initState() {
    super.initState();
    _langNotifier.addListener(_onLangChanged);
  }

  @override
  void dispose() {
    _langNotifier.removeListener(_onLangChanged);
    super.dispose();
  }

  void _onLangChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final l = L10n(_langNotifier.uiLang);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        title: Text(l.settings,
            style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _SettingsEntry(
            icon: Icons.record_voice_over,
            iconColor: const Color(0xFF1565C0),
            title: l.settingsVoice,
            subtitle: l.settingsVoiceSub,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SettingsVoicePage())),
          ),
          _SettingsEntry(
            icon: Icons.bar_chart,
            iconColor: Colors.teal,
            title: l.settingsDict,
            subtitle: l.settingsDictSub,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SettingsDictPage())),
          ),
          _SettingsEntry(
            icon: Icons.notifications_active,
            iconColor: Colors.orange,
            title: l.settingsNotif,
            subtitle: l.settingsNotifSub,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SettingsNotifPage())),
          ),
          _SettingsEntry(
            icon: Icons.translate,
            iconColor: Colors.purple,
            title: l.settingsLang,
            subtitle: l.settingsLangSub,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(
                    builder: (_) => const SettingsLanguagePage())),
          ),
        ],
      ),
    );
  }
}

// ── 导航条目 ──────────────────────────────────────────────────
class _SettingsEntry extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SettingsEntry({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: iconColor.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: iconColor, size: 22),
      ),
      title: Text(title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
      trailing: Icon(Icons.chevron_right, color: Colors.grey.shade400),
      onTap: onTap,
    );
  }
}

// ════════════════════════════════════════════════════════════════
// 语音子页
// ════════════════════════════════════════════════════════════════
class SettingsVoicePage extends StatefulWidget {
  const SettingsVoicePage({super.key});

  @override
  State<SettingsVoicePage> createState() => _SettingsVoicePageState();
}

class _SettingsVoicePageState extends State<SettingsVoicePage> {
  String _voiceGender = TtsPrefs.defaultGender;
  int _speedPercent = TtsPrefs.defaultSpeedPercent;

  L10n get _l => L10n(AppLangNotifier().uiLang);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _voiceGender =
          prefs.getString(TtsPrefs.voiceGender) ?? TtsPrefs.defaultGender;
      _speedPercent =
          prefs.getInt(TtsPrefs.speedPercent) ?? TtsPrefs.defaultSpeedPercent;
    });
  }

  Future<void> _saveString(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  Future<void> _saveInt(String key, int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(key, value);
  }

  @override
  Widget build(BuildContext context) {
    final l = _l;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        title: Text(l.voiceTitle,
            style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 性别选择
                  Row(
                    children: [
                      const Icon(Icons.person_outline,
                          color: Color(0xFF1565C0), size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l.voiceSoundLabel),
                            Text(l.voiceSoundNote,
                                style: TextStyle(
                                    fontSize: 11, color: Colors.grey.shade500)),
                          ],
                        ),
                      ),
                      _GenderToggle(
                        value: _voiceGender,
                        femaleLabel: l.voiceFemale,
                        maleLabel: l.voiceMale,
                        onChanged: (v) {
                          setState(() => _voiceGender = v);
                          _saveString(TtsPrefs.voiceGender, v);
                        },
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // 速度滑块
                  Row(
                    children: [
                      const Icon(Icons.speed,
                          color: Color(0xFF1565C0), size: 20),
                      const SizedBox(width: 8),
                      Text(l.voiceSlowLabel),
                      const Spacer(),
                      Text(
                        '$_speedPercent%',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1565C0),
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: const Color(0xFF1565C0),
                      thumbColor: const Color(0xFF1565C0),
                      overlayColor:
                          const Color(0xFF1565C0).withOpacity(0.15),
                      inactiveTrackColor:
                          const Color(0xFF1565C0).withOpacity(0.2),
                    ),
                    child: Slider(
                      value: _speedPercent.toDouble(),
                      min: 0,
                      max: 50,
                      divisions: 10,
                      label: '$_speedPercent%',
                      onChanged: (v) =>
                          setState(() => _speedPercent = v.round()),
                      onChangeEnd: (v) =>
                          _saveInt(TtsPrefs.speedPercent, v.round()),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(l.voiceSlowMin,
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey.shade500)),
                        Text(l.voiceSlowMax,
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey.shade500)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// 词典子页
// ════════════════════════════════════════════════════════════════
class SettingsDictPage extends StatefulWidget {
  const SettingsDictPage({super.key});

  @override
  State<SettingsDictPage> createState() => _SettingsDictPageState();
}

class _SettingsDictPageState extends State<SettingsDictPage> {
  final TextEditingController _maxCountCtrl = TextEditingController();

  L10n get _l => L10n(AppLangNotifier().uiLang);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _maxCountCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final v =
        prefs.getInt(DictPrefs.maxCorrectCount) ?? DictPrefs.defaultMaxCorrectCount;
    setState(() {
      _maxCountCtrl.text = v.toString();
    });
  }

  Future<void> _saveInt(String key, int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(key, value);
  }

  @override
  Widget build(BuildContext context) {
    final l = _l;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        title: Text(l.dictTitle,
            style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const Icon(Icons.local_fire_department,
                      color: Color(0xFF1565C0), size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l.dictMaxCount),
                        Text(l.dictMaxCountNote,
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey.shade500)),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 80,
                    child: TextField(
                      controller: _maxCountCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1565C0),
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            vertical: 8, horizontal: 8),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8)),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                              color: Color(0xFF1565C0), width: 2),
                        ),
                      ),
                      onChanged: (v) {
                        final n = int.tryParse(v);
                        if (n != null && n > 0) {
                          _saveInt(DictPrefs.maxCorrectCount, n);
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// 定时提醒子页
// ════════════════════════════════════════════════════════════════
class SettingsNotifPage extends StatefulWidget {
  const SettingsNotifPage({super.key});

  @override
  State<SettingsNotifPage> createState() => _SettingsNotifPageState();
}

class _SettingsNotifPageState extends State<SettingsNotifPage> {
  bool _enabled = false;
  TimeOfDay _startTime = const TimeOfDay(
    hour: NotifPrefs.defaultStartHour,
    minute: NotifPrefs.defaultStartMinute,
  );
  TimeOfDay _endTime = const TimeOfDay(
    hour: NotifPrefs.defaultEndHour,
    minute: NotifPrefs.defaultEndMinute,
  );
  int _intervalMinutes = NotifPrefs.defaultIntervalMinutes;

  static const _intervalOptions = [10, 15, 20, 30, 45, 60, 90, 120];

  L10n get _l => L10n(AppLangNotifier().uiLang);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _enabled = prefs.getBool(NotifPrefs.enabled) ?? false;
      _startTime = TimeOfDay(
        hour: prefs.getInt(NotifPrefs.startHour) ?? NotifPrefs.defaultStartHour,
        minute:
            prefs.getInt(NotifPrefs.startMinute) ?? NotifPrefs.defaultStartMinute,
      );
      _endTime = TimeOfDay(
        hour: prefs.getInt(NotifPrefs.endHour) ?? NotifPrefs.defaultEndHour,
        minute:
            prefs.getInt(NotifPrefs.endMinute) ?? NotifPrefs.defaultEndMinute,
      );
      _intervalMinutes = prefs.getInt(NotifPrefs.intervalMinutes) ??
          NotifPrefs.defaultIntervalMinutes;
    });
  }

  Future<void> _saveBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  Future<void> _saveInt(String key, int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(key, value);
  }

  Future<void> _onNotifToggle(bool value) async {
    final l = _l;
    if (value) {
      final ok = await NotificationService.requestPermission();
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.notifPermDenied)),
        );
        return;
      }
      final canExact = await NotificationService.canScheduleExactAlarms();
      if (!canExact && mounted) {
        final goSettings = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l.notifExactTitle),
            content: Text(l.notifExactContent),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l.notifCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l.notifGoSettings),
              ),
            ],
          ),
        );
        if (goSettings == true) {
          await NotificationService.openExactAlarmSettings();
        }
      }
    }
    setState(() => _enabled = value);
    await _saveBool(NotifPrefs.enabled, value);
    await NotificationService.reschedule();
  }

  Future<void> _pickTime(bool isStart) async {
    final l = _l;
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart ? _startTime : _endTime,
      helpText: isStart ? l.notifStartTime : l.notifEndTime,
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _startTime = picked;
      } else {
        _endTime = picked;
      }
    });
    if (isStart) {
      await _saveInt(NotifPrefs.startHour, picked.hour);
      await _saveInt(NotifPrefs.startMinute, picked.minute);
    } else {
      await _saveInt(NotifPrefs.endHour, picked.hour);
      await _saveInt(NotifPrefs.endMinute, picked.minute);
    }
    await NotificationService.reschedule();
  }

  String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _fmtInterval(int m, L10n l) {
    if (m >= 60) {
      final h = m ~/ 60;
      final rem = m % 60;
      return rem > 0 ? '$h ${l.hour} $rem ${l.minute}' : '$h ${l.hour}';
    }
    return '$m ${l.minute}';
  }

  @override
  Widget build(BuildContext context) {
    final l = _l;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        title: Text(l.notifTitle,
            style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 开→'
                  Row(
                    children: [
                      const Icon(Icons.notifications_active,
                          color: Color(0xFF1565C0)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(l.settingsNotif,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                      Switch(
                        value: _enabled,
                        onChanged: _onNotifToggle,
                        activeColor: const Color(0xFF1565C0),
                      ),
                    ],
                  ),
                  const Divider(),

                  // 开始时→'
                  _TimeTile(
                    label: l.notifStartTime,
                    icon: Icons.wb_sunny_outlined,
                    time: _startTime,
                    enabled: _enabled,
                    onTap: () => _pickTime(true),
                    fmt: _fmt,
                  ),

                  // 结束时间
                  _TimeTile(
                    label: l.notifEndTime,
                    icon: Icons.bedtime_outlined,
                    time: _endTime,
                    enabled: _enabled,
                    onTap: () => _pickTime(false),
                    fmt: _fmt,
                  ),

                  const SizedBox(height: 8),

                  // 间隔
                  Row(
                    children: [
                      const Icon(Icons.timer_outlined,
                          color: Color(0xFF1565C0), size: 20),
                      const SizedBox(width: 8),
                      Text(l.notifInterval),
                      const Spacer(),
                      DropdownButton<int>(
                        value: _intervalOptions.contains(_intervalMinutes)
                            ? _intervalMinutes
                            : _intervalOptions.first,
                        underline: const SizedBox(),
                        items: _intervalOptions
                            .map((m) => DropdownMenuItem(
                                  value: m,
                                  child: Text(_fmtInterval(m, l)),
                                ))
                            .toList(),
                        onChanged: _enabled
                            ? (v) {
                                if (v != null) {
                                  setState(() => _intervalMinutes = v);
                                  _saveInt(NotifPrefs.intervalMinutes, v);
                                  NotificationService.reschedule();
                                }
                              }
                            : null,
                      ),
                    ],
                  ),

                  const SizedBox(height: 4),
                  Text(
                    _enabled
                        ? l.notifActiveHint(
                            _fmt(_startTime), _fmt(_endTime), _intervalMinutes)
                        : l.notifInactiveHint,
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// 共享 Widget helpers
// ════════════════════════════════════════════════════════════════

// ── 性别切换按钮→─────────────────────────────────────────────
class _GenderToggle extends StatelessWidget {
  final String value;
  final String femaleLabel;
  final String maleLabel;
  final ValueChanged<String> onChanged;

  const _GenderToggle({
    required this.value,
    required this.femaleLabel,
    required this.maleLabel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _GenderChip(
          label: femaleLabel,
          icon: Icons.face,
          selected: value == 'female',
          onTap: () => onChanged('female'),
        ),
        const SizedBox(width: 8),
        _GenderChip(
          label: maleLabel,
          icon: Icons.face_2,
          selected: value == 'male',
          onTap: () => onChanged('male'),
        ),
      ],
    );
  }
}

class _GenderChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _GenderChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF1565C0)
              : const Color(0xFF1565C0).withOpacity(0.07),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? const Color(0xFF1565C0)
                : const Color(0xFF1565C0).withOpacity(0.3),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 16,
                color: selected ? Colors.white : const Color(0xFF1565C0)),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : const Color(0xFF1565C0),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 时间选择→────────────────────────────────────────────────
class _TimeTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final TimeOfDay time;
  final bool enabled;
  final VoidCallback onTap;
  final String Function(TimeOfDay) fmt;

  const _TimeTile({
    required this.label,
    required this.icon,
    required this.time,
    required this.enabled,
    required this.onTap,
    required this.fmt,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(icon,
                color: enabled ? const Color(0xFF1565C0) : Colors.grey,
                size: 20),
            const SizedBox(width: 8),
            Text(label,
                style: TextStyle(color: enabled ? null : Colors.grey)),
            const Spacer(),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: enabled
                    ? const Color(0xFF1565C0).withOpacity(0.1)
                    : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                fmt(time),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: enabled ? const Color(0xFF1565C0) : Colors.grey,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
