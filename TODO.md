# Feature Ideas

## Settings Page
- [x] **Challenge settings section** — "Challenge" entry in system settings
  - Slider to set challenge starting duration: 2–10 seconds (default: 5)
  - Duration is read fresh from settings every time Challenge is toggled on (persistent, never eroded by session decrements)
  - "Minimum Duration" slider (2–5s, default: 2) — congrats decrement will not go below this value within a session

## Practice Page
- [x] **Challenge Mode button** — toggle button to the right of the category dropdown
  - When activated, enters Challenge Mode with a countdown timer
  - Timer duration loaded from settings on each toggle-on
  - Auto-advances to next question when timer runs out
  - Resets sequential correct-answer chain on wrong answer
  - "Congratulations" popup when all words in the category are answered sequentially correctly
    - Decrements in-session timer by 1s (down to minimum), does NOT overwrite the settings value
    - OK → re-enter challenge with decremented in-session timer
    - Later → return to normal interactive test mode, load next word

- [x] **Romanization hide/show toggle** — small eye icon next to the Thai romanization on the practice page
  - Toggles display of romanization in both Mode A (main display) and Mode B (option tiles)
  - Preference is persistent across app restarts
  - Encourages learners to focus on hearing the words rather than reading the phonetics

## Lesson Progression *(pending design)*
- [ ] **Sequential category unlocking** — present lessons in order; user advances only after meeting pass criteria for the current lesson (see **Supabase: on-demand lesson loading**).
  - **Data source:** We **no longer** download LearnDb / NativeDb from **GitHub**. The **local SQLite** database is **populated from Supabase** (sync / fetch as designed below).
  - **Current milestone (bootstrap):** Populate **all** **category** rows (lesson list / metadata). Populate **WORD** table content **only for the first category**; other categories have **no** words locally until fetched later.
  - Categories remain ordered by their index in the database (or equivalent ordering from Supabase).
  - Only categories that are **unlocked** *and* have **words loaded** should be usable in the selector (greyed list UX per section below).
  - **Open design questions:**
    1. **Unlock criteria** — what threshold counts as "passing" a category to unlock the next? (e.g. challenge scores, completion counts.)
    2. **Backward navigation** — can the user freely revisit any already-unlocked category?
    3. **"All words" mode** — disabled until all lessons unlocked, or always available?
  - **Resolved for UI:** Locked or not-yet-loaded lessons are **greyed out**, not hidden (see **§3** under Supabase below).

## Supabase: on-demand lesson loading
- [ ] **1. Unlock next lesson via challenge** — Using Supabase, implement on-demand lesson loading where the user must **finish the current lesson** (pass challenge tests with **sufficient scores**) before the **next** lesson’s content becomes available / is fetched.
- [ ] **2. First-time language selection + partial initial load** — After the user selects **Translate** and **Native** languages for the **first time**: from Supabase, fill local SQLite with **all categories** (lesson list). Load **WORD** rows **only for the first category**; other categories stay without words until on-demand fetch. (No GitHub DB download.)
- [ ] **3. Lesson page list UX** — On the lesson page, show the **full list** of lessons. Only lessons for which **WORD** data has been **loaded locally** are **selectable**; all others are **greyed out** and **cannot** be selected.
