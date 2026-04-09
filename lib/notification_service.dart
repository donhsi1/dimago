import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest_all.dart' as tzData;
import 'database_helper.dart';

/// 设置→'
class NotifPrefs {
  static const enabled = 'notif_enabled';
  static const startHour = 'notif_start_hour';
  static const startMinute = 'notif_start_minute';
  static const endHour = 'notif_end_hour';
  static const endMinute = 'notif_end_minute';
  static const intervalMinutes = 'notif_interval_minutes';

  // 默认→'
  static const defaultStartHour = 9;
  static const defaultStartMinute = 0;
  static const defaultEndHour = 22;
  static const defaultEndMinute = 0;
  static const defaultIntervalMinutes = 30;
}

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  // ── 初始→──────────────────────────────────────────────────

  static Future<void> initialize() async {
    if (_initialized) return;
    if (!_isAndroid) {
      _initialized = true;
      return;
    }
    tzData.initializeTimeZones();

    // 获取设备本地时区并设置（修复 tz.local 默认 UTC 的问题）
    try {
      final timezoneInfo = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timezoneInfo.identifier));
    } catch (_) {
      // 若获取失败，→UTC+8 作为后备（适合东南→中国用户→'
      tz.setLocalLocation(tz.getLocation('Asia/Bangkok'));
    }

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await _plugin.initialize(initSettings);
    _initialized = true;
  }

  /// 请求通知权限（Android 13+），返回是否获得权限
  static Future<bool> requestPermission() async {
    if (!_isAndroid) return false;
    final android =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return false;
    final granted = await android.requestNotificationsPermission();
    return granted ?? false;
  }

  /// 检查精确闹钟权限是否已授予（Android 12+→'
  /// 返回 true = 已有权限，false = 没有权限
  static Future<bool> canScheduleExactAlarms() async {
    if (!_isAndroid) return true;
    final android =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return true; // →Android 平台默认通过
    return await android.canScheduleExactNotifications() ?? true;
  }

  /// 跳转到系→闹钟和提→设置页，让用户手动开启精确闹钟权→'
  static Future<void> openExactAlarmSettings() async {
    if (!_isAndroid) return;
    final android =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestExactAlarmsPermission();
  }

  // ── 调度逻辑 ─────────────────────────────────────────────────

  /// 根据当前设置重新调度所有通知（先取消旧的→'
  static Future<void> reschedule() async {
    if (!_isAndroid) return;
    await initialize();
    await _plugin.cancelAll();

    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(NotifPrefs.enabled) ?? false;
    if (!enabled) return;

    final startH = prefs.getInt(NotifPrefs.startHour) ?? NotifPrefs.defaultStartHour;
    final startM = prefs.getInt(NotifPrefs.startMinute) ?? NotifPrefs.defaultStartMinute;
    final endH = prefs.getInt(NotifPrefs.endHour) ?? NotifPrefs.defaultEndHour;
    final endM = prefs.getInt(NotifPrefs.endMinute) ?? NotifPrefs.defaultEndMinute;
    final interval = prefs.getInt(NotifPrefs.intervalMinutes) ??
        NotifPrefs.defaultIntervalMinutes;

    // 预调度接下来 24 小时内符合时间窗口的通知
    await _scheduleUpcoming(
      startHour: startH,
      startMinute: startM,
      endHour: endH,
      endMinute: endM,
      intervalMinutes: interval,
    );
  }

  static Future<void> _scheduleUpcoming({
    required int startHour,
    required int startMinute,
    required int endHour,
    required int endMinute,
    required int intervalMinutes,
  }) async {
    // 取数据库词条
    final entries = await DatabaseHelper.getAll();
    if (entries.isEmpty) return;

    final now = tz.TZDateTime.now(tz.local);
    final rng = Random();

    // 计算今天和明天的时间窗口内各个触发时刻（最多调→50 个）
    int notifId = 100; // →100 开始，避免与其他通知冲突
    int scheduled = 0;
    const maxSchedule = 50;

    for (int dayOffset = 0; dayOffset <= 1 && scheduled < maxSchedule; dayOffset++) {
      final base = now.add(Duration(days: dayOffset));
      final startTime = tz.TZDateTime(
        tz.local,
        base.year,
        base.month,
        base.day,
        startHour,
        startMinute,
      );
      final endTime = tz.TZDateTime(
        tz.local,
        base.year,
        base.month,
        base.day,
        endHour,
        endMinute,
      );

      var t = startTime;
      while (!t.isAfter(endTime) && scheduled < maxSchedule) {
        // 只调度在当前时间之后→'
        if (t.isAfter(now)) {
          final entry = entries[rng.nextInt(entries.length)];
          await _scheduleOne(
            id: notifId++,
            thai: entry.thai,
            chinese: entry.chinese,
            when: t,
          );
          scheduled++;
        }
        t = t.add(Duration(minutes: intervalMinutes));
      }
    }
  }

  static Future<void> _scheduleOne({
    required int id,
    required String thai,
    required String chinese,
    required tz.TZDateTime when,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'thai_learn_channel',
      '泰语学习提醒',
      channelDescription: '定时推送泰语词→',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      icon: '@mipmap/ic_launcher',
    );
    const details = NotificationDetails(android: androidDetails);

    // 优先使用精确闹钟；若权限不足则降级用非精确（inexact→'
    try {
      await _plugin.zonedSchedule(
        id,
        '泰语练习 🇹🇭',
        '$thai　$chinese',
        when,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (_) {
      // 精确闹钟权限未授予时，降级为非精确（时间可能偏差几分钟，但能用）
      await _plugin.zonedSchedule(
        id,
        '泰语练习 🇹🇭',
        '$thai　$chinese',
        when,
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    }
  }

  /// 取消全部通知
  static Future<void> cancelAll() async {
    if (!_isAndroid) return;
    await initialize();
    await _plugin.cancelAll();
  }
}
