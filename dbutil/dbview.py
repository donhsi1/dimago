#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
dbview.py — Windows DB browser/editor (tkinter).

**Entry points (this file is the single implementation of the GUI)**

* **Standalone:** ``python dbview.py`` — use ``build_standalone_parser()`` / ``run_cli()`` / ``main()``.
* **Via dbutil:** ``python dbutil.py --view ...`` — dbutil calls ``run_view_from_dbutil_namespace()``;
  same UI, no duplicate code.

  python dbview.py --input path/to.db
  python dbview.py path/to.db
  python dbutil.py --view [--input path/to.db]
  python dbutil.py --view --view-postgres [--database-url postgresql://...]
  python dbview.py --postgres              # DATABASE_URL (dbutil/.env or .env.local)
  python dbview.py --postgres --database-url postgresql://...

Optional: pip install pillow  (in-app image preview; otherwise opens system viewer)
Optional: pip install psycopg[binary]  (Postgres / Supabase via DATABASE_URL)

Features: open DB, browse tables, **Edit selected row** for text columns;
audio/image BLOBs get an icon-only **play** control / **Photo** in that dialog (magic-byte sniff).
**Update (TTS)** stages MP3 in memory (language + source field reads current text fields); play preview
then **Apply (UPDATE this row)** writes text and all BLOBs in one shot. Same Google ``translate_tts`` as dbutil.
Audio BLOB cells show a **▶** in the grid; single-click plays (SQLite loads from cache; Postgres fetches that cell then plays or opens image).
**Postgres / Supabase:** use ``--view-postgres`` (``DATABASE_URL``). Table list includes ``public`` DimaGo tables
(``vocabulary_bundles``, ``users``, ``lessons``, ``words``, ``word_photo_blobs``) plus ``auth.users`` when present.
**Add row** inserts a new row (INSERT); **Apply** on edit stages an UPDATE; **File → Save** commits SQLite; **Save As** copies via sqlite backup.
**File → Commit to Supabase…** runs ``dbutil.py --commit`` (REST upsert). Edits to ``category`` / ``word`` are tracked; you can sync **only those rows** via ``--commit-modified`` (optional full sync). JWT: optional field in the dialog or ``--key`` / ``.env`` (service_role bypasses RLS). With ``HARDCODED_SUPABASE_SERVICE_ROLE_KEY`` in ``dbutil.py``, URL/ref/key may be read there.
**File → Apply local schema…** syncs columns (DROP missing locally, ADD missing on server), writes ``_schema_migration_run.py``, runs it (``DATABASE_URL`` + ``psycopg``).
**Help → Run SQL file…** applies a chosen ``.sql`` via ``DATABASE_URL`` + ``psycopg``.
**Open file** asks Save / Discard / Cancel if the current DB has uncommitted changes.
Uses rowid in UPDATE (not for WITHOUT ROWID tables).
"""

from __future__ import annotations

import argparse
import base64
import importlib.util
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, scrolledtext, ttk
from typing import Any, Callable
from urllib.parse import urlparse

# DimaGo Supabase tables — listed in this order when present (Postgres / --view-postgres).
# ``users`` = ``public.users`` (schema_dimago). ``auth.users`` is added when that table exists.
SUPABASE_DIMAGO_TABLES: tuple[str, ...] = (
    "vocabulary_bundles",
    "users",
    "lessons",
    "words",
    "word_photo_blobs",
)

# Safety cap for SELECT * in Postgres mode.
PG_ROW_LIMIT = 10_000

# ``word`` BLOB column → default text source in Update (TTS) dialog.
TTS_BLOB_DEFAULT_SOURCE_COLUMN: dict[str, str] = {
    "audio_translate": "name_translate",
    "audio_native": "name_native",
    "sample1_native_audio": "sample1_native",
    "sample1_translate_audio": "sample1_translate",
}

_DBUTIL_SCRIPT = Path(__file__).resolve().parent / "dbutil.py"
_SCHEMA_MIGRATE_SCRIPT = Path(__file__).resolve().parent / "schema_migrate.py"


def _load_schema_migrate_module() -> Any:
    spec = importlib.util.spec_from_file_location(
        "dimago_schema_migrate",
        _SCHEMA_MIGRATE_SCRIPT,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load schema_migrate")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _parse_migration_sql_script(sql: str) -> list[str]:
    """Split SQL on ';' and drop empty / comment-only chunks (same as scripts/supabase migrations)."""
    chunks: list[str] = []
    for part in sql.split(";"):
        lines = [
            ln
            for ln in part.splitlines()
            if ln.strip() and not ln.strip().startswith("--")
        ]
        if lines:
            chunks.append("\n".join(lines))
    return chunks

try:
    from PIL import Image, ImageTk  # type: ignore
except ImportError:
    Image = ImageTk = None  # type: ignore[misc, assignment]

try:
    import psycopg  # type: ignore
    from psycopg.rows import dict_row  # type: ignore
except ImportError:
    psycopg = None  # type: ignore[misc, assignment]
    dict_row = None  # type: ignore[misc, assignment]


def _merge_dbutil_dotenv_files() -> dict[str, str]:
    """Parse ``dbutil/.env`` then ``dbutil/.env.local``; later file overrides keys from earlier."""
    base = Path(__file__).resolve().parent
    merged: dict[str, str] = {}
    for fname in (".env", ".env.local"):
        path = base / fname
        if not path.is_file():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            k, v = k.strip(), v.strip()
            if k:
                merged[k] = v
    return merged


def _load_dbutil_dotenv() -> None:
    """Load local config next to this script into ``os.environ`` (does not override existing OS vars)."""
    for k, v in _merge_dbutil_dotenv_files().items():
        if k not in os.environ:
            os.environ[k] = v


def _postgres_dsn_from_config() -> str:
    """Postgres URI after loading ``dbutil/.env`` / ``dbutil/.env.local``."""
    _load_dbutil_dotenv()
    return (
        (os.environ.get("DATABASE_URL") or "").strip()
        or (os.environ.get("SUPABASE_DB_URL") or "").strip()
        or (os.environ.get("POSTGRES_URL") or "").strip()
    )


_dbutil_tts_load_attempted: bool = False
_dbutil_synthesize_tts_ref: Any = None
_dbutil_tts_import_error: str | None = None


def _get_dbutil_synthesize_tts() -> tuple[Any, str | None]:
    """Lazy-import ``dbutil.synthesize_tts`` (Google Translate web TTS, same as ``--audio``)."""
    global _dbutil_tts_load_attempted, _dbutil_synthesize_tts_ref, _dbutil_tts_import_error
    if _dbutil_tts_load_attempted:
        return _dbutil_synthesize_tts_ref, _dbutil_tts_import_error
    _dbutil_tts_load_attempted = True
    try:
        ensure_dimago_db_scripts_on_path()
        import dbutil as _dbutil  # noqa: PLC0415

        _dbutil_synthesize_tts_ref = _dbutil.synthesize_tts
        _dbutil_tts_import_error = None
    except Exception as ex:  # noqa: BLE001
        _dbutil_synthesize_tts_ref = None
        _dbutil_tts_import_error = str(ex)
    return _dbutil_synthesize_tts_ref, _dbutil_tts_import_error


def _pg_dsn_title(dsn: str) -> str:
    """Host/database for window title (no password)."""
    try:
        p = urlparse(dsn)
        host = p.hostname or "?"
        db = (p.path or "").lstrip("/") or "postgres"
        return f"{host}/{db}"
    except Exception:
        return "Postgres"


def _sniff_blob_kind(data: bytes | None) -> str | None:
    if not data or not isinstance(data, (bytes, bytearray)):
        return None
    b = bytes(data[:32])
    if len(b) >= 8 and b[:8] == b"\x89PNG\r\n\x1a\n":
        return "image"
    if len(b) >= 6 and (b[:6] in (b"GIF87a", b"GIF89a")):
        return "image"
    if len(b) >= 3 and b[:3] == b"\xff\xd8\xff":
        return "image"
    if len(b) >= 4 and b[:4] == b"RIFF" and len(b) >= 12 and b[8:12] == b"WEBP":
        return "image"
    if len(b) >= 3 and b[:3] == b"ID3":
        return "audio"
    if len(b) >= 2 and b[0] == 0xFF and (b[1] & 0xE0) == 0xE0:
        return "audio"
    if len(b) >= 4 and b[:4] == b"OggS":
        return "audio"
    if len(b) >= 12 and b[4:8] == b"ftyp":
        return "audio"  # e.g. mp4/m4a; default app may play it
    return None


def _normalize_cell_binary(v: Any) -> bytes | None:
    """Coerce BYTEA / BLOB driver values to bytes (memoryview, bytearray, etc.)."""
    if v is None:
        return None
    if isinstance(v, memoryview):
        return v.tobytes()
    if isinstance(v, (bytes, bytearray)):
        return bytes(v)
    return None


def _sql_quote_ident(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def _pg_split_schema_table(table_spec: str) -> tuple[str, str]:
    """``words`` → ``(public, words)``; ``auth.users`` → ``(auth, users)``."""
    s = (table_spec or "").strip()
    if "." in s:
        sch, rel = s.split(".", 1)
        return sch.strip() or "public", rel.strip()
    return "public", s


def _pg_qualified_table(table_spec: str) -> str:
    """SQL ``FROM`` / ``INTO`` fragment: ``"public"."words"`` or ``"auth"."users"``."""
    sch, rel = _pg_split_schema_table(table_spec)
    return f"{_sql_quote_ident(sch)}.{_sql_quote_ident(rel)}"


# Sentinel: omit column from INSERT (SQLite assigns INTEGER PRIMARY KEY).
_OMIT_INSERT = object()


# Tiny play-triangle GIF (GIF87a) for icon-only ttk.Button; keep reference via app instance.
_PLAY_ICON_GIF_B64 = (
    "R0lGODdhFgAWAIEAAPX19Tc3PAAAAAAAACwAAAAAFgAWAEAIRgABCBxIsKBBgwESKkx48ODC"
    "AA0jQoxIEcDDixMratzIUeDDjh4xLqQokmNGkChTVlSoEmNHkQxXwhzpEKZGlyZjqtyJMiAAOw=="
)


class DbViewApp(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("dbview")
        self.geometry("1100x700")
        self.minsize(800, 500)

        self._backend: str = "none"  # "none" | "sqlite" | "postgres"
        self._path: str | None = None
        self._conn: sqlite3.Connection | None = None
        self._pg_conn: Any = None
        self._pg_dsn: str | None = None
        self._pk_columns: list[str] = []
        self._dirty = False
        self._current_table: str | None = None
        self._columns: list[str] = []
        self._col_types: dict[str, str] = {}
        self._col_meta: dict[str, dict[str, Any]] = {}
        self._tree_play_after_id: str | int | None = None
        self._play_icon_photo: tk.PhotoImage | None = None
        # SQLite: (iid, col) -> audio bytes for grid play overlay.
        self._tree_audio_blobs: dict[tuple[str, str], bytes] = {}
        # Postgres: BYTEA cells with data (no payload until user clicks play).
        self._tree_lazy_blob_cells: set[tuple[str, str]] = set()
        self._tree_audio_buttons: list[ttk.Button] = []
        self._tree_audio_place_after: str | int | None = None
        # Postgres: BYTEA columns loaded as presence flags only (see _pg_select_list_sql).
        self._pg_bytea_lazy_columns: set[str] = set()
        # SQLite: logical ids (category.id / word.id) touched since open — partial Supabase sync.
        self._sb_dirty_category_ids: set[int] = set()
        self._sb_dirty_word_ids: set[int] = set()

        self._build_menu()
        self._build_ui()

    def _is_connected(self) -> bool:
        if self._backend == "sqlite":
            return self._conn is not None
        if self._backend == "postgres":
            return self._pg_conn is not None
        return False

    def _disconnect_all(self) -> None:
        if self._conn:
            try:
                self._conn.close()
            except Exception:
                pass
            self._conn = None
        if self._pg_conn:
            try:
                self._pg_conn.close()
            except Exception:
                pass
            self._pg_conn = None
        self._backend = "none"
        self._path = None
        self._pg_dsn = None
        self._pk_columns = []
        self._current_table = None
        self._columns = []
        self._col_types = {}
        self._col_meta = {}
        self._cancel_tree_audio_place_schedule()
        self._destroy_tree_audio_overlay_widgets()
        self._tree_audio_blobs.clear()
        self._tree_lazy_blob_cells.clear()
        self._pg_bytea_lazy_columns.clear()
        self._sb_dirty_category_ids.clear()
        self._sb_dirty_word_ids.clear()
        self._update_sqlite_only_ui()

    def _update_sqlite_only_ui(self) -> None:
        """Commit / schema actions apply to the local SQLite file only."""
        sqlite_ok = self._backend == "sqlite"
        if sqlite_ok:
            self._btn_commit_sb.state(["!disabled"])
            self._btn_schema_pg.state(["!disabled"])
        else:
            self._btn_commit_sb.state(["disabled"])
            self._btn_schema_pg.state(["disabled"])
        st = tk.NORMAL if sqlite_ok else tk.DISABLED
        fm = getattr(self, "_file_menu", None)
        if fm is not None:
            for label in (
                "Commit to Supabase…",
                "Apply local schema (generate script)…",
            ):
                try:
                    fm.entryconfigure(fm.index(label), state=st)
                except tk.TclError:
                    pass

    def _destroy_tree_audio_overlay_widgets(self) -> None:
        for b in self._tree_audio_buttons:
            try:
                b.destroy()
            except tk.TclError:
                pass
        self._tree_audio_buttons.clear()

    def _cancel_tree_audio_place_schedule(self) -> None:
        if self._tree_audio_place_after is not None:
            try:
                self.after_cancel(self._tree_audio_place_after)
            except (tk.TclError, ValueError):
                pass
            self._tree_audio_place_after = None

    def _schedule_place_tree_audio_overlay(self) -> None:
        if not self._tree_audio_blobs and not self._tree_lazy_blob_cells:
            return
        self._cancel_tree_audio_place_schedule()
        self._tree_audio_place_after = self.after_idle(self._place_tree_audio_overlay_buttons)

    def _place_tree_audio_overlay_buttons(self) -> None:
        self._tree_audio_place_after = None
        self._destroy_tree_audio_overlay_widgets()
        disp = list(self._tree["columns"])
        if not disp or (not self._tree_audio_blobs and not self._tree_lazy_blob_cells):
            return
        parent = self._tree.master
        play_img = self._play_icon_photoimage()

        def place_one(iid: str, col: str, command: Any) -> None:
            if col not in disp:
                return
            try:
                ci = disp.index(col) + 1
            except ValueError:
                return
            col_ident = f"#{ci}"
            if iid not in self._tree.get_children():
                return
            box = self._tree.bbox(iid, col_ident)
            if not box or not isinstance(box, (tuple, list)) or len(box) < 4:
                return
            x, y, w, h = (int(box[0]), int(box[1]), int(box[2]), int(box[3]))
            btn = ttk.Button(parent, image=play_img, command=command)
            bw = max(20, min(w - 4, 34))
            bh = max(16, h - 4)
            btn.place(in_=self._tree, x=x + 2, y=y + 2, width=bw, height=bh)
            self._tree_audio_buttons.append(btn)

        for (iid, col), blob in self._tree_audio_blobs.items():
            place_one(iid, col, lambda d=blob: self._play_audio_blob(d))
        for (iid, col) in self._tree_lazy_blob_cells:
            place_one(
                iid,
                col,
                lambda i=iid, c=col: self._open_lazy_pg_blob(i, c),
            )

    def _build_menu(self) -> None:
        m = tk.Menu(self)
        fm = tk.Menu(m, tearoff=0)
        fm.add_command(label="Open SQLite…", command=self._open_sqlite, accelerator="Ctrl+O")
        fm.add_command(
            label="Connect Postgres (DATABASE_URL)…",
            command=self._connect_postgres_from_env,
        )
        fm.add_command(label="Save", command=self._save, accelerator="Ctrl+S")
        fm.add_command(label="Save As…", command=self._save_as)
        fm.add_separator()
        fm.add_command(label="Commit to Supabase…", command=self._commit_supabase_dialog)
        fm.add_command(
            label="Apply local schema (generate script)…",
            command=self._apply_local_schema_dialog,
        )
        fm.add_separator()
        fm.add_command(label="Exit", command=self._on_close)
        m.add_cascade(label="File", menu=fm)
        self._file_menu = fm
        em = tk.Menu(m, tearoff=0)
        em.add_command(label="Add row…", command=self._add_row, accelerator="Ctrl+N")
        m.add_cascade(label="Edit", menu=em)
        hm = tk.Menu(m, tearoff=0)
        hm.add_command(label="Schema vs data sync…", command=self._help_schema_vs_data)
        hm.add_command(label="Run SQL file…", command=self._run_sql_file_dialog)
        m.add_cascade(label="Help", menu=hm)
        self.config(menu=m)
        self.bind("<Control-n>", lambda e: self._add_row())
        self.bind("<Control-o>", lambda e: self._open_sqlite())
        self.bind("<Control-s>", lambda e: self._save())

    def _build_ui(self) -> None:
        pan = ttk.PanedWindow(self, orient=tk.HORIZONTAL)
        pan.pack(fill=tk.BOTH, expand=True, padx=4, pady=4)

        left = ttk.Frame(pan, width=200)
        pan.add(left, weight=0)
        ttk.Label(left, text="Tables").pack(anchor=tk.W)
        self._table_list = tk.Listbox(left, exportselection=False)
        self._table_list.pack(fill=tk.BOTH, expand=True)
        self._table_list.bind("<<ListboxSelect>>", self._on_table_pick)

        right = ttk.Frame(pan)
        pan.add(right, weight=1)

        bar = ttk.Frame(right)
        bar.pack(fill=tk.X, pady=(0, 4))
        ttk.Button(bar, text="Edit selected row", command=self._edit_row).pack(side=tk.LEFT, padx=2)
        ttk.Button(bar, text="Add row", command=self._add_row).pack(side=tk.LEFT, padx=2)
        ttk.Button(bar, text="Refresh", command=self._refresh_table).pack(side=tk.LEFT, padx=2)
        self._btn_commit_sb = ttk.Button(
            bar, text="Commit to Supabase", command=self._commit_supabase_dialog
        )
        self._btn_commit_sb.pack(side=tk.LEFT, padx=2)
        self._btn_schema_pg = ttk.Button(
            bar, text="Schema → Postgres", command=self._apply_local_schema_dialog
        )
        self._btn_schema_pg.pack(side=tk.LEFT, padx=2)

        tree_fr = ttk.Frame(right)
        tree_fr.pack(fill=tk.BOTH, expand=True)
        self._tree = ttk.Treeview(tree_fr, show="headings", selectmode="browse")
        sy = ttk.Scrollbar(tree_fr, orient=tk.VERTICAL, command=self._tree.yview)
        sx = ttk.Scrollbar(tree_fr, orient=tk.HORIZONTAL, command=self._tree.xview)

        def yscroll_set(*args: Any) -> None:
            sy.set(*args)
            self._schedule_place_tree_audio_overlay()

        def xscroll_set(*args: Any) -> None:
            sx.set(*args)
            self._schedule_place_tree_audio_overlay()

        self._tree.configure(yscrollcommand=yscroll_set, xscrollcommand=xscroll_set)
        self._tree.grid(row=0, column=0, sticky="nsew")
        sy.grid(row=0, column=1, sticky="ns")
        sx.grid(row=1, column=0, sticky="ew")
        tree_fr.rowconfigure(0, weight=1)
        tree_fr.columnconfigure(0, weight=1)
        self._tree.bind("<Button-1>", self._on_tree_button1)
        self._tree.bind("<Double-1>", self._on_tree_double)
        self._tree.bind("<Configure>", lambda _e: self._schedule_place_tree_audio_overlay())
        self._tree.bind("<MouseWheel>", lambda _e: self._schedule_place_tree_audio_overlay())
        self._tree.bind("<Button-4>", lambda _e: self._schedule_place_tree_audio_overlay())
        self._tree.bind("<Button-5>", lambda _e: self._schedule_place_tree_audio_overlay())

        self.protocol("WM_DELETE_WINDOW", self._on_close)
        self._update_sqlite_only_ui()

    def _run_sql_file_dialog(self) -> None:
        if psycopg is None:
            messagebox.showerror(
                "Run SQL file",
                "psycopg is not installed.\n\n  pip install psycopg[binary]",
                parent=self,
            )
            return
        dsn = _postgres_dsn_from_config()
        if not dsn:
            messagebox.showerror(
                "Run SQL file",
                "DATABASE_URL is not set.\n\n"
                "Add it to dbutil/.env or dbutil/.env.local "
                "(Supabase Dashboard → Connect → URI), "
                "or set SUPABASE_DB_URL / POSTGRES_URL.",
                parent=self,
            )
            return

        path = filedialog.askopenfilename(
            parent=self,
            title="Choose SQL migration file",
            filetypes=[("SQL", "*.sql"), ("All files", "*.*")],
        )
        if not path:
            return

        try:
            sql_text = Path(path).read_text(encoding="utf-8")
        except OSError as e:
            messagebox.showerror("Run SQL file", str(e), parent=self)
            return

        statements = _parse_migration_sql_script(sql_text)
        if not statements:
            messagebox.showinfo(
                "Run SQL file",
                "No executable statements found (empty file or comments only).",
                parent=self,
            )
            return

        target = _pg_dsn_title(dsn)
        if not messagebox.askokcancel(
            "Run SQL file",
            f"Apply {len(statements)} statement(s) from:\n{path}\n\n"
            f"Target: {target}\n(DATABASE_URL from environment / dbutil/.env / .env.local)\n\n"
            "DDL can change or destroy data. Continue?",
            parent=self,
        ):
            return

        dlg = tk.Toplevel(self)
        dlg.title("Run SQL file")
        dlg.transient(self)
        dlg.geometry("720x420")
        frm = ttk.Frame(dlg, padding=8)
        frm.pack(fill=tk.BOTH, expand=True)
        ttk.Label(frm, text=f"File: {path}", wraplength=680).pack(anchor=tk.W)
        ttk.Label(frm, text=f"Target: {target}", wraplength=680).pack(anchor=tk.W)

        out = scrolledtext.ScrolledText(frm, height=12, wrap=tk.WORD, state=tk.DISABLED)
        out.pack(fill=tk.BOTH, expand=True, pady=8)

        def append_log(s: str) -> None:
            out.configure(state=tk.NORMAL)
            out.insert(tk.END, s)
            out.see(tk.END)
            out.configure(state=tk.DISABLED)

        btn_close = ttk.Button(frm, text="Close", command=dlg.destroy)
        btn_close.pack(side=tk.LEFT, padx=4)

        def job() -> None:
            def log_start() -> None:
                append_log(f"Executing {len(statements)} statement(s)…\n\n")

            self.after(0, log_start)
            exec_state: dict[str, Any] = {"failed": False, "err": ""}
            try:
                with psycopg.connect(dsn, autocommit=True) as conn:
                    with conn.cursor() as cur:
                        for i, stmt in enumerate(statements, start=1):
                            preview = stmt.strip().replace("\n", " ")
                            if len(preview) > 160:
                                preview = preview[:157] + "…"

                            ok_line = f"  [{i}/{len(statements)}] {preview}\n    OK\n"

                            def log_ok(line: str = ok_line) -> None:
                                append_log(line)

                            try:
                                cur.execute(stmt)
                                self.after(0, log_ok)
                            except Exception as ex:
                                exec_state["failed"] = True
                                exec_state["err"] = str(ex)
                                err_line = (
                                    f"  [{i}/{len(statements)}] {preview}\n"
                                    f"    ERROR: {exec_state['err']}\n"
                                )

                                def log_fail(line: str = err_line) -> None:
                                    append_log(line)

                                self.after(0, log_fail)
                                break

                if exec_state["failed"]:

                    def done_fail() -> None:
                        append_log("\nStopped after error (earlier statements may have applied).\n")
                        messagebox.showerror(
                            "Run SQL file",
                            exec_state["err"],
                            parent=dlg,
                        )

                    self.after(0, done_fail)
                else:

                    def done_ok() -> None:
                        append_log(f"\nDone: {len(statements)} statement(s) applied.\n")
                        messagebox.showinfo(
                            "Run SQL file",
                            f"Applied {len(statements)} statement(s).",
                            parent=dlg,
                        )

                    self.after(0, done_ok)
            except Exception as e:
                err = str(e)

                def done_err() -> None:
                    append_log(f"\nConnection or fatal error: {err}\n")
                    messagebox.showerror("Run SQL file", err, parent=dlg)

                self.after(0, done_err)

        threading.Thread(target=job, daemon=True).start()

    def _help_schema_vs_data(self) -> None:
        messagebox.showinfo(
            "Schema vs data sync",
            "Data sync — File → Commit to Supabase\n"
            "• Runs dbutil.py --commit (REST upsert). Optional: only edited category/word "
            "rows via --commit-modified (SQLite category.id / word.id).\n"
            "• Paste service_role JWT in the dialog or use env / key files (bypasses RLS).\n"
            "• pip install supabase\n\n"
            "Schema — File → Apply local schema (generate script)…\n"
            "• Syncs SQLite word/category ↔ Postgres words/lessons: DROP columns missing "
            "locally (data in those columns is removed), then ADD missing columns.\n"
            "• Writes dbutil/_schema_migration_run.py and runs it (DATABASE_URL + psycopg).\n\n"
            "Other\n"
            "• Help → Run SQL file… for manual .sql.\n"
            "• After server DDL, align local dict_*.db columns for full upserts.",
            parent=self,
        )

    def _commit_supabase_dialog(self) -> None:
        if self._backend != "sqlite" or not self._path:
            messagebox.showinfo(
                "Commit to Supabase",
                "Open a local SQLite dictionary (.db) first.\n\n"
                "This runs the same upload as:\n"
                "  python dbutil.py --input your.db --commit",
                parent=self,
            )
            return
        if not _DBUTIL_SCRIPT.is_file():
            messagebox.showerror(
                "Commit to Supabase",
                f"dbutil.py not found next to dbview:\n{_DBUTIL_SCRIPT}",
                parent=self,
            )
            return
        if self._dirty:
            r = messagebox.askyesnocancel(
                "Unsaved SQLite changes",
                "Commit reads the database file on disk.\n\n"
                "Yes — Save SQLite now, then continue\n"
                "No — Roll back uncommitted edits and continue (disk state without them)\n"
                "Cancel",
                parent=self,
            )
            if r is None:
                return
            if r is True:
                try:
                    assert self._conn
                    self._conn.commit()
                    self._dirty = False
                except Exception as e:
                    messagebox.showerror("Save", str(e), parent=self)
                    return
            else:
                try:
                    assert self._conn
                    self._conn.rollback()
                except Exception:
                    pass
                self._dirty = False
                self._sb_dirty_category_ids.clear()
                self._sb_dirty_word_ids.clear()

        _load_dbutil_dotenv()

        dlg = tk.Toplevel(self)
        dlg.title("Commit to Supabase")
        dlg.transient(self)
        dlg.geometry("720x520")
        frm = ttk.Frame(dlg, padding=8)
        frm.pack(fill=tk.BOTH, expand=True)
        ttk.Label(
            frm,
            text=f"SQLite file:\n{self._path}",
            wraplength=680,
        ).pack(anchor=tk.W)
        ttk.Label(
            frm,
            text=(
                "Uses dbutil.py: service_role JWT bypasses RLS. Paste a key below or use "
                "SUPABASE_SERVICE_ROLE_KEY / supabase_service_role_key.txt / .env.\n"
                "Full sync: python dbutil.py --input <file> --commit\n"
                "Modified rows only: adds --commit-modified <json> (category.id / word.id)."
            ),
            wraplength=680,
        ).pack(anchor=tk.W, pady=(12, 0))

        n_cat = len(self._sb_dirty_category_ids)
        n_word = len(self._sb_dirty_word_ids)
        mod_default = bool(n_cat or n_word)
        mod_only_var = tk.BooleanVar(value=mod_default)
        mod_chk = ttk.Checkbutton(
            frm,
            text=(
                f"Only sync rows edited here ({n_cat} categor{'y' if n_cat == 1 else 'ies'}, "
                f"{n_word} word{'s' if n_word != 1 else ''})"
            ),
            variable=mod_only_var,
        )
        mod_chk.pack(anchor=tk.W, pady=(8, 0))

        key_frm = ttk.Frame(frm)
        key_frm.pack(fill=tk.X, pady=(8, 0))
        ttk.Label(
            key_frm,
            text="Service role JWT (optional):",
        ).pack(anchor=tk.W)
        key_var = tk.StringVar(value="")
        key_ent = ttk.Entry(key_frm, textvariable=key_var, width=80, show="*")
        key_ent.pack(fill=tk.X)

        out = scrolledtext.ScrolledText(frm, height=12, wrap=tk.WORD, state=tk.DISABLED)
        out.pack(fill=tk.BOTH, expand=True, pady=8)

        def append_log(s: str) -> None:
            out.configure(state=tk.NORMAL)
            out.insert(tk.END, s)
            out.see(tk.END)
            out.configure(state=tk.DISABLED)

        btn_run = ttk.Button(frm, text="Run commit")

        def run_job() -> None:
            use_partial = bool(mod_only_var.get())
            cur_nc = len(self._sb_dirty_category_ids)
            cur_nw = len(self._sb_dirty_word_ids)
            if use_partial and not cur_nc and not cur_nw:
                self.after(
                    0,
                    lambda: messagebox.showinfo(
                        "Commit to Supabase",
                        "No edited category/word rows tracked. Uncheck “Only sync rows edited "
                        "here” for a full upload, or edit rows first.",
                        parent=dlg,
                    ),
                )
                return

            cmd: list[str] = [
                sys.executable,
                str(_DBUTIL_SCRIPT),
                "--input",
                self._path or "",
                "--commit",
            ]
            jwt_val = (key_var.get() or "").strip()
            if jwt_val:
                cmd.extend(["--key", jwt_val])

            mod_path: str | None = None
            if use_partial:
                payload = {
                    "category_ids": sorted(self._sb_dirty_category_ids),
                    "word_ids": sorted(self._sb_dirty_word_ids),
                }
                fd, mod_path = tempfile.mkstemp(
                    suffix=".dbview-commit-modified.json",
                    prefix="dimago_",
                    text=True,
                )
                try:
                    with os.fdopen(fd, "w", encoding="utf-8") as f:
                        json.dump(payload, f)
                except Exception:
                    try:
                        os.unlink(mod_path)
                    except OSError:
                        pass
                    raise
                cmd.extend(["--commit-modified", mod_path])

            def start() -> None:
                btn_run.configure(state=tk.DISABLED)
                out.configure(state=tk.NORMAL)
                out.delete("1.0", tk.END)
                out.configure(state=tk.DISABLED)
                append_log("$ " + subprocess.list2cmdline(cmd) + "\n\n")

            self.after(0, start)

            try:
                cp = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    cwd=str(_DBUTIL_SCRIPT.parent),
                    timeout=3600,
                )
                text = (cp.stdout or "") + ((cp.stderr or "") if cp.stderr else "")
                if not text.strip():
                    text = f"(exit code {cp.returncode}, no output)\n"

                def done() -> None:
                    if mod_path:
                        try:
                            os.unlink(mod_path)
                        except OSError:
                            pass
                    append_log(text)
                    btn_run.configure(state=tk.NORMAL)
                    if cp.returncode == 0:
                        self._sb_dirty_category_ids.clear()
                        self._sb_dirty_word_ids.clear()
                        messagebox.showinfo(
                            "Commit to Supabase",
                            "Commit finished successfully.",
                            parent=dlg,
                        )
                    else:
                        messagebox.showerror(
                            "Commit to Supabase",
                            f"dbutil exited with code {cp.returncode}.\nSee log in this window.",
                            parent=dlg,
                        )

                self.after(0, done)
            except subprocess.TimeoutExpired:
                def on_timeout() -> None:
                    if mod_path:
                        try:
                            os.unlink(mod_path)
                        except OSError:
                            pass
                    append_log("\n[timeout after 1 hour]\n")
                    btn_run.configure(state=tk.NORMAL)
                    messagebox.showerror("Commit", "Timed out.", parent=dlg)

                self.after(0, on_timeout)
            except Exception as e:
                err = str(e)

                def on_err() -> None:
                    if mod_path:
                        try:
                            os.unlink(mod_path)
                        except OSError:
                            pass
                    append_log(f"\n{err}\n")
                    btn_run.configure(state=tk.NORMAL)
                    messagebox.showerror("Commit", err, parent=dlg)

                self.after(0, on_err)

        btn_run.configure(command=lambda: threading.Thread(target=run_job, daemon=True).start())
        btn_run.pack(side=tk.LEFT, padx=4)
        ttk.Button(frm, text="Close", command=dlg.destroy).pack(side=tk.LEFT, padx=4)

    def _apply_local_schema_dialog(self) -> None:
        if self._backend != "sqlite" or not self._path:
            messagebox.showinfo(
                "Apply local schema",
                "Open a local SQLite dictionary (.db) first.",
                parent=self,
            )
            return
        if not _SCHEMA_MIGRATE_SCRIPT.is_file():
            messagebox.showerror(
                "Apply local schema",
                f"schema_migrate.py not found:\n{_SCHEMA_MIGRATE_SCRIPT}",
                parent=self,
            )
            return
        if self._dirty:
            r = messagebox.askyesnocancel(
                "Unsaved SQLite changes",
                "Schema compare reads the file on disk.\n\n"
                "Yes — Save now\n"
                "No — Roll back and continue\n"
                "Cancel",
                parent=self,
            )
            if r is None:
                return
            if r is True:
                try:
                    assert self._conn
                    self._conn.commit()
                    self._dirty = False
                except Exception as e:
                    messagebox.showerror("Save", str(e), parent=self)
                    return
            else:
                try:
                    assert self._conn
                    self._conn.rollback()
                except Exception:
                    pass
                self._dirty = False
                self._sb_dirty_category_ids.clear()
                self._sb_dirty_word_ids.clear()

        if psycopg is None:
            messagebox.showerror(
                "Apply local schema",
                "psycopg is not installed.\n\n  pip install psycopg[binary]",
                parent=self,
            )
            return
        dsn = _postgres_dsn_from_config()
        if not dsn:
            messagebox.showerror(
                "Apply local schema",
                "DATABASE_URL is not set (dbutil/.env or dbutil/.env.local).",
                parent=self,
            )
            return

        try:
            sm = _load_schema_migrate_module()
            stmts, report = sm.generate_alter_statements(self._path, dsn)
        except Exception as e:
            messagebox.showerror("Apply local schema", str(e), parent=self)
            return

        if not stmts:
            messagebox.showinfo(
                "Apply local schema",
                "No schema drift: Postgres columns match SQLite (word→words, "
                "category→lessons), aside from protected keys/FKs.\n\n"
                + report[:3000],
                parent=self,
            )
            return

        preview = report[:8000] + ("…" if len(report) > 8000 else "")
        if not messagebox.askokcancel(
            "Apply local schema",
            f"Will generate Python script and run {len(stmts)} ALTER(s).\n\n"
            f"Target: {_pg_dsn_title(dsn)}\n\n"
            "Includes DROP COLUMN for Postgres fields not present in your SQLite "
            "schema (irreversible data loss in those columns).\n\n"
            f"Preview:\n{preview}\n\n"
            "Continue?",
            parent=self,
        ):
            return

        out_path = _SCHEMA_MIGRATE_SCRIPT.parent / sm.GENERATED_SCRIPT_NAME
        dlg = tk.Toplevel(self)
        dlg.title("Apply local schema")
        dlg.transient(self)
        dlg.geometry("720x460")
        frm = ttk.Frame(dlg, padding=8)
        frm.pack(fill=tk.BOTH, expand=True)
        ttk.Label(frm, text=f"Script: {out_path}", wraplength=680).pack(anchor=tk.W)
        log = scrolledtext.ScrolledText(frm, height=16, wrap=tk.WORD, state=tk.DISABLED)
        log.pack(fill=tk.BOTH, expand=True, pady=6)

        def append_log(s: str) -> None:
            log.configure(state=tk.NORMAL)
            log.insert(tk.END, s)
            log.see(tk.END)
            log.configure(state=tk.DISABLED)

        ttk.Button(frm, text="Close", command=dlg.destroy).pack(side=tk.LEFT, padx=4)

        def job() -> None:
            def start() -> None:
                append_log(f"Writing {out_path.name}…\n")

            self.after(0, start)
            try:
                sm.write_migration_script(stmts, out_path)
                env = os.environ.copy()
                cp = sm.run_generated_script(out_path, env)
                text = (cp.stdout or "") + (cp.stderr or "")
                if not text.strip():
                    text = f"(exit {cp.returncode})\n"

                def done() -> None:
                    append_log(text)
                    if cp.returncode == 0:
                        messagebox.showinfo(
                            "Apply local schema",
                            f"Ran {len(stmts)} statement(s).",
                            parent=dlg,
                        )
                    else:
                        messagebox.showerror(
                            "Apply local schema",
                            f"Script exited {cp.returncode}. See log.",
                            parent=dlg,
                        )

                self.after(0, done)
            except Exception as e:
                err = str(e)

                def fail() -> None:
                    append_log(f"\n{err}\n")
                    messagebox.showerror("Apply local schema", err, parent=dlg)

                self.after(0, fail)

        threading.Thread(target=job, daemon=True).start()

    def _play_icon_photoimage(self) -> tk.PhotoImage:
        if self._play_icon_photo is None:
            self._play_icon_photo = tk.PhotoImage(master=self, data=_PLAY_ICON_GIF_B64)
        return self._play_icon_photo

    def _prepare_to_switch_database(self) -> bool:
        """If there are uncommitted changes, prompt Save / Discard / Cancel.

        Returns True to continue opening another database, False to abort.
        """
        if not self._dirty:
            return True
        r = messagebox.askyesnocancel(
            "Unsaved changes",
            "Save changes?\n\n"
            "Yes — Commit, then continue\n"
            "No — Roll back and continue\n"
            "Cancel — Stay here",
            parent=self,
        )
        if r is None:
            return False
        if r is True:
            if not self._is_connected():
                self._dirty = False
                return True
            try:
                if self._backend == "sqlite" and self._conn:
                    self._conn.commit()
                elif self._backend == "postgres" and self._pg_conn:
                    self._pg_conn.commit()
                self._dirty = False
            except Exception as e:
                messagebox.showerror("Save", str(e), parent=self)
                return False
            return True
        if self._backend == "sqlite" and self._conn:
            try:
                self._conn.rollback()
            except Exception:
                pass
            self._sb_dirty_category_ids.clear()
            self._sb_dirty_word_ids.clear()
        elif self._backend == "postgres" and self._pg_conn:
            try:
                self._pg_conn.rollback()
            except Exception:
                pass
        self._dirty = False
        return True

    def _open_sqlite(self) -> None:
        if not self._prepare_to_switch_database():
            return
        path = filedialog.askopenfilename(
            filetypes=[("SQLite", "*.db *.sqlite *.sqlite3"), ("All", "*.*")]
        )
        if not path:
            return
        try:
            self._connect_sqlite(path)
        except Exception as e:
            messagebox.showerror("Open", str(e))
            return
        self._load_table_names()

    def _connect_postgres_from_env(self) -> None:
        if psycopg is None or dict_row is None:
            messagebox.showerror(
                "Postgres",
                "psycopg is not installed.\n\n  pip install psycopg[binary]",
                parent=self,
            )
            return
        if not self._prepare_to_switch_database():
            return
        dsn = _postgres_dsn_from_config()
        if not dsn:
            messagebox.showerror(
                "Postgres",
                "DATABASE_URL is not set.\n\n"
                "Add it to dbutil/.env or dbutil/.env.local "
                "(Supabase Dashboard → Connect → URI), "
                "or set DATABASE_URL / SUPABASE_DB_URL / POSTGRES_URL in the environment.",
                parent=self,
            )
            return
        try:
            self._connect_postgres(dsn)
        except Exception as e:
            messagebox.showerror("Postgres", str(e), parent=self)
            return
        self._load_table_names()

    def _connect_sqlite(self, path: str) -> None:
        self._disconnect_all()
        self._path = path
        self._conn = sqlite3.connect(path)
        self._conn.row_factory = sqlite3.Row
        self._backend = "sqlite"
        self._dirty = False
        self.title(f"dbview — SQLite — {os.path.basename(path)}")
        self._update_sqlite_only_ui()

    def _mark_supabase_dirty_sqlite(self, table: str, sqlite_rowid: int) -> None:
        """Record SQLite ``category.id`` or ``word.id`` for partial ``--commit-modified`` sync."""
        if self._backend != "sqlite" or not self._conn:
            return
        t = (table or "").strip()
        if t not in ("category", "word"):
            return
        try:
            row = self._conn.execute(
                f'SELECT id FROM {_sql_quote_ident(t)} WHERE rowid = ?',
                (int(sqlite_rowid),),
            ).fetchone()
            if row is None:
                return
            logical_id = int(row[0])
            if t == "category":
                self._sb_dirty_category_ids.add(logical_id)
            else:
                self._sb_dirty_word_ids.add(logical_id)
        except Exception:
            pass

    def _connect_postgres(self, dsn: str) -> None:
        if psycopg is None:
            raise RuntimeError("psycopg not installed")
        self._disconnect_all()
        self._pg_dsn = dsn
        self._pg_conn = psycopg.connect(dsn, autocommit=False)
        self._backend = "postgres"
        self._dirty = False
        self.title(f"dbview — Postgres — {_pg_dsn_title(dsn)}")
        self._update_sqlite_only_ui()

    def _load_table_names(self) -> None:
        self._table_list.delete(0, tk.END)
        if self._backend == "sqlite":
            assert self._conn
            cur = self._conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table' "
                "AND (name IS NULL OR SUBSTR(name,1,7) != 'sqlite_') ORDER BY name"
            )
            for (name,) in cur:
                self._table_list.insert(tk.END, name)
        elif self._backend == "postgres":
            assert self._pg_conn
            names = list(SUPABASE_DIMAGO_TABLES)
            ph = ",".join(["%s"] * len(names))
            with self._pg_conn.cursor() as cur:
                cur.execute(
                    f"""
                    SELECT tablename FROM pg_tables
                    WHERE schemaname = 'public' AND tablename IN ({ph})
                    """,
                    names,
                )
                found = {r[0] for r in cur.fetchall()}
                cur.execute(
                    """
                    SELECT 1 FROM information_schema.tables
                    WHERE table_schema = 'auth' AND table_name = 'users'
                    """
                )
                has_auth_users = cur.fetchone() is not None
            for name in SUPABASE_DIMAGO_TABLES:
                if name in found:
                    self._table_list.insert(tk.END, name)
            if has_auth_users:
                self._table_list.insert(tk.END, "auth.users")
        else:
            return
        if self._table_list.size():
            self._table_list.selection_set(0)
            self._on_table_pick(None)

    def _on_table_pick(self, _evt: Any) -> None:
        sel = self._table_list.curselection()
        if not sel:
            return
        name = self._table_list.get(sel[0])
        self._current_table = name
        self._refresh_table()

    def _pg_map_udt_to_ui(self, udt_name: str, data_type: str) -> str:
        u = (udt_name or "").lower()
        d = (data_type or "").lower()
        if u == "bytea" or d == "bytea":
            return "BLOB"
        if u in ("int2", "int4", "int8") or "int" in d or d in ("bigint", "integer", "smallint"):
            return "INTEGER"
        if u in ("float4", "float8") or "double" in d or "real" in d or d == "numeric":
            return "REAL"
        if u == "bool" or d == "boolean":
            return "INTEGER"
        return "TEXT"

    def _load_pg_table_schema(self, tbl: str) -> None:
        assert self._pg_conn
        schema, table = _pg_split_schema_table(tbl)
        q_pk = """
            SELECT kcu.column_name
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
              ON tc.constraint_schema = kcu.constraint_schema
             AND tc.constraint_name = kcu.constraint_name
            WHERE tc.table_schema = %s AND tc.table_name = %s
              AND tc.constraint_type = 'PRIMARY KEY'
            ORDER BY kcu.ordinal_position
        """
        q_col = """
            SELECT column_name, data_type, udt_name, is_nullable, column_default
            FROM information_schema.columns
            WHERE table_schema = %s AND table_name = %s
            ORDER BY ordinal_position
        """
        with self._pg_conn.cursor() as cur:
            cur.execute(q_pk, (schema, table))
            self._pk_columns = [r[0] for r in cur.fetchall()]
            cur.execute(q_col, (schema, table))
            rows = cur.fetchall()
        self._columns = [r[0] for r in rows]
        self._col_types = {}
        self._col_meta = {}
        pk_set = set(self._pk_columns)
        for col_name, data_type, udt_name, is_nullable, col_default in rows:
            ui = self._pg_map_udt_to_ui(udt_name, data_type)
            self._col_types[col_name] = ui
            self._col_meta[col_name] = {
                "type": ui,
                "notnull": 0 if (is_nullable or "").upper() == "YES" else 1,
                "dflt": col_default,
                "pk": 1 if col_name in pk_set else 0,
            }

    def _pg_select_list_sql(self) -> str:
        """Build SELECT list. BYTEA columns return only a boolean (data present), not payload."""
        self._pg_bytea_lazy_columns.clear()
        parts: list[str] = []
        for col in self._columns:
            qcol = _sql_quote_ident(col)
            if (self._col_types.get(col, "").upper() == "BLOB"):
                parts.append(
                    f"({qcol} IS NOT NULL AND octet_length({qcol}) > 0) AS {qcol}"
                )
                self._pg_bytea_lazy_columns.add(col)
            else:
                parts.append(qcol)
        return ", ".join(parts)

    def _raw_cell_binary(self, col: str, v: Any) -> bytes | None:
        """Bytes payload for this cell, or None if not binary / not loaded (Postgres lazy BYTEA)."""
        if v is None:
            return None
        if self._backend == "postgres" and col in self._pg_bytea_lazy_columns:
            return None
        return _normalize_cell_binary(v)

    def _pg_fetch_bytea_raw(self, iid: str, col: str) -> bytes | None:
        """Load one BYTEA from Postgres (single round-trip)."""
        assert self._pg_conn and self._current_table and len(self._pk_columns) == 1
        tbl = self._current_table
        pk = self._pk_columns[0]
        val = self._pg_parse_iid(iid)
        qcol = _sql_quote_ident(col)
        q = (
            f"SELECT encode({qcol}, 'base64') AS _blob_b64 "
            f"FROM {_pg_qualified_table(tbl)} WHERE {_sql_quote_ident(pk)} = %s"
        )
        try:
            with self._pg_conn.cursor(row_factory=dict_row) as cur:
                cur.execute(q, (val,))
                row = cur.fetchone()
        except Exception as e:
            messagebox.showerror("Postgres", str(e), parent=self)
            return None
        if not row:
            return None
        s = row.get("_blob_b64")
        if s is None:
            return None
        if isinstance(s, str):
            s = s.strip()
            if not s:
                return b""
            try:
                return base64.b64decode(s, validate=False)
            except Exception:
                return None
        return _normalize_cell_binary(s)

    def _open_lazy_pg_blob(self, iid: str, col: str) -> None:
        """Fetch BYTEA on demand; play audio, show image, or report unknown binary."""
        data = self._pg_fetch_bytea_raw(iid, col)
        if data is None:
            messagebox.showinfo("BLOB", "Could not load this cell.", parent=self)
            return
        if not data:
            messagebox.showinfo("BLOB", "Empty BLOB.", parent=self)
            return
        kind = _sniff_blob_kind(data)
        if kind == "audio":
            self._play_audio_blob(data)
        elif kind == "image":
            self._show_image_blob(data)
        else:
            messagebox.showinfo(
                "BLOB",
                f"Loaded {len(data)} bytes (not recognized as audio or image).",
                parent=self,
            )

    def _refresh_table(self) -> None:
        if not self._current_table or not self._is_connected():
            return
        self._cancel_tree_audio_place_schedule()
        self._destroy_tree_audio_overlay_widgets()
        self._tree_audio_blobs.clear()
        self._tree_lazy_blob_cells.clear()
        self._pg_bytea_lazy_columns.clear()
        tbl = self._current_table
        for c in self._tree.get_children():
            self._tree.delete(c)

        if self._backend == "sqlite":
            assert self._conn
            info = self._conn.execute(f"PRAGMA table_info({_sql_quote_ident(tbl)})").fetchall()
            self._columns = [r[1] for r in info]
            self._col_types = {r[1]: (r[2] or "").upper() for r in info}
            self._col_meta = {
                r[1]: {"type": r[2] or "", "notnull": int(r[3] or 0), "dflt": r[4], "pk": int(r[5] or 0)}
                for r in info
            }
            self._pk_columns = []

            disp_cols = ["rowid"] + self._columns
            self._tree["columns"] = disp_cols
            for c in disp_cols:
                self._tree.heading(c, text=c)
                self._tree.column(c, width=min(180, 80 + len(c) * 8), stretch=True)

            q = f'SELECT rowid AS "_rowid_", * FROM {_sql_quote_ident(tbl)}'
            try:
                rows = self._conn.execute(q).fetchall()
            except sqlite3.Error as e:
                messagebox.showerror("Query", str(e))
                return

            for row in rows:
                rid = row["_rowid_"]
                cells = []
                for col in self._columns:
                    v = row[col]
                    cells.append(self._cell_display(v, col))
                    nb = self._raw_cell_binary(col, v)
                    if nb is not None and _sniff_blob_kind(nb) == "audio":
                        self._tree_audio_blobs[(str(rid), col)] = bytes(nb)
                self._tree.insert("", tk.END, iid=str(rid), values=(rid, *cells))
            self._schedule_place_tree_audio_overlay()
            return

        # Postgres
        assert self._pg_conn
        self._load_pg_table_schema(tbl)
        if len(self._pk_columns) != 1:
            messagebox.showerror(
                "Postgres",
                f'Table "{tbl}" must have a single-column primary key for this viewer '
                f"(got {self._pk_columns!r}).",
            )
            return

        disp_cols = self._columns
        self._tree["columns"] = disp_cols
        for c in disp_cols:
            self._tree.heading(c, text=c)
            self._tree.column(c, width=min(180, 80 + len(c) * 8), stretch=True)

        pk = self._pk_columns[0]
        select_sql = self._pg_select_list_sql()
        q = (
            f'SELECT {select_sql} FROM {_pg_qualified_table(tbl)} '
            f'ORDER BY {_sql_quote_ident(pk)} LIMIT {PG_ROW_LIMIT}'
        )
        try:
            with self._pg_conn.cursor(row_factory=dict_row) as cur:
                cur.execute(q)
                rows = cur.fetchall()
        except Exception as e:
            messagebox.showerror("Query", str(e))
            return

        for row in rows:
            pk_val = row[pk]
            iid = self._pg_iid_from_pk(pk_val)
            cells = []
            for c in self._columns:
                v = row[c]
                cells.append(self._cell_display(v, c))
                if c in self._pg_bytea_lazy_columns and v is True:
                    self._tree_lazy_blob_cells.add((iid, c))
            self._tree.insert("", tk.END, iid=iid, values=tuple(cells))
        self._schedule_place_tree_audio_overlay()

    def _pg_iid_from_pk(self, pk_val: Any) -> str:
        if isinstance(pk_val, (bytes, memoryview)):
            return "b64:" + base64.b64encode(bytes(pk_val)).decode("ascii")
        return str(pk_val)

    def _pg_parse_iid(self, iid: str) -> Any:
        if iid.startswith("b64:"):
            return base64.b64decode(iid[4:])
        if re.fullmatch(r"-?\d+", iid):
            return int(iid, 10)
        return iid

    def _cell_display(self, v: Any, col: str) -> str:
        if v is None:
            return ""
        if (
            self._backend == "postgres"
            and col in self._pg_bytea_lazy_columns
            and v is True
        ):
            return "\u25b6"
        if (
            self._backend == "postgres"
            and col in self._pg_bytea_lazy_columns
            and v is False
        ):
            return ""
        nb = self._raw_cell_binary(col, v)
        if nb is not None:
            k = _sniff_blob_kind(nb)
            if k == "audio":
                return "\u25b6"  # ▶ + overlay play icon (same as edit dialog)
            if k:
                return f"<{k} {len(nb)} bytes>"
            return f"<binary {len(nb)} bytes>"
        s = str(v)
        if len(s) > 120:
            return s[:117] + "…"
        return s

    def _fetch_row_sqlite(self, rowid: int) -> sqlite3.Row | None:
        assert self._conn and self._current_table
        q = f'SELECT rowid AS "_rowid_", * FROM {_sql_quote_ident(self._current_table)} WHERE rowid = ?'
        return self._conn.execute(q, (rowid,)).fetchone()

    def _fetch_row_pg(self, iid: str) -> dict[str, Any] | None:
        assert self._pg_conn and self._current_table and len(self._pk_columns) == 1
        tbl = self._current_table
        pk = self._pk_columns[0]
        val = self._pg_parse_iid(iid)
        select_sql = self._pg_select_list_sql()
        q = (
            f'SELECT {select_sql} FROM {_pg_qualified_table(tbl)} '
            f'WHERE {_sql_quote_ident(pk)} = %s'
        )
        with self._pg_conn.cursor(row_factory=dict_row) as cur:
            cur.execute(q, (val,))
            return cur.fetchone()

    def _fetch_row_by_iid(self, iid: str) -> Any:
        if self._backend == "sqlite":
            return self._fetch_row_sqlite(int(iid))
        if self._backend == "postgres":
            return self._fetch_row_pg(iid)
        return None

    def _tree_column_from_ident(self, ident: str) -> str | None:
        if not ident.startswith("#"):
            return None
        try:
            n = int(ident[1:])
        except ValueError:
            return None
        cols = list(self._tree["columns"])
        idx = n - 1
        if 0 <= idx < len(cols):
            return cols[idx]
        return None

    def _cancel_scheduled_tree_play(self) -> None:
        if self._tree_play_after_id is not None:
            self.after_cancel(self._tree_play_after_id)
            self._tree_play_after_id = None

    def _on_tree_button1(self, event: tk.Event) -> None:
        if self._tree.identify_region(event.x, event.y) != "cell":
            return
        row = self._tree.identify_row(event.y)
        col = self._tree.identify_column(event.x)
        if not row or not col:
            return
        name = self._tree_column_from_ident(col)
        if not name or name == "rowid":
            return
        r = self._fetch_row_by_iid(row)
        if not r:
            return
        v = r[name]
        if (
            self._backend == "postgres"
            and name in self._pg_bytea_lazy_columns
            and v is True
        ):
            self._cancel_scheduled_tree_play()
            iid = row

            def fire() -> None:
                self._tree_play_after_id = None
                self._open_lazy_pg_blob(iid, name)

            self._tree_play_after_id = self.after(280, fire)
            return
        nb = self._raw_cell_binary(name, v)
        if not (nb is not None and _sniff_blob_kind(nb) == "audio"):
            return
        self._cancel_scheduled_tree_play()
        blob = nb

        def fire() -> None:
            self._tree_play_after_id = None
            self._play_audio_blob(blob)

        self._tree_play_after_id = self.after(280, fire)

    def _on_tree_double(self, _event: tk.Event) -> None:
        self._cancel_scheduled_tree_play()
        self._edit_row()

    def _add_row(self) -> None:
        if not self._is_connected() or not self._current_table:
            return
        if not self._columns:
            messagebox.showinfo("Add row", "Select a table first.")
            return

        pk_cols = [c for c in self._columns if self._col_meta.get(c, {}).get("pk")]
        single_int_pk = (
            len(pk_cols) == 1
            and "INT" in (self._col_meta[pk_cols[0]]["type"] or "").upper()
        )

        dlg = tk.Toplevel(self)
        dlg.title(f"Add row — {self._current_table}")
        dlg.transient(self)
        dlg.grab_set()
        frm = ttk.Frame(dlg, padding=8)
        frm.pack(fill=tk.BOTH, expand=True)

        entries: dict[str, tk.StringVar] = {}
        r = 0
        for col in self._columns:
            meta = self._col_meta[col]
            ct = (meta["type"] or "").upper()
            extra = ""
            if meta["pk"] and single_int_pk and "INT" in ct:
                extra = " (empty → auto)"
            ttk.Label(frm, text=f"{col}{extra}").grid(row=r, column=0, sticky=tk.NW, pady=2)
            if "BLOB" in ct:
                ttk.Label(
                    frm,
                    text="NULL — use Edit row after insert to set BLOB",
                ).grid(row=r, column=1, sticky=tk.W, pady=2)
            else:
                dflt = meta["dflt"]
                init = "" if dflt is None else str(dflt)
                var = tk.StringVar(value=init)
                entries[col] = var
                ttk.Entry(frm, textvariable=var, width=64).grid(row=r, column=1, sticky=tk.EW, pady=2)
            r += 1

        frm.columnconfigure(1, weight=1)

        def coerce(col: str, raw: str) -> Any:
            meta = self._col_meta[col]
            pk = int(meta["pk"] or 0)
            notnull = int(meta["notnull"] or 0)
            t = (meta["type"] or "").upper()
            s = raw.strip()
            if "BLOB" in t:
                return None
            if pk and not s and single_int_pk and col == pk_cols[0] and "INT" in t:
                return _OMIT_INSERT
            if pk and not s:
                raise ValueError(f'Column "{col}" is a primary key and cannot be empty.')
            if not s:
                if notnull == 0:
                    return None
                if "INT" in t:
                    return 0
                if "REAL" in t or "FLOA" in t or "DOUB" in t:
                    return 0.0
                return ""
            try:
                if "INT" in t:
                    return int(s, 10)
                if "REAL" in t or "FLOA" in t or "DOUB" in t:
                    return float(s)
            except ValueError as e:
                raise ValueError(f'Column "{col}": invalid numeric value.') from e
            return s

        def apply_insert() -> None:
            cols_out: list[str] = []
            vals_out: list[Any] = []
            for col in self._columns:
                meta = self._col_meta[col]
                ct = (meta["type"] or "").upper()
                if "BLOB" in ct:
                    continue
                if col not in entries:
                    continue
                try:
                    v = coerce(col, entries[col].get())
                except ValueError as e:
                    messagebox.showerror("Add row", str(e), parent=dlg)
                    return
                if v is _OMIT_INSERT:
                    continue
                cols_out.append(col)
                vals_out.append(v)
            if not cols_out:
                messagebox.showerror("Add row", "No columns to insert.", parent=dlg)
                return
            quoted = ",".join(_sql_quote_ident(c) for c in cols_out)
            tbl = self._current_table
            try:
                if self._backend == "sqlite":
                    assert self._conn
                    ph = ",".join("?" * len(vals_out))
                    sql = f'INSERT INTO {_sql_quote_ident(tbl)} ({quoted}) VALUES ({ph})'
                    self._conn.execute(sql, vals_out)
                    new_rid = int(
                        self._conn.execute("SELECT last_insert_rowid()").fetchone()[0]
                    )
                else:
                    assert self._pg_conn
                    ph = ",".join(["%s"] * len(vals_out))
                    rpk = _sql_quote_ident(pk_cols[0])
                    sql = (
                        f'INSERT INTO {_pg_qualified_table(tbl)} ({quoted}) '
                        f'VALUES ({ph}) RETURNING {rpk}'
                    )
                    with self._pg_conn.cursor() as cur:
                        cur.execute(sql, vals_out)
                        new_rid = cur.fetchone()[0]
            except Exception as e:
                messagebox.showerror("Add row", str(e), parent=dlg)
                return
            self._dirty = True
            if self._backend == "sqlite" and tbl in ("category", "word"):
                self._mark_supabase_dirty_sqlite(tbl, int(new_rid))
            self._refresh_table()
            dlg.destroy()
            iid = self._pg_iid_from_pk(new_rid) if self._backend == "postgres" else str(new_rid)
            if iid in self._tree.get_children():
                self._tree.selection_set(iid)
                self._tree.focus(iid)
                self._tree.see(iid)

        btnf = ttk.Frame(frm)
        btnf.grid(row=r, column=0, columnspan=2, pady=12)
        ttk.Button(btnf, text="Apply (INSERT row)", command=apply_insert).pack(side=tk.LEFT, padx=4)
        ttk.Button(btnf, text="Cancel", command=dlg.destroy).pack(side=tk.LEFT, padx=4)

    def _column_is_blob_like(self, col: str) -> bool:
        """True for BYTEA/BLOB columns, or any column whose name contains ``audio`` (app convention: audio BLOB)."""
        if "audio" in col.lower():
            return True
        meta = self._col_meta.get(col, {})
        t = (meta.get("type") or "").upper()
        if "BLOB" in t or "BYTEA" in t:
            return True
        return (self._col_types.get(col, "") or "").upper() == "BYTEA"

    def _tts_source_column_names(self) -> list[str]:
        return [c for c in self._columns if not self._column_is_blob_like(c)]

    @staticmethod
    def _normalize_category_lang_code(raw: object) -> str | None:
        """Strip ``lang_translate`` / ``lang_native`` cell text; use segment before ``:`` if present."""
        if raw is None:
            return None
        s = str(raw).strip()
        if not s:
            return None
        if ":" in s:
            s = s.split(":", 1)[0].strip()
        return s if s else None

    def _edit_row_resolve_category_index(
        self,
        row: Any,
        entries: dict[str, tk.Variable],
    ) -> int | None:
        """SQLite ``word.category_index`` from staged entries or loaded row."""
        if (self._current_table or "").lower() != "word":
            return None
        ev = entries.get("category_index")
        if ev is not None:
            s = (ev.get() or "").strip()
            if s:
                try:
                    return int(s, 10)
                except ValueError:
                    pass
        try:
            raw = row["category_index"]
            if raw is not None:
                return int(raw)
        except (KeyError, TypeError, ValueError):
            pass
        return None

    def _edit_row_resolve_lesson_id(
        self,
        row: Any,
        entries: dict[str, tk.Variable],
    ) -> int | None:
        """Postgres ``words.lesson_id`` from staged entries or loaded row (FK to ``lessons``)."""
        if (self._current_table or "").lower() != "words":
            return None
        ev = entries.get("lesson_id")
        if ev is not None:
            s = (ev.get() or "").strip()
            if s:
                try:
                    return int(s, 10)
                except ValueError:
                    pass
        try:
            raw = row["lesson_id"]
            if raw is not None:
                return int(raw)
        except (KeyError, TypeError, ValueError):
            pass
        return None

    @staticmethod
    def _tts_lang_column_for_blob_name(blob_col: str) -> str | None:
        """``lang_translate`` if the column name suggests translate audio; ``lang_native`` for native; else None."""
        lc = blob_col.lower()
        if "translate" in lc:
            return "lang_translate"
        if "native" in lc:
            return "lang_native"
        return None

    def _pg_fetch_lessons_lang(self, lesson_pk: int, col: str) -> object | None:
        assert col in ("lang_translate", "lang_native")
        if not self._pg_conn:
            return None
        qtbl = _sql_quote_ident("lessons")
        qcol = _sql_quote_ident(col)
        qid = _sql_quote_ident("id")
        sql = f"SELECT {qcol} FROM {qtbl} WHERE {qid} = %s"
        try:
            with self._pg_conn.cursor() as cur:
                cur.execute(sql, (lesson_pk,))
                r = cur.fetchone()
                return r[0] if r else None
        except Exception:
            return None

    def _default_tts_lang_for_blob_column(
        self,
        blob_col: str,
        row: Any,
        entries: dict[str, tk.Variable],
    ) -> tuple[str | None, str | None]:
        """Default TTS language from category/lessons; hint text for the dialog. ``(None, None)`` if not applicable."""
        colname = self._tts_lang_column_for_blob_name(blob_col)
        if not colname:
            return None, None
        tbl = (self._current_table or "").lower()
        try:
            if self._backend == "sqlite" and self._conn:
                if tbl == "word":
                    cid = self._edit_row_resolve_category_index(row, entries)
                    if cid is None:
                        return None, None
                    r = self._conn.execute(
                        f"SELECT {_sql_quote_ident(colname)} FROM {_sql_quote_ident('category')} WHERE id = ?",
                        (cid,),
                    ).fetchone()
                    if r:
                        code = self._normalize_category_lang_code(r[0])
                        return code, f"category.{colname}"
                elif tbl == "category":
                    ev = entries.get(colname)
                    if ev is not None:
                        v = self._normalize_category_lang_code(ev.get())
                        if v:
                            return v, f"category.{colname}"
                    return (
                        self._normalize_category_lang_code(row[colname]),
                        f"category.{colname}",
                    )
            elif self._backend == "postgres" and self._pg_conn:
                if tbl == "words":
                    lid = self._edit_row_resolve_lesson_id(row, entries)
                    if lid is None:
                        return None, None
                    raw = self._pg_fetch_lessons_lang(lid, colname)
                    code = self._normalize_category_lang_code(raw)
                    return code, f"lessons.{colname}"
                elif tbl == "lessons":
                    ev = entries.get(colname)
                    if ev is not None:
                        v = self._normalize_category_lang_code(ev.get())
                        if v:
                            return v, f"lessons.{colname}"
                    return (
                        self._normalize_category_lang_code(row[colname]),
                        f"lessons.{colname}",
                    )
        except (sqlite3.Error, KeyError, TypeError):
            pass
        return None, None

    def _default_tts_source_field_for_blob(self, blob_col: str, sources: list[str]) -> str | None:
        tgt = TTS_BLOB_DEFAULT_SOURCE_COLUMN.get(blob_col)
        if tgt and tgt in sources:
            return tgt
        return None

    def _open_tts_update_blob_dialog(
        self,
        blob_col: str,
        parent: tk.Toplevel,
        *,
        get_source_text: Callable[[str], str],
        on_tts_done: Callable[[bytes], None],
        default_lang_code: str | None = None,
        default_lang_hint: str | None = None,
        default_source_field: str | None = None,
    ) -> None:
        """Prompt for language + source field; TTS audio is passed to ``on_tts_done`` (staged)."""
        synth, import_err = _get_dbutil_synthesize_tts()
        if synth is None:
            messagebox.showerror(
                "TTS",
                "Could not load dbutil.synthesize_tts (needs dbutil.py + requests next to dbview).\n"
                + (import_err or "unknown error"),
                parent=parent,
            )
            return
        sources = self._tts_source_column_names()
        if not sources:
            messagebox.showerror(
                "TTS",
                "This table has no non-BLOB columns to use as speech source text.",
                parent=parent,
            )
            return

        sub = tk.Toplevel(parent)
        sub.title(f"TTS → {blob_col}")
        sub.transient(parent)
        sub.grab_set()
        sf = ttk.Frame(sub, padding=10)
        sf.pack(fill=tk.BOTH, expand=True)
        init_lang = (default_lang_code or "").strip() or "EN"
        ttk.Label(
            sf,
            text="Language / country code (TH, CN, EN, JA, … — same as dbutil / Flutter):",
            wraplength=420,
        ).grid(row=0, column=0, columnspan=2, sticky=tk.W)
        if (default_lang_code or "").strip():
            hint = (default_lang_hint or "category / lesson language").strip()
            ttk.Label(
                sf,
                text=f"(Prefilled from {hint}.)",
                foreground="gray",
                wraplength=420,
            ).grid(row=1, column=0, columnspan=2, sticky=tk.W)
            lang_row = 2
            field_label_row = 3
            field_cb_row = 4
            status_row = 5
            btn_row_idx = 6
        else:
            lang_row = 1
            field_label_row = 2
            field_cb_row = 3
            status_row = 4
            btn_row_idx = 5
        lang_var = tk.StringVar(value=init_lang)
        ttk.Entry(sf, textvariable=lang_var, width=32).grid(
            row=lang_row, column=0, columnspan=2, sticky=tk.EW, pady=(4, 12)
        )
        ttk.Label(sf, text="Data field name (text column to speak):").grid(
            row=field_label_row, column=0, columnspan=2, sticky=tk.W
        )
        init_field = (
            default_source_field
            if (default_source_field and default_source_field in sources)
            else (sources[0] if sources else "")
        )
        if default_source_field and default_source_field in sources:
            ttk.Label(
                sf,
                text=f"(Default source for {blob_col} → {default_source_field}.)",
                foreground="gray",
                wraplength=420,
            ).grid(row=field_cb_row, column=0, columnspan=2, sticky=tk.W)
            field_cb_row += 1
            btn_row_idx += 1
            status_row += 1
        field_var = tk.StringVar(value=init_field)
        field_cb = ttk.Combobox(sf, textvariable=field_var, values=sources, width=40)
        field_cb.grid(row=field_cb_row, column=0, columnspan=2, sticky=tk.EW, pady=(4, 12))
        sf.columnconfigure(0, weight=1)

        status = tk.StringVar(value="")
        ttk.Label(sf, textvariable=status, foreground="gray").grid(
            row=status_row, column=0, columnspan=2, sticky=tk.W
        )

        btn_row = ttk.Frame(sf)
        btn_row.grid(row=btn_row_idx, column=0, columnspan=2, pady=(12, 0))

        def on_confirm() -> None:
            code = lang_var.get().strip()
            fld = field_var.get().strip()
            if not code:
                messagebox.showerror("TTS", "Enter a language / country code.", parent=sub)
                return
            if not fld:
                messagebox.showerror("TTS", "Choose or enter a text column name.", parent=sub)
                return
            if fld not in self._columns:
                messagebox.showerror("TTS", f"No column {fld!r} in this table.", parent=sub)
                return
            if self._column_is_blob_like(fld):
                messagebox.showerror(
                    "TTS",
                    "Source must be a text column, not BLOB/BYTEA.",
                    parent=sub,
                )
                return
            text = get_source_text(fld)
            if not text:
                messagebox.showerror(
                    "TTS",
                    f'Column "{fld}" is empty in the edit form — type text or Apply text edits first.',
                    parent=sub,
                )
                return

            ok_btn.configure(state=tk.DISABLED)
            cancel_btn.configure(state=tk.DISABLED)
            status.set("Requesting audio from Google Translate TTS…")

            def work() -> None:
                audio = synth(text, code)

                def finish() -> None:
                    ok_btn.configure(state=tk.NORMAL)
                    cancel_btn.configure(state=tk.NORMAL)
                    status.set("")
                    if not audio:
                        messagebox.showerror(
                            "TTS",
                            "No audio returned (check console for HTTP errors).",
                            parent=sub,
                        )
                        return
                    try:
                        audio_b = bytes(audio)
                    except (TypeError, ValueError):
                        messagebox.showerror("TTS", "Invalid audio payload from TTS.", parent=sub)
                        return
                    try:
                        self._play_audio_blob(audio_b)
                    except Exception as ex:  # noqa: BLE001
                        messagebox.showwarning(
                            "TTS",
                            f"Playback could not start ({ex}).\n"
                            "Audio is still staged for the BLOB column.",
                            parent=sub,
                        )
                    try:
                        on_tts_done(audio_b)
                    except Exception as ex:  # noqa: BLE001
                        messagebox.showerror("TTS", str(ex), parent=sub)
                        return
                    sub.destroy()

                self.after(0, finish)

            threading.Thread(target=work, daemon=True).start()

        ok_btn = ttk.Button(btn_row, text="Confirm", command=on_confirm)
        ok_btn.pack(side=tk.LEFT, padx=4)
        cancel_btn = ttk.Button(btn_row, text="Cancel", command=sub.destroy)
        cancel_btn.pack(side=tk.LEFT, padx=4)

        sub.update_idletasks()
        rw = sub.winfo_reqwidth()
        rh = sub.winfo_reqheight()
        sw = sub.winfo_screenwidth()
        sh = sub.winfo_screenheight()
        sub.geometry(
            f"+{max(0, (sw - rw) // 2)}+{max(0, (sh - rh) // 2)}"
        )

    def _edit_row(self) -> None:
        if not self._is_connected() or not self._current_table:
            return
        sel = self._tree.selection()
        if not sel:
            messagebox.showinfo("Edit", "Select a row first.")
            return
        row_key = sel[0]
        row = self._fetch_row_by_iid(row_key)
        if not row:
            messagebox.showerror("Edit", "Row not found.")
            return

        dlg = tk.Toplevel(self)
        dlg.title(
            f"Edit row — {self._current_table} — pk={row_key}"
            if self._backend == "postgres"
            else f"Edit row rowid={row_key}"
        )
        dlg.transient(self)
        dlg.grab_set()
        frm = ttk.Frame(dlg, padding=8)
        frm.pack(fill=tk.BOTH, expand=True)

        # Staged copy of BLOB/BYTEA columns; text fields use StringVars in ``entries``.
        blob_buffer: dict[str, bytes | None] = {}
        for col in self._columns:
            if not self._column_is_blob_like(col):
                continue
            val = row[col]
            if self._backend == "postgres" and col in self._pg_bytea_lazy_columns:
                if val is True:
                    raw = self._pg_fetch_bytea_raw(row_key, col)
                    blob_buffer[col] = bytes(raw) if raw else b""
                elif val is False:
                    blob_buffer[col] = b""
                else:
                    blob_buffer[col] = None
            else:
                nb = self._raw_cell_binary(col, val)
                if nb is not None:
                    blob_buffer[col] = bytes(nb)
                elif val is None:
                    blob_buffer[col] = None
                elif isinstance(val, (bytes, bytearray, memoryview)):
                    blob_buffer[col] = bytes(val)
                else:
                    blob_buffer[col] = b""

        entries: dict[str, tk.Variable] = {}
        blob_frames: dict[str, ttk.Frame] = {}

        def get_source_text(fld: str) -> str:
            ev = entries.get(fld)
            if ev is not None:
                return (ev.get() or "").strip()
            return ""

        def clear_staged_blob(c: str) -> None:
            if not messagebox.askyesno(
                "Clear BLOB",
                f'Set staged column "{c}" to SQL NULL?\n'
                "Apply (UPDATE this row) writes all staged changes.",
                parent=dlg,
            ):
                return
            blob_buffer[c] = None
            rebuild_blob_ui(c)

        def open_tts_for_col(bc: str) -> None:
            def done(audio_b: bytes) -> None:
                blob_buffer[bc] = audio_b
                rebuild_blob_ui(bc)

            src_cols = self._tts_source_column_names()
            d_lang, d_lang_hint = self._default_tts_lang_for_blob_column(bc, row, entries)
            d_field = self._default_tts_source_field_for_blob(bc, src_cols)
            self._open_tts_update_blob_dialog(
                bc,
                dlg,
                get_source_text=get_source_text,
                on_tts_done=done,
                default_lang_code=d_lang,
                default_lang_hint=d_lang_hint,
                default_source_field=d_field,
            )

        def rebuild_blob_ui(col: str) -> None:
            bf = blob_frames[col]
            for w in bf.winfo_children():
                w.destroy()
            buf = blob_buffer.get(col)
            if buf is None:
                ttk.Button(
                    bf,
                    text="Update (TTS)",
                    command=lambda c=col: open_tts_for_col(c),
                ).pack(side=tk.LEFT, padx=2)
                ttk.Label(
                    bf,
                    text="(NULL — staged; Apply writes to DB)",
                ).pack(side=tk.LEFT, padx=4)
                return
            data = buf
            if len(data) == 0:
                ttk.Button(
                    bf,
                    text="Update (TTS)",
                    command=lambda c=col: open_tts_for_col(c),
                ).pack(side=tk.LEFT, padx=2)
                ttk.Label(bf, text="(empty BLOB — staged)").pack(side=tk.LEFT, padx=4)
                return
            kind = _sniff_blob_kind(data) if data else None
            if kind == "audio" and data:
                ttk.Button(
                    bf,
                    image=self._play_icon_photoimage(),
                    command=lambda c=col: self._play_audio_blob(blob_buffer[c] or b""),
                ).pack(side=tk.LEFT, padx=2)
                ttk.Button(
                    bf,
                    text="Clear",
                    command=lambda c=col: clear_staged_blob(c),
                ).pack(side=tk.LEFT, padx=2)
            elif kind == "image" and data:
                ttk.Button(
                    bf,
                    text="Photo",
                    command=lambda c=col: self._show_image_blob(blob_buffer[c] or b""),
                ).pack(side=tk.LEFT, padx=2)
            else:
                ttk.Label(
                    bf,
                    text=f"<binary {len(data)} bytes>",
                ).pack(side=tk.LEFT, padx=4)
            ttk.Button(
                bf,
                text="Update (TTS)",
                command=lambda c=col: open_tts_for_col(c),
            ).pack(side=tk.LEFT, padx=2)
            ttk.Label(
                bf,
                text=f"BLOB ({len(data)} bytes)" + (f" [{kind}]" if kind else ""),
            ).pack(side=tk.LEFT, padx=4)

        r = 0
        ttk.Label(
            frm,
            text=(
                "Edits are staged here: change text, TTS, and Clear as needed, then "
                "Apply (UPDATE this row) once to write every column. TTS uses the text "
                "currently shown in the fields (no need to Apply text first). "
                "After Apply, use File → Save to persist the SQLite file."
            ),
            wraplength=640,
        ).grid(row=r, column=0, columnspan=2, sticky=tk.W, pady=(0, 8))
        r += 1

        sample1_apply_holder: list[ttk.Button] = []

        for col in self._columns:
            ttk.Label(frm, text=col).grid(row=r, column=0, sticky=tk.NW, pady=2)
            val = row[col]
            meta = self._col_meta.get(col, {})

            if self._backend == "postgres" and meta.get("pk"):
                ttk.Label(frm, text="" if val is None else str(val)).grid(
                    row=r, column=1, sticky=tk.W, pady=2
                )
                r += 1
                continue

            if self._column_is_blob_like(col):
                bf = ttk.Frame(frm)
                bf.grid(row=r, column=1, sticky=tk.EW, pady=2)
                blob_frames[col] = bf
                rebuild_blob_ui(col)
                r += 1
                continue

            var = tk.StringVar(value="" if val is None else str(val))
            entries[col] = var
            _sample1_cols = (
                "sample1_native",
                "sample1_native_audio",
                "sample1_translate",
                "sample1_translate_roman",
                "sample1_translate_audio",
            )
            is_sample1_native_apply = (
                self._backend == "sqlite"
                and (self._current_table or "").lower() == "word"
                and col == "sample1_native"
                and bool(self._path)
                and all(c in self._columns for c in _sample1_cols)
            )
            if is_sample1_native_apply:
                row_fr = ttk.Frame(frm)
                row_fr.grid(row=r, column=1, sticky=tk.EW, pady=2)
                row_fr.columnconfigure(0, weight=1)
                ttk.Entry(row_fr, textvariable=var, width=52).grid(
                    row=0, column=0, sticky=tk.EW
                )
                ab = ttk.Button(row_fr, text="Apply")
                ab.grid(row=0, column=1, sticky=tk.E, padx=(8, 0))
                sample1_apply_holder.append(ab)
            else:
                ttk.Entry(frm, textvariable=var, width=64).grid(
                    row=r, column=1, sticky=tk.EW, pady=2
                )
            r += 1

        def run_sample1_native_pipeline() -> None:
            path = self._path
            if not path:
                return
            try:
                ensure_dimago_db_scripts_on_path()
                import dbutil as _du  # noqa: PLC0415
            except Exception as ex:  # noqa: BLE001
                messagebox.showerror(
                    "Apply sample1",
                    f"Could not load dbutil: {ex}",
                    parent=dlg,
                )
                return
            native = (entries.get("sample1_native") and entries["sample1_native"].get() or "").strip()
            if not native:
                messagebox.showwarning(
                    "Apply sample1",
                    "sample1_native is empty — enter text first.",
                    parent=dlg,
                )
                return
            btn = sample1_apply_holder[0] if sample1_apply_holder else None

            def finish_ui(
                *,
                native_audio: bytes | None,
                translated: str | None,
                roman: str | None,
                translate_audio: bytes | None,
                err: str | None,
                warn: str | None,
            ) -> None:
                if btn is not None:
                    btn.state(["!disabled"])
                if native_audio is not None:
                    blob_buffer["sample1_native_audio"] = native_audio
                    rebuild_blob_ui("sample1_native_audio")
                if err:
                    messagebox.showerror("Apply sample1", err, parent=dlg)
                    if warn:
                        messagebox.showwarning("Apply sample1", warn, parent=dlg)
                    return
                if translated is not None and "sample1_translate" in entries:
                    entries["sample1_translate"].set(translated)
                if roman is not None and "sample1_translate_roman" in entries:
                    entries["sample1_translate_roman"].set(roman)
                if translate_audio is not None:
                    blob_buffer["sample1_translate_audio"] = translate_audio
                    rebuild_blob_ui("sample1_translate_audio")
                if warn:
                    messagebox.showwarning("Apply sample1", warn, parent=dlg)

            if btn is not None:
                btn.state(["disabled"])

            def work() -> None:
                err: str | None = None
                warn: str | None = None
                native_audio: bytes | None = None
                translated: str | None = None
                roman: str | None = None
                translate_audio: bytes | None = None
                try:
                    n_code, t_code = _du.parse_db_lang_codes(path)
                    lang_n = _du.tts_lang_code_for_source_column(
                        "sample1_native", n_code, t_code
                    )
                    lang_t = _du.tts_lang_code_for_source_column(
                        "sample1_translate", n_code, t_code
                    )
                    if not lang_n or not lang_t:
                        err = "Could not resolve TTS language codes from the DB filename."
                    else:
                        native_audio = _du.synthesize_tts(native, lang_n)
                        if not native_audio:
                            warn = (
                                "TTS for sample1_native_audio failed (see console). "
                                "Continuing with translate / roman / translate TTS."
                            )
                        translated = _du.translate_text_google(native, n_code, t_code)
                        if not translated:
                            err = "Translation to sample1_translate failed (see console)."
                        else:
                            roman = _du.romanize_translate_sample_text(translated, t_code)
                            if roman is None:
                                roman = ""
                            translate_audio = _du.synthesize_tts(translated, lang_t)
                            if not translate_audio:
                                w2 = "TTS for sample1_translate_audio failed (see console)."
                                warn = f"{warn}\n{w2}" if warn else w2
                except Exception as ex:  # noqa: BLE001
                    err = str(ex)

                def done() -> None:
                    finish_ui(
                        native_audio=native_audio,
                        translated=translated,
                        roman=roman,
                        translate_audio=translate_audio,
                        err=err,
                        warn=warn,
                    )

                dlg.after(0, done)

            threading.Thread(target=work, daemon=True).start()

        for b in sample1_apply_holder:
            b.configure(command=run_sample1_native_pipeline)

        frm.columnconfigure(1, weight=1)

        def _coerce_edit(col: str, raw: str) -> Any:
            meta = self._col_meta[col]
            t = (meta["type"] or "").upper()
            s = raw.strip()
            if not s:
                return None
            if "INT" in t:
                return int(s, 10)
            if "REAL" in t or "FLOA" in t or "DOUB" in t:
                return float(s)
            return s

        def apply_changes() -> None:
            sets: list[str] = []
            vals: list[Any] = []
            tbl = self._current_table
            assert tbl

            for col, var in entries.items():
                if self._backend == "sqlite":
                    sets.append(f"{_sql_quote_ident(col)} = ?")
                    vals.append(var.get())
                else:
                    try:
                        coerced = _coerce_edit(col, var.get())
                    except ValueError as e:
                        messagebox.showerror("Save row", str(e), parent=dlg)
                        return
                    sets.append(f"{_sql_quote_ident(col)} = %s")
                    vals.append(coerced)

            for col in self._columns:
                if not self._column_is_blob_like(col):
                    continue
                b = blob_buffer[col]
                if self._backend == "sqlite":
                    sets.append(f"{_sql_quote_ident(col)} = ?")
                    vals.append(sqlite3.Binary(b) if b is not None else None)
                else:
                    sets.append(f"{_sql_quote_ident(col)} = %s")
                    vals.append(b)

            if not sets:
                messagebox.showinfo("Save row", "Nothing to update.", parent=dlg)
                return
            try:
                if self._backend == "sqlite":
                    sql = (
                        f'UPDATE {_sql_quote_ident(tbl)} SET {", ".join(sets)} '
                        f"WHERE rowid = ?"
                    )
                    vals.append(int(row_key))
                    assert self._conn
                    cur = self._conn.execute(sql, vals)
                    if cur.rowcount == 0:
                        messagebox.showerror(
                            "Save row",
                            "UPDATE affected 0 rows (row may have been deleted).",
                            parent=dlg,
                        )
                        return
                else:
                    pk = self._pk_columns[0]
                    sql = (
                        f'UPDATE {_pg_qualified_table(tbl)} SET {", ".join(sets)} '
                        f'WHERE {_sql_quote_ident(pk)} = %s'
                    )
                    vals.append(self._pg_parse_iid(row_key))
                    assert self._pg_conn
                    with self._pg_conn.cursor() as cur:
                        cur.execute(sql, vals)
                        if cur.rowcount == 0:
                            messagebox.showerror(
                                "Save row",
                                "UPDATE affected 0 rows (row may have been deleted).",
                                parent=dlg,
                            )
                            return
            except Exception as e:
                messagebox.showerror("Save row", str(e), parent=dlg)
                return
            self._dirty = True
            if self._backend == "sqlite" and tbl in ("category", "word"):
                self._mark_supabase_dirty_sqlite(tbl, int(row_key))
            self._refresh_table()
            dlg.destroy()

        btnf = ttk.Frame(frm)
        btnf.grid(row=r, column=0, columnspan=2, pady=12)
        ttk.Button(btnf, text="Apply (UPDATE this row)", command=apply_changes).pack(
            side=tk.LEFT, padx=4
        )
        ttk.Button(btnf, text="Cancel", command=dlg.destroy).pack(side=tk.LEFT, padx=4)

    def _play_audio_blob(self, data: bytes) -> None:
        if not data:
            return
        sfx = ".mp3"
        if data[:4] == b"RIFF":
            sfx = ".wav"
        elif data[:4] == b"OggS":
            sfx = ".ogg"
        try:
            fd, tmp = tempfile.mkstemp(suffix=sfx)
            os.write(fd, data)
            os.close(fd)
            os.startfile(tmp)  # type: ignore[attr-defined]
        except Exception as e:
            messagebox.showerror("Audio", str(e))

    def _show_image_blob(self, data: bytes) -> None:
        if not data:
            return
        suf = ".img"
        if data[:8] == b"\x89PNG\r\n\x1a\n":
            suf = ".png"
        elif data[:2] == b"\xff\xd8":
            suf = ".jpg"
        elif data[:6] in (b"GIF87a", b"GIF89a"):
            suf = ".gif"
        if Image is None:
            try:
                fd, tmp = tempfile.mkstemp(suffix=suf)
                os.write(fd, data)
                os.close(fd)
                os.startfile(tmp)  # type: ignore[attr-defined]
            except Exception as e:
                messagebox.showerror("Image", str(e))
            return
        try:
            import io

            im = Image.open(io.BytesIO(data))
            im.thumbnail((900, 900))
            photo = ImageTk.PhotoImage(im)
            win = tk.Toplevel(self)
            win.title("Image preview")
            lbl = tk.Label(win, image=photo)
            lbl.image = photo  # prevent GC
            lbl.pack(padx=8, pady=8)
        except Exception as e:
            messagebox.showerror("Image", str(e))

    def _save(self) -> None:
        if not self._is_connected():
            return
        try:
            if self._backend == "sqlite" and self._conn:
                self._conn.commit()
                msg = "Committed changes to the SQLite file."
            elif self._backend == "postgres" and self._pg_conn:
                self._pg_conn.commit()
                msg = "Committed changes to Postgres."
            else:
                return
            self._dirty = False
            messagebox.showinfo("Save", msg)
        except Exception as e:
            messagebox.showerror("Save", str(e))

    def _save_as(self) -> None:
        if self._backend == "postgres":
            messagebox.showinfo(
                "Save As",
                "SQLite backup is only available in SQLite mode.\n"
                "Use Open SQLite… for a local .db file.",
            )
            return
        if not self._conn or not self._path:
            messagebox.showinfo("Save As", "Open a SQLite database first.")
            return
        path = filedialog.asksaveasfilename(
            defaultextension=".db",
            filetypes=[("SQLite", "*.db *.sqlite *.sqlite3"), ("All", "*.*")],
        )
        if not path:
            return
        try:
            self._conn.commit()
            dest = sqlite3.connect(path)
            try:
                self._conn.backup(dest)
            finally:
                dest.close()
            messagebox.showinfo("Save As", f"Backup written to:\n{path}")
        except Exception as e:
            messagebox.showerror("Save As", str(e))

    def _on_close(self) -> None:
        if self._dirty and not messagebox.askyesno(
            "Quit", "Quit without saving? Uncommitted row edits will be lost."
        ):
            return
        self._disconnect_all()
        self.destroy()


def dimago_db_scripts_dir() -> Path:
    """Directory containing ``dbview.py`` and ``dbutil.py`` (siblings on ``sys.path``)."""
    return Path(__file__).resolve().parent


def ensure_dimago_db_scripts_on_path() -> None:
    """So ``import dbutil`` works when this file is loaded from another cwd."""
    sd = str(dimago_db_scripts_dir())
    if sd not in sys.path:
        sys.path.insert(0, sd)


def run_view(
    *,
    input_path: str | None = None,
    legacy_path: str | None = None,
    postgres: bool = False,
    database_url: str | None = None,
) -> None:
    """Start the tkinter DB browser (programmatic API).

    Used by standalone ``run_cli()`` / ``main()`` and by ``run_view_from_dbutil_namespace()``.
    """
    path = (input_path or legacy_path or "").strip() or None
    use_pg = postgres or bool((database_url or "").strip())

    app = DbViewApp()
    if use_pg:
        if psycopg is None:
            print("dbview: install psycopg: pip install psycopg[binary]", file=sys.stderr)
            sys.exit(3)
        dsn = (database_url or "").strip() or _postgres_dsn_from_config()
        if not dsn:
            print(
                "dbview: set DATABASE_URL in dbutil/.env or dbutil/.env.local, "
                "or pass --database-url",
                file=sys.stderr,
            )
            sys.exit(2)
        try:
            app._connect_postgres(dsn)
            app._load_table_names()
        except Exception as e:
            messagebox.showerror("Postgres", str(e))
    elif path:
        if not os.path.isfile(path):
            messagebox.showerror("Open", f"File not found:\n{path}")
        else:
            try:
                app._connect_sqlite(path)
                app._load_table_names()
            except Exception as e:
                messagebox.showerror("Open", str(e))
    app.mainloop()


def build_standalone_parser() -> argparse.ArgumentParser:
    """CLI for ``python dbview.py`` (standalone only; dbutil uses its own ``--view`` flags)."""
    parser = argparse.ArgumentParser(
        prog="dbview",
        description="View and edit SQLite or Postgres (Supabase) tables (tkinter).",
    )
    parser.add_argument(
        "--input",
        metavar="FILE",
        help="SQLite database file to open on startup",
    )
    parser.add_argument(
        "--postgres",
        action="store_true",
        help="Connect with DATABASE_URL on startup (loads dbutil/.env and dbutil/.env.local)",
    )
    parser.add_argument(
        "--database-url",
        metavar="DSN",
        help="Postgres URI (overrides DATABASE_URL); implies --postgres",
    )
    parser.add_argument(
        "legacy_path",
        nargs="?",
        metavar="FILE",
        help=argparse.SUPPRESS,
    )
    return parser


def run_cli(argv: list[str] | None = None) -> None:
    """Parse ``argv`` with :func:`build_standalone_parser` and start the GUI."""
    parser = build_standalone_parser()
    args = parser.parse_args(argv)
    run_view(
        input_path=args.input,
        legacy_path=args.legacy_path,
        postgres=args.postgres,
        database_url=args.database_url,
    )


def run_view_from_dbutil_namespace(ns: argparse.Namespace) -> None:
    """Map ``dbutil.py``\ ``--view`` / ``--view-postgres`` / ``--database-url`` / ``--input`` → :func:`run_view`."""
    du_url = getattr(ns, "database_url", None)
    run_view(
        input_path=getattr(ns, "input", None),
        postgres=bool(getattr(ns, "view_postgres", False))
        or bool((du_url or "").strip()),
        database_url=du_url,
    )


def main() -> None:
    """``python dbview.py`` entry point (equivalent to ``run_cli(None)``)."""
    run_cli(None)


__all__ = [
    "DbViewApp",
    "build_standalone_parser",
    "dimago_db_scripts_dir",
    "ensure_dimago_db_scripts_on_path",
    "main",
    "run_cli",
    "run_view",
    "run_view_from_dbutil_namespace",
]


if __name__ == "__main__":
    main()