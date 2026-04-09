import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── 语言偏好 Key 常量 ─────────────────────────────────────────
class LangPrefs {
  static const uiLang = 'lang_ui';
  static const targetLang = 'lang_target';
  static const nativeLang = 'lang_native';
  static const langPackDone = 'lang_pack_done';
  static const setupDone = 'setup_done';
  static const rememberMe = 'remember_me';
  static const loggedIn = 'logged_in';

  static const defaultUiLang = 'en_US';
  static const defaultTargetLang = 'th';
  static const defaultNativeLang = 'zh_CN';
}

// ── 语言选项定义 ──────────────────────────────────────────────
class LangOption {
  final String code;
  final String label;
  final String flag;

  const LangOption({required this.code, required this.label, required this.flag});
}

const kAllLanguages = <LangOption>[
  LangOption(code: 'zh_CN', label: 'Chinese Simplified / 简体中→', flag: '🇨🇳'),
  LangOption(code: 'en_US', label: 'English', flag: '🇺🇸'),
  LangOption(code: 'th', label: 'Thai / ภาษาไท→', flag: '🇹🇭'),
  LangOption(code: 'zh_TW', label: 'Chinese Traditional / 繁體中文', flag: '🇹🇼'),
  LangOption(code: 'fr', label: 'French / Français', flag: '🇫🇷'),
  LangOption(code: 'de', label: 'German / Deutsch', flag: '🇩🇪'),
  LangOption(code: 'it', label: 'Italian / Italiano', flag: '🇮🇹'),
  LangOption(code: 'es', label: 'Spanish / Español', flag: '🇪🇸'),
  LangOption(code: 'ja', label: 'Japanese / 日本→', flag: '🇯🇵'),
  LangOption(code: 'ko', label: 'Korean / 한국→', flag: '🇰🇷'),
  LangOption(code: 'my', label: 'Burmese / မြန်မ→', flag: '🇲🇲'),
  LangOption(code: 'he', label: 'Hebrew / עברית', flag: '🇮🇱'),
  LangOption(code: 'ru', label: 'Russian / Русский', flag: '🇷🇺'),
  LangOption(code: 'uk', label: 'Ukrainian / Українська', flag: '🇺🇦'),
];

// backward compat aliases
const kUiLangOptions = kAllLanguages;
const kTargetLangOptions = kAllLanguages;
const kNativeLangOptions = kAllLanguages;

// ── 全局语言状→──────────────────────────────────────────────
class AppLangNotifier extends ChangeNotifier {
  static final AppLangNotifier _instance = AppLangNotifier._();
  factory AppLangNotifier() => _instance;
  AppLangNotifier._();

  String _uiLang = LangPrefs.defaultUiLang;
  String _nativeLang = LangPrefs.defaultNativeLang;
  String _targetLang = LangPrefs.defaultTargetLang;

  String get uiLang => _uiLang;
  String get nativeLang => _nativeLang;
  String get targetLang => _targetLang;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _uiLang = prefs.getString(LangPrefs.uiLang) ?? LangPrefs.defaultUiLang;
    _nativeLang = prefs.getString(LangPrefs.nativeLang) ?? LangPrefs.defaultNativeLang;
    _targetLang = prefs.getString(LangPrefs.targetLang) ?? LangPrefs.defaultTargetLang;
    notifyListeners();
  }

  Future<void> setUiLang(String code) async {
    _uiLang = code;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(LangPrefs.uiLang, code);
    notifyListeners();
  }

  Future<void> setNativeLang(String code) async {
    _nativeLang = code;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(LangPrefs.nativeLang, code);
    notifyListeners();
  }

  Future<void> setTargetLang(String code) async {
    _targetLang = code;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(LangPrefs.targetLang, code);
    notifyListeners();
  }
}

// ── i18n helper ──────────────────────────────────────────────
// Maps UI lang code -> localized strings. Falls back to English.
class L10n {
  final String uiLang;
  const L10n(this.uiLang);

  bool get isZhCN => uiLang == 'zh_CN';
  bool get isZhTW => uiLang == 'zh_TW';
  bool get isEn => uiLang == 'en_US';

