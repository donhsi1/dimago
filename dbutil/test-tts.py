#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Compare TTS backends: synthesize audio and play each sample.

  python test-tts.py --text "สวัสดี"
  python test-tts.py --text "你好" --lang CN
  python test-tts.py --text "Hello" --engines google,edge,cloud

Dependencies:
  - requests (required for Google web TTS via dbutil + Cloud TTS)
  - pip install edge-tts   (optional — Microsoft Edge neural voices)
  - pip install pyttsx3    (optional — local OS TTS, e.g. Windows SAPI)

Paid Google Cloud Text-to-Speech (--engines cloud):
  Uses the same API key as Gemini when found (env GEMINI_API_KEY / GOOGLE_API_KEY,
  dbutil/.env, or dimago/lib/gemini_service.dart). The key must be allowed to call
  Text-to-Speech: enable “Cloud Text-to-Speech API” + billing on the Google Cloud
  project (AI Studio–only keys may return 403).

Playback: Windows uses the default app (os.startfile). With ffplay in PATH,
that is used instead for auto-exit after playback.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Callable

import requests

# Script dir on path for `import dbutil`
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)

import dbutil  # noqa: E402

_CLOUD_TTS_URL = "https://texttospeech.googleapis.com/v1/text:synthesize"

# App language code → (Cloud TTS languageCode, voice name) — Neural2 / high-quality where available
CLOUD_VOICE_BY_LANG: dict[str, tuple[str, str]] = {
    "TH": ("th-TH", "th-TH-Neural2-C"),
    "CN": ("zh-CN", "zh-CN-Neural2-A"),
    "TW": ("zh-TW", "zh-TW-Neural2-A"),
    "EN": ("en-US", "en-US-Neural2-F"),
    "JA": ("ja-JP", "ja-JP-Neural2-B"),
    "KO": ("ko-KR", "ko-KR-Neural2-A"),
    "FR": ("fr-FR", "fr-FR-Neural2-A"),
    "DE": ("de-DE", "de-DE-Neural2-F"),
    "IT": ("it-IT", "it-IT-Neural2-A"),
    "ES": ("es-ES", "es-ES-Neural2-F"),
    "RU": ("ru-RU", "ru-RU-Wavenet-A"),
    "UK": ("uk-UA", "uk-UA-Wavenet-A"),
    "HE": ("he-IL", "he-IL-Wavenet-A"),
    "MY": ("en-US", "en-US-Neural2-F"),  # Burmese neural limited — fallback
}

# App language code (same as dbutil) → Edge TTS neural voice name
EDGE_VOICE_BY_LANG: dict[str, str] = {
    "TH": "th-TH-PremwadeeNeural",
    "CN": "zh-CN-XiaoxiaoNeural",
    "TW": "zh-TW-HsiaoChenNeural",
    "EN": "en-US-JennyNeural",
    "JA": "ja-JP-NanamiNeural",
    "KO": "ko-KR-SunHiNeural",
    "FR": "fr-FR-DeniseNeural",
    "DE": "de-DE-KatjaNeural",
    "IT": "it-IT-ElsaNeural",
    "ES": "es-ES-ElviraNeural",
    "RU": "ru-RU-SvetlanaNeural",
    "UK": "uk-UA-PolinaNeural",
    "HE": "he-IL-HilaNeural",
    "MY": "my-MM-NilarNeural",
}


def _play_file(path: str, *, delete_after: bool = False) -> None:
    ffplay = shutil.which("ffplay")
    if ffplay:
        subprocess.run(
            [ffplay, "-nodisp", "-autoexit", "-loglevel", "quiet", path],
            check=False,
        )
        if delete_after:
            try:
                os.unlink(path)
            except OSError:
                pass
        return
    if sys.platform == "win32":
        os.startfile(path)  # type: ignore[attr-defined]
        return
    if sys.platform == "darwin":
        subprocess.run(["open", path], check=False)
        return
    xdg = shutil.which("xdg-open")
    if xdg:
        subprocess.run([xdg, path], check=False)
        return
    print("  [warn] No ffplay / OS opener; saved file not played:", path, file=sys.stderr)


def _play_bytes(data: bytes, suffix: str) -> None:
    fd, path = tempfile.mkstemp(suffix=suffix)
    os.write(fd, data)
    os.close(fd)
    # ffplay blocks until done → safe to delete; startfile/xdg-open do not → leave temp file
    _play_file(path, delete_after=bool(shutil.which("ffplay")))


def _dimago_root() -> Path:
    return Path(_SCRIPT_DIR).resolve().parent


