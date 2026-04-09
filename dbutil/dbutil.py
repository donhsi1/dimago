#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
dbutil.py — DimaGo database utility
====================================
Adds romanization and/or TTS audio to a dict_<TRANSLATE>_<NATIVE>.db SQLite file
(same naming as Flutter ``LangDbService.dbFileNamePair``),
then optionally syncs all data to Supabase.

**Layout:** Command-line features live in this file. The graphical DB browser is implemented
only in ``dbview.py``; ``--view`` imports it and calls ``dbview.run_view_from_dbutil_namespace``.
You can still run the GUI standalone: ``python dbview.py`` (see that file’s docstring).

Usage examples:
  python dbutil.py --input dict_TH_CN.db
  python dbutil.py --input dict_TH_CN.db --lesson-show native
  python dbutil.py --input dict_TH_CN.db --lesson "Basic Greetings"
  python dbutil.py --input dict_TH_CN.db --roman
  python dbutil.py --input dict_TH_CN.db --roman --force
  python dbutil.py --input dict_TH_CN.db --audio --lesson "Basic Greetings"
  python dbutil.py --input dict_TH_CN.db --roman --audio
  python dbutil.py --input dict_TH_CN.db --commit prxmhmkndgvnlrbmnyxp --key eyJ...
  python dbutil.py --input dict_TH_CN.db --commit
        → With HARDCODED_SUPABASE_SERVICE_ROLE_KEY set in dbutil.py: uses hardcoded URL/ref/key.
        → Else: default project ref; key from SUPABASE_SERVICE_ROLE_KEY / service_role file / .env.
  python dbutil.py --input dict_TH_CN.db --commit --commit-modified dirty.json
        → Partial upsert: JSON {"category_ids": [1], "word_ids": [2,3]} (SQLite ids).
  python dbutil.py --input dict_TH_CN.db --commit --commit-sync
        → Compare local SQLite to this language pair on Supabase; upsert only rows that
          differ or are missing remotely (unlike a full --commit, which re-upserts all rows).
  python dbutil.py --view [--input dict_TH_CN.db]
        → Graphical DB browser (tkinter): same as dbview.py (edit, Supabase, schema tools).
  python dbutil.py --view --view-postgres [--database-url postgresql://...]
        → Viewer connected to Postgres (DATABASE_URL or --database-url).

  python dbutil.py --input dict_TH_CN.db --commit-force --yes
        → Postgres: build ``lessons`` / ``words`` DDL from this SQLite file
          (``PRAGMA table_info`` on ``category`` and ``word``), apply it plus
          RLS/indexes, DELETE this language-pair vocabulary_bundles row
          (CASCADE lessons + words), then same as --commit.
        → Needs DATABASE_URL (Supabase Database URI) and: pip install psycopg[binary]

Requirements:
  pip install requests pypinyin pythainlp supabase
  (optional) psycopg[binary] for --commit-force
  (optional) tkinter for --view (usually bundled with Python on Windows)

  --audio uses the same Google Translate web TTS as the Flutter app
  (translate.googleapis.com/translate_tts, client=tw-ob; ttsspeed for Thai).
  Optional env: TTS_SPEED_PERCENT (default 20, matches Flutter) or
  GOOGLE_TRANSLATE_TTS_SPEED (direct 0.5–1.0, e.g. 0.80).

Fields updated by --roman (TH vs CN from each source cell):
  name_native → roman_native; name_translate → roman_translate;
  sample1_translate → sample1_translate_roman.
  Each non-empty source is romanized if it contains Thai or CJK (English-only cells skipped).
  Thai: Google Translate romanization (translate_a, dt=rm, sl=th); PyThaiNLP ISO 11940 + RTGS if that fails.
  Chinese (CN/TW): Google first (translate_a, dt=rm, sl=zh-CN, client=gtx); pypinyin tone marks if that fails.
  Use --force to overwrite non-empty roman columns.

Fields updated by --audio (TTS from dict_<TRANSLATE>_<NATIVE>.db, Flutter pair naming):
  *_native text → native_code (second segment); *_translate text → translate_code (first).
  e.g. dict_TH_CN → CN TTS for name_native / sample1_native; TH TTS for name_translate / sample1_translate.
  Use --force to overwrite existing MP3 blobs.
"""

import argparse
import base64
import json
import os
import re
import sqlite3
import sys
import time
from pathlib import Path

# ── .env loader (dbutil/.env, gitignored) ────────────────────────────────────

def _load_dotenv() -> None:
    """Load ``dbutil/.env`` then ``dbutil/.env.local`` (later overrides); ``setdefault`` — OS env wins."""
    base = Path(__file__).parent
    merged: dict[str, str] = {}
    for fname in (".env", ".env.local"):
        env_file = base / fname
        if not env_file.is_file():
            continue
        for line in env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            k, v = k.strip(), v.strip()
            if k:
                merged[k] = v
    for k, v in merged.items():
        os.environ.setdefault(k, v)


_load_dotenv()

# Default Supabase project ref (Flutter `supabase_bootstrap.dart`); override via
# ``SUPABASE_PROJECT_REF`` or ``--commit <ref|url>``.
DEFAULT_SUPABASE_PROJECT_REF = 'prxmhmkndgvnlrbmnyxp'

# ── Hardwired data commit (``--commit``) ─────────────────────────────────────
# When ``HARDCODED_SUPABASE_SERVICE_ROLE_KEY`` is set to a real JWT (not a
# placeholder), ``run_commit`` uses the URL/ref/key below and ignores .env for
# those values. Optional ``--commit <ref|url>`` / ``--key`` still override URL / key.
HARDCODED_SUPABASE_URL = 'https://prxmhmkndgvnlrbmnyxp.supabase.co'
HARDCODED_SUPABASE_PROJECT_REF = 'prxmhmkndgvnlrbmnyxp'
HARDCODED_SUPABASE_SERVICE_ROLE_KEY = 'PASTE_SERVICE_ROLE_JWT_HERE'

_HARDCODE_KEY_SENTINELS = frozenset(
    ('', 'PASTE_SERVICE_ROLE_JWT_HERE', 'REPLACE_ME', 'your-service-role-jwt')
)


def _use_hardcoded_supabase_data_commit() -> bool:
    k = (HARDCODED_SUPABASE_SERVICE_ROLE_KEY or '').strip()
    return bool(k) and k not in _HARDCODE_KEY_SENTINELS


def _dimago_repo_root() -> Path:
    """Parent of ``dbutil/`` (``dimago`` checkout)."""
    return Path(__file__).resolve().parent.parent


def _read_supabase_anon_key_file() -> str:
    """Key from ``dimago/supabase_anon_key.txt`` (single line, stripped)."""
    path = _dimago_repo_root() / 'supabase_anon_key.txt'
    if not path.is_file():
        return ''
    return path.read_text(encoding='utf-8').strip()


def _read_supabase_service_role_key_file() -> str:
    """Service role JWT from ``dimago/supabase_service_role_key.txt`` (gitignored)."""
    path = _dimago_repo_root() / 'supabase_service_role_key.txt'
    if not path.is_file():
        return ''
    return path.read_text(encoding='utf-8').strip()


def _resolve_supabase_key_for_commit(cli_key: str) -> str:
    """``--commit`` needs a key that bypasses RLS (service role). Anon often fails."""
    k = (cli_key or '').strip()
    if k:
        return k
    k = (os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '') or '').strip()
    if k:
        return k
    k = _read_supabase_service_role_key_file()
    if k:
        return k
    k = (os.environ.get('SUPABASE_KEY', '') or '').strip()
    if k:
        return k
    k = _read_supabase_anon_key_file()
    if k:
        return k
    print(
        '[error] No Supabase key. For --commit set SUPABASE_SERVICE_ROLE_KEY, add '
        'dimago/supabase_service_role_key.txt (service role JWT), or use --key. '
        'Anon/publishable keys are blocked by RLS on lessons/words.',
        file=sys.stderr,
    )
    sys.exit(1)


# ── Dependencies check ───────────────────────────────────────────────────────

try:
    import requests
except ImportError:
    print("[error] 'requests' not installed. Run: pip install requests")
    sys.exit(1)

# ── Language code maps ───────────────────────────────────────────────────────

# App language code (uppercase) → Google Translate 'sl' parameter
LANG_TO_SL: dict[str, str] = {
    'TH': 'th',
    'CN': 'zh-CN',
    'TW': 'zh-TW',
    'EN': 'en',
    'JA': 'ja',
    'KO': 'ko',
    'FR': 'fr',
    'DE': 'de',
    'IT': 'it',
    'ES': 'es',
    'RU': 'ru',
    'UK': 'uk',
    'HE': 'iw',
    'MY': 'my',
}

# App language code → Google Translate TTS ``tl`` (same mapping as Flutter EdgeTTSService).
LANG_TO_TTS: dict[str, str] = {
    'TH': 'th',
    'CN': 'zh-CN',
    'TW': 'zh-TW',
    'EN': 'en',
    'JA': 'ja',
    'KO': 'ko',
    'FR': 'fr',
    'DE': 'de',
    'IT': 'it',
    'ES': 'es',
    'RU': 'ru',
    'UK': 'uk',
    'HE': 'iw',
    'MY': 'my',
}

# DB filename code → app language code used in Supabase vocabulary_bundles
DB_CODE_TO_APP_LANG: dict[str, str] = {
    'TH': 'th',
    'CN': 'zh_CN',
    'TW': 'zh_TW',
    'EN': 'en_US',
    'JA': 'ja',
    'KO': 'ko',
    'FR': 'fr',
    'DE': 'de',
    'IT': 'it',
    'ES': 'es',
    'RU': 'ru',
    'UK': 'uk',
    'HE': 'he',
    'MY': 'my',
}

# Browser headers to avoid Google API rejections
_HEADERS = {
    'User-Agent': (
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/120.0.0.0 Safari/537.36'
    ),
    'Referer': 'https://translate.google.com/',
}

# Delay between outgoing API requests (seconds) to stay under rate limits
REQUEST_DELAY = 0.35

# Supabase batch size for upsert payloads
PAGE_SIZE = 200

# Script sniffing for TH vs CN romanization
_RE_THAI = re.compile(r'[\u0e00-\u0e7f]')
_RE_CJK = re.compile(r'[\u4e00-\u9fff\u3400-\u4dbf\uf900-\ufadf]')


def _heading_lang_th_or_cn(text: object) -> str | None:
    """Infer Thai vs Chinese from cell text (e.g. name_native, name_translate, samples)."""
    if text is None:
        return None
    s = str(text).strip()
    if not s:
        return None
    if _RE_THAI.search(s):
        return 'TH'
    if _RE_CJK.search(s):
        return 'CN'
    return None


# ── Romanization ─────────────────────────────────────────────────────────────

def _romanize_google(text: str, lang_code: str) -> str | None:
    """Fetch romanization via Google Translate dt=rm."""
    sl = LANG_TO_SL.get(lang_code.upper(), lang_code.lower())
    try:
        r = requests.get(
            'https://translate.googleapis.com/translate_a/single',
            params={'client': 'gtx', 'sl': sl, 'tl': 'en', 'dt': 'rm', 'q': text},
            headers=_HEADERS,
            timeout=10,
        )
        r.raise_for_status()
        data = r.json()
        parts = []
        if isinstance(data, list) and data and isinstance(data[0], list):
            for seg in data[0]:
                if isinstance(seg, list) and len(seg) > 3 and isinstance(seg[3], str):
                    parts.append(seg[3])
        result = ''.join(parts).strip()
        return result or None
    except Exception:
        return None


def _romanize_chinese(text: str) -> str | None:
    """Romanize Chinese text with pypinyin (tone marks)."""
    try:
        from pypinyin import lazy_pinyin, Style  # type: ignore
        return ' '.join(lazy_pinyin(text, style=Style.TONE)).strip() or None
    except ImportError:
        print('\n  [warn] pypinyin not installed — run: pip install pypinyin')
        return None
    except Exception:
        return None


def _romanize_thai(text: str) -> str | None:
    """Thai: Google ``translate_a`` ``dt=rm`` first; then ISO 11940 + RTGS (royin) offline."""
    g = _romanize_google(text, 'TH')
    if g:
        return g.strip() or None
    try:
        from pythainlp.transliterate import romanize, transliterate  # type: ignore
    except ImportError:
        print('\n  [warn] pythainlp not installed — Thai offline fallback: pip install pythainlp')
        return None
    try:
        out = transliterate(text, engine='iso_11940')
        if isinstance(out, str) and out.strip():
            return out.strip()
    except Exception:
        pass
    try:
        out = romanize(text, engine='royin')
        if isinstance(out, str) and out.strip():
            return out.strip()
    except Exception:
        pass
    return None


def _roman_column_has_value(existing: object) -> bool:
    """True if DB cell already has romanization worth skipping (without --force)."""
    if existing is None:
        return False
    if isinstance(existing, str):
        return bool(existing.strip())
    return bool(existing)


def _audio_column_has_value(existing: object) -> bool:
    """True if audio BLOB already has bytes (skip unless --force)."""
    if existing is None:
        return False
    if isinstance(existing, (bytes, bytearray)):
        return len(existing) > 0
    return bool(existing)


def get_romanization(text: str, lang_code: str) -> str | None:
    if not text or not text.strip():
        return None
    code = lang_code.upper()
    if code in ('CN', 'TW'):
        g = _romanize_google(text, 'CN')
        if g:
            return g.strip() or None
        return _romanize_chinese(text)
    if code == 'TH':
        result = _romanize_thai(text)
        if result:
            return result
    return _romanize_google(text, lang_code)


def romanize_translate_sample_text(text: str, filename_translate_code: str) -> str | None:
    """Romanize text for a *translate* column: infer Thai/CJK from script, else use pair translate code."""
    if not text or not text.strip():
        return None
    lang = _heading_lang_th_or_cn(text) or (filename_translate_code or "").strip().upper() or None
    if not lang:
        return None
    return get_romanization(text, lang)


def translate_text_google(
    text: str, source_lang_code: str, target_lang_code: str
) -> str | None:
    """Translate ``text`` between app language codes (TH, CN, TW, …) via ``translate_a`` (client=gtx, dt=t)."""
    if not text or not text.strip():
        return None
    sl = LANG_TO_SL.get(source_lang_code.upper(), source_lang_code.lower())
    tl = LANG_TO_SL.get(target_lang_code.upper(), target_lang_code.lower())
    try:
        r = requests.get(
            "https://translate.googleapis.com/translate_a/single",
            params={
                "client": "gtx",
                "sl": sl,
                "tl": tl,
                "dt": "t",
                "q": text,
            },
            headers=_HEADERS,
            timeout=20,
        )
        r.raise_for_status()
        data = r.json()
        parts: list[str] = []
        if isinstance(data, list) and data and isinstance(data[0], list):
            for segment in data[0]:
                if segment and segment[0]:
                    parts.append(str(segment[0]))
        out = "".join(parts).strip()
        time.sleep(REQUEST_DELAY)
        return out if out else None
    except Exception as ex:
        print(
            f"\n  [error] Google Translate text [{sl!r}→{tl!r}]: {ex}",
            flush=True,
        )
        return None


# ── TTS (Google Translate web — same as Flutter lib/edge_tts_service.dart) ────

def _translate_tts_ttsspeed_param() -> str:
    """Thai-only ``ttsspeed`` query value: Flutter uses 1.0 - speedPercent/100, clamp 0.5–1.0."""
    direct = (os.environ.get('GOOGLE_TRANSLATE_TTS_SPEED') or '').strip()
    if direct:
        try:
            v = float(direct)
            v = max(0.5, min(1.0, v))
            return f'{v:.2f}'
        except ValueError:
            pass
    try:
        pct = int(os.environ.get('TTS_SPEED_PERCENT', '20'))
    except ValueError:
        pct = 20
    speed = 1.0 - pct / 100.0
    speed = max(0.5, min(1.0, speed))
    return f'{speed:.2f}'


def _split_text(text: str, max_len: int = 200) -> list[str]:
    """Split long text at word/punctuation boundaries for TTS chunking."""
    if len(text) <= max_len:
        return [text]
    segments: list[str] = []
    remaining = text
    while len(remaining) > max_len:
        cut_at = max_len
        for i in range(max_len, max_len // 2, -1):
            if remaining[i] in (' ', ',', '.', '\u0e00'):
                cut_at = i + 1
                break
        segments.append(remaining[:cut_at].strip())
        remaining = remaining[cut_at:].strip()
    if remaining:
        segments.append(remaining)
    return segments


_TRANSLATE_TTS_URL = 'https://translate.googleapis.com/translate_tts'


def synthesize_tts(text: str, lang_code: str) -> bytes | None:
    """MP3 from Google Translate web TTS (``translate_tts``, ``client=tw-ob``).

    Matches Flutter ``EdgeTTSService._synthesizeLang`` (``edge_tts_service.dart``):
    ``ie``, ``q``, ``tl``, ``client``; ``ttsspeed`` only when ``tl == 'th'``;
    Chrome User-Agent and Referer ``https://translate.google.com/``.
    """
    tl = LANG_TO_TTS.get(lang_code.upper(), lang_code.lower())
    chunks = _split_text(text, 200)
    buf = bytearray()
    try:
        for seg in chunks:
            c = seg.strip()
            if not c:
                continue
            params: dict[str, str] = {
                'ie': 'UTF-8',
                'q': c,
                'tl': tl,
                'client': 'tw-ob',
            }
            if tl == 'th':
                params['ttsspeed'] = _translate_tts_ttsspeed_param()
            r = requests.get(
                _TRANSLATE_TTS_URL,
                params=params,
                headers=_HEADERS,
                timeout=15,
            )
            if not r.ok:
                body = (r.text or '')[:400]
                print(
                    f'\n  [error] Google Translate TTS [tl={tl}]: HTTP {r.status_code} {body}',
                    flush=True,
                )
                return None
            if not r.content:
                print(
                    f'\n  [error] Google Translate TTS [tl={tl}]: empty response body',
                    flush=True,
                )
                return None
            buf.extend(r.content)
            time.sleep(REQUEST_DELAY)
        return bytes(buf) if buf else None
    except requests.RequestException as ex:
        print(f'\n  [error] Google Translate TTS [tl={tl}]: {ex}', flush=True)
        return None
    except Exception as ex:
        print(f'\n  [error] Google Translate TTS [{lang_code}]: {ex}', flush=True)
        return None


# ── DB helpers ────────────────────────────────────────────────────────────────

def parse_db_lang_codes(db_path: str) -> tuple[str, str]:
    """Return ``(native_code, translate_code)`` from ``dict_<TRANSLATE>_<NATIVE>.db``.

    Matches Flutter ``LangDbService.dbFileNamePair(translateLang, nativeLang)``:
    first segment = language for **translate** fields (``name_translate``, ``sample*_translate``, …),
    second = language for **native** fields (``name_native``, …).

    Example: ``dict_TH_CN.db`` → learn/target TH, user native CN → returns ``('CN', 'TH')``.
    """
    stem = Path(db_path).stem  # e.g. 'dict_TH_CN'
    m = re.match(r'dict_([A-Za-z]+)_([A-Za-z]+)', stem, re.IGNORECASE)
    if m:
        translate_code = m.group(1).upper()
        native_code = m.group(2).upper()
        return native_code, translate_code
    return '', ''


def get_category_ids(conn: sqlite3.Connection, lesson_name: str) -> list[int]:
    """Return category IDs matching lesson_name across all name columns."""
    rows = conn.execute(
        'SELECT id FROM category WHERE name_EN=? OR name_native=? OR name_translate=?',
        (lesson_name, lesson_name, lesson_name),
    ).fetchall()
    if not rows:
        print(f'\n  [warn] No category matched "{lesson_name}" — processing all words.')
        return []
    ids = [r[0] for r in rows]
    print(f'  Lesson "{lesson_name}" → category IDs: {ids}')
    return ids


def parse_lesson_as_category_ids(
    conn: sqlite3.Connection, lesson_name: str,
) -> list[int] | None:
    """If ``--lesson`` is comma-separated integers, treat as ``category.id`` values.

    Returns ids present in ``category`` (order preserved), or ``None`` if the
    argument is not in that form (caller should use name-based matching).
    """
    s = lesson_name.strip()
    parts = [p.strip() for p in s.split(',') if p.strip()]
    if not parts or not all(p.isdigit() for p in parts):
        return None
    want = [int(p) for p in parts]
    ph = ','.join('?' * len(want))
    rows = conn.execute(
        f'SELECT id FROM category WHERE id IN ({ph})', want,
    ).fetchall()
    found_set = {r[0] for r in rows}
    missing = [i for i in want if i not in found_set]
    if missing:
        print(f'  [warn] category id(s) not in DB: {missing}')
    ordered = [i for i in want if i in found_set]
    if ordered:
        print(f'  Lesson (category.id) → {ordered}')
    return ordered


def fetch_words(
    conn: sqlite3.Connection,
    category_ids: list[int],
    *,
    treat_empty_ids_as_all_words: bool = True,
) -> list[sqlite3.Row]:
    """Load words; when ``category_ids`` is empty, either all rows or none."""
    conn.row_factory = sqlite3.Row
    if not category_ids:
        if treat_empty_ids_as_all_words:
            return conn.execute('SELECT * FROM word').fetchall()
        return []
    ph = ','.join('?' * len(category_ids))
    return conn.execute(
        f'SELECT * FROM word WHERE category_index IN ({ph})', category_ids
    ).fetchall()


def fetch_words_for_lesson(
    conn: sqlite3.Connection,
    lesson_name: str | None,
) -> list[sqlite3.Row]:
    """Words for ``--lesson``: numeric ``category.id`` list, else name match, else all."""
    if not lesson_name:
        return fetch_words(conn, [], treat_empty_ids_as_all_words=True)
    strict = parse_lesson_as_category_ids(conn, lesson_name)
    if strict is not None:
        if not strict:
            print('  [warn] No valid category id(s); 0 words to process.')
        return fetch_words(conn, strict, treat_empty_ids_as_all_words=False)
    cat_ids = get_category_ids(conn, lesson_name)
    return fetch_words(conn, cat_ids, treat_empty_ids_as_all_words=True)


def get_category_ids_by_lesson_en(
    conn: sqlite3.Connection, lesson_name: str,
) -> list[int]:
    """Return category IDs where name_EN equals lesson_name (exact match)."""
    rows = conn.execute(
        'SELECT id FROM category WHERE name_EN = ?',
        (lesson_name,),
    ).fetchall()
    return [r[0] for r in rows]


def run_show_schema(conn: sqlite3.Connection) -> None:
    """Print CREATE statements for tables, indexes, and triggers from sqlite_master."""
    rows = conn.execute(
        """
        SELECT sql FROM sqlite_master
        WHERE sql IS NOT NULL AND (name IS NULL OR SUBSTR(name, 1, 7) != 'sqlite_')
        ORDER BY
            CASE type WHEN 'table' THEN 0 WHEN 'index' THEN 1 ELSE 2 END,
            name
        """
    ).fetchall()
    print()
    for (sql,) in rows:
        print(sql + ';')
        print()


def run_list_words_for_lesson_en(conn: sqlite3.Connection, lesson_name: str) -> None:
    """Print word name_EN values for categories whose name_EN matches, comma-separated."""
    cat_ids = get_category_ids_by_lesson_en(conn, lesson_name)
    if not cat_ids:
        print(f'\n  [warn] No category with name_EN matching "{lesson_name}".')
        return
    ph = ','.join('?' * len(cat_ids))
    rows = conn.execute(
        f'SELECT name_EN FROM word WHERE category_index IN ({ph}) ORDER BY id',
        cat_ids,
    ).fetchall()
    parts = [r[0] if r[0] is not None else '' for r in rows]
    print()
    print(','.join(parts))


LESSON_SHOW_COLUMNS: dict[str, str] = {
    'native': 'name_native',
    'translate': 'name_translate',
    'EN': 'name_EN',
}


def _parse_lesson_show_field(s: str) -> str:
    key = s.strip().lower()
    if key == 'en':
        return 'EN'
    if key == 'native':
        return 'native'
    if key == 'translate':
        return 'translate'
    raise argparse.ArgumentTypeError(
        f'--lesson-show expects native, translate, or EN (got {s!r})'
    )


def run_show_category_lesson_names(conn: sqlite3.Connection, field: str) -> None:
    """Print every category row's name_native, name_translate, or name_EN (ordered by id)."""
    col = LESSON_SHOW_COLUMNS[field]
    rows = conn.execute(f'SELECT {col} FROM category ORDER BY id').fetchall()
    print(f'\n  category.{col} — {len(rows)} rows')
    print()
    for (val,) in rows:
        print(val if val is not None else '')


# ── Field maps ────────────────────────────────────────────────────────────────

# roman: source text column → target roman column, keyed by role
ROMAN_FIELDS: dict[str, list[tuple[str, str]]] = {
    'native': [
        ('name_native', 'roman_native'),
    ],
    'translate': [
        ('name_translate',    'roman_translate'),
        ('sample1_translate', 'sample1_translate_roman'),
    ],
}

# audio: source text column → target audio BLOB column, keyed by role
AUDIO_FIELDS: dict[str, list[tuple[str, str]]] = {
    'native': [
        ('name_native', 'audio_native'),
        ('sample1_native', 'sample1_native_audio'),
    ],
    'translate': [
        ('name_translate',    'audio_translate'),
        ('sample1_translate', 'sample1_translate_audio'),
    ],
}


def tts_lang_code_for_source_column(
    source_col: str, native_code: str, translate_code: str
) -> str | None:
    """Map a ``word`` table text column to the filename lang code for Google TTS.

    ``dict_<TRANSLATE>_<NATIVE>.db``: columns ending with ``_native`` use the second
    segment; columns ending with ``_translate`` use the first (learn/target language).
    """
    if source_col.endswith('_native'):
        return native_code
    if source_col.endswith('_translate'):
        return translate_code
    return None


# ── Progress bar ──────────────────────────────────────────────────────────────

def _progress(current: int, total: int, suffix: str = '') -> None:
    width = 30
    filled = int(width * current / total) if total else width
    bar = '█' * filled + '░' * (width - filled)
    pct = 100 * current // total if total else 100
    print(f'\r  [{bar}] {pct:3d}% {current}/{total}  {suffix}', end='', flush=True)


# ── Roman operation ───────────────────────────────────────────────────────────

def run_roman(
    conn: sqlite3.Connection,
    lesson_name: str | None,
    force: bool,
) -> None:
    words = fetch_words_for_lesson(conn, lesson_name)
    total = len(words)
    print(
        '\nRomanization (TH/CN inferred per source field; name_native → roman_native, …) '
        f'— {total} words'
    )

    updated = skipped = errors = 0
    for i, row in enumerate(words):
        word_id = row['id']
        updates: dict[str, str] = {}

        for role in ('native', 'translate'):
            for src_col, tgt_col in ROMAN_FIELDS[role]:
                text = row[src_col]
                existing = row[tgt_col]
                if not text:
                    continue
                if _roman_column_has_value(existing) and not force:
                    continue
                field_lang = _heading_lang_th_or_cn(text)
                if not field_lang:
                    continue
                roman = get_romanization(text, field_lang)
                time.sleep(REQUEST_DELAY)
                if roman:
                    updates[tgt_col] = roman
                else:
                    errors += 1

        if updates:
            set_clause = ', '.join(f'{k}=?' for k in updates)
            conn.execute(
                f'UPDATE word SET {set_clause}, date_modified=date("now") WHERE id=?',
                [*updates.values(), word_id],
            )
            conn.commit()
            updated += 1
        else:
            skipped += 1

        _progress(i + 1, total, f'updated={updated} skipped={skipped} errors={errors}')

    print(f'\n  Done. updated={updated} skipped={skipped} errors={errors}')


# ── Audio operation ───────────────────────────────────────────────────────────

def run_audio(
    conn: sqlite3.Connection,
    db_path: str,
    lesson_name: str | None,
    force: bool,
) -> None:
    native_code, translate_code = parse_db_lang_codes(db_path)
    specs: list[tuple[str, str, str]] = []
    for role_pairs in AUDIO_FIELDS.values():
        for src, tgt in role_pairs:
            lang = tts_lang_code_for_source_column(src, native_code, translate_code)
            if not lang:
                print(f'  [warn] No TTS lang rule for source column {src!r}; skipped.')
                continue
            specs.append((src, tgt, lang))

    if not native_code or not translate_code:
        print(
            f'  [warn] Filename should be dict_<TRANSLATE>_<NATIVE>.db '
            f'(see LangDbService.dbFileNamePair); '
            f'got native={native_code!r} translate={translate_code!r} — TTS lang may be wrong.'
        )

    print(
        '  TTS: Google Translate web (translate_tts / tw-ob; ttsspeed for Thai) '
        '— same as Flutter edge_tts_service.dart'
    )

    ensure_word_audio_columns(conn)
    have_cols = {r[1] for r in conn.execute('PRAGMA table_info(word)').fetchall()}
    use_specs: list[tuple[str, str, str]] = []
    for src_col, tgt_col, tts_lang in specs:
        if src_col not in have_cols:
            print(
                f'  [warn] word table has no column {src_col!r}; skip TTS → {tgt_col}'
            )
            continue
        if tgt_col not in have_cols:
            print(
                f'  [warn] word table has no column {tgt_col!r}; skip TTS from {src_col!r}'
            )
            continue
        use_specs.append((src_col, tgt_col, tts_lang))
    specs = use_specs
    if not specs:
        print('  [warn] No audio columns match this DB schema; nothing to do.')
        return

    words = fetch_words_for_lesson(conn, lesson_name)
    total = len(words)
    print(
        f'\nTTS Audio (voice: native={native_code or "?"} translate={translate_code or "?"}) '
        f'— {total} words'
    )

    updated = skipped = errors = 0
    for i, row in enumerate(words):
        word_id = row['id']
        updates: dict[str, bytes] = {}

        for src_col, tgt_col, tts_lang in specs:
            text = row[src_col]
            existing = row[tgt_col]
            if not text:
                continue
            if _audio_column_has_value(existing) and not force:
                continue
            audio = synthesize_tts(text, tts_lang)
            time.sleep(REQUEST_DELAY)
            if audio:
                updates[tgt_col] = audio
            else:
                errors += 1

        if updates:
            set_clause = ', '.join(f'{k}=?' for k in updates)
            conn.execute(
                f'UPDATE word SET {set_clause}, date_modified=date("now") WHERE id=?',
                [*updates.values(), word_id],
            )
            conn.commit()
            updated += 1
        else:
            skipped += 1

        _progress(i + 1, total, f'updated={updated} skipped={skipped} errors={errors}')

    print(f'\n  Done. updated={updated} skipped={skipped} errors={errors}')


# ── Supabase commit ───────────────────────────────────────────────────────────

def _bytes_to_hex(data: object) -> str | None:
    r"""Encode bytes as Postgres hex-escape bytea string (\x...)."""
    if isinstance(data, (bytes, bytearray)) and data:
        return '\\x' + data.hex()
    return None


def _row_blob_hex(row: sqlite3.Row, col: str) -> str | None:
    """Hex-encode a BLOB column if present on the row; else None (missing column)."""
    if col not in row.keys():
        return None
    return _bytes_to_hex(row[col])


def _sb_select_all_eq(
    sb: object,
    table: str,
    columns: str,
    eq_column: str,
    eq_value: int,
    *,
    page_size: int = 1000,
) -> list[dict]:
    """All rows matching ``eq_column = eq_value`` (paginated; default PostgREST cap is 1000)."""
    out: list[dict] = []
    offset = 0
    while True:
        end = offset + page_size - 1
        res = (
            sb.table(table)
            .select(columns)
            .eq(eq_column, eq_value)
            .range(offset, end)
            .execute()
        )
        batch = res.data or []
        out.extend(batch)
        if len(batch) < page_size:
            break
        offset += page_size
    return out


def _vocabulary_bundle_lookup_or_create(
    sb: object,
    db_path: str,
    native_app: str,
    transl_app: str,
    *,
    verbose: bool = True,
) -> int:
    """Return ``vocabulary_bundles.id`` for this SQLite file’s language pair; insert row if missing."""
    if verbose:
        print("  Resolving vocabulary_bundle…")
    res = (
        sb.table("vocabulary_bundles")
        .select("id")
        .eq("translate_lang", transl_app)
        .eq("native_lang", native_app)
        .maybe_single()
        .execute()
    )
    if res is not None and res.data:
        bundle_id = res.data["id"]
        if verbose:
            print(f"  Found bundle id={bundle_id}")
        return int(bundle_id)
    source_fn = Path(db_path).name
    ins = (
        sb.table("vocabulary_bundles")
        .insert(
            {
                "translate_lang": transl_app,
                "native_lang": native_app,
                "source_filename": source_fn,
            }
        )
        .execute()
    )
    bundle_id = int(ins.data[0]["id"])
    if verbose:
        print(f"  Created bundle id={bundle_id} (source_filename={source_fn!r})")
    return bundle_id


def _row_blob_bytes(row: sqlite3.Row, col: str) -> bytes | None:
    if col not in row.keys():
        return None
    v = row[col]
    if v is None:
        return None
    if isinstance(v, (bytes, bytearray, memoryview)):
        b = bytes(v)
        return b if b else None
    return None


def _bytes_from_supabase_bytea(v: object) -> bytes | None:
    """Normalize PostgREST / client BYTEA (hex string, raw bytes, or base64) to ``bytes`` or None."""
    if v is None:
        return None
    if isinstance(v, (bytes, bytearray, memoryview)):
        b = bytes(v)
        return b if b else None
    if isinstance(v, str):
        s = v.strip()
        if not s:
            return None
        if s.startswith("\\x"):
            try:
                return bytes.fromhex(s[2:])
            except ValueError:
                pass
        try:
            dec = base64.b64decode(s, validate=False)
            return dec if dec else None
        except Exception:
            return None
    return None


def _sync_norm_date_val(v: object) -> str | None:
    if v is None:
        return None
    s = str(v).strip()
    if not s:
        return None
    if "T" in s:
        s = s.split("T", 1)[0]
    return s


def _sync_int(v: object, default: int = 0) -> int:
    if v is None:
        return default
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return default


def _sync_str_empty(v: object) -> str:
    if v is None:
        return ""
    return str(v) if str(v).strip() else ""


def _sync_str_or_none(v: object) -> str | None:
    if v is None:
        return None
    s = str(v).strip()
    return s if s else None


def _lesson_compare_dict_from_sqlite(cat: sqlite3.Row, bundle_id: int) -> dict[str, object]:
    return {
        "bundle_id": bundle_id,
        "legacy_category_id": int(cat["id"]),
        "name_native": _sync_str_empty(cat["name_native"]),
        "name_translate": _sync_str_empty(cat["name_translate"]),
        "name_en": _sync_str_empty(cat["name_EN"]),
        "lesson_id": _sync_int(cat["lesson_id"], 0),
        "user_id": _sync_int(cat["user_id"], 0) if "user_id" in cat.keys() else 0,
        "language_tag": _sync_str_or_none(cat["language_tag"])
        if "language_tag" in cat.keys()
        else None,
        "lang_translate": _sync_str_or_none(cat["lang_translate"])
        if "lang_translate" in cat.keys()
        else None,
        "lang_native": _sync_str_or_none(cat["lang_native"])
        if "lang_native" in cat.keys()
        else None,
        "access": _sync_int(cat["access"], 0),
        "difficulty": _sync_int(cat["difficulty"], 0),
        "date_created": _sync_norm_date_val(cat["date_created"])
        if "date_created" in cat.keys()
        else None,
        "date_modified": _sync_norm_date_val(cat["date_modified"])
        if "date_modified" in cat.keys()
        else None,
        "count": _sync_int(cat["count"], 0),
        "count_down": _sync_int(cat["count_down"], 5),
        "practice_type": _sync_int(cat["practice_type"], 0),
        "challenge": _sync_int(cat["challenge"], 0),
        "photo": _sync_str_or_none(cat["photo"]) if "photo" in cat.keys() else None,
        "is_favorite": _sync_int(cat["is_favorite"], 0),
    }


def _lesson_compare_dict_from_remote(r: dict[str, object], bundle_id: int) -> dict[str, object]:
    lc = r.get("legacy_category_id")
    return {
        "bundle_id": _sync_int(r.get("bundle_id"), bundle_id),
        "legacy_category_id": int(lc) if lc is not None else None,
        "name_native": _sync_str_empty(r.get("name_native")),
        "name_translate": _sync_str_empty(r.get("name_translate")),
        "name_en": _sync_str_empty(r.get("name_en")),
        "lesson_id": _sync_int(r.get("lesson_id"), 0),
        "user_id": _sync_int(r.get("user_id"), 0),
        "language_tag": _sync_str_or_none(r.get("language_tag")),
        "lang_translate": _sync_str_or_none(r.get("lang_translate")),
        "lang_native": _sync_str_or_none(r.get("lang_native")),
        "access": _sync_int(r.get("access"), 0),
        "difficulty": _sync_int(r.get("difficulty"), 0),
        "date_created": _sync_norm_date_val(r.get("date_created")),
        "date_modified": _sync_norm_date_val(r.get("date_modified")),
        "count": _sync_int(r.get("count"), 0),
        "count_down": _sync_int(r.get("count_down"), 5),
        "practice_type": _sync_int(r.get("practice_type"), 0),
        "challenge": _sync_int(r.get("challenge"), 0),
        "photo": _sync_str_or_none(r.get("photo")),
        "is_favorite": _sync_int(r.get("is_favorite"), 0),
    }


def _word_compare_dict_from_sqlite(w: sqlite3.Row) -> dict[str, object]:
    wid = int(w["id"])
    cat_ix = w["category_index"]
    return {
        "legacy_word_id": wid,
        "legacy_category_index": int(cat_ix) if cat_ix is not None else None,
        "name_native": _sync_str_empty(w["name_native"]),
        "name_translate": _sync_str_empty(w["name_translate"]),
        "name_en": _sync_str_empty(w["name_EN"]),
        "roman_native": _sync_str_or_none(w["roman_native"])
        if "roman_native" in w.keys()
        else None,
        "roman_translate": _sync_str_or_none(w["roman_translate"])
        if "roman_translate" in w.keys()
        else None,
        "audio_translate": _row_blob_bytes(w, "audio_translate"),
        "audio_native": _row_blob_bytes(w, "audio_native"),
        "definition_native": _sync_str_or_none(w["definition_native"])
        if "definition_native" in w.keys()
        else None,
        "action_native": _sync_str_or_none(w["action_native"])
        if "action_native" in w.keys()
        else None,
        "definition_translate": _sync_str_or_none(w["definition_translate"])
        if "definition_translate" in w.keys()
        else None,
        "action_translate": _sync_str_or_none(w["action_translate"])
        if "action_translate" in w.keys()
        else None,
        "sample1_native": _sync_str_or_none(w["sample1_native"])
        if "sample1_native" in w.keys()
        else None,
        "sample1_translate": _sync_str_or_none(w["sample1_translate"])
        if "sample1_translate" in w.keys()
        else None,
        "sample1_translate_roman": _sync_str_or_none(w["sample1_translate_roman"])
        if "sample1_translate_roman" in w.keys()
        else None,
        "sample1_native_audio": _row_blob_bytes(w, "sample1_native_audio"),
        "sample1_translate_audio": _row_blob_bytes(w, "sample1_translate_audio"),
        "photo": _sync_str_or_none(w["photo"]) if "photo" in w.keys() else None,
        "date_created": _sync_norm_date_val(w["date_created"])
        if "date_created" in w.keys()
        else None,
        "date_modified": _sync_norm_date_val(w["date_modified"])
        if "date_modified" in w.keys()
        else None,
        "use_count": _sync_int(w["use_count"], 0),
        "is_favorite": _sync_int(w["is_favorite"], 0),
        "user_id": _sync_int(w["user_id"], 0) if "user_id" in w.keys() else 0,
        "correct_count": _sync_int(w["correct_count"], 0) if "correct_count" in w.keys() else 0,
        "hint": _sync_str_or_none(w["hint"]) if "hint" in w.keys() else None,
    }


def _word_compare_dict_from_remote(r: dict[str, object]) -> dict[str, object]:
    lw = r.get("legacy_word_id")
    lci = r.get("legacy_category_index")
    return {
        "legacy_word_id": int(lw) if lw is not None else None,
        "legacy_category_index": int(lci) if lci is not None else None,
        "name_native": _sync_str_empty(r.get("name_native")),
        "name_translate": _sync_str_empty(r.get("name_translate")),
        "name_en": _sync_str_empty(r.get("name_en")),
        "roman_native": _sync_str_or_none(r.get("roman_native")),
        "roman_translate": _sync_str_or_none(r.get("roman_translate")),
        "audio_translate": _bytes_from_supabase_bytea(r.get("audio_translate")),
        "audio_native": _bytes_from_supabase_bytea(r.get("audio_native")),
        "definition_native": _sync_str_or_none(r.get("definition_native")),
        "action_native": _sync_str_or_none(r.get("action_native")),
        "definition_translate": _sync_str_or_none(r.get("definition_translate")),
        "action_translate": _sync_str_or_none(r.get("action_translate")),
        "sample1_native": _sync_str_or_none(r.get("sample1_native")),
        "sample1_translate": _sync_str_or_none(r.get("sample1_translate")),
        "sample1_translate_roman": _sync_str_or_none(r.get("sample1_translate_roman")),
        "sample1_native_audio": _bytes_from_supabase_bytea(r.get("sample1_native_audio")),
        "sample1_translate_audio": _bytes_from_supabase_bytea(r.get("sample1_translate_audio")),
        "photo": _sync_str_or_none(r.get("photo")),
        "date_created": _sync_norm_date_val(r.get("date_created")),
        "date_modified": _sync_norm_date_val(r.get("date_modified")),
        "use_count": _sync_int(r.get("use_count"), 0),
        "is_favorite": _sync_int(r.get("is_favorite"), 0),
        "user_id": _sync_int(r.get("user_id"), 0),
        "correct_count": _sync_int(r.get("correct_count"), 0),
        "hint": _sync_str_or_none(r.get("hint")),
    }


def _sync_compare_dicts(a: dict[str, object], b: dict[str, object]) -> bool:
    if set(a.keys()) != set(b.keys()):
        return False
    for k in a:
        if a[k] != b[k]:
            return False
    return True


def run_commit_sync(
    conn: sqlite3.Connection,
    project: str,
    key: str,
    db_path: str,
) -> None:
    """Compare local ``category``/``word`` to Supabase ``lessons``/``words`` for this bundle; upsert diffs only."""
    try:
        from supabase import create_client  # type: ignore
    except ImportError:
        print("[error] supabase-py not installed. Run: pip install supabase")
        sys.exit(1)

    url, key = _commit_resolve_supabase_url_and_key(project, key)
    native_code, translate_code = parse_db_lang_codes(db_path)
    native_app = DB_CODE_TO_APP_LANG.get(native_code, native_code.lower())
    transl_app = DB_CODE_TO_APP_LANG.get(translate_code, translate_code.lower())

    sb = create_client(url, key)
    print(f"\nSupabase commit-sync → {url}")
    print(f"  Language pair: {native_app} / {transl_app}")

    bundle_id = _vocabulary_bundle_lookup_or_create(
        sb, db_path, native_app, transl_app, verbose=True
    )

    print("  Fetching remote lessons and words for comparison…")
    remote_lessons = _sb_select_all_eq(sb, "lessons", "*", "bundle_id", bundle_id)
    remote_words = _sb_select_all_eq(sb, "words", "*", "bundle_id", bundle_id)
    rl_by: dict[int, dict[str, object]] = {}
    for r in remote_lessons:
        lc = r.get("legacy_category_id")
        if lc is not None:
            rl_by[int(lc)] = r
    rw_by: dict[int, dict[str, object]] = {}
    for r in remote_words:
        lw = r.get("legacy_word_id")
        if lw is not None:
            rw_by[int(lw)] = r

    conn.row_factory = sqlite3.Row
    cats = conn.execute("SELECT * FROM category").fetchall()
    words = conn.execute("SELECT * FROM word").fetchall()

    cats_lesson_drift: set[int] = set()
    words_drift: set[int] = set()

    for cat in cats:
        lid = int(cat["id"])
        loc = _lesson_compare_dict_from_sqlite(cat, bundle_id)
        rem = rl_by.get(lid)
        if rem is None:
            cats_lesson_drift.add(lid)
            continue
        rem_c = _lesson_compare_dict_from_remote(rem, bundle_id)
        if not _sync_compare_dicts(loc, rem_c):
            cats_lesson_drift.add(lid)

    for w in words:
        wid = int(w["id"])
        loc = _word_compare_dict_from_sqlite(w)
        rem = rw_by.get(wid)
        if rem is None:
            words_drift.add(wid)
            continue
        if not _sync_compare_dicts(loc, _word_compare_dict_from_remote(rem)):
            words_drift.add(wid)

    all_words_under_changed_lessons: set[int] = set()
    for cid in cats_lesson_drift:
        for r in conn.execute(
            "SELECT id FROM word WHERE category_index = ?",
            (cid,),
        ):
            all_words_under_changed_lessons.add(int(r[0]))

    cats_for_word_fk = _category_ids_referenced_by_words(conn, words_drift)
    partial_cats = cats_lesson_drift | cats_for_word_fk
    partial_words = words_drift | all_words_under_changed_lessons

    if not partial_cats and not partial_words:
        print("  Already in sync (no row-level differences vs local SQLite for this bundle).")
        return

    print(
        f"  Drift: {len(cats_lesson_drift)} lesson(s) (category) differ or missing; "
        f"{len(words_drift)} word(s) differ or missing."
    )
    print(
        f"  Upserting {len(partial_cats)} category row(s) (lessons) and "
        f"{len(partial_words)} word(s) (includes FK parents and words under changed lessons)."
    )
    run_commit(
        conn,
        project,
        key,
        db_path,
        partial_category_ids=partial_cats,
        partial_word_ids=partial_words,
        bundle_resolve_verbose=False,
        echo_header=False,
    )


def _parse_migration_sql_statements(sql: str) -> list[str]:
    """Split SQL on ';' into executable chunks.

    Full-line ``--`` comments are removed *before* splitting so semicolons inside comments
    do not break statements (e.g. ``-- note; more`` must not produce `` more`` as SQL).
    """
    cleaned_lines: list[str] = []
    for ln in sql.splitlines():
        if ln.lstrip().startswith("--"):
            continue
        cleaned_lines.append(ln)
    sql_body = "\n".join(cleaned_lines)
    chunks: list[str] = []
    for part in sql_body.split(";"):
        lines: list[str] = []
        for pln in part.splitlines():
            s = pln.strip()
            if not s or s.startswith("--"):
                continue
            lines.append(pln.rstrip())
        body = "\n".join(lines).strip()
        if body:
            chunks.append(body)
    return chunks


def _commit_resolve_supabase_url_and_key(project: str, key: str) -> tuple[str, str]:
    """Supabase REST base URL and API key for ``create_client`` (same rules as ``--commit``)."""
    cli_project = (project or "").strip()
    cli_key = (key or "").strip()

    if _use_hardcoded_supabase_data_commit():
        url = (HARDCODED_SUPABASE_URL or "").strip()
        if not url and (HARDCODED_SUPABASE_PROJECT_REF or "").strip():
            ref = (HARDCODED_SUPABASE_PROJECT_REF or "").strip()
            url = f"https://{ref}.supabase.co"
        if cli_project.startswith("http"):
            url = cli_project
        elif cli_project:
            url = f"https://{cli_project}.supabase.co"
        if not url:
            print(
                "[error] Hardcoded commit: set HARDCODED_SUPABASE_URL or "
                "HARDCODED_SUPABASE_PROJECT_REF in dbutil.py.",
                file=sys.stderr,
            )
            sys.exit(1)
        use_key = cli_key or (HARDCODED_SUPABASE_SERVICE_ROLE_KEY or "").strip()
        return url, use_key

    eff_project = cli_project
    if not eff_project:
        eff_project = (
            os.environ.get("SUPABASE_PROJECT_REF", "") or DEFAULT_SUPABASE_PROJECT_REF
        ).strip()

    if eff_project.startswith("http"):
        url = eff_project
    elif eff_project:
        url = f"https://{eff_project}.supabase.co"
    else:
        url = os.environ.get("SUPABASE_URL", "")
    if not url:
        print(
            "[error] Supabase URL unknown. Use --commit, set SUPABASE_URL, or "
            "SUPABASE_PROJECT_REF / default project ref — or set "
            "HARDCODED_SUPABASE_SERVICE_ROLE_KEY in dbutil.py.",
            file=sys.stderr,
        )
        sys.exit(1)

    use_key = _resolve_supabase_key_for_commit(key)
    return url, use_key


# ── --commit-force: Postgres schema from SQLite PRAGMA ───────────────────────

_COMMIT_FORCE_INFRA_DDL = """
CREATE TABLE IF NOT EXISTS public.users (
    id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    email TEXT UNIQUE,
    display_name TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.vocabulary_bundles (
    id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    translate_lang TEXT NOT NULL,
    native_lang TEXT NOT NULL,
    source_filename TEXT NOT NULL UNIQUE,
    imported_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON COLUMN public.vocabulary_bundles.translate_lang IS 'App code e.g. th';
COMMENT ON COLUMN public.vocabulary_bundles.native_lang IS 'App code e.g. zh_CN';

CREATE TABLE IF NOT EXISTS public.word_photo_blobs (
    id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    legacy_row_id BIGINT NOT NULL UNIQUE,
    rec_id BIGINT,
    word TEXT NOT NULL,
    photo BYTEA,
    format TEXT
);

CREATE INDEX IF NOT EXISTS idx_word_photo_blobs_word ON public.word_photo_blobs (word);
"""

_COMMIT_FORCE_INDEX_RLS_DDL = """
CREATE INDEX IF NOT EXISTS idx_lessons_bundle ON public.lessons (bundle_id);
CREATE UNIQUE INDEX IF NOT EXISTS lessons_bundle_legacy_category_uq
    ON public.lessons (bundle_id, legacy_category_id);
CREATE UNIQUE INDEX IF NOT EXISTS lessons_bundle_name_native_uq
    ON public.lessons (bundle_id, name_native);

CREATE INDEX IF NOT EXISTS idx_words_lesson ON public.words (lesson_id);
CREATE INDEX IF NOT EXISTS idx_words_bundle ON public.words (bundle_id);
CREATE INDEX IF NOT EXISTS idx_words_favorite ON public.words (is_favorite);
CREATE INDEX IF NOT EXISTS idx_words_legacy ON public.words (bundle_id, legacy_word_id);
CREATE INDEX IF NOT EXISTS idx_words_legacy_category ON public.words (legacy_category_index);

ALTER TABLE public.vocabulary_bundles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lessons ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.words ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.word_photo_blobs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "vocabulary_bundles_select_public" ON public.vocabulary_bundles;
CREATE POLICY "vocabulary_bundles_select_public"
    ON public.vocabulary_bundles FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "lessons_select_public" ON public.lessons;
CREATE POLICY "lessons_select_public"
    ON public.lessons FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "words_select_public" ON public.words;
CREATE POLICY "words_select_public"
    ON public.words FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "word_photo_blobs_select_public" ON public.word_photo_blobs;
CREATE POLICY "word_photo_blobs_select_public"
    ON public.word_photo_blobs FOR SELECT TO anon, authenticated USING (true);

GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT SELECT ON public.vocabulary_bundles, public.lessons, public.words, public.word_photo_blobs
    TO anon, authenticated;
"""


def _pg_ident(name: str) -> str:
    return '"' + str(name).replace('"', '""') + '"'


def _sqlite_decl_to_pg_type(decl: str) -> str:
    d = (decl or "").strip().upper()
    if not d:
        return "TEXT"
    if "BLOB" in d:
        return "BYTEA"
    if any(x in d for x in ("REAL", "FLOA", "DOUB")):
        return "DOUBLE PRECISION"
    if "INT" in d:
        return "INTEGER"
    return "TEXT"


def _sqlite_has_table(conn: sqlite3.Connection, table: str) -> bool:
    r = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        (table,),
    ).fetchone()
    return r is not None