  String _pick(String zhCN, String zhTW, String en) {
    if (isZhTW) return zhTW;
    if (isZhCN) return zhCN;
    return en;
  }

  String get appTitle => 'DimaGo';

  // ── Menu ──
  String get menuDictionary => _pick('词典', '詞典', 'Dictionary');
  String get menuAddWord => _pick('添加词典', '添加詞典', 'Add Word');
  String get menuSettings => _pick('设定', '設定', 'Settings');
  String get menuLogin => _pick('账户 / 登录', '帳戶 / 登入', 'Account / Sign In');
  String get menuExit => _pick('退→', '退→', 'Exit');

  // ── Settings page ──
  String get settings => _pick('设定', '設定', 'Settings');
  String get settingsVoice => _pick('语音', '語音', 'Voice');
  String get settingsVoiceSub => _pick('发音速度与声→', '發音速度與聲→', 'Speed & voice gender');
  String get settingsDict => _pick('词典', '詞典', 'Dictionary');
  String get settingsDictSub => _pick('词典显示设定', '詞典顯示設定', 'Display settings');
  String get settingsNotif => _pick('定时', '定時', 'Reminders');
  String get settingsNotifSub => _pick('定时词汇提醒', '定時詞彙提醒', 'Scheduled vocabulary reminders');
  String get settingsLang => _pick('语言', '語言', 'Language');
  String get settingsLangSub => _pick('界面、翻译源、母→', '介面、翻譯源、母→', 'UI, translation & native language');
  String get settingsRecorder => _pick('录屏', '錄屏', 'Recorder');
  String get settingsRecorderSub => _pick(
      '屏幕录制（含麦克风）与回放',
      '螢幕錄製（含麥克風）與回放',
      'Screen recording (with mic) and playback');

  // ── System / Profile ──
  String get settingsSystem => _pick('系统', '系統', 'System');
  String get settingsSystemSub => _pick(
      '帮助提示与账户信息', '幫助提示與帳戶資訊', 'Help tooltips and account info');
  String get recorderTitle => _pick('录屏', '錄屏', 'Recorder');
  String get recorderStart => _pick('开始', '開始', 'Start');
  String get recorderStop => _pick('停止', '停止', 'Stop');
  String get recorderPlay => _pick('播放', '播放', 'Play');
  String get recorderPause => _pick('暂停', '暫停', 'Pause');
  String get recorderPlaybackStop => _pick('停止播放', '停止播放', 'Stop');
  String get recorderNoRecording => _pick('暂无录制内容', '暫無錄製內容', 'No recording yet');
  String get recorderPreparing => _pick('正在载入视频…', '正在載入影片…', 'Preparing video…');
  String get recorderStartFailed => _pick('无法开始录制', '無法開始錄製', 'Failed to start recording');
  String get recorderStopFailed => _pick('无法停止录制', '無法停止錄製', 'Failed to stop recording');
  String get systemShowHelpTooltips => _pick('显示帮助提示', '顯示幫助提示', 'Show help tooltips');
  String get systemShowHelpTooltipsNote => _pick(
      '在部分按钮/图标上显示/隐藏提示信息',
      '在部分按鈕/圖示上顯示/隱藏提示資訊',
      'Show/hide tooltip help messages on parts of the UI');
  String get systemFeedbackTitle => _pick('反馈', '回饋', 'Feedback');
  String get systemFeedbackSub => _pick(
      '发送意见与问题给管理员',
      '傳送意見與問題給管理員',
      'Send comments and issues to admin');
  String get feedbackSubjectLabel => _pick('主题', '主旨', 'Subject');
  String get feedbackCommentLabel => _pick('内容', '內容', 'Comment');
  String get feedbackSend => _pick('发送', '發送', 'Send');
  String get feedbackDefaultSubject => _pick('Dimago Feedack', 'Dimago Feedack', 'Dimago Feedack');
  String get feedbackNoMailApp => _pick(
      '未找到可用的邮件应用',
      '找不到可用的郵件應用程式',
      'No mail app available');

