-- TTS blob for phrase sample in native language (SQLite: word.sample1_native_audio).
-- Run in SQL Editor if `words` was created before this column existed.

ALTER TABLE words ADD COLUMN IF NOT EXISTS sample1_native_audio BYTEA;