def _pragma_table_info(conn: sqlite3.Connection, table: str) -> list[tuple]:
    if not re.fullmatch(r"^[a-zA-Z_][a-zA-Z0-9_]*$", table):
        print(f"[error] Invalid SQLite table name for PRAGMA: {table!r}", file=sys.stderr)
        sys.exit(1)
    return list(conn.execute(f"PRAGMA table_info({table})").fetchall())


def _sqlite_default_sql(dflt: object, pg_type: str) -> str | None:
    if dflt is None:
        return None
    s = str(dflt).strip()
    if pg_type == "INTEGER":
        try:
            return f"DEFAULT {int(float(s))}"
        except ValueError:
            return None
    if pg_type == "DOUBLE PRECISION":
        try:
            return f"DEFAULT {float(s)!r}"
        except ValueError:
            return None
    if pg_type == "TEXT":
        return "DEFAULT '" + s.replace("'", "''") + "'"
    return None


def _create_column_line(
    pg_name: str,
    pg_type: str,
    notnull: int,
    dflt: object,
) -> str:
    parts = [_pg_ident(pg_name), pg_type]
    dsql = _sqlite_default_sql(dflt, pg_type)
    if notnull:
        parts.append("NOT NULL")
    if dsql:
        parts.append(dsql)
    return " ".join(parts)


