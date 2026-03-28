#!/usr/bin/env python3
"""
dict_gen.py - Thai Dictionary Multi-Language Translator
Reads dictionary.json, translates English to 12 languages + Chinese Pinyin,
and saves everything to translation.db (SQLite).

Usage:
    python dict_gen.py
    python dict_gen.py --input dictionary.json --output translation.db
"""

import json
import sqlite3
import time
import argparse
import sys
import os
import urllib.request
import urllib.parse
import urllib.error

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
DEFAULT_INPUT  = "dictionary.json"
DEFAULT_OUTPUT = "translation.db"

# Language codes for Google Translate
LANGUAGES = {
    "chinese_simplified": "zh-CN",
    "chinese_traditional": "zh-TW",
    "german":    "de",
    "french":    "fr",
    "spanish":   "es",
    "italian":   "it",
    "russian":   "ru",
    "ukrainian": "uk",
    "hebrew":    "iw",
    "japanese":  "ja",
    "korean":    "ko",
    "burmese":   "my",
}

# Human-readable column labels (used in the CREATE TABLE comment / display)
COLUMN_LABELS = {
    "chinese_simplified":  "中文简体(Chinese)",
    "chinese_traditional": "中文繁体(Taiwan)",
    "german":    "德语(German)",
    "french":    "法语(French)",
    "spanish":   "西班牙语(Spanish)",
    "italian":   "意大利语(Italian)",
    "russian":   "俄语(Russian)",
    "ukrainian": "乌克兰语(Ukrainian)",
    "hebrew":    "希伯来语(Hebrew)",
    "japanese":  "日语(Japanese)",
    "korean":    "韩语(Korean)",
    "burmese":   "缅甸语(Burmese)",
    "roman_cn":  "Roman-CN(拼音)",
}

DELAY_BETWEEN_REQUESTS = 0.3   # seconds between Google API calls

# ---------------------------------------------------------------------------
# Google Translate (free, no API key required)
# ---------------------------------------------------------------------------
def google_translate(text: str, target_lang: str, src_lang: str = "en") -> str:
    """Translate text using Google Translate free endpoint."""
    if not text or not text.strip():
        return ""
    url = "https://translate.googleapis.com/translate_a/single"
    params = urllib.parse.urlencode({
        "client": "gtx",
        "sl": src_lang,
        "tl": target_lang,
        "dt": "t",
        "q": text,
    })
    full_url = f"{url}?{params}"
    headers = {
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/120.0.0.0 Safari/537.36"
        )
    }
    try:
        req = urllib.request.Request(full_url, headers=headers)
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        parts = []
        for segment in data[0]:
            if segment[0]:
                parts.append(segment[0])
        return "".join(parts)
    except Exception as e:
        print(f"  [WARN] Translation failed for '{text}' -> {target_lang}: {e}")
        return ""


# ---------------------------------------------------------------------------
# Pinyin generator
# ---------------------------------------------------------------------------
def get_pinyin(chinese_text: str) -> str:
    """Convert Chinese text to Pinyin. Uses pypinyin if available, else Google TTS."""
    if not chinese_text:
        return ""
    try:
        from pypinyin import pinyin, Style
        result = pinyin(chinese_text, style=Style.TONE)
        return " ".join([p[0] for p in result])
    except ImportError:
        pass
    # Fallback: use Google Translate romanization endpoint
    try:
        url = "https://translate.googleapis.com/translate_a/single"
        params = urllib.parse.urlencode({
            "client": "gtx",
            "sl": "zh-CN",
            "tl": "zh-CN",
            "dt": "rm",     # 'rm' = romanization
            "q": chinese_text,
        })
        full_url = f"{url}?{params}"
        headers = {"User-Agent": "Mozilla/5.0"}
        req = urllib.request.Request(full_url, headers=headers)
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        # Romanization is in data[0][i][3]
        parts = []
        for segment in data[0]:
            if len(segment) > 3 and segment[3]:
                parts.append(segment[3])
        return " ".join(parts) if parts else ""
    except Exception as e:
        print(f"  [WARN] Pinyin fallback failed for '{chinese_text}': {e}")
        return ""


