#!/usr/bin/env python3
"""
Import DimaGo dict_*.db + dict_photo.db from GitHub (or local files) into Supabase Postgres.

Prereq: run schema_dimago.sql in the Supabase SQL editor.

  pip install -r requirements-migrate.txt

  Supabase DATABASE_URL (use the password from Dashboard → Database, not the anon key):

  • Direct (IPv6 only): postgresql://postgres:PASSWORD@db.PROJECT_REF.supabase.co:5432/postgres

  • Session pooler (IPv4 + IPv6): user MUST be postgres.PROJECT_REF on the pooler host:
    postgresql://postgres.PROJECT_REF:PASSWORD@aws-0-REGION.pooler.supabase.com:5432/postgres
    Copy the exact “Session pooler” URI from Connect. Plain “postgres” as user → FATAL: Tenant or user not found.

  If your password has @ or other reserved characters, URL-encode it in the URI.

  python migrate_sqlite_to_supabase.py --all-github
  python migrate_sqlite_to_supabase.py --file dict_TH_CN.db --replace

Steps:
  1. Run schema_dimago.sql in the Supabase SQL editor.
  2. Set DATABASE_URL (session pooler URI or direct URI).
  3. pip install -r requirements-migrate.txt
  4. python migrate_sqlite_to_supabase.py --all-github --photo-github [--replace]
  Optional: --local-dir path\\to\\repo  to read dict_*.db from disk (no download).
"""

from __future__ import annotations

import argparse
import os
import re
import sqlite3
import sys
import tempfile
import shutil
from urllib.parse import unquote, urlparse
from pathlib import Path
from typing import Any
from urllib.request import Request, urlopen

import psycopg

GITHUB_RAW = "https://raw.githubusercontent.com/donhsi1/dimago/main"
GITHUB_API = "https://api.github.com/repos/donhsi1/dimago/contents"


def validate_pooler_username(dsn: str) -> None:
    """Supavisor session pooler requires user postgres.<project_ref>, not bare postgres."""
    try:
        parsed = urlparse(dsn)
    except Exception:
        return
    host = (parsed.hostname or "").lower()
    if "pooler.supabase.com" not in host:
        return
    user = unquote(parsed.username or "")
    parts = user.split(".", 1)
    if len(parts) == 2 and parts[0] == "postgres" and parts[1]:
        return
    print(
        "Invalid DATABASE_URL for Supabase Pooler (Session mode, port 5432).\n"
        "The database user must include your project ref, e.g.:\n"
        "  postgresql://postgres.YOUR_PROJECT_REF:YOUR_PASSWORD@aws-0-REGION.pooler.supabase.com:5432/postgres\n"
        "Copy the full URI from Supabase Dashboard → Connect → Session pooler.\n"
        "Using user `postgres` alone causes: FATAL: Tenant or user not found.\n"
        "If your password contains @ # / etc., URL-encode it in the connection string.",
        file=sys.stderr,
    )
    sys.exit(1)

# Mirrors lib/lang_db_service.dart _code() — token in filename → app language code.
TOKEN_TO_APP: dict[str, str] = {
    "TH": "th",
    "CN": "zh_CN",
    "TW": "zh_TW",
    "EN": "en_US",
    "FR": "fr",
    "DE": "de",
    "IT": "it",
    "ES": "es",
    "JA": "ja",
    "KO": "ko",
    "MY": "my",
    "HE": "he",
    "RU": "ru",
    "UK": "uk",
    "VI": "vi",
}


def token_to_lang(token: str) -> str:
    return TOKEN_TO_APP.get(token.upper(), token.lower())


def parse_db_filename(name: str) -> tuple[str, str] | None:
    if name == "dict_photo.db":
        return None
    m = re.match(r"dict_([A-Z]{2})_([A-Z]{2})\.db$", name, re.I)
    if m:
        return token_to_lang(m.group(1)), token_to_lang(m.group(2))
    m = re.match(r"dict_([A-Z]{2})\.db$", name, re.I)
    if m:
        t = token_to_lang(m.group(1))
        return t, t
    return "unknown", "unknown"