def _alter_add_column_if_missing(
    pg: object,
    table: str,
    pg_name: str,
    pg_type: str,
    notnull: int,
    dflt: object,
) -> None:
    ident = _pg_ident(pg_name)
    if pg_type in ("BYTEA", "DOUBLE PRECISION") or not notnull:
        pg.execute(
            f"ALTER TABLE public.{table} ADD COLUMN IF NOT EXISTS {ident} {pg_type}"
        )
        return
    if pg_type == "TEXT":
        pg.execute(
            f"ALTER TABLE public.{table} ADD COLUMN IF NOT EXISTS {ident} "
            f"TEXT NOT NULL DEFAULT ''"
        )
        return
    if pg_type == "INTEGER":
        dv = 0
        if dflt is not None:
            try:
                dv = int(float(str(dflt).strip()))
            except ValueError:
                dv = 0
        pg.execute(
            f"ALTER TABLE public.{table} ADD COLUMN IF NOT EXISTS {ident} "
            f"INTEGER NOT NULL DEFAULT {dv}"
        )


def _pg_table_exists(cur: object, relname: str) -> bool:
    cur.execute(
        "SELECT 1 FROM pg_catalog.pg_class c "
        "JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace "
        "WHERE n.nspname = 'public' AND c.relname = %s AND c.relkind IN ('r', 'p')",
        (relname,),
    )
    return cur.fetchone() is not None