  String get profileTitle => _pick('个人资料', '個人資料', 'Profile');
  String get profileSub => _pick('账户信息（本地保存）', '帳戶資訊（本地保存）', 'Account info (local)');
  String get profileLoggedIn => _pick('已登录', '已登入', 'Logged in');
  String get profileNotLoggedIn => _pick('未登录', '未登入', 'Not logged in');
  String get profileLoginProvider => _pick('登录方式', '登入方式', 'Login provider');
  String get profileDisplayName => _pick('显示名称', '顯示名稱', 'Display name');
  String get profileRememberMe => _pick('记住我', '記住我', 'Remember me');

  // ── Voice ──
  String get voiceTitle => _pick('语音设定', '語音設定', 'Voice Settings');
  String get voiceSoundLabel => _pick('声音', '聲音', 'Voice');
  String get voiceSoundNote => _pick('泰语目前仅支持女→', '泰語目前僅支援女→', 'Thai only supports female voice');
  String get voiceFemale => _pick('女声', '女聲', 'Female');
  String get voiceMale => _pick('男声', '男聲', 'Male');
  String get voiceSlowLabel => _pick('减慢速度', '減慢速度', 'Slow down');
  String get voiceSlowMin => _pick('正常速度', '正常速度', 'Normal');
  String get voiceSlowMax => _pick('减慢 50%', '減慢 50%', 'Slow 50%');

  // ── Dictionary settings ──
  String get dictTitle => _pick('词典设定', '詞典設定', 'Dictionary Settings');
  String get dictMaxCount => _pick('最高访问次→', '最高訪問次→', 'Max correct count');
  String get dictMaxCountNote => _pick('热度红杠以此为满格基→', '熱度紅杠以此為滿格基→', 'Heat bar full reference');

  // ── Notifications ──
  String get notifTitle => _pick('定时提醒', '定時提醒', 'Reminders');
  String get notifStartTime => _pick('开始时→', '開始時間', 'Start Time');
  String get notifEndTime => _pick('结束时间', '結束時間', 'End Time');
  String get notifInterval => _pick('推送间→', '推送間→', 'Interval');
  String get notifPermDenied => _pick('未获得通知权限，请在系统设置中手动开→', '未取得通知權限，請在系統設定中手動開啟', 'Notification permission denied. Enable it in system settings.');
  String get notifExactTitle => _pick('需要「闹钟和提醒」权→', '需要「鬧鐘和提醒」權→', 'Exact Alarm Permission Required');
  String get notifExactContent => _pick(
      '要在 APP 关闭时也能定时推送通知，需要开启「精确闹钟」权限。\n\n点击「去开启」→ 找到 LANGO →开启权限，然后回来重新打开通知开关→',
      '要在 APP 關閉時也能定時推送通知，需要開啟「精確鬧鐘」權限。\n\n點擊「去開啟」→ 找到 LANGO →開啟權限，然後回來重新開啟通知開關→',
      'To receive notifications when the app is closed, enable the Exact Alarm permission.\n\nTap "Go to Settings" →find LANGO →enable the permission, then come back and re-enable notifications.');
  String get notifGoSettings => _pick('去开→', '去開→', 'Go to Settings');
  String get notifCancel => _pick('暂不', '暫不', 'Not Now');
  String notifActiveHint(String start, String end, int min) =>
      _pick('将在 $start →$end →$min 分钟推送一个词→', '將在 $start →$end →$min 分鐘推送一個詞→', 'Will send a word every $min min between $start →$end');
  String get notifInactiveHint => _pick('开启后将在指定时间段内定时推送词→', '開啟後將在指定時間段內定時推送詞→', 'Enable to receive vocabulary reminders during the set time range');
  String get hour => _pick('小时', '小時', 'h');
  String get minute => _pick('分钟', '分鐘', 'min');