# ---------------------------------------------------------------------------
# SQLite helpers
# ---------------------------------------------------------------------------
def init_db(db_path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS translations (
            id                  INTEGER PRIMARY KEY,
            thai                TEXT,
            roman               TEXT,
            english             TEXT,
            category            TEXT,
            chinese_simplified  TEXT,
            chinese_traditional TEXT,
            german              TEXT,
            french              TEXT,
            spanish             TEXT,
            italian             TEXT,
            russian             TEXT,
            ukrainian           TEXT,
            hebrew              TEXT,
            japanese            TEXT,
            korean              TEXT,
            burmese             TEXT,
            roman_cn            TEXT
        )
    """)
    conn.commit()
    return conn


def upsert_row(conn: sqlite3.Connection, row: dict):
    """Insert or replace a row in the translations table."""
    conn.execute("""
        INSERT OR REPLACE INTO translations
            (id, thai, roman, english, category,
             chinese_simplified, chinese_traditional,
             german, french, spanish, italian,
             russian, ukrainian, hebrew, japanese, korean, burmese,
             roman_cn)
        VALUES
            (:id, :thai, :roman, :english, :category,
             :chinese_simplified, :chinese_traditional,
             :german, :french, :spanish, :italian,
             :russian, :ukrainian, :hebrew, :japanese, :korean, :burmese,
             :roman_cn)
    """, row)
    conn.commit()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Translate Thai dictionary English field to multiple languages."
    )
    parser.add_argument(
        "--input", "-i",
        default=DEFAULT_INPUT,
        help=f"Input JSON file (default: {DEFAULT_INPUT})"
    )
    parser.add_argument(
        "--output", "-o",
        default=DEFAULT_OUTPUT,
        help=f"Output SQLite DB file (default: {DEFAULT_OUTPUT})"
    )
    parser.add_argument(
        "--resume", action="store_true",
        help="Skip rows that already have chinese_simplified populated"
    )
    args = parser.parse_args()

    # Resolve paths relative to script location
    script_dir = os.path.dirname(os.path.abspath(__file__))
    input_path  = args.input  if os.path.isabs(args.input)  else os.path.join(script_dir, args.input)
    output_path = args.output if os.path.isabs(args.output) else os.path.join(script_dir, args.output)

    # Load JSON
    print(f"Reading: {input_path}")
    with open(input_path, "r", encoding="utf-8") as f:
        entries = json.load(f)
    total = len(entries)
    print(f"Loaded {total} entries.\n")

    # Init DB
    conn = init_db(output_path)
    print(f"Database: {output_path}\n")

    # Check existing IDs if --resume
    existing_ids = set()
    if args.resume:
        rows = conn.execute(
            "SELECT id FROM translations WHERE chinese_simplified IS NOT NULL AND chinese_simplified != ''"
        ).fetchall()
        existing_ids = {r["id"] for r in rows}
        print(f"Resume mode: {len(existing_ids)} rows already translated.\n")

    lang_keys = list(LANGUAGES.keys())

    for idx, entry in enumerate(entries, start=1):
        entry_id   = entry.get("id", idx)
        thai       = entry.get("thai", "")
        roman      = entry.get("roman", "")
        english    = entry.get("english", "")
        category   = entry.get("category", "")

        if args.resume and entry_id in existing_ids:
            print(f"[{idx}/{total}] ID={entry_id} skip (already done)")
            continue

        print(f"[{idx}/{total}] ID={entry_id} | {english[:40]:<40}", end=" ", flush=True)

        translations = {}
        for lang_key in lang_keys:
            lang_code = LANGUAGES[lang_key]
            translated = google_translate(english, lang_code)
            translations[lang_key] = translated
            print(".", end="", flush=True)
            time.sleep(DELAY_BETWEEN_REQUESTS)

        # Generate Pinyin from Simplified Chinese
        cn_simplified = translations.get("chinese_simplified", "")
        roman_cn = get_pinyin(cn_simplified) if cn_simplified else ""
        time.sleep(DELAY_BETWEEN_REQUESTS)

        row = {
            "id":                   entry_id,
            "thai":                 thai,
            "roman":                roman,
            "english":              english,
            "category":             category,
            "chinese_simplified":   translations.get("chinese_simplified", ""),
            "chinese_traditional":  translations.get("chinese_traditional", ""),
            "german":               translations.get("german", ""),
            "french":               translations.get("french", ""),
            "spanish":              translations.get("spanish", ""),
            "italian":              translations.get("italian", ""),
            "russian":              translations.get("russian", ""),
            "ukrainian":            translations.get("ukrainian", ""),
            "hebrew":               translations.get("hebrew", ""),
            "japanese":             translations.get("japanese", ""),
            "korean":               translations.get("korean", ""),
            "burmese":              translations.get("burmese", ""),
            "roman_cn":             roman_cn,
        }
        upsert_row(conn, row)
        print(f" ✓ CN={cn_simplified[:10] if cn_simplified else '?'} | PY={roman_cn[:15] if roman_cn else '?'}")

    conn.close()
    print(f"\nDone! All {total} entries saved to {output_path}")
    print("\nColumns in translations table:")
    for key, label in COLUMN_LABELS.items():
        print(f"  {key:<25} -> {label}")


if __name__ == "__main__":
    main()