def _pg_column_names(cur: object, table: str) -> set[str]:
    cur.execute(
        "SELECT column_name FROM information_schema.columns "
        "WHERE table_schema = 'public' AND table_name = %s",
        (table,),
    )
    return {r[0] for r in cur.fetchall()}


def _lessons_columns_from_category(
    pragma_rows: list[tuple],
) -> list[tuple[str, str, int, object]]:
    """(pg_name, pg_type, notnull, dflt_value) for lessons body (no id / bundle / legacy)."""
    out: list[tuple[str, str, int, object]] = []
    seen: set[str] = set()
    for row in pragma_rows:
        _cid, name, decl, notnull, dflt_value, _pk = (
            row[0],
            row[1],
            row[2],
            row[3],
            row[4],
            row[5],
        )
        if name == "id":
            continue
        pg_name = "name_en" if name == "name_EN" else name
        if pg_name in seen:
            continue
        seen.add(pg_name)
        out.append((pg_name, _sqlite_decl_to_pg_type(decl), int(notnull), dflt_value))
    return out


def _words_columns_from_word(
    pragma_rows: list[tuple],
) -> list[tuple[str, str, int, object]]:
    """Map SQLite ``word`` → ``words`` (skip id; category_index → legacy_category_index)."""
    out: list[tuple[str, str, int, object]] = []
    seen: set[str] = set()
    for row in pragma_rows:
        _cid, name, decl, notnull, dflt_value, _pk = (
            row[0],
            row[1],
            row[2],
            row[3],
            row[4],
            row[5],
        )
        if name == "id":
            continue
        if name == "category_index":
            pg_name = "legacy_category_index"
        elif name == "name_EN":
            pg_name = "name_en"
        else:
            pg_name = name
        if pg_name in seen:
            continue
        seen.add(pg_name)
        out.append((pg_name, _sqlite_decl_to_pg_type(decl), int(notnull), dflt_value))
    extras = (
        ("correct_count", "INTEGER", 1, 0),
        ("hint", "TEXT", 0, None),
    )
    for pg_name, pg_type, nn, dv in extras:
        if pg_name not in seen:
            seen.add(pg_name)
            out.append((pg_name, pg_type, nn, dv))
    return out


