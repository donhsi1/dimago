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
  String get menuImport => _pick('导入数据', '匯入數據', 'Import Data');
  String get menuImportSub => _pick('→Excel 批量导入', '→Excel 批量匯入', 'Batch import from Excel');
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

  // ── Dictionary list ──
  String get dictPageTitle => _pick('词典', '詞典', 'Dictionary');
  String get dictSearch => _pick('搜索...', '搜尋...', 'Search...');
  String get dictNoResult => _pick('没有匹配的词→', '沒有符合的詞→', 'No matching entries');
  String get dictEmpty => _pick('词典是空→', '詞典是空→', 'Dictionary is empty');
  String get dictChangeCat => _pick('修改类别', '修改類別', 'Change Category');
  String get dictTimes => _pick('→', '→', 'times');

  // ── Add word ──
  String get addWordTitle => _pick('添加词典', '添加詞典', 'Add Word');

  // ── Import ──
  String get importTitle => _pick('导入数据', '匯入數據', 'Import Data');

  // ── Language pack ──
  String get langPackDownloading => _pick('正在下载语言→', '正在下載語言→', 'Downloading language pack');
  String get langPackRetry => _pick('重试', '重試', 'Retry');
  String get langPackError => _pick('下载失败，请检查网→', '下載失敗，請檢查網路', 'Download failed. Check your connection.');
  String get langPackSetupTitle => _pick('选择您的语言', '選擇您的語言', 'Choose Your Language');
  String get langPackSetupSubtitle => _pick('请选择学习语言和母语，我们将为您下载对应的词库', '請選擇學習語言和母語，我們將為您下載對應的詞→', 'Select your learning and native language. We will download the word database for you.');
  String get langPackSetupConfirm => _pick('确定并下→', '確定並下→', 'Confirm & Download');
  String get langPackSetupSkip => _pick('稍后设置', '稍後設定', 'Set up later');

  // ── Setup flow ──
  String get setupWelcome => _pick('欢迎使用 LANGO', '歡迎使用 LANGO', 'Welcome to LANGO');
  String get setupSelectUiLang => _pick('请选择界面语言', '請選擇介面語言', 'Select UI Language');
  String get setupSelectLearnLang => _pick('请选择要学习的语言', '請選擇要學習的語言', 'Select Language to Learn');
  String get setupSelectTransLang => _pick('请选择翻译语言', '請選擇翻譯語言', 'Select Translation Language');
  String get setupNext => _pick('下一→', '下一→', 'Next');
  String get setupBack => _pick('上一→', '上一→', 'Back');
  String get setupStart => _pick('开始使→', '開始使用', 'Get Started');

  // ── Login ──
  String get loginWelcome => _pick('欢迎使用 LANGO', '歡迎使用 LANGO', 'Welcome to LANGO');
  String get loginSubtitle => _pick('登录以在设备间同步您的词→', '登入以在裝置間同步您的詞→', 'Sign in to sync your vocabulary across devices');
  String get loginWithTiktok => _pick('使用 TikTok 登录', '使用 TikTok 登入', 'Continue with TikTok');
  String get loginWithGoogle => _pick('使用 Google 登录', '使用 Google 登入', 'Continue with Google');
  String get loginWithFacebook => _pick('使用 Facebook 登录', '使用 Facebook 登入', 'Continue with Facebook');
  String get loginWithInstagram => _pick('使用 Instagram 登录', '使用 Instagram 登入', 'Continue with Instagram');
  String get loginWithIcloud => _pick('使用 iCloud 登录', '使用 iCloud 登入', 'Continue with iCloud');
  String get loginWithWechat => _pick('使用微信登录', '使用微信登入', 'Continue with WeChat');
  String get loginWithPhone => _pick('手机号登→', '手機號碼登入', 'Sign in with Phone');
  String get loginWithEmail => _pick('邮箱登录', '電子郵件登入', 'Sign in with Email');
  String get loginRememberMe => _pick('记住→', '記住→', 'Remember me');
  String get loginGuest => _pick('以访客身份继→', '以訪客身份繼→', 'Continue as Guest');
  String get loginTerms => _pick('登录即表示您同意我们的服务条款和隐私政策', '登入即表示您同意我們的服務條款與隱私政→', 'By signing in, you agree to our Terms & Privacy Policy');
  String get loginPhoneHint => _pick('请输入手机号→', '請輸入手機號→', 'Enter your phone number');
  String get loginEmailHint => _pick('请输入邮箱地址', '請輸入電子郵件地址', 'Enter your email address');
  String get loginCodeHint => _pick('请输入验证码', '請輸入驗證碼', 'Enter verification code');
  String get loginSendCode => _pick('发送验证码', '發送驗證碼', 'Send Code');
  String get loginVerify => _pick('验证并登→', '驗證並登→', 'Verify & Sign In');
  String get loginCodeSent => _pick('验证码已发→', '驗證碼已發→', 'Code sent');
  String get loginOr => _pick('或使用以下方式登→', '或使用以下方式登→', 'Or sign in with');

  // ── Common ──
  String get cancel => _pick('取消', '取消', 'Cancel');
  String get confirm => _pick('确认', '確認', 'Confirm');
  String get save => _pick('保存', '儲存', 'Save');

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
      'general':     ['通用', '通用', 'General'],
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