  // ── Language settings ──
  String get langTitle => _pick('语言设定', '語言設定', 'Language Settings');
  String get langUi => _pick('界面语言', '介面語言', 'UI Language');
  String get langUiNote => _pick('应用界面显示语言', '應用介面顯示語言', 'Language of the app UI');
  String get langTarget => _pick('学习语言', '學習語言', 'Language to Learn');
  String get langTargetNote => _pick('学习目标语言', '學習目標語言', 'Language you are learning');
  String get langNative => _pick('翻译语言', '翻譯語言', 'Translation Language');
  String get langNativeNote => _pick('翻译的目标语言', '翻譯的目標語言', 'Language to translate into');

  // ── Challenge / Quiz mode ──
  String get challengeLabel => _pick('挑战', '挑戰', 'Challenge');
  String get challengeSettingsSub => _pick('计时器时长与自动跳题', '計時器時長與自動跳題', 'Timer duration & auto-advance');
  String get challengeSettingsTitle => _pick('挑战设定', '挑戰設定', 'Challenge Settings');
  String get challengeTimerDuration => _pick('计时时长', '計時時長', 'Timer Duration');
  String get challengeTimerDurationNote => _pick('自动进入下一词前的秒数', '自動進入下一詞前的秒數', 'Seconds before auto-advancing to next word');
  String get challengeMinDuration => _pick('最短时长', '最短時長', 'Minimum Duration');
  String get challengeMinDurationNote => _pick('恭喜后计时器不会减少低于此值', '恭喜後計時器不會減少低於此值', 'Timer will not decrease below this after Congratulations');
  String get challengeAccuracyThreshold => _pick('发音准确度阈值', '發音準確度閾值', 'Accuracy threshold');
  String get challengeAccuracyThresholdNote => _pick(
      'Talk 挑战：得分≥此值视为答对',
      'Talk 挑戰：得分≥此值視為答對',
      'Talk challenge: score at or above this counts as correct');
  String get challengeCongratsTitle => _pick('🎉 恭喜！', '🎉 恭喜！', '🎉 Congratulations!');
  String challengeCongratsMsg(int newDuration) => _pick(
      '你已完美全对！\n所有词汇均连续答对。\n\n新的挑战计时：${newDuration}s\n\n要接受新的挑战吗？',
      '你已完美全對！\n所有詞彙均連續答對。\n\n新的挑戰計時：${newDuration}s\n\n要接受新的挑戰嗎？',
      'You are 100% perfect!\nAll words answered correctly in sequence.\n\nNew timer: ${newDuration}s\n\nAccept the challenge now?');
  String get challengeOk => _pick('接受挑战', '接受挑戰', 'Accept Challenge');
  String get challengeLater => _pick('以后再说', '以後再說', 'Later');
  String get challengeNextLesson => _pick('下一课', '下一課', 'Next Lesson');
  String get challengeResultTitle => _pick('挑战完成', '挑戰完成', 'Challenge Complete');
  String challengeResultMsg(int elapsedSeconds) => _pick(
      '本次挑战耗时：${elapsedSeconds}s',
      '本次挑戰耗時：${elapsedSeconds}s',
      'Elapsed time: ${elapsedSeconds}s');
  String get challengeTryAgain => _pick('再来一次', '再來一次', 'Try again');
  String get challengeNextChallenge => _pick('下一个挑战', '下一個挑戰', 'Next challenge');
  String get challengeSkip => _pick('跳过', '跳過', 'Skip');
  // Circular score chart (8-digit challenge, lesson progress pie)
  String get circularScoreTalk => _pick('说', '說', 'Talk');
  String get circularScoreChoice => _pick('选', '選', 'Pick');
  String get circularScoreWord => _pick('词', '詞', 'Word');
  String get circularScorePhrase => _pick('句', '句', 'Phrase');
  String get circularScoreTw =>
      _pick('学·词', '學·詞', 'Learn·word');
  String get circularScoreTp =>
      _pick('学·句', '學·句', 'Learn·phrase');
  String get circularScoreNw =>
      _pick('译·词', '譯·詞', 'Native·word');
  String get circularScoreNp =>
      _pick('译·句', '譯·句', 'Native·phrase');
  String get circularScorePanelTitle =>
      _pick('进度', '進度', 'Progress');
  /// Lesson tab bottom panel: sum of the eight [category.challenge] digits.
  String lessonProgressTotalScoreHeader(int lessonNum, int totalScore) =>
      _pick(
        '第$lessonNum课 总分：$totalScore',
        '第$lessonNum課 總分：$totalScore',
        'Lesson $lessonNum total score: $totalScore',
      );

