# DIMAGO — Project Overview for AI Coding Tools

> Read this file before making code changes. It describes the project architecture,
> key conventions, and the purpose of every major file.

---

## What is DIMAGO?

**DIMAGO** (Flutter package name: `lango`) is a mobile/desktop language learning app.
It targets **Android**, **iOS**, and **Windows Desktop**.

Primary use-case: vocabulary multiple-choice quiz (practice mode) for studying
a foreign language (initially Thai) with translations shown in the user's native
language (initially Simplified Chinese).

---

## Repository Layout

```
dimago/
├── lib/                        Flutter Dart source
│   ├── main.dart               App entry point & startup router
│   ├── practice_page.dart      Main quiz UI (root screen)
│   ├── database_helper.dart    SQLite dual-DB access layer
│   ├── lang_db_service.dart    Download / locate dict_*.db files
│   ├── language_prefs.dart     AppLangNotifier singleton + L10n strings
│   ├── translate_service.dart  Google Translate free API (text + romanization)
│   ├── edge_tts_service.dart   Google Translate TTS (MP3, cached locally)
│   ├── notification_service.dart  Scheduled local notifications
│   ├── settings_page.dart      Settings UI + preference key constants
│   ├── login_page.dart         Auth / Supabase sign-in
│   ├── supabase_bootstrap.dart Supabase init (URL + anon key via --dart-define)
│   └── supabase_vocab_hydrator.dart  Download vocab bundle from Supabase → SQLite
├── dict/                       Python scripts for building language packs
│   ├── dict_gen.py             JSON → multi-language .db generator
│   ├── thai_dict_editor.py     Tkinter GUI editor
│   ├── update_pinyin.py        Add Chinese romanization (pypinyin)
│   └── convert_to_traditional.py  Simplified → Traditional Chinese
├── dbutil/                     Python CLI utility for offline DB enrichment
│   ├── dbutil.py               Main utility (romanization, TTS audio, Supabase sync)
│   └── requirements.txt        pip dependencies
├── schema.sql                  SQLite DDL (top) + Supabase PostgreSQL reference after `DIMAGO_SUPABASE_POSTGRES_DDL` (`dbutil --commit-force` uses SQLite PRAGMA instead)
├── schema.json                 Same schema as JSON (machine-readable)
├── schema_postgres_lessons_users_assets.sql  Alternate PostgreSQL DDL (lessons/users/assets)
├── android/                    Android platform project
├── ios/                        iOS platform project
├── windows/                    Windows desktop platform project
└── CLAUDE.md                   Instructions for Claude Code AI assistant
```

---

## Database Design

### SQLite (local, on-device)

Two databases are opened simultaneously by `DatabaseHelper`:

| Database file          | Role                              |
|------------------------|-----------------------------------|
| `dict_<NL>.db`         | Native language words (e.g. TH)   |
| `dict_<NL>_<TL>.db`    | Bilingual vocabulary bundle       |

Filename convention: `dict_TH_CN.db` = Thai words with Simplified Chinese translations.

**Tables** (see `schema.sql` for full DDL):

#### `category` — Lesson/category metadata
| Column         | Type    | Notes                                     |
|----------------|---------|-------------------------------------------|
| id             | INTEGER | Primary key                               |
| name_native    | TEXT    | Lesson name in learning language          |
| name_translate | TEXT    | Lesson name in native language            |
| name_EN        | TEXT    | English name (used as stable identifier)  |
| lesson_id      | INTEGER | Logical lesson order index                |
| difficulty     | INTEGER | 0=easy 1=medium 2=hard                    |
| practice_type  | INTEGER | 0=word 1=phrase 2=photo                   |
| count_down     | INTEGER | Challenge mode timer (seconds, default 5) |

#### `word` — Vocabulary entries
| Column                  | Type    | Notes                                  |
|-------------------------|---------|----------------------------------------|
| id                      | INTEGER | Primary key                            |
| name_native             | TEXT    | Word in the language being learned     |
| name_translate          | TEXT    | Translation in user's native language  |
| name_EN                 | TEXT    | English gloss                          |
| roman_native            | TEXT    | Romanization of name_native            |
| roman_translate         | TEXT    | Romanization of name_translate         |
| audio_native            | BLOB    | MP3 bytes for name_native TTS          |
| audio_translate         | BLOB    | MP3 bytes for name_translate TTS       |
| sample1_native           | TEXT    | Example sentence 1 (native language)     |
| sample1_translate        | TEXT    | Example sentence 1 (translate language) |
| sample1_translate_roman  | TEXT    | Romanization of sample1_translate       |
| sample1_native_audio     | BLOB    | MP3 bytes for sample1_native TTS        |
| sample1_translate_audio  | BLOB    | MP3 bytes for sample1_translate TTS     |
| category_index           | INTEGER | FK → category.id                        |

### Supabase (cloud, optional sync)

PostgreSQL schema mirrors SQLite with these table name changes:
- `category` → `lessons` (+ `bundle_id`, `legacy_category_id`)
- `word` → `words` (+ `bundle_id`, `legacy_word_id`, `legacy_category_index`)
- `vocabulary_bundles` — one row per language pair (`translate_lang`, `native_lang`)

