-- Align existing Supabase tables with schema_dimago.sql (columns added after first deploy).
-- Run once in Supabase → SQL Editor. Safe to re-run (IF NOT EXISTS).
--
-- After running, PostgREST usually picks up new columns within seconds.
-- If dbutil --commit still reports unknown columns, wait briefly or restart the project API.

-- lessons: user_id (SQLite category.user_id — dbutil syncs it)
ALTER TABLE public.lessons
  ADD COLUMN IF NOT EXISTS user_id BIGINT NOT NULL DEFAULT 0;

-- words: user_id, correct_count, hint
ALTER TABLE public.words
  ADD COLUMN IF NOT EXISTS user_id BIGINT NOT NULL DEFAULT 0;

ALTER TABLE public.words
  ADD COLUMN IF NOT EXISTS correct_count INTEGER NOT NULL DEFAULT 0;

ALTER TABLE public.words
  ADD COLUMN IF NOT EXISTS hint TEXT;
