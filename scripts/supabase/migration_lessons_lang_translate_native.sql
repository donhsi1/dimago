-- Add category language codes to Supabase `lessons` (SQLite: category.lang_*).
-- Run in SQL Editor if the table was created before these columns existed.

ALTER TABLE lessons ADD COLUMN IF NOT EXISTS lang_translate TEXT;
ALTER TABLE lessons ADD COLUMN IF NOT EXISTS lang_native TEXT;

COMMENT ON COLUMN lessons.lang_translate IS 'DB filename code: language to learn (dict_<TR>_<NA> first segment), e.g. TH';
COMMENT ON COLUMN lessons.lang_native IS 'DB filename code: user native (dict_<TR>_<NA> second segment), e.g. CN';