def _apply_supabase_schema_from_sqlite(
    sqlite_conn: sqlite3.Connection,
    pg: object,
) -> None:
    """Create or align Supabase tables from SQLite ``category`` / ``word`` PRAGMA."""
    if not _sqlite_has_table(sqlite_conn, "category"):
        print("[error] SQLite file has no category table.", file=sys.stderr)
        sys.exit(1)
    if not _sqlite_has_table(sqlite_conn, "word"):
        print("[error] SQLite file has no word table.", file=sys.stderr)
        sys.exit(1)

    _psycopg_exec_sql_script(pg, _COMMIT_FORCE_INFRA_DDL, "commit-force (core tables)")

    cat_pragma = _pragma_table_info(sqlite_conn, "category")
    word_pragma = _pragma_table_info(sqlite_conn, "word")
    lesson_cols = _lessons_columns_from_category(cat_pragma)
    word_cols = _words_columns_from_word(word_pragma)

    with pg.cursor() as cur:
        lessons_exists = _pg_table_exists(cur, "lessons")
        words_exists = _pg_table_exists(cur, "words")
        lessons_have = _pg_column_names(cur, "lessons") if lessons_exists else set()
        words_have = _pg_column_names(cur, "words") if words_exists else set()

    if not lessons_exists:
        parts = [
            "id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY",
            "bundle_id BIGINT NOT NULL REFERENCES public.vocabulary_bundles (id) ON DELETE CASCADE",
            "legacy_category_id BIGINT NOT NULL",
        ]
        for pg_name, pg_type, notnull, dflt in lesson_cols:
            parts.append(_create_column_line(pg_name, pg_type, notnull, dflt))
        parts.append("UNIQUE (bundle_id, legacy_category_id)")
        parts.append("UNIQUE (bundle_id, name_native)")
        create_sql = "CREATE TABLE public.lessons (\n  " + ",\n  ".join(parts) + "\n)"
        pg.execute(create_sql)
    else:
        for pg_name, pg_type, notnull, dflt in lesson_cols:
            if pg_name not in lessons_have:
                _alter_add_column_if_missing(pg, "lessons", pg_name, pg_type, notnull, dflt)

    if not words_exists:
        parts = [
            "id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY",
            "bundle_id BIGINT NOT NULL REFERENCES public.vocabulary_bundles (id) ON DELETE CASCADE",
            "lesson_id BIGINT REFERENCES public.lessons (id) ON DELETE SET NULL",
            "legacy_word_id BIGINT",
        ]
        for pg_name, pg_type, notnull, dflt in word_cols:
            parts.append(_create_column_line(pg_name, pg_type, notnull, dflt))
        create_sql = "CREATE TABLE public.words (\n  " + ",\n  ".join(parts) + "\n)"
        pg.execute(create_sql)
    else:
        for pg_name, pg_type, notnull, dflt in word_cols:
            if pg_name not in words_have:
                _alter_add_column_if_missing(pg, "words", pg_name, pg_type, notnull, dflt)

    _psycopg_exec_sql_script(pg, _COMMIT_FORCE_INDEX_RLS_DDL, "commit-force (indexes + RLS)")


