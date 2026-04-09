"""Apply a SQL migration using DATABASE_URL from dbutil/.env.

Default file: migration_lessons_lang_translate_native.sql
Override: python _apply_migration_lang_columns.py migration_words_sample1_native_audio.sql
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[2]
_ENV = _ROOT / "dbutil" / ".env"
_SCRIPT_DIR = Path(__file__).resolve().parent


def _sql_path() -> Path:
    if len(sys.argv) > 1:
        p = Path(sys.argv[1])
        path = p if p.is_absolute() else _SCRIPT_DIR / p
    else:
        path = _SCRIPT_DIR / "migration_lessons_lang_translate_native.sql"
    return path.resolve()


def main() -> None:
    if _ENV.is_file():
        for line in _ENV.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            k, v = k.strip(), v.strip()
            if k and k not in os.environ:
                os.environ[k] = v

    url = (os.environ.get("DATABASE_URL") or "").strip()
    if not url:
        print(
            "No DATABASE_URL. Set Postgres URI in dbutil/.env (Supabase Dashboard -> Connect).",
            file=sys.stderr,
        )
        sys.exit(2)

    sql_file = _sql_path()
    if not sql_file.is_file():
        print(f"No such migration file: {sql_file}", file=sys.stderr)
        sys.exit(4)

    try:
        import psycopg
    except ImportError:
        print("Run: pip install psycopg[binary]", file=sys.stderr)
        sys.exit(3)

    sql = sql_file.read_text(encoding="utf-8")
    chunks: list[str] = []
    for part in sql.split(";"):
        lines = [
            ln
            for ln in part.splitlines()
            if ln.strip() and not ln.strip().startswith("--")
        ]
        if lines:
            chunks.append("\n".join(lines))

    with psycopg.connect(url, autocommit=True) as conn:
        with conn.cursor() as cur:
            for stmt in chunks:
                cur.execute(stmt)

    print(f"OK: {sql_file.name} ({len(chunks)} statements)")


if __name__ == "__main__":
    main()