def _load_api_key_from_gemini_dart() -> str | None:
    dart = _dimago_root() / "lib" / "gemini_service.dart"
    if not dart.is_file():
        return None
    try:
        raw = dart.read_text(encoding="utf-8")
    except OSError:
        return None
    m = re.search(r"static const _apiKey = '([^']+)';", raw)
    if not m:
        return None
    key = m.group(1).strip()
    return key or None


def resolve_google_cloud_api_key(explicit: str | None = None) -> str | None:
    """Key for Cloud Text-to-Speech / Gemini-style Google APIs (never printed)."""
    if explicit and explicit.strip():
        return explicit.strip()
    for name in ("GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_CLOUD_API_KEY"):
        v = (os.environ.get(name) or "").strip()
        if v:
            return v
    env_file = Path(_SCRIPT_DIR) / ".env"
    if env_file.is_file():
        try:
            for line in env_file.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, val = line.partition("=")
                k, val = k.strip(), val.strip()
                if k in ("GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_CLOUD_API_KEY") and val:
                    return val
        except OSError:
            pass
    return _load_api_key_from_gemini_dart()


def _run_google_cloud_tts(
    text: str, lang: str, api_key: str | None, voice_override: str | None
) -> tuple[str, bytes | None]:
    key = resolve_google_cloud_api_key(api_key)
    if not key:
        return (
            "Google Cloud Text-to-Speech (paid, Neural2) — skipped: no API key "
            "(set GEMINI_API_KEY, add to dbutil/.env, or keep key in dimago/lib/gemini_service.dart)",
            None,
        )

    if voice_override and "|" in voice_override:
        lc, name = voice_override.split("|", 1)
        language_code, voice_name = lc.strip(), name.strip()
    elif voice_override:
        vn = voice_override.strip()
        hyp = vn.split("-")
        language_code = f"{hyp[0]}-{hyp[1]}" if len(hyp) >= 2 else "en-US"
        voice_name = vn
    else:
        language_code, voice_name = CLOUD_VOICE_BY_LANG.get(
            lang.upper(),
            ("en-US", "en-US-Neural2-F"),
        )

    label = (
        f"Google Cloud Text-to-Speech (paid) — API text:synthesize, "
        f"voice={voice_name!r}, languageCode={language_code!r}"
    )
    body = {
        "input": {"text": text},
        "voice": {
            "languageCode": language_code,
            "name": voice_name,
        },
        "audioConfig": {
            "audioEncoding": "MP3",
            "speakingRate": 1.0,
        },
    }
    try:
        r = requests.post(
            _CLOUD_TTS_URL,
            params={"key": key},
            headers={"Content-Type": "application/json"},
            data=json.dumps(body),
            timeout=60,
        )
        if not r.ok:
            msg = (r.text or "").strip()
            try:
                ed = r.json().get("error") or {}
                if isinstance(ed.get("message"), str):
                    msg = ed["message"]
            except (json.JSONDecodeError, ValueError, TypeError):
                pass
            print(f"  [error] Cloud TTS HTTP {r.status_code}:\n  {msg}", file=sys.stderr)
            url_m = re.search(
                r"https://console\.developers\.google\.com[^\s\"']+",
                msg,
            )
            if url_m:
                print(f"  Enable API: {url_m.group(0)}", file=sys.stderr)
            print(
                "  Billing must be enabled on that GCP project for Neural2 voices.",
                file=sys.stderr,
            )
            return label, None
        data = r.json()
        b64 = data.get("audioContent")
        if not b64:
            print("  [error] Cloud TTS: missing audioContent in response", file=sys.stderr)
            return label, None
        return label, base64.b64decode(b64)
    except requests.RequestException as ex:
        print(f"  [error] Cloud TTS: {ex}", file=sys.stderr)
        return label, None


def _run_google_translate_web(text: str, lang: str) -> tuple[str, bytes | None]:
    label = "Google Translate web TTS — translate.googleapis.com/translate_tts (client=tw-ob)"
    data = dbutil.synthesize_tts(text, lang)
    return label, data


def _run_edge_tts(text: str, lang: str) -> tuple[str, bytes | None]:
    try:
        import edge_tts  # type: ignore
    except ImportError:
        return "Microsoft Edge TTS (edge-tts) — skipped: pip install edge-tts", None

    voice = EDGE_VOICE_BY_LANG.get(lang.upper())
    if not voice:
        voice = "en-US-JennyNeural"
    label = f"Microsoft Edge TTS (edge-tts) — voice={voice}"

    async def _synth() -> bytes:
        communicate = edge_tts.Communicate(text, voice)
        chunks: list[bytes] = []
        async for chunk in communicate.stream():
            if chunk["type"] == "audio":
                chunks.append(chunk["data"])
        return b"".join(chunks)

    try:
        data = asyncio.run(_synth())
        return label, data if data else None
    except Exception as ex:
        print(f"  [error] edge-tts: {ex}", file=sys.stderr)
        return label, None