def http_get_bytes(url: str) -> bytes:
    req = Request(url, headers={"User-Agent": "dimago-supabase-migrate/1.0"})
    with urlopen(req, timeout=120) as resp:
        return resp.read()


def list_github_dict_dbs() -> list[str]:
    import json

    req = Request(
        f"{GITHUB_API}?ref=main",
        headers={"User-Agent": "dimago-supabase-migrate/1.0", "Accept": "application/vnd.github+json"}
    )
    with urlopen(req, timeout=60) as resp:
        data = json.load(resp)
    names: list[str] = []
    for item in data:
        n = item.get("name", "")
        if re.match(r"dict_.+\.db$", n) and n != "dict_photo.db":
            names.append(n)
    return sorted(names)


def as_bytea(val: Any) -> bytes | None:
    if val is None:
        return None
    if isinstance(val, bytes):
        return val
    if isinstance(val, memoryview):
        return val.tobytes()
    return None


def sqlite_cols(cur: sqlite3.Cursor, table: str) -> set[str]:
    cur.execute(f'PRAGMA table_info("{table}")')
    return {row[1] for row in cur.fetchall()}


def detect_schema(cur: sqlite3.Cursor) -> str:
    cur.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
    )
    tables = {r[0] for r in cur.fetchall()}
    if "word" not in tables:
        return "unknown"
    w = sqlite_cols(cur, "word")
    if "category" in tables:
        c = sqlite_cols(cur, "category")
        if "name_native" in c and "name_native" in w:
            return "full"
        if "name" in c and "word" in w:
            return "legacy_simple"
    if "word" in w and "name_native" not in w:
        return "minimal_word"
    return "unknown"


def delete_bundle_cur(cur_pg: psycopg.Cursor, source_filename: str) -> None:
    cur_pg.execute("DELETE FROM vocabulary_bundles WHERE source_filename = %s", (source_filename,))


def insert_bundle(cur_pg: psycopg.Cursor, translate_lang: str, native_lang: str, source_filename: str) -> int:
    cur_pg.execute(
        """
        INSERT INTO vocabulary_bundles (translate_lang, native_lang, source_filename)
        VALUES (%s, %s, %s)
        RETURNING id
        """,
        (translate_lang, native_lang, source_filename),
    )
    row = cur_pg.fetchone()
    assert row
    return int(row[0])


LESSON_INSERT_FULL = """
INSERT INTO lessons (
  bundle_id, legacy_category_id, name_native, name_translate, name_en,
  lesson_id, user_id, language_tag, lang_translate, lang_native, access, difficulty,
  date_created, date_modified, count, count_down,
  practice_type, challenge, photo, is_favorite
) VALUES (
  %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s
)
RETURNING id
"""

# Matches scripts/supabase/schema_dimago.sql `words`.
WORDS_INSERT_SQL = """
INSERT INTO words (
  bundle_id, lesson_id, legacy_word_id, name_native, name_translate, name_en,
  roman_native, roman_translate, audio_translate, audio_native,
  definition_native, action_native, definition_translate, action_translate,
  sample1_native, sample1_translate, sample1_translate_roman,
  sample1_native_audio, sample1_translate_audio,
  legacy_category_index, photo, user_id, date_created, date_modified,
  use_count, is_favorite, correct_count, hint
) VALUES (
  %s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s
)
"""


