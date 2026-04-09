#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Compare local SQLite ``word`` / ``category`` to Postgres ``words`` / ``lessons`` and emit DDL.

Generates a standalone Python script (``DATABASE_URL`` + psycopg) that:

* **DROP COLUMN** for Postgres columns not present in SQLite (destroys data in those columns).
* **ADD COLUMN IF NOT EXISTS** for SQLite columns missing on Postgres.

Protected columns (never dropped): PKs, ``bundle_id``, ``lesson_id``, ``legacy_*`` links.
Review generated SQL before running in production.
"""
from __future__ import annotations

import os
import sqlite3
import subprocess
import sys
import textwrap
from datetime import datetime, timezone
from pathlib import Path

SQLITE_PG_TABLE_PAIRS: tuple[tuple[str, str], ...] = (
    ("word", "words"),
    ("category", "lessons"),
)

# SQLite PK ``id`` maps to Postgres ``id`` (identity) / ``legacy_*`` — do not ADD COLUMN id.
SKIP_SQLITE_COLUMN: dict[tuple[str, str], None] = {
    ("word", "id"): None,
    ("category", "id"): None,
}

# Never DROP these Postgres columns (required for app / FKs / identity).
PG_NEVER_DROP: dict[str, frozenset[str]] = {
    "words": frozenset(
        {
            "id",
            "bundle_id",
            "lesson_id",
            "legacy_word_id",
            "legacy_category_index",
        }
    ),
    "lessons": frozenset(
        {
            "id",
            "bundle_id",
            "legacy_category_id",
        }
    ),
}


def _sqlite_quote_ident(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def _pg_quote_ident(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def _sqlite_to_pg_type(sqlite_decl: str) -> str:
    u = (sqlite_decl or "").strip().upper()
    if not u:
        return "TEXT"
    if "INT" in u:
        return "BIGINT"
    if "BLOB" in u:
        return "BYTEA"
    if "REAL" in u or "FLOA" in u or "DOUB" in u:
        return "DOUBLE PRECISION"
    return "TEXT"


def _sqlite_table_names(conn: sqlite3.Connection) -> set[str]:
    rows = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name IS NOT NULL"
    ).fetchall()
    return {r[0] for r in rows}


def _sqlite_table_columns(conn: sqlite3.Connection, table: str) -> list[tuple[str, str]]:
    q = _sqlite_quote_ident(table)
    cur = conn.execute(f"PRAGMA table_info({q})")
    # cid, name, type, notnull, dflt, pk
    return [(str(r[1]), str(r[2] or "")) for r in cur.fetchall()]


def pg_existing_columns(dsn: str, pg_table: str) -> set[str]:
    import psycopg  # type: ignore

    with psycopg.connect(dsn) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT column_name FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = %s
                """,
                (pg_table,),
            )
            return {r[0] for r in cur.fetchall()}