def _psycopg_exec_sql_script(conn: object, sql_text: str, label: str) -> None:
    """Run semicolon-separated DDL/DML statements (psycopg 3 connection)."""
    stmts = _parse_migration_sql_statements(sql_text)
    for i, stmt in enumerate(stmts):
        try:
            conn.execute(stmt)
        except Exception:
            preview = stmt[:480] + ("…" if len(stmt) > 480 else "")
            print(
                f"[error] {label}: statement {i + 1}/{len(stmts)} failed:\n{preview}",
                file=sys.stderr,
            )
            raise


def run_commit_force(
    conn: sqlite3.Connection,
    project: str,
    key: str,
    db_path: str,
) -> None:
    """Derive Postgres ``lessons``/``words`` from SQLite PRAGMA, wipe this bundle, ``run_commit``."""
    _load_dotenv()
    dsn = (
        os.environ.get("DATABASE_URL", "").strip()
        or os.environ.get("SUPABASE_DB_URL", "").strip()
        or os.environ.get("POSTGRES_URL", "").strip()
    )
    if not dsn:
        print(
            "[error] --commit-force needs a direct Postgres connection string in the environment:\n"
            "        DATABASE_URL (recommended) or SUPABASE_DB_URL / POSTGRES_URL.\n"
            "        Supabase Dashboard → Project Settings → Database → Connection string → URI\n"
            "        (use the session mode or direct connection; not the REST URL).",
            file=sys.stderr,
        )
        sys.exit(1)
    try:
        import psycopg  # type: ignore
    except ImportError:
        print(
            "[error] --commit-force requires psycopg. Run: pip install psycopg[binary]",
            file=sys.stderr,
        )
        sys.exit(1)

    url, _api_key = _commit_resolve_supabase_url_and_key(project, key)
    native_code, translate_code = parse_db_lang_codes(db_path)
    native_app = DB_CODE_TO_APP_LANG.get(native_code, native_code.lower())
    transl_app = DB_CODE_TO_APP_LANG.get(translate_code, translate_code.lower())

    print("\nSupabase commit-force (Postgres DDL + delete bundle + REST reload)")
    print(f"  Schema:    from SQLite PRAGMA (category → lessons, word → words): {db_path}")
    print(f"  Postgres:  {dsn.split('@')[-1] if '@' in dsn else '(dsn)'}")
    print(f"  REST API:  {url}")
    print(f"  Wipe bundle where translate_lang={transl_app!r} native_lang={native_app!r}")

    with psycopg.connect(dsn, autocommit=False) as pg:
        print("  Applying Postgres schema derived from SQLite …")
        _apply_supabase_schema_from_sqlite(conn, pg)
        print("  Deleting vocabulary_bundles row (CASCADE → lessons, words) …")
        with pg.cursor() as cur:
            cur.execute(
                "DELETE FROM public.vocabulary_bundles "
                "WHERE translate_lang = %s AND native_lang = %s",
                (transl_app, native_app),
            )
            deleted = cur.rowcount
        print(f"  Deleted {deleted} bundle row(s).")
        pg.commit()

    print("  Loading from SQLite via REST (same as --commit) …")
    run_commit(conn, project, key, db_path)