def import_full_pair(cur_sl: sqlite3.Cursor, cur_pg: psycopg.Cursor, bundle_id: int) -> None:
    cur_sl.row_factory = sqlite3.Row
    lesson_by_legacy: dict[int, int] = {}
    cur_sl.execute("SELECT * FROM category ORDER BY id")
    for row in cur_sl.fetchall():
        lid = int(row["id"])
        cur_pg.execute(
            LESSON_INSERT_FULL,
            (
                bundle_id,
                lid,
                row["name_native"],
                row["name_translate"],
                row["name_EN"],
                int(row["lesson_id"] or 0),
                int(float(row["user_id"] or 0)),
                row["language_tag"],
                row["lang_translate"] if "lang_translate" in row.keys() else None,
                row["lang_native"] if "lang_native" in row.keys() else None,
                int(row["access"] or 0),
                int(row["difficulty"] or 0),
                row["date_created"],
                row["date_modified"],
                int(row["count"] or 0),
                int(row["count_down"] or 5),
                row["practice_type"],
                int(row["challenge"] or 0),
                row["photo"],
                int(row["is_favorite"] or 0),
            ),
        )
        lesson_by_legacy[lid] = int(cur_pg.fetchone()[0])

    cur_sl.execute("PRAGMA table_info(word)")
    word_col_set = {r[1] for r in cur_sl.fetchall()}

    cur_sl.execute("SELECT * FROM word ORDER BY id")
    for row in cur_sl.fetchall():
        cid = row["category_index"]
        lesson_fk = lesson_by_legacy.get(int(cid)) if cid is not None else None

        def opt(col: str) -> Any:
            return row[col] if col in word_col_set else None

        cur_pg.execute(
            WORDS_INSERT_SQL,
            (
                bundle_id,
                lesson_fk,
                int(row["id"]),
                row["name_native"],
                row["name_translate"],
                row["name_EN"],
                row["roman_native"],
                row["roman_translate"],
                as_bytea(row["audio_translate"]),
                as_bytea(row["audio_native"]) if "audio_native" in word_col_set else None,
                opt("definition_native"),
                opt("action_native"),
                opt("definition_translate"),
                opt("action_translate"),
                opt("sample1_native"),
                opt("sample1_translate"),
                opt("sample1_translate_roman"),
                as_bytea(opt("sample1_native_audio")),
                as_bytea(opt("sample1_translate_audio")),
                int(row["category_index"]) if row["category_index"] is not None else None,
                row["photo"],
                int(row["user_id"] or 0),
                str(row["date_created"]) if row["date_created"] is not None else None,
                row["date_modified"],
                int(row["use_count"] or 0),
                int(row["is_favorite"] or 0),
                int(opt("correct_count") or 0),
                opt("hint"),
            ),
        )


def _legacy_word_col(row: sqlite3.Row, cols: set[str], name: str, default: Any = None) -> Any:
    if name not in cols:
        return default
    return row[name]


def import_legacy_simple(cur_sl: sqlite3.Cursor, cur_pg: psycopg.Cursor, bundle_id: int) -> None:
    cur_sl.row_factory = sqlite3.Row
    cur_sl.execute("PRAGMA table_info(word)")
    word_cols = {r[1] for r in cur_sl.fetchall()}

    cur_sl.execute("SELECT id, name FROM category ORDER BY id")
    lesson_by_legacy: dict[int, int] = {}
    for row in cur_sl.fetchall():
        cid = int(row["id"])
        name = row["name"] or ""
        cur_pg.execute(
            LESSON_INSERT_FULL,
            (
                bundle_id,
                cid,
                name,
                name,
                name,
                0,
                0,
                None,
                None,
                None,
                0,
                0,
                None,
                None,
                0,
                5,
                None,
                0,
                None,
                0,
            ),
        )
        lesson_by_legacy[cid] = int(cur_pg.fetchone()[0])

    cur_sl.execute("SELECT id, name FROM category")
    name_to_cid = {str(r["name"]): int(r["id"]) for r in cur_sl.fetchall()}

    cur_sl.execute("SELECT * FROM word ORDER BY id")
    for row in cur_sl.fetchall():
        cname = _legacy_word_col(row, word_cols, "category")
        cid = name_to_cid.get(str(cname)) if cname is not None else None
        lesson_fk = lesson_by_legacy.get(cid) if cid is not None else None
        w = (_legacy_word_col(row, word_cols, "word", "") or "") or ""
        roman = _legacy_word_col(row, word_cols, "roman")

        audio_tr: bytes | None = None
        if "audio" in word_cols:
            audio_tr = as_bytea(row["audio"])
        elif "audio_translation" in word_cols:
            audio_tr = as_bytea(row["audio_translation"])
        audio_nat = (
            as_bytea(row["audio_native"]) if "audio_native" in word_cols else None
        )

        definition = _legacy_word_col(row, word_cols, "definition")
        action = _legacy_word_col(row, word_cols, "action")
        s1 = _legacy_word_col(row, word_cols, "sample1")

        user_id = int(_legacy_word_col(row, word_cols, "user_id", 0) or 0)
        date_created = _legacy_word_col(row, word_cols, "date_created")
        date_modified = _legacy_word_col(row, word_cols, "date_modified")
        use_count = int(_legacy_word_col(row, word_cols, "use_count", 0) or 0)
        is_fav = int(_legacy_word_col(row, word_cols, "is_favorite", 0) or 0)

        cur_pg.execute(
            WORDS_INSERT_SQL,
            (
                bundle_id,
                lesson_fk,
                int(row["id"]),
                w,
                w,
                "",
                roman,
                None,
                audio_tr,
                audio_nat,
                definition,
                action,
                None,
                None,
                s1,
                None,
                None,
                None,
                None,
                None,
                cid,
                None,
                user_id,
                date_created,
                date_modified,
                use_count,
                is_fav,
                0,
                None,
            ),
        )