  /// Challenge progress table (Lesson tab bottom panel; replaces circular chart).
  String get challengeTableColDirection =>
      _pick('方向', '方向', 'Direction');
  String get challengeTableColUnit => _pick('单位', '單位', 'Unit');
  String get challengeTableColMode => _pick('模式', '模式', 'Mode');
  String get challengeTableColScore => _pick('分数', '分數', 'Score');
  String get challengeTableColAction => _pick('操作', '操作', 'Action');
  String get challengeTableTranslateDir =>
      _pick('泰→中', '泰→中', 'TH→CN');
  String get challengeTableNativeDir =>
      _pick('中→泰', '中→泰', 'CN→TH');
  String get challengeTableWord => _pick('字词', '字詞', 'Word');
  String get challengeTablePhrase => _pick('句子', '句子', 'Phrase');
  String get challengeTableModeTalk =>
      _pick('发音', '發音', 'Talk');
  String get challengeTableModeChoice =>
      _pick('多选', '多選', 'Choice');

  String get favoritesStarRow => _pick('★ 收藏', '★ 收藏', '★ Favorites');

  // ── Practice ──
  String get practiceCategory => _pick('类别→', '類別→', 'Category:');
  String get practiceAll => _pick('全部', '全部', 'All');
  String get practiceFavorite => _pick('→收藏', '→收藏', '→Favorites');
  String get practiceSelectThai => _pick('请选择正确的翻译：', '請選擇正確的翻譯→', 'Select the correct translation:');
  String get practiceSelectNative => _pick('请选择正确的翻译：', '請選擇正確的翻譯→', 'Select the correct translation:');
  String get practiceEmpty => _pick('词典里还没有词汇，\n请先通过菜单「添加词典」添加词汇再来练习！', '詞典裡還沒有詞彙，\n請先透過選單「添加詞典」新增詞彙再來練習！', 'No words yet.\nPlease add words via the menu first!');
  String get practiceCatEmpty => _pick('该类别暂无词汇，请切换类别或先添加词→', '此類別暫無詞彙，請切換類別或先新增詞→', 'No words in this category. Switch category or add words first.');
  String get modeTooltipAtoB => _pick('当前：正→反  点击切换', '當前：正→反  點擊切換', 'Current: Forward  Tap to switch');
  String get modeTooltipBtoA => _pick('当前：反→正  点击切换', '當前：反→正  點擊切換', 'Current: Reverse  Tap to switch');
  String get practiceToggleWord => _pick('字词', '字詞', 'Word');
  String get practiceTogglePhrase => _pick('句子', '句子', 'Phrase');
  String get practiceToggleTalk => _pick('发音', '發音', 'Talk');
  String get practiceToggleChoice => _pick('选择', '選擇', 'Choice');
  /// Talk mode: ASR pronunciation score toggle.
  String get talkAccuracyLabel => _pick('准确度', '準確度', 'Accuracy');
  String get talkScoringLabel => _pick('评分中…', '評分中…', 'Scoring...');
  /// Talk + accuracy: same pattern as tts_test circular + linear score UI.
  String get talkPhoneticMatchTitle =>
      _pick('发音匹配得分', '發音匹配得分', 'Phonetic match score');
  String get talkAccuracyCalculating =>
      _pick('计算中…', '計算中…', 'Calculating…');
  String get talkAccuracyLabelExcellent =>
      _pick('优秀 — 几乎完全一致', '優秀 — 幾乎完全一致', 'Excellent — nearly perfect match');
  String get talkAccuracyLabelGood =>
      _pick('良好 — 较为接近', '良好 — 較為接近', 'Good — close match');
  String get talkAccuracyLabelFair =>
      _pick('一般 — 部分匹配', '一般 — 部分匹配', 'Fair — partially matched');
  String get talkAccuracyLabelPoor =>
      _pick('较差 — 差异较大', '較差 — 差異較大', 'Poor — significant differences');
  String get talkAccuracyLabelVeryPoor =>
      _pick('很差 — 几乎不匹配', '很差 — 幾乎不匹配', 'Very poor — little or no match');