def _run_pyttsx3(text: str, lang: str) -> tuple[str, bytes | None]:
    try:
        import pyttsx3  # type: ignore
    except ImportError:
        return "pyttsx3 (local OS TTS) — skipped: pip install pyttsx3", None

    try:
        engine = pyttsx3.init()
        voices = engine.getProperty("voices") or []
        vid = getattr(voices[0], "id", "") if voices else "(default)"
        label = f"pyttsx3 (local OS TTS) — engine voice id={vid!r}"
        fd, path = tempfile.mkstemp(suffix=".wav")
        os.close(fd)
        try:
            engine.save_to_file(text, path)
            engine.runAndWait()
            data = _read_file_bytes(path)
            return label, data
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass
    except Exception as ex:
        print(f"  [error] pyttsx3: {ex}", file=sys.stderr)
        return "pyttsx3 (local OS TTS)", None


def _read_file_bytes(path: str) -> bytes:
    with open(path, "rb") as f:
        return f.read()


ENGINE_ORDER = ("google", "edge", "pyttsx3", "cloud")
ENGINE_KEYS = frozenset(ENGINE_ORDER)


def _build_engine_runners(
    api_key: str | None, cloud_voice: str | None
) -> dict[str, Callable[[str, str], tuple[str, bytes | None]]]:
    def cloud_wrapped(t: str, lang: str) -> tuple[str, bytes | None]:
        return _run_google_cloud_tts(t, lang, api_key, cloud_voice)

    return {
        "google": _run_google_translate_web,
        "edge": _run_edge_tts,
        "pyttsx3": _run_pyttsx3,
        "cloud": cloud_wrapped,
    }


def main() -> None:
    p = argparse.ArgumentParser(description="Synthesize and play text with several TTS APIs.")
    p.add_argument("--text", required=True, help="Phrase to speak")
    p.add_argument(
        "--lang",
        default="TH",
        help="App language code (TH, CN, EN, …) — same as dict_*.db codes (default: TH)",
    )
    p.add_argument(
        "--engines",
        default="google,edge,pyttsx3,cloud",
        help=f"Comma-separated: {','.join(ENGINE_ORDER)} (default: all incl. paid Cloud TTS)",
    )
    p.add_argument(
        "--api-key",
        default=None,
        help="Override Google API key for Cloud TTS (default: env / .env / dimago lib/gemini_service.dart)",
    )
    p.add_argument(
        "--cloud-voice",
        default=None,
        metavar="SPEC",
        help=(
            "Cloud TTS voice override: full voice name (e.g. th-TH-Neural2-D) "
            "or languageCode|voiceName"
        ),
    )
    p.add_argument(
        "--pause",
        type=float,
        default=0.0,
        help="Seconds to wait after each playback before the next (default: 0)",
    )
    args = p.parse_args()
    text = args.text.strip()
    if not text:
        print("Empty --text", file=sys.stderr)
        sys.exit(1)

    wanted = {x.strip().lower() for x in args.engines.split(",") if x.strip()}
    unknown = wanted - ENGINE_KEYS
    if unknown:
        print(f"Unknown --engines: {unknown}", file=sys.stderr)
        sys.exit(1)

    engines = _build_engine_runners(args.api_key, args.cloud_voice)

    tl = dbutil.LANG_TO_TTS.get(args.lang.upper(), args.lang.lower())
    print(f"Phrase: {text!r}\nLang code: {args.lang} (free Google web TTS tl={tl!r})\n", flush=True)

    order = [k for k in ENGINE_ORDER if k in wanted]
    for key in order:
        runner = engines[key]
        label, data = runner(text, args.lang)
        print(f"\n>>> Playing — {label}\n", flush=True)
        if not data:
            print("    (no audio; skipped)\n", flush=True)
        elif data[:4] == b"RIFF":
            _play_bytes(data, ".wav")
        elif data[:2] == b"\xff\xfb" or data[:3] == b"ID3" or data[:2] == b"\xff\xf3":
            _play_bytes(data, ".mp3")
        else:
            _play_bytes(data, ".mp3")
        if args.pause > 0 and key != order[-1]:
            time.sleep(args.pause)


if __name__ == "__main__":
    main()