def generate_alter_statements(sqlite_path: str, dsn: str) -> tuple[list[str], str]:
    """Return (executable ALTER statements, human-readable report).

    For each mapped table: DROP Postgres columns absent from SQLite (except protected),
    then ADD SQLite columns missing on Postgres. Column names compared case-insensitively.
    """
    uri = f"file:{Path(sqlite_path).resolve().as_posix()}?mode=ro"
    sl = sqlite3.connect(uri, uri=True)
    stmts: list[str] = []
    log_lines: list[str] = []
    try:
        sl_tables = _sqlite_table_names(sl)
        for sl_tbl, pg_tbl in SQLITE_PG_TABLE_PAIRS:
            if sl_tbl not in sl_tables:
                log_lines.append(f"-- SQLite table {sl_tbl!r} missing; skipped")
                continue
            have_pg = pg_existing_columns(dsn, pg_tbl)
            never = PG_NEVER_DROP.get(pg_tbl, frozenset())

            sl_cols: list[tuple[str, str]] = _sqlite_table_columns(sl, sl_tbl)
            sl_cols_lower: set[str] = set()
            for col_name, decl in sl_cols:
                if (sl_tbl, col_name) in SKIP_SQLITE_COLUMN:
                    continue
                sl_cols_lower.add(col_name.lower())

            have_pg_lower = {c.lower() for c in have_pg}
            log_lines.append(
                f"-- === {sl_tbl} → {pg_tbl} === "
                f"(Postgres {len(have_pg)} cols, SQLite mapped {len(sl_cols_lower)} cols)"
            )

            to_drop = sorted(
                c
                for c in have_pg
                if c.lower() not in never and c.lower() not in sl_cols_lower
            )
            for c in to_drop:
                stmt = (
                    f"ALTER TABLE {_pg_quote_ident(pg_tbl)} "
                    f"DROP COLUMN IF EXISTS {_pg_quote_ident(c)}"
                )
                stmts.append(stmt)
                log_lines.append(f"--   - DROP {c}  (not in local SQLite {sl_tbl})")

            remaining_pg_lower = have_pg_lower - {x.lower() for x in to_drop}

            for col_name, decl in sl_cols:
                if (sl_tbl, col_name) in SKIP_SQLITE_COLUMN:
                    continue
                lk = col_name.lower()
                if lk in remaining_pg_lower:
                    continue
                pg_t = _sqlite_to_pg_type(decl)
                stmt = (
                    f"ALTER TABLE {_pg_quote_ident(pg_tbl)} "
                    f"ADD COLUMN IF NOT EXISTS {_pg_quote_ident(col_name)} {pg_t}"
                )
                stmts.append(stmt)
                log_lines.append(f"--   + ADD {col_name} {pg_t}  (SQLite {decl!r})")

        log_lines.append("-- --- executable statements ---")
        log_lines.extend(stmts)
        return stmts, "\n".join(log_lines)
    finally:
        sl.close()


GENERATED_SCRIPT_NAME = "_schema_migration_run.py"


def write_migration_script(stmts: list[str], out_path: Path) -> None:
    """Write a runnable script that applies ``stmts`` with psycopg + DATABASE_URL."""
    stamp = datetime.now(timezone.utc).isoformat()
    stmts_repr = repr(stmts)
    body = textwrap.dedent(
        f'''
        # -*- coding: utf-8 -*-
        # Auto-generated by dimago dbutil/schema_migrate.py at {stamp}
        # Do not edit by hand - regenerate from dbview or: python schema_migrate.py <db>
        import os
        import sys

        try:
            import psycopg
        except ImportError:
            print("pip install psycopg[binary]", file=sys.stderr)
            sys.exit(3)

        STMTS = {stmts_repr}

        def main() -> None:
            url = (os.environ.get("DATABASE_URL") or "").strip()
            if not url:
                print("DATABASE_URL is not set", file=sys.stderr)
                sys.exit(2)
            with psycopg.connect(url, autocommit=True) as conn:
                with conn.cursor() as cur:
                    for i, s in enumerate(STMTS, 1):
                        preview = s.replace("\\n", " ")
                        if len(preview) > 100:
                            preview = preview[:97] + "..."
                        print(f"[{{i}}/{{len(STMTS)}}] {{preview}}")
                        cur.execute(s)
            print("OK:", {{len(STMTS)}}, "statement(s) applied")

        if __name__ == "__main__":
            main()
        '''
    ).lstrip()
    out_path.write_text(body, encoding="utf-8")


def run_generated_script(script_path: Path, env: dict[str, str]) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(script_path)],
        cwd=str(script_path.parent),
        env=env,
        capture_output=True,
        text=True,
        timeout=600,
    )


def main() -> None:
    """CLI: python schema_migrate.py <sqlite.db>  (uses DATABASE_URL from env)."""
    if len(sys.argv) < 2:
        print("Usage: python schema_migrate.py <dict_TR_NA.db>", file=sys.stderr)
        sys.exit(2)
    db = sys.argv[1]
    dsn = (os.environ.get("DATABASE_URL") or "").strip()
    if not dsn:
        print("DATABASE_URL required", file=sys.stderr)
        sys.exit(2)
    stmts, report = generate_alter_statements(db, dsn)
    print(report)
    if not stmts:
        print("No ALTER statements needed.", file=sys.stderr)
        return
    out = Path(__file__).resolve().parent / GENERATED_SCRIPT_NAME
    write_migration_script(stmts, out)
    print(f"Wrote {out}", file=sys.stderr)
    cp = run_generated_script(out, os.environ.copy())
    sys.stdout.write(cp.stdout or "")
    sys.stderr.write(cp.stderr or "")
    sys.exit(cp.returncode)


if __name__ == "__main__":
    main()