Full DDL reference for Flutter sync / manual Supabase setup: `schema.sql` (PostgreSQL section after `DIMAGO_SUPABASE_POSTGRES_DDL`; mirrors `scripts/supabase/schema_dimago.sql`). `dbutil --commit-force` builds `lessons`/`words` from the target SQLite file’s `category` and `word` tables. Alternate layout: `schema_postgres_lessons_users_assets.sql`.

> **Authoritative sources**: `schema.sql` (SQLite at top; Postgres block is reference). `schema.json` mirrors the SQLite tables for machine-readable use.

Supabase project URL: `https://prxmhmkndgvnlrbmnyxp.supabase.co`
Key is passed at build time via `--dart-define=SUPABASE_ANON_KEY=...` (never committed).

---

## Language Codes

| DB filename code | App `LangPrefs` code | Google Translate `tl` |
|------------------|---------------------|-----------------------|
| TH               | th                  | th                    |
| CN               | zh_CN               | zh-CN                 |
| TW               | zh_TW               | zh-TW                 |
| EN               | en_US               | en                    |
| JA               | ja                  | ja                    |
| KO               | ko                  | ko                    |
| FR               | fr                  | fr                    |
| DE               | de                  | de                    |
| IT               | it                  | it                    |
| ES               | es                  | es                    |
| RU               | ru                  | ru                    |
| UK               | uk                  | uk                    |
| HE               | he                  | iw                    |
| MY               | my                  | my                    |

---

## State Management

- **No external state library** — uses `ChangeNotifier` + singleton pattern.
- `AppLangNotifier` in `language_prefs.dart` is the **global singleton** for:
  - `uiLang` — language of the app UI
  - `targetLang` — language being learned
  - `nativeLang` — user's native/translation language
- Always access via the factory constructor: `AppLangNotifier()`.
- Widget-local state uses `setState`. Cross-widget state goes through `AppLangNotifier`.

---

## Navigation

- Imperative `Navigator.push` throughout. No GoRouter, no named routes.
- Startup: `main()` → `_StartupRouter` → setup wizard (first run) → login → `_AppShell`
- `_AppShell` hosts `PracticePage` as the root tab.
- All other pages are pushed via a `PopupMenuButton` in the app bar.

---

## External Services

| Service                    | File                       | Notes                                      |
|----------------------------|----------------------------|--------------------------------------------|
| Google Translate (text)    | translate_service.dart     | Free API, no key, rate-limited             |
| Google Translate (TTS)     | edge_tts_service.dart      | MP3 cached to app cache dir                |
| Google Translate (roman.)  | translate_service.dart     | `dt=rm` romanization endpoint              |
| Supabase                   | supabase_bootstrap.dart    | Auth + vocab bundle sync                   |
| Local notifications        | notification_service.dart  | Schedules up to 50 for next 24–48 h        |
| ASR (speech input)         | whisper_asr_service.dart   | Whisper-based                              |

---

## dbutil — Offline DB Enrichment CLI

`dbutil/dbutil.py` is a Python 3.11+ CLI tool that enriches a local `dict_*.db`
SQLite file with romanization and/or TTS audio, then optionally syncs to Supabase.

```
python dbutil/dbutil.py --input dict_TH_CN.db --roman TH --roman CN --audio TH --audio CN
python dbutil/dbutil.py --input dict_TH_CN.db --commit prxmhmkndgvnlrbmnyxp --key eyJ...
```

| Flag                  | Effect                                                              |
|-----------------------|---------------------------------------------------------------------|
| `--input FILE`        | SQLite database file (required)                                     |
| `--lesson NAME`       | Limit to one category (matches name_EN / name_native / name_translate) |
| `--roman CODE`        | Fill roman_* columns for that language using Google/pypinyin        |
| `--audio CODE`        | Fill audio_* BLOB columns using Google Translate TTS                |
| `--commit PROJECT`    | Upsert all data to Supabase (project ID or full URL)                |
| `--key KEY`           | Supabase key (or set `SUPABASE_KEY` env var)                        |
| `--force`             | Overwrite existing non-null values                                  |

`--roman` / `--audio` are repeatable: `--roman TH --roman CN` fills both roles.

---

## SharedPreferences Keys (selected)

| Constant class        | Key prefix / notes                                   |
|-----------------------|------------------------------------------------------|
| `LangPrefs`           | UI/target/native lang, setup done, login state       |
| `TtsPrefs`            | Speed percent, voice gender                          |
| `DictPrefs`           | Active category filter; `kFavoriteId = -999`         |
| `NotifPrefs`          | Notification schedule settings                       |

---

## Build Commands

```bash
flutter pub get          # Install dependencies
flutter analyze          # Lint
flutter test             # Unit + widget tests
flutter run              # Hot-reload on connected device
flutter build apk        # Android APK
flutter build appbundle  # Android AAB
flutter build windows    # Windows desktop
flutter build ios        # iOS (macOS only)
```

---

## Key Conventions

- SQLite `name_EN` column is `TEXT NOT NULL` — used as a stable English identifier.
- `kFavoriteId = -999` is the magic category ID for the "Favorites" virtual list.
- Windows uses `sqflite_common_ffi` (FFI); mobile uses the standard `sqflite` plugin.
- Language pack `.db` files are downloaded from GitHub at first launch.
- Audio BLOBs store raw MP3 bytes. They are written by `EdgeTTSService` in the app
  and by `dbutil.py` offline.
- Romanization for Thai uses Google `dt=rm`; for Chinese uses `pypinyin` (tone marks).
