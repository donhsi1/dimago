#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
dbupload.py — Upload a local SQLite database to Supabase (Postgres).

Usage:
  python dbupload.py --input dict_TH_CN.db
  python dbupload.py --input dict_TH_CN.db --schema-only
  python dbupload.py --input dict_TH_CN.db --drop-existing
  python dbupload.py --input dict_TH_CN.db --tables category word

Steps:
  1. Read schema from SQLite (CREATE TABLE statements from sqlite_master)
  2. Convert to Postgres DDL and CREATE TABLE IF NOT EXISTS (or DROP first with --drop-existing)
  3. Upload all rows, converting BLOB → bytea

Requires:
  pip install psycopg[binary]
  DATABASE_URL in .env (postgresql://user:pass@host:port/db)
"""

import argparse
import os
import re
import sqlite3
import sys
from pathlib import Path

# ── .env loader ───────────────────────────────────────────────────────────────

def _load_dotenv() -> None:
    env_file = Path(__file__).parent / '.env'
    if not env_file.exists():
        return
    for line in env_file.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        k, _, v = line.partition('=')
        os.environ.setdefault(k.strip(), v.strip())

_load_dotenv()

# ── SQLite → Postgres type mapping ────────────────────────────────────────────

# Map SQLite type affinities to Postgres types.
_TYPE_MAP = [
    (r'\bINTEGER\b',  'INTEGER'),
    (r'\bINT\b',      'INTEGER'),
    (r'\bTEXT\b',     'TEXT'),
    (r'\bBLOB\b',     'BYTEA'),
    (r'\bREAL\b',     'DOUBLE PRECISION'),
    (r'\bFLOAT\b',    'DOUBLE PRECISION'),
    (r'\bNUMERIC\b',  'TEXT'),    # SQLite NUMERIC affinity stores arbitrary values
    (r'\bDOUBLE\b',   'DOUBLE PRECISION'),
    (r'\bBOOLEAN\b',  'BOOLEAN'),
]

def _sqlite_type_to_pg(sqlite_type: str) -> str:
    t = sqlite_type.strip().upper()
    for pattern, pg_type in _TYPE_MAP:
        if re.search(pattern, t):
            return pg_type
    # Fallback: treat unknown as TEXT
    return 'TEXT'


def _convert_column_def(col_def: str) -> str:
    """Convert one SQLite column definition line to Postgres syntax."""
    col = col_def.strip().rstrip(',')

    # Remove SQLite-specific quoting from identifiers ("colname" → colname)
    col = re.sub(r'"(\w+)"', r'\1', col)

    # PRIMARY KEY AUTOINCREMENT → SERIAL PRIMARY KEY
    if re.search(r'PRIMARY\s+KEY', col, re.IGNORECASE) and re.search(r'AUTOINCREMENT', col, re.IGNORECASE):
        # Extract column name (first token)
        name = col.split()[0]
        col = f'{name} SERIAL PRIMARY KEY'
        return col

    # Separate column name from type+constraints
    parts = col.split(None, 1)
    if len(parts) < 2:
        return col  # bare name with no type — unlikely but safe
    col_name, rest = parts[0], parts[1]

    # Extract the type token (first word of rest)
    type_match = re.match(r'(\w+)(.*)', rest, re.DOTALL)
    if not type_match:
        return col
    sqlite_type, remainder = type_match.group(1), type_match.group(2)
    pg_type = _sqlite_type_to_pg(sqlite_type)


    # Remove AUTOINCREMENT from remainder (shouldn't reach here, but belt+braces)
    remainder = re.sub(r'\bAUTOINCREMENT\b', '', remainder, flags=re.IGNORECASE).strip()

    return f'{col_name} {pg_type} {remainder}'.strip()


def _sqlite_ddl_to_pg(table_name: str, create_sql: str) -> str:
    """Convert a SQLite CREATE TABLE statement to a Postgres CREATE TABLE IF NOT EXISTS."""
    # Extract the column/constraint block between the outer parentheses
    m = re.search(r'\((.*)\)\s*$', create_sql, re.DOTALL)
    if not m:
        raise ValueError(f'Cannot parse CREATE TABLE for {table_name!r}')
    inner = m.group(1)

    # Split on commas at the top level (not inside parentheses).
    raw_lines = []
    depth = 0
    current: list[str] = []
    for ch in inner:
        if ch == '(':
            depth += 1
            current.append(ch)
        elif ch == ')':
            depth -= 1
            current.append(ch)
        elif ch == ',' and depth == 0:
            token = ''.join(current).strip()
            if token:
                raw_lines.append(token)
            current = []
        else:
            current.append(ch)
    token = ''.join(current).strip()
    if token:
        raw_lines.append(token)

    # First pass: detect table-level PRIMARY KEY with AUTOINCREMENT,
    # e.g.  PRIMARY KEY("id" AUTOINCREMENT)  → remember the PK col name
    autoincrement_pk_col: str | None = None
    for line in raw_lines:
        line_stripped = line.strip().rstrip(',')
        upper = line_stripped.upper()
        if upper.startswith('PRIMARY KEY'):
            # Check for AUTOINCREMENT inside the parens
            if 'AUTOINCREMENT' in upper:
                pk_m = re.search(r'PRIMARY\s+KEY\s*\(\s*"?(\w+)"?\s+AUTOINCREMENT\s*\)',
                                 line_stripped, re.IGNORECASE)
                if pk_m:
                    autoincrement_pk_col = pk_m.group(1).lower()
            break

    pg_lines = []
    for line in raw_lines:
        line = line.rstrip(',')
        upper = line.upper().lstrip()

        # Table constraints: PRIMARY KEY (...), UNIQUE (...), FOREIGN KEY
        if upper.startswith('PRIMARY KEY') or upper.startswith('UNIQUE') or upper.startswith('FOREIGN KEY'):
            if 'AUTOINCREMENT' in upper:
                # Strip AUTOINCREMENT and SQLite quoting; emit as plain PRIMARY KEY(col)
                clean = re.sub(r'\bAUTOINCREMENT\b', '', line, flags=re.IGNORECASE).strip()
                clean = re.sub(r'"(\w+)"', r'\1', clean)
                pg_lines.append(clean)
            else:
                line = re.sub(r'"(\w+)"', r'\1', line)
                pg_lines.append(line)
            continue

        # Column definition — detect if this is the autoincrement PK column
        col_def = _convert_column_def(line)
        if autoincrement_pk_col:
            col_name = col_def.split()[0].lower().strip('"')
            if col_name == autoincrement_pk_col:
                # Replace INTEGER with SERIAL (keep other constraints if any)
                col_def = re.sub(r'\bINTEGER\b', 'SERIAL', col_def, count=1, flags=re.IGNORECASE)

        pg_lines.append(col_def)

    cols = ',\n  '.join(pg_lines)
    return f'CREATE TABLE IF NOT EXISTS {table_name} (\n  {cols}\n);'


# ── Schema extraction ─────────────────────────────────────────────────────────

SKIP_TABLES = {'sqlite_sequence', 'sqlite_stat1', 'sqlite_stat4'}

def get_tables(conn: sqlite3.Connection) -> list[str]:
    rows = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY rowid"
    ).fetchall()
    return [r[0] for r in rows if r[0] not in SKIP_TABLES]


def get_create_sql(conn: sqlite3.Connection, table: str) -> str:
    row = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name=?", (table,)
    ).fetchone()
    if not row:
        raise ValueError(f'Table {table!r} not found in SQLite db')
    return row[0]


# ── Data upload ───────────────────────────────────────────────────────────────

_BATCH_SIZE = 200  # rows per INSERT batch


def _sqlite_row_to_pg(row: sqlite3.Row, col_names: list[str]) -> dict:
    """Convert a sqlite3.Row to a plain dict.
    - Bytes stay as bytes (psycopg maps to bytea).
    - Empty strings become None (Postgres typed columns reject '' for INTEGER etc.).
    """
    result = {}
    for col in col_names:
        v = row[col]
        if v == '':
            v = None
        result[col] = v
    return result


def _pg_table_columns(pg_conn, table: str) -> list[str]:
    """Return column names of an existing Postgres table."""
    rows = pg_conn.execute(
        "SELECT column_name FROM information_schema.columns "
        "WHERE table_schema = 'public' AND table_name = %s ORDER BY ordinal_position",
        (table,),
    ).fetchall()
    return [r[0] for r in rows]


def upload_table(
    pg_conn,
    sqlite_conn: sqlite3.Connection,
    table: str,
    truncate: bool = False,
    schema_supa: bool = False,
    verbose: bool = True,
) -> int:
    """Upload all rows from a SQLite table to the matching Postgres table.
    truncate=True: TRUNCATE the Postgres table first so all local rows land.
    schema_supa=True: only insert columns that exist in the Supabase table.
    Returns the number of rows inserted."""
    sqlite_conn.row_factory = sqlite3.Row
    rows = sqlite_conn.execute(f'SELECT * FROM "{table}"').fetchall()

    cur = pg_conn.cursor()
    if truncate:
        cur.execute(f'TRUNCATE TABLE {table} RESTART IDENTITY CASCADE')
        pg_conn.commit()
        if verbose:
            print(f'  {table}: truncated')

    if not rows:
        if verbose:
            print(f'  {table}: 0 rows (skip)')
        return 0

    sqlite_cols = list(rows[0].keys())
    if schema_supa:
        pg_cols = _pg_table_columns(pg_conn, table)
        if not pg_cols:
            print(f'  [warn] {table}: table not found in Supabase — skip')
            return 0
        col_names = [c for c in sqlite_cols if c in pg_cols]
        skipped = set(sqlite_cols) - set(col_names)
        if skipped and verbose:
            print(f'  {table}: skipping SQLite-only columns: {", ".join(sorted(skipped))}')
        if not col_names:
            print(f'  [warn] {table}: no column overlap between SQLite and Supabase — skip')
            return 0
    else:
        col_names = sqlite_cols

    placeholders = ', '.join(f'%({c})s' for c in col_names)
    col_list = ', '.join(col_names)
    sql = f'INSERT INTO {table} ({col_list}) VALUES ({placeholders}) ON CONFLICT DO NOTHING'

    inserted = 0
    try:
        for i in range(0, len(rows), _BATCH_SIZE):
            batch = [_sqlite_row_to_pg(r, col_names) for r in rows[i:i + _BATCH_SIZE]]
            cur.executemany(sql, batch)
            inserted += len(batch)
            if verbose:
                print(f'  {table}: {inserted}/{len(rows)} rows…', end='\r')
        pg_conn.commit()
    except Exception as e:
        pg_conn.rollback()
        print(f'  [warn] {table}: insert failed — {e}')
        print(f'         Matched columns: {", ".join(col_names)}')
        return 0
    if verbose:
        print(f'  {table}: {inserted} rows inserted        ')
    return inserted


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description='Upload a SQLite database to Supabase (Postgres).',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument('--input', required=True, metavar='DBFILE',
                        help='Path to the local SQLite .db file')
    parser.add_argument('--tables', nargs='+', metavar='TABLE',
                        help='Only upload these tables (default: all)')
    parser.add_argument('--schema-only', action='store_true',
                        help='Create tables but do not upload data')
    parser.add_argument('--schema-supa', action='store_true',
                        help='Skip schema step — use existing Supabase tables as-is')
    parser.add_argument('--truncate', action='store_true',
                        help='TRUNCATE each table before inserting (replaces all data)')
    parser.add_argument('--drop-existing', action='store_true',
                        help='DROP TABLE IF EXISTS before re-creating (destructive!)')
    parser.add_argument('--db-url', metavar='URL',
                        help='Postgres connection string (overrides DATABASE_URL in .env)')
    args = parser.parse_args()

    db_path = Path(args.input)
    if not db_path.exists():
        print(f'[error] File not found: {db_path}')
        sys.exit(1)

    db_url = args.db_url or os.environ.get('DATABASE_URL', '').strip()
    if not db_url:
        print(
            '[error] No Postgres connection string found.\n'
            '  Set DATABASE_URL in dbutil/.env or pass --db-url.'
        )
        sys.exit(1)

    try:
        import psycopg  # type: ignore
    except ImportError:
        print('[error] psycopg not installed. Run: pip install psycopg[binary]')
        sys.exit(1)

    sqlite_conn = sqlite3.connect(str(db_path))
    tables = get_tables(sqlite_conn)
    if args.tables:
        unknown = set(args.tables) - set(tables)
        if unknown:
            print(f'[error] Tables not found in SQLite db: {", ".join(sorted(unknown))}')
            sys.exit(1)
        tables = [t for t in tables if t in args.tables]

    print(f'Source: {db_path}  ({len(tables)} table(s): {", ".join(tables)})')
    print(f'Target: {re.sub(r":([^:@]+)@", ":***@", db_url)}')
    print()

    with psycopg.connect(db_url, autocommit=False) as pg:
        cur = pg.cursor()

        # ── Schema ────────────────────────────────────────────────────────────
        if args.schema_supa:
            print('=== Supabase Schema ===')
            for table in tables:
                pg_cols = _pg_table_columns(pg, table)
                if not pg_cols:
                    print(f'  {table}: (not found in Supabase)')
                else:
                    print(f'  {table}: {", ".join(pg_cols)}')
        else:
            print('=== Schema ===')
            for table in tables:
                create_sql = get_create_sql(sqlite_conn, table)
                try:
                    pg_ddl = _sqlite_ddl_to_pg(table, create_sql)
                except Exception as e:
                    print(f'  [warn] Could not convert DDL for {table!r}: {e}')
                    print(f'         SQLite DDL: {create_sql[:200]}')
                    continue

                if args.drop_existing:
                    cur.execute(f'DROP TABLE IF EXISTS {table} CASCADE')
                    print(f'  Dropped {table}')

                cur.execute(pg_ddl)
                pg.commit()
                action = 'Created' if args.drop_existing else 'Created (if not exists)'
                print(f'  {action}: {table}')

        if args.schema_only:
            print('\nSchema-only mode — done.')
            return

        # ── Data ──────────────────────────────────────────────────────────────
        print('\n=== Data ===')
        total = 0
        for table in tables:
            total += upload_table(pg, sqlite_conn, table,
                                  truncate=args.truncate,
                                  schema_supa=args.schema_supa)

        print(f'\nDone. {total} total rows uploaded.')

    sqlite_conn.close()


if __name__ == '__main__':
    main()