  // ── Lesson picker ──
  String get lessonLabel       => _pick('课程', '課程', 'Lesson');
  String get selectLessonLabel => _pick('选择课程', '選擇課程', 'Select Lesson');
  String get lessonTabEmpty => _pick(
        '本地暂无课程分类。请先完成词库下载，或在练习页继续学习。',
        '本機暫無課程分類。請先完成詞庫下載，或在練習頁繼續學習。',
        'No lesson categories on this device yet. Finish the vocabulary download, or keep learning on the Practice tab.',
      );
  String get lessonTabLoadError => _pick(
        '课程列表加载失败',
        '課程清單載入失敗',
        'Could not load lessons',
      );
  String get lessonTabRetry => _pick('重试', '重試', 'Retry');

  // ── Bottom tab panel ──
  String get tabDefinition   => _pick('释义', '釋義', 'Definition');
  String get tabActions      => _pick('操作', '操作', 'Actions');
  String get tabExample      => _pick('例句', '例句', 'Example');
  String get tabPhoto        => _pick('图片', '圖片', 'Photo');

  // ── Definition ──
  String get definitionNone    => _pick('暂无释义', '暫無釋義', 'No definition');
  String get definitionLoading => _pick('加载释义…', '載入釋義…', 'Loading definition…');

  // ── Sample phrase ──
  String get sampleLabel     => _pick('例句', '例句', 'Sample');
  String get sampleNone      => _pick('暂无例句', '暫無例句', 'No sample available');
  String get sampleLoading   => _pick('加载中…', '載入中…', 'Loading…');

  // ── Actions tab ──
  String get actionFavorite       => _pick('添加收藏', '加入收藏', 'Add to Favorites');
  String get actionUnfavorite     => _pick('取消收藏', '取消收藏', 'Remove Favorite');
  String get actionCopy           => _pick('复制词条', '複製詞條', 'Copy Word');
  String get actionCopied         => _pick('已复制', '已複製', 'Copied!');

  // ── Dictionary list ──
  String get dictPageTitle => _pick('词典', '詞典', 'Dictionary');
  String get dictSearch => _pick('搜索...', '搜尋...', 'Search...');
  String get dictNoResult => _pick('没有匹配的词→', '沒有符合的詞→', 'No matching entries');
  String get dictEmpty => _pick('词典是空→', '詞典是空→', 'Dictionary is empty');
  String get dictChangeCat => _pick('修改类别', '修改類別', 'Change Category');
  String get dictTimes => _pick('→', '→', 'times');

  // ── Add word ──
  String get addWordTitle => _pick('添加词典', '添加詞典', 'Add Word');

  // ── Language pack ──
  String get langPackDownloading => _pick('正在下载语言→', '正在下載語言→', 'Downloading language pack');
  String get langPackRetry => _pick('重试', '重試', 'Retry');
  String get langPackError => _pick('下载失败，请检查网→', '下載失敗，請檢查網路', 'Download failed. Check your connection.');
  String get langPackSetupTitle => _pick('选择您的语言', '選擇您的語言', 'Choose Your Language');
  String get langPackSetupSubtitle => _pick('请选择学习语言和母语，我们将为您下载对应的词库', '請選擇學習語言和母語，我們將為您下載對應的詞→', 'Select your learning and native language. We will download the word database for you.');
  String get langPackSetupConfirm => _pick('确定并下→', '確定並下→', 'Confirm & Download');
  String get langPackSetupSkip => _pick('稍后设置', '稍後設定', 'Set up later');