def ensure_word_audio_columns(conn: sqlite3.Connection) -> None:
    """ALTER TABLE word ADD COLUMN for any AUDIO_FIELDS source (TEXT) or target (BLOB) missing."""
    have = {r[1] for r in conn.execute('PRAGMA table_info(word)').fetchall()}
    for pairs in AUDIO_FIELDS.values():
        for src, tgt in pairs:
            for col, typ in ((src, 'TEXT'), (tgt, 'BLOB')):
                if col in have:
                    continue
                try:
                    conn.execute(f'ALTER TABLE word ADD COLUMN {col} {typ}')
                    conn.commit()
                    have.add(col)
                except sqlite3.OperationalError:
                    pass


def _category_ids_referenced_by_words(
    conn: sqlite3.Connection, word_ids: set[int]
) -> set[int]:
    """SQLite ``category.id`` values referenced by the given ``word.id`` rows."""
    if not word_ids:
        return set()
    ph = ",".join("?" * len(word_ids))
    rows = conn.execute(
        f"SELECT DISTINCT category_index FROM word WHERE id IN ({ph})",
        list(word_ids),
    ).fetchall()
    out: set[int] = set()
    for r in rows:
        if r[0] is not None:
            out.add(int(r[0]))
    return out


def run_commit(
    conn: sqlite3.Connection,
    project: str,
    key: str,
    db_path: str,
    *,
    partial_category_ids: set[int] | None = None,
    partial_word_ids: set[int] | None = None,
    bundle_resolve_verbose: bool = True,
    echo_header: bool = True,
) -> None:
    """Upsert categories (→ lessons) and words (→ words) into Supabase.

    When ``partial_*`` are both ``None``, sync all rows. Otherwise sync only the
    listed SQLite ``category.id`` / ``word.id`` values; lessons for categories
    referenced by synced words are always upserted so ``lesson_id`` FK resolves.
    """
    try:
        from supabase import create_client  # type: ignore
    except ImportError:
        print('[error] supabase-py not installed. Run: pip install supabase')
        sys.exit(1)

    url, key = _commit_resolve_supabase_url_and_key(project, key)

    native_code, translate_code = parse_db_lang_codes(db_path)
    native_app  = DB_CODE_TO_APP_LANG.get(native_code,    native_code.lower())
    transl_app  = DB_CODE_TO_APP_LANG.get(translate_code, translate_code.lower())

    sb = create_client(url, key)
    if echo_header:
        print(f'\nSupabase commit → {url}')
        print(f'  Language pair: {native_app} / {transl_app}')

    bundle_id = _vocabulary_bundle_lookup_or_create(
        sb, db_path, native_app, transl_app, verbose=bundle_resolve_verbose
    )

    partial = partial_category_ids is not None or partial_word_ids is not None
    cat_ids_filter: set[int] | None = None
    word_ids_filter: set[int] | None = None
    if partial:
        cats_explicit = set(partial_category_ids or ())
        words_explicit = set(partial_word_ids or ())
        cat_ids_filter = cats_explicit | _category_ids_referenced_by_words(conn, words_explicit)
        word_ids_filter = words_explicit
        if not cat_ids_filter and not word_ids_filter:
            print(
                "[error] Partial commit: no category_ids or word_ids to sync.",
                file=sys.stderr,
            )
            sys.exit(1)
        print(
            f'  Partial sync: {len(cat_ids_filter)} lesson row(s), {len(word_ids_filter)} word row(s) '
            f'(SQLite category.id / word.id; includes categories for word FKs)'
        )

    # ── lessons (category) ───────────────────────────────────────────────────
    conn.row_factory = sqlite3.Row
    cats = conn.execute('SELECT * FROM category').fetchall()
    if partial and cat_ids_filter is not None:
        cats = [c for c in cats if int(c['id']) in cat_ids_filter]
    print(f'  Upserting {len(cats)} categories → lessons…')
    lesson_rows = [
        {
            'bundle_id':          bundle_id,
            'legacy_category_id': cat['id'],
            'name_native':        cat['name_native']    or '',
            'name_translate':     cat['name_translate'] or '',
            'name_en':            cat['name_EN']        or '',
            'lesson_id':          cat['lesson_id']      or 0,
            'user_id':            int(float(cat['user_id'] or 0)) if 'user_id' in cat.keys() else 0,
            'language_tag':       cat['language_tag'],
            'lang_translate':     cat['lang_translate']
            if 'lang_translate' in cat.keys()
            else None,
            'lang_native':        cat['lang_native']
            if 'lang_native' in cat.keys()
            else None,
            'access':             cat['access']         or 0,
            'difficulty':         cat['difficulty']     or 0,
            'date_created':       cat['date_created'],
            'date_modified':      cat['date_modified'],
            'count':              cat['count']          or 0,
            'count_down':         cat['count_down']     or 5,
            'practice_type':      cat['practice_type']  or 0,
            'challenge':          cat['challenge']      or 0,
            'photo':              cat['photo'],
            'is_favorite':        cat['is_favorite']    or 0,
        }
        for cat in cats
    ]
    _upsert_pages(
        sb,
        'lessons',
        lesson_rows,
        'lessons',
        on_conflict='bundle_id,legacy_category_id',
    )

    # Map SQLite category.id → Postgres lessons.id (required FK on words.lesson_id).
    lesson_pg_by_legacy: dict[int, int] = {}
    for lr in _sb_select_all_eq(sb, 'lessons', 'id,legacy_category_id', 'bundle_id', bundle_id):
        lc = lr.get('legacy_category_id')
        if lc is not None:
            lesson_pg_by_legacy[int(lc)] = int(lr['id'])

    # Map SQLite word.id → Postgres words.id so upsert merges on PK (schema has no UNIQUE on
    # bundle_id+legacy_word_id; without ``id``, PostgREST only conflicts on PK and each row INSERTs).
    word_pg_by_legacy: dict[int, int] = {}
    for wr in _sb_select_all_eq(sb, 'words', 'id,legacy_word_id', 'bundle_id', bundle_id):
        lw = wr.get('legacy_word_id')
        if lw is not None:
            word_pg_by_legacy[int(lw)] = int(wr['id'])

    # ── words ────────────────────────────────────────────────────────────────
    words = conn.execute('SELECT * FROM word').fetchall()
    if partial and word_ids_filter is not None:
        words = [w for w in words if int(w['id']) in word_ids_filter]
    print(f'  Upserting {len(words)} words…')
    word_rows: list[dict] = []
    for w in words:
        wid = int(w['id'])
        cat_ix = w['category_index']
        lesson_fk = None
        if cat_ix is not None:
            lesson_fk = lesson_pg_by_legacy.get(int(cat_ix))

        row: dict = {
            'bundle_id':               bundle_id,
            'legacy_word_id':          wid,
            'lesson_id':               lesson_fk,
            'legacy_category_index':   cat_ix,
            'name_native':             w['name_native']             or '',
            'name_translate':          w['name_translate']          or '',
            'name_en':                 w['name_EN']                 or '',
            'roman_native':            w['roman_native'],
            'roman_translate':         w['roman_translate'],
            'audio_translate':         _row_blob_hex(w, 'audio_translate'),
            'audio_native':            _row_blob_hex(w, 'audio_native'),
            'definition_native':       w['definition_native'],
            'action_native':           w['action_native'],
            'definition_translate':    w['definition_translate'],
            'action_translate':        w['action_translate'],
            'sample1_native':          w['sample1_native'],
            'sample1_translate':       w['sample1_translate'],
            'sample1_translate_roman': w['sample1_translate_roman'],
            'sample1_native_audio':    _row_blob_hex(w, 'sample1_native_audio'),
            'sample1_translate_audio': _row_blob_hex(w, 'sample1_translate_audio'),
            'photo':                   w['photo'],
            'date_created':            w['date_created'],
            'date_modified':           w['date_modified'],
            'use_count':               w['use_count']               or 0,
            'is_favorite':             w['is_favorite']             or 0,
            'user_id':                 int(float(w['user_id'] or 0)) if 'user_id' in w.keys() else 0,
            'correct_count':           int(w['correct_count'] or 0) if 'correct_count' in w.keys() else 0,
            'hint':                    w['hint'] if 'hint' in w.keys() else None,
        }
        pg_id = word_pg_by_legacy.get(wid)
        if pg_id is not None:
            row['id'] = pg_id
        word_rows.append(row)
    _upsert_pages(sb, 'words', word_rows, 'words')

    print('\n  Commit complete.')


