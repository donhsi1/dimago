# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**DIMAGO** is a Flutter language learning app (internal codename: "lango") supporting Android, iOS, and Windows. It focuses on vocabulary practice (multiple-choice quiz) with local-first SQLite storage and optional cloud sync.

## Commands

```bash
flutter pub get          # Install dependencies
flutter analyze          # Lint / static analysis
flutter test             # Run tests
flutter run              # Run on connected device with hot reload
flutter build apk        # Android APK
flutter build appbundle  # Android App Bundle
flutter build windows    # Windows desktop
flutter build ios        # iOS (macOS only)
```

Run a single test file:
```bash
flutter test test/widget_test.dart
```

## Architecture

### State Management
- **No external state library** — uses `ChangeNotifier` + singleton pattern
- `AppLangNotifier` (`language_prefs.dart`) is the global singleton for UI language, target learning language, and native translation language. Always use the factory constructor: `AppLangNotifier()`. Never instantiate directly.
- UI state is local `setState`; cross-widget state flows through `AppLangNotifier`

### Dual-Database Pattern
`DatabaseHelper` (`database_helper.dart`) opens two SQLite databases simultaneously:
- **Learn DB** (e.g., `dict_TH.db`) — words in the language being learned
- **Native DB** (e.g., `dict_CN.db`) — translations in the user's native language
- **Photo DB** (`dict_photo.db`) — image references

Language packs are pre-built `.db` files downloaded from GitHub (`https://github.com/donhsi1/dimago/tree/main/dict`). Both DBs must be present before the practice mode works. Download is managed by `LangDbService` (`lang_db_service.dart`).

### Navigation
Uses imperative `Navigator.push` (no GoRouter or named routes).

Startup sequence: `main()` → `_StartupRouter` → Setup wizard (first run) → Login → `_AppShell`.

`_AppShell` hosts `PracticePage` as the root tab. All other pages (Dictionary, Add Word, Import, Settings, Login) are pushed via a `PopupMenuButton`.

### Localization
`L10n` class in `language_prefs.dart` provides all UI strings for 14 languages (Thai, Simplified/Traditional Chinese, English, French, German, Italian, Spanish, Japanese, Korean, Burmese, Hebrew, Russian, Ukrainian). Usage: `L10n(AppLangNotifier().uiLang).someKey`.

### External Services
- **Google Translate free API** (`translate_service.dart`) — no API key; used for translation and romanization. Subject to undocumented rate limits.
- **Google Translate TTS** (`edge_tts_service.dart`) — MP3 synthesis cached locally in app documents directory to avoid re-requests.
- **Scheduled notifications** (`notification_service.dart`) — pre-schedules up to 50 notifications for the next 24–48 hours. Android 12+ requires exact alarm permission (graceful fallback if denied).

### Windows
Uses `sqflite_common_ffi` for SQLite via native FFI instead of the mobile `sqflite` plugin. Initialization differs from mobile: must call `sqfliteFFiInit()` before opening any database.

## Key SharedPreferences Keys
Preference keys are scattered across multiple files. Central constants:
- `LangPrefs` — UI/target/native language, setup completion, login state
- `SharedCategoryPrefs` — active category filter (`kFavoriteId = -999` is the magic value for "Favorites")
- `NotifPrefs`, `TtsPrefs`, `DictPrefs`, `_PracticePrefs` — feature-specific settings in their respective files

## Dictionary Data / Python Tools
`dict/` contains Python scripts for building and editing the SQLite language packs (not used at runtime):
- `dict_gen.py` — master generator: JSON → multi-language `.db`
- `thai_dict_editor.py` — Tkinter-based editor UI
- `update_pinyin.py` — add Chinese romanization
- `convert_to_traditional.py` — Simplified → Traditional Chinese conversion