  // ── Setup flow ──
  String get setupWelcome => _pick('欢迎使用 DimaGo', '歡迎使用 DimaGo', 'Welcome to DimaGo');
  String get setupSelectUiLang => _pick('请选择界面语言', '請選擇介面語言', 'Select UI Language');
  String get setupSelectLearnLang => _pick('请选择要学习的语言', '請選擇要學習的語言', 'Select Language to Learn');
  String get setupSelectTransLang => _pick('请选择翻译语言', '請選擇翻譯語言', 'Select Translation Language');
  String get setupNext => _pick('下一→', '下一→', 'Next');
  String get setupBack => _pick('上一→', '上一→', 'Back');
  String get setupStart => _pick('下载', '下載', 'Download');

  // ── Login ──
  String get loginWelcome => _pick('欢迎使用 DimaGo', '歡迎使用 DimaGo', 'Welcome to DimaGo');
  String get loginSubtitle => _pick('登录以在设备间同步您的课程', '登入以在裝置間同步您的課程', 'Sign in to sync your lessons across devices');
  String get loginWithGoogle => _pick('使用 Google 登录', '使用 Google 登入', 'Continue with Google');
  String get loginWithApple => _pick('使用 Apple 账号登录', '使用 Apple 帳號登入', 'Continue with Apple');
  String get loginWithWechat => _pick('使用微信登录', '使用微信登入', 'Continue with WeChat');
  String get loginWithEmailRegister =>
      _pick('邮箱注册与登录', '電子郵件註冊與登入', 'Email register & sign in');
  String get loginEmailRegisterTitle =>
      _pick('邮箱注册与登录', '電子郵件註冊與登入', 'Email register & sign in');
  String get loginAppleUnavailable => _pick(
        'Apple 登录仅在 iPhone、iPad 或 Mac 上可用。',
        'Apple 登入僅在 iPhone、iPad 或 Mac 上可用。',
        'Sign in with Apple is available on iPhone, iPad, and Mac only.',
      );
  String get loginRememberMe => _pick('记住我', '記住我', 'Remember me');
  String get loginGuest => _pick('以访客身份继续', '以訪客身份繼續', 'Continue as Guest');
  String get loginTerms => _pick('登录即表示您同意我们的服务条款和隐私政策', '登入即表示您同意我們的服務條款與隱私政→', 'By signing in, you agree to our Terms & Privacy Policy');
  String get loginEmailHint => _pick('请输入邮箱地址', '請輸入電子郵件地址', 'Enter your email address');
  String get loginPasswordHint => _pick('请输入密码', '請輸入密碼', 'Enter your password');
  String get loginCodeHint => _pick('请输入验证码', '請輸入驗證碼', 'Enter verification code');
  String get loginSendCode => _pick('发送验证码', '發送驗證碼', 'Send Code');
  String get loginPasswordSignIn =>
      _pick('邮箱密码登录', '電子郵件密碼登入', 'Sign in with password');
  String get loginPasswordRegister =>
      _pick('邮箱密码注册', '電子郵件密碼註冊', 'Register with password');
  String get loginForgotPassword =>
      _pick('忘记密码？', '忘記密碼？', 'Forgot password?');
  String get loginResetPassword =>
      _pick('重置密码', '重設密碼', 'Reset password');
  String get loginResetPasswordSent => _pick(
      '重置密码邮件已发送，请检查邮箱。',
      '重設密碼郵件已送出，請檢查信箱。',
      'Password reset email sent. Please check your inbox.');
  String get loginResetPasswordSupabaseRedirectHint => _pick(
      '若链接无效：在 Supabase 控制台 → 身份验证 → URL → 重定向 URL 中加入 dimago://login-callback',
      '若連結無效：於 Supabase 控制台 → 驗證 → URL → 重新導向網址加入 dimago://login-callback',
      'If the link fails: Supabase Dashboard → Auth → URL → add dimago://login-callback to Redirect URLs');
  String get loginVerify => _pick('验证并登→', '驗證並登→', 'Verify & Sign In');
  String get loginCodeSent => _pick('验证码已发→', '驗證碼已發→', 'Code sent');
  String get loginOr => _pick('使用以下方式登录', '使用以下方式登入', 'Or sign in with');