def _upsert_pages(
    sb,
    table: str,
    rows: list[dict],
    label: str,
    *,
    on_conflict: str = '',
) -> None:
    """Bulk upsert. ``on_conflict`` must list columns of a UNIQUE constraint (PostgREST)."""
    total = len(rows)
    if not total:
        print(f'  No rows for {label}.')
        return
    for i in range(0, total, PAGE_SIZE):
        chunk = rows[i: i + PAGE_SIZE]
        try:
            q = sb.table(table).upsert(chunk, on_conflict=on_conflict) if on_conflict else sb.table(
                table
            ).upsert(chunk)
            q.execute()
        except Exception as ex:
            low = str(ex).lower()
            if 'row-level security' in low or '42501' in str(ex):
                print(
                    '\n[error] RLS blocked this upsert. Use the service_role JWT '
                    '(Dashboard -> Settings -> API -> service_role), not the anon key: '
                    'SUPABASE_SERVICE_ROLE_KEY, supabase_service_role_key.txt, or --key.',
                    file=sys.stderr,
                )
            if '23505' in str(ex) and 'duplicate key' in low:
                print(
                    '\n[error] Duplicate key: upsert needs matching on_conflict for your '
                    'table unique constraint (dbutil sets this for lessons).',
                    file=sys.stderr,
                )
            raise
        _progress(min(i + PAGE_SIZE, total), total, label)
    print()


# ── CLI ───────────────────────────────────────────────────────────────────────

def _ensure_dimago_db_scripts_path() -> None:
    """Put this directory on ``sys.path`` so ``import dbview`` resolves next to ``dbutil.py``."""
    sd = str(Path(__file__).resolve().parent)
    if sd not in sys.path:
        sys.path.insert(0, sd)


def _launch_dbview(args: argparse.Namespace) -> None:
    """Delegate to ``dbview.run_view_from_dbutil_namespace`` (GUI code stays in ``dbview.py``)."""
    _ensure_dimago_db_scripts_path()
    import dbview as _dbview  # noqa: PLC0415

    _dbview.ensure_dimago_db_scripts_on_path()
    _dbview.run_view_from_dbutil_namespace(args)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog='dbutil',
        description='DimaGo DB Utility — add romanization / TTS audio, sync to Supabase',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument(
        '--input',
        metavar='FILE',
        default=None,
        help='SQLite DB file, e.g. dict_TH_CN.db (required unless --view with no initial file)',
    )
    p.add_argument(
        '--view',
        action='store_true',
        help='Open graphical DB browser (tkinter): browse/edit SQLite or Postgres, Supabase '
             'commit, schema migration — same features as dbview.py.',
    )
    p.add_argument(
        '--view-postgres',
        action='store_true',
        help='With --view: connect using DATABASE_URL (dbutil/.env, .env.local, or environment).',
    )
    p.add_argument(
        '--database-url',
        metavar='DSN',
        default=None,
        help='With --view: Postgres connection URI (overrides DATABASE_URL; opens in Postgres mode).',
    )
    p.add_argument('--lesson', metavar='NAME',
                   help='Roman/audio: category filter — comma-separated category.id (e.g. 3 or 3,5), '
                   'or a lesson name matching name_EN / name_native / name_translate '
                   '(name match with no hit processes all words). '
                   'Introspection (--input only): match category by name_EN; word name_EN list.')
    p.add_argument('--lesson-show', metavar='FIELD', type=_parse_lesson_show_field,
                   default=None,
                   help='With only --input: list category.name_native, name_translate, or name_EN '
                   'for all rows (FIELD = native | translate | EN).')
    p.add_argument('--roman', action='store_true',
                   help='Fill roman_* columns; Thai vs Chinese from each source cell '
                   '(name_native → roman_native, name_translate → roman_translate, '
                   'sample1_translate → sample1_translate_roman).')
    p.add_argument('--audio', action='store_true',
                   help='TTS: name_native→audio_native, sample1_native→sample1_native_audio; '
                   'name_translate→audio_translate, sample1_translate→sample1_translate_audio. '
                   'Langs from dict_<TRANSLATE>_<NATIVE>.db (Flutter pair filename; '
                   '*_translate columns use first code, *_native the second).')
    p.add_argument('--commit', metavar='PROJECT', nargs='?', const='',
                   help='Sync local SQLite to Supabase. If HARDCODED_SUPABASE_SERVICE_ROLE_KEY '
                   'is set in dbutil.py, URL/key come from there (optional PROJECT overrides URL). '
                   'Else optional project ref or https URL; bare --commit uses env / defaults.')
    p.add_argument(
        '--commit-force',
        action='store_true',
        help=(
            'Postgres (DATABASE_URL): build lessons/words columns from this SQLite file '
            '(PRAGMA on category and word), apply RLS/indexes, delete this language-pair '
            'vocabulary_bundles row (CASCADE lessons and words), then run a full --commit. '
            'Requires --yes. Other bundles untouched.'
        ),
    )
    p.add_argument(
        '--yes',
        action='store_true',
        help='Confirm destructive --commit-force.',
    )
    p.add_argument('--key', metavar='KEY',
                   help='Supabase JWT for --commit: prefer service_role (bypasses RLS). '
                   'Else SUPABASE_SERVICE_ROLE_KEY, supabase_service_role_key.txt, '
                   'then SUPABASE_KEY / supabase_anon_key.txt.')
    p.add_argument(
        '--commit-modified',
        metavar='FILE',
        default=None,
        help='With --commit: JSON {"category_ids": [..], "word_ids": [..]} — SQLite category.id '
             'and word.id rows to upsert only; lessons for words\' category_index are included.',
    )
    p.add_argument(
        '--commit-sync',
        action='store_true',
        help='With --commit: compare local SQLite to this vocabulary bundle on Supabase and upsert '
             'only lessons/words that differ or are missing remotely (not a full re-push of every row). '
             'Does not delete extra remote-only rows.',
    )
    p.add_argument('--force', action='store_true',
                   help='Re-generate romanization / TTS even when targets are filled '
                   '(whitespace-only roman counts as empty; non-empty audio BLOBs overwritten).')
    return p


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    if args.view:
        conflicts: list[str] = []
        if args.roman:
            conflicts.append('--roman')
        if args.audio:
            conflicts.append('--audio')
        if args.commit is not None:
            conflicts.append('--commit')
        if args.commit_force:
            conflicts.append('--commit-force')
        if args.lesson_show is not None:
            conflicts.append('--lesson-show')
        if args.lesson:
            conflicts.append('--lesson')
        if args.force:
            conflicts.append('--force')
        if args.commit_modified:
            conflicts.append('--commit-modified')
        if args.commit_sync:
            conflicts.append('--commit-sync')
        if args.yes:
            conflicts.append('--yes')
        if conflicts:
            print(
                '[error] --view cannot be combined with: ' + ', '.join(conflicts),
                file=sys.stderr,
            )
            sys.exit(2)
        _launch_dbview(args)
        return

    db_path = args.input
    if not db_path:
        print(
            '[error] --input is required unless you use --view for the graphical browser.',
            file=sys.stderr,
        )
        sys.exit(1)
    if not Path(db_path).exists():
        print(f'[error] File not found: {db_path}')
        sys.exit(1)

    if args.commit_modified and args.commit is None:
        print('[error] --commit-modified requires --commit', file=sys.stderr)
        sys.exit(1)
    if args.commit_sync and args.commit is None:
        print('[error] --commit-sync requires --commit', file=sys.stderr)
        sys.exit(1)
    if args.commit_sync and args.commit_modified:
        print(
            '[error] --commit-sync cannot be used with --commit-modified',
            file=sys.stderr,
        )
        sys.exit(1)
    if args.commit_sync and args.commit_force:
        print(
            '[error] --commit-sync cannot be used with --commit-force',
            file=sys.stderr,
        )
        sys.exit(1)

    native_code, translate_code = parse_db_lang_codes(db_path)
    print('DimaGo DBUtil')
    print(f'  DB:     {db_path}')
    print(f'  Codes:  native={native_code}  translate={translate_code}')
    if args.lesson:
        print(f'  Lesson: {args.lesson}')
    if args.lesson_show is not None:
        print(f'  Lesson-show: {args.lesson_show}')
    if args.force:
        print('  Mode:   --force (overwriting existing values)')
    if args.commit_force:
        print('  Mode:   --commit-force (Postgres schema from SQLite PRAGMA + wipe bundle + REST)')
    if args.commit_sync:
        print('  Mode:   --commit-sync (diff vs Supabase; upsert changed/missing rows only)')

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row

    try:
        # Use ``is None``: bare ``--commit`` sets commit to ``''`` (const), which must
        # not be treated as “no commit” (``not ''`` is true and wrongly showed schema).
        if not args.roman and not args.audio and args.commit is None and not args.commit_force:
            if args.lesson_show is not None:
                run_show_category_lesson_names(conn, args.lesson_show)
            elif args.lesson:
                run_list_words_for_lesson_en(conn, args.lesson)
            else:
                run_show_schema(conn)
            return

        if args.roman:
            run_roman(conn, args.lesson, args.force)

        if args.audio:
            run_audio(conn, db_path, args.lesson, args.force)

        if args.commit_force:
            if not args.yes:
                print(
                    '[error] --commit-force deletes remote bundle data for this SQLite language pair. '
                    'Add --yes to confirm.',
                    file=sys.stderr,
                )
                sys.exit(1)
            proj = '' if args.commit is None else args.commit
            run_commit_force(conn, proj, (args.key or '').strip(), db_path)
        elif args.commit is not None:
            key = (args.key or '').strip()
            if args.commit_sync:
                run_commit_sync(conn, args.commit, key, db_path)
            elif args.commit_modified:
                mod_path = Path(args.commit_modified)
                if not mod_path.is_file():
                    print(
                        f'[error] --commit-modified file not found: {mod_path}',
                        file=sys.stderr,
                    )
                    sys.exit(1)
                try:
                    data = json.loads(mod_path.read_text(encoding='utf-8'))
                except json.JSONDecodeError as e:
                    print(
                        f'[error] Invalid JSON in {mod_path}: {e}',
                        file=sys.stderr,
                    )
                    sys.exit(1)
                cats = {int(x) for x in (data.get('category_ids') or [])}
                wrds = {int(x) for x in (data.get('word_ids') or [])}
                run_commit(
                    conn,
                    args.commit,
                    key,
                    db_path,
                    partial_category_ids=cats,
                    partial_word_ids=wrds,
                )
            else:
                run_commit(conn, args.commit, key, db_path)

    finally:
        conn.close()


if __name__ == '__main__':
    main()