def import_minimal_word(cur_sl: sqlite3.Cursor, cur_pg: psycopg.Cursor, bundle_id: int) -> None:
    cur_sl.row_factory = sqlite3.Row
    cur_sl.execute(
        "SELECT DISTINCT category FROM word WHERE category IS NOT NULL AND TRIM(category) != '' ORDER BY category"
    )
    categories = [str(r[0]) for r in cur_sl.fetchall()]

    cat_to_lesson: dict[str, int] = {}
    for i, cname in enumerate(categories):
        legacy_id = -(i + 1)
        cur_pg.execute(
            LESSON_INSERT_FULL,
            (
                bundle_id,
                legacy_id,
                cname,
                cname,
                cname,
                0,
                0,
                None,
                None,
                None,
                0,
                0,
                None,
                None,
                0,
                5,
                None,
                0,
                None,
                0,
            ),
        )
        cat_to_lesson[cname] = int(cur_pg.fetchone()[0])

    cur_sl.execute("SELECT * FROM word ORDER BY id")
    for row in cur_sl.fetchall():
        cname = row["category"]
        if cname is None or str(cname).strip() == "":
            lesson_fk = None
            legacy_cat = None
        else:
            cname = str(cname)
            lesson_fk = cat_to_lesson.get(cname)
            legacy_cat = -(categories.index(cname) + 1) if cname in cat_to_lesson else None

        w = row["word"] or ""
        wid = row["id"]
        cur_pg.execute(
            WORDS_INSERT_SQL,
            (
                bundle_id,
                lesson_fk,
                int(wid),
                w,
                w,
                "",
                row["roman"],
                None,
                as_bytea(row["audio"]),
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                legacy_cat,
                None,
                0,
                None,
                None,
                0,
                0,
                0,
                None,
            ),
        )


def import_vocab_sqlite_path(
    pg: psycopg.Connection, sqlite_path: Path, source_filename: str, replace: bool
) -> None:
    langs = parse_db_filename(source_filename)
    if not langs:
        raise ValueError("not a vocabulary db")
    translate_lang, native_lang = langs

    sl = sqlite3.connect(str(sqlite_path))
    try:
        cur_sl = sl.cursor()
        variant = detect_schema(cur_sl)
        if variant == "unknown":
            raise RuntimeError(f"Unknown SQLite layout in {source_filename}")

        with pg.transaction():
            cur = pg.cursor()
            if replace:
                delete_bundle_cur(cur, source_filename)
            bundle_id = insert_bundle(cur, translate_lang, native_lang, source_filename)

            if variant == "full":
                import_full_pair(cur_sl, cur, bundle_id)
            elif variant == "legacy_simple":
                import_legacy_simple(cur_sl, cur, bundle_id)
            else:
                import_minimal_word(cur_sl, cur, bundle_id)

        print(f"OK {source_filename} ({variant}) → bundle_id={bundle_id}", file=sys.stderr)
    finally:
        sl.close()