  // ── Community ──
  String get communityFilterAll => _pick('全部', '全部', 'All');
  String get communityFilterLearning => _pick('学习语言', '學習語言', 'Learning');
  String get communityFilterNative => _pick('母语', '母語', 'Native');
  String get communityFilterCountry => _pick('国家', '國家', 'Country');
  String get communityAnonymous => _pick('匿名用户', '匿名使用者', 'Anonymous');
  String get communityNotConfigured => _pick(
      '社区未配置（Supabase 不可用）',
      '社區未配置（Supabase 不可用）',
      'Community is not configured (Supabase unavailable)');
  String get communityNoUsers => _pick('暂无用户', '暫無使用者', 'No users yet');
  String get communityScore => _pick('总分', '總分', 'Score');
  String get communityLessonProgress => _pick('课程进度', '課程進度', 'Lesson Progress');
  String get communityNoLessons => _pick('暂无课程进度', '暫無課程進度', 'No lesson progress');

  // ── Common ──
  String get cancel => _pick('取消', '取消', 'Cancel');
  String get confirm => _pick('确认', '確認', 'Confirm');
  String get save => _pick('保存', '儲存', 'Save');
  String get continueLabel => _pick('继续', '繼續', 'Continue');
  String get downloadSuccess => _pick('下载成功', '下載成功', 'Download Complete');

  // ── Category name translation (English →UI language) ──
  String translateCategory(String englishName) {
    const map = <String, List<String>>{
      // [zhCN, zhTW, en]
      'Grammar':     ['语法', '語法', 'Grammar'],
      'Verbs':       ['动词', '動詞', 'Verbs'],
      'Food':        ['食物', '食物', 'Food'],
      'Greeting':    ['问→', '問→', 'Greeting'],
      'Basic':       ['基础', '基礎', 'Basic'],
      'People':      ['人物', '人物', 'People'],
      'Education':   ['教育', '教育', 'Education'],
      'Description': ['描述', '描述', 'Description'],
      'Time':        ['时间', '時間', 'Time'],
      'Places':      ['地点', '地點', 'Places'],
      'Shopping':    ['购物', '購物', 'Shopping'],
      'Weather':     ['天气', '天氣', 'Weather'],
      'Family':      ['家庭', '家庭', 'Family'],
      'Body':        ['身体', '身體', 'Body'],
      'Health':      ['健康', '健康', 'Health'],
      'Numbers':     ['数字', '數字', 'Numbers'],
      'Colors':      ['颜色', '顏色', 'Colors'],
      'Objects':     ['物品', '物品', 'Objects'],
      'Travel':      ['旅行', '旅行', 'Travel'],
      'Directions':  ['方向', '方向', 'Directions'],
      'Question':    ['疑问', '疑問', 'Question'],
      'Feelings':    ['情感', '情感', 'Feelings'],
      'Work':        ['工作', '工作', 'Work'],
      'House':       ['家居', '家居', 'House'],
      'Nature':      ['自然', '自然', 'Nature'],
      'Adjectives':  ['形容→', '形容→', 'Adjectives'],
      'Adverbs':     ['副词', '副詞', 'Adverbs'],
      'Quantity':    ['数量', '數量', 'Quantity'],
      'Comparison':  ['比较', '比較', 'Comparison'],
      'Services':    ['服务', '服務', 'Services'],
      'Tech':        ['科技', '科技', 'Tech'],
      'Art':         ['艺术', '藝術', 'Art'],
      'Activity':    ['活动', '活動', 'Activity'],
      'Abstract':    ['抽象', '抽象', 'Abstract'],
      'Social':      ['社交', '社交', 'Social'],
    };
    final entry = map[englishName];
    if (entry == null) return englishName;
    return _pick(entry[0], entry[1], entry[2]);
  }
}

// ── 全局共享 category 选择 key ────────────────────────────────
class SharedCategoryPrefs {
  static const categoryKey = 'shared_category_id'; // -1=全部, -999=收藏, 其余=id
  static const kFavoriteId = -999;

  static Future<int?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt(categoryKey);
    if (v == null || v == -1) return null;
    return v;
  }

  static Future<void> save(int? catId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(categoryKey, catId ?? -1);
  }
}