def import_photo_db(pg: psycopg.Connection, sqlite_path: Path, replace: bool) -> None:
    sl = sqlite3.connect(str(sqlite_path))
    try:
        sl.row_factory = sqlite3.Row
        cur_sl = sl.cursor()
        cur_sl.execute("SELECT * FROM photo_dict")
        rows = cur_sl.fetchall()
        with pg.transaction():
            cur = pg.cursor()
            if replace:
                cur.execute("TRUNCATE word_photo_blobs RESTART IDENTITY")
            for row in rows:
                cur.execute(
                    """
                    INSERT INTO word_photo_blobs (legacy_row_id, rec_id, word, photo, format)
                    VALUES (%s, %s, %s, %s, %s)
                    ON CONFLICT (legacy_row_id) DO UPDATE SET
                      rec_id = EXCLUDED.rec_id,
                      word = EXCLUDED.word,
                      photo = EXCLUDED.photo,
                      format = EXCLUDED.format
                    """,
                    (
                        int(row["row_id"]),
                        int(row["rec_id"]) if row["rec_id"] is not None else None,
                        row["word"],
                        as_bytea(row["photo"]),
                        row["format"],
                    ),
                )
        print(f"OK dict_photo.db  rows={len(rows)}", file=sys.stderr)
    finally:
        sl.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="DimaGo SQLite → Supabase Postgres")
    parser.add_argument("--all-github", action="store_true", help="Import every dict_*.db except dict_photo")
    parser.add_argument("--photo-github", action="store_true", help="Import dict_photo.db")
    parser.add_argument("--file", action="append", default=[], metavar="NAME", help="Single db filename (GitHub or --local-dir)")
    parser.add_argument("--local-dir", type=Path, help="Use files from this folder instead of downloading")
    parser.add_argument("--replace", action="store_true", help="Re-import: delete existing bundle / truncate photos")
    args = parser.parse_args()

    dsn = os.environ.get("DATABASE_URL")
    if not dsn:
        print("Set DATABASE_URL to your Supabase Postgres connection string.", file=sys.stderr)
        sys.exit(1)
    validate_pooler_username(dsn)

    if not args.all_github and not args.file and not args.photo_github:
        parser.error("Specify --all-github and/or --file … and/or --photo-github")

    work: list[tuple[str, Path]] = []
    tmp: Path | None = None

    if args.local_dir:
        base = args.local_dir.resolve()
        names: list[str] = []
        if args.all_github:
            names.extend(list_github_dict_dbs())
        names.extend(args.file)
        for name in names:
            work.append((name, base / name))
    else:
        tmp = Path(tempfile.mkdtemp(prefix="dimago_migrate_"))
        if args.all_github:
            for name in list_github_dict_dbs():
                path = tmp / name
                path.write_bytes(http_get_bytes(f"{GITHUB_RAW}/{name}"))
                work.append((name, path))
        for name in args.file:
            path = tmp / name
            path.write_bytes(http_get_bytes(f"{GITHUB_RAW}/{name}"))
            work.append((name, path))

    try:
        with psycopg.connect(dsn) as pg:
            for name, path in work:
                if not path.exists():
                    print(f"Missing {path}", file=sys.stderr)
                    sys.exit(1)
                import_vocab_sqlite_path(pg, path, name, replace=args.replace)
            if args.photo_github:
                if args.local_dir:
                    photo_path = args.local_dir.resolve() / "dict_photo.db"
                else:
                    assert tmp is not None
                    photo_path = tmp / "dict_photo.db"
                    photo_path.write_bytes(http_get_bytes(f"{GITHUB_RAW}/dict_photo.db"))
                if not photo_path.exists():
                    print(f"Missing {photo_path}", file=sys.stderr)
                    sys.exit(1)
                import_photo_db(pg, photo_path, replace=args.replace)
    finally:
        if tmp is not None:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
