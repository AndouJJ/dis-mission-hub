-- DIS Mission Hub — Supabase Schema
-- Run this in the Supabase SQL Editor: https://app.supabase.com → your project → SQL Editor

-- ============================================================
-- 1. TABLES
-- ============================================================

-- Digital handles: one row per registered handle
CREATE TABLE IF NOT EXISTS handles (
  handle       TEXT PRIMARY KEY,
  created_at   TIMESTAMPTZ DEFAULT NOW(),
  points       INT         DEFAULT 0
);

-- Challenge reference table — single source of truth for valid IDs and point values
CREATE TABLE IF NOT EXISTS challenges (
  id     TEXT PRIMARY KEY,
  points INT  NOT NULL
);
INSERT INTO challenges (id, points) VALUES
  ('exp-1', 10), ('exp-2', 70), ('exp-3', 80), ('exp-4', 100),
  ('ne-1', 40), ('ne-2', 60), ('ne-3', 80)
ON CONFLICT DO NOTHING;

-- Individual challenge completions
CREATE TABLE IF NOT EXISTS completions (
  id           UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  handle       TEXT REFERENCES handles(handle) ON DELETE CASCADE,
  challenge_id TEXT REFERENCES challenges(id) NOT NULL,
  points       INT         NOT NULL DEFAULT 0,
  completed_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(handle, challenge_id)   -- prevents double-submission
);

-- ============================================================
-- 2. TRIGGER — enforce correct points and keep handles.points in sync
-- ============================================================

-- Overwrite client-supplied points with the server-authoritative value
-- and reject any challenge_id not in the challenges table.
-- SECURITY DEFINER: runs as the function owner (bypasses RLS) so it can
-- read the challenges table regardless of the caller's role.
CREATE OR REPLACE FUNCTION enforce_challenge_points()
RETURNS TRIGGER AS $$
BEGIN
  SELECT points INTO NEW.points FROM challenges WHERE id = NEW.challenge_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invalid challenge_id: %', NEW.challenge_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS before_completion_insert ON completions;
CREATE TRIGGER before_completion_insert
  BEFORE INSERT ON completions
  FOR EACH ROW EXECUTE FUNCTION enforce_challenge_points();

-- SECURITY DEFINER: runs as function owner so it can UPDATE handles even
-- though the anon role has an explicit UPDATE deny policy on that table.
CREATE OR REPLACE FUNCTION update_handle_points()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE handles
  SET points = (
    SELECT COALESCE(SUM(points), 0)
    FROM completions
    WHERE handle = NEW.handle
  )
  WHERE handle = NEW.handle;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS after_completion_insert ON completions;
CREATE TRIGGER after_completion_insert
  AFTER INSERT ON completions
  FOR EACH ROW EXECUTE FUNCTION update_handle_points();

-- ============================================================
-- 3. ROW LEVEL SECURITY
-- ============================================================

ALTER TABLE challenges  ENABLE ROW LEVEL SECURITY;
ALTER TABLE handles     ENABLE ROW LEVEL SECURITY;
ALTER TABLE completions ENABLE ROW LEVEL SECURITY;

-- challenges: publicly readable, immutable by anon
DROP POLICY IF EXISTS "challenges_select" ON challenges;
DROP POLICY IF EXISTS "challenges_insert" ON challenges;
DROP POLICY IF EXISTS "challenges_update" ON challenges;
DROP POLICY IF EXISTS "challenges_delete" ON challenges;
CREATE POLICY "challenges_select" ON challenges FOR SELECT USING (true);
CREATE POLICY "challenges_insert" ON challenges FOR INSERT WITH CHECK (false);
CREATE POLICY "challenges_update" ON challenges FOR UPDATE USING (false);
CREATE POLICY "challenges_delete" ON challenges FOR DELETE USING (false);

-- handles: anyone can register a new handle and view the list
DROP POLICY IF EXISTS "handles_select" ON handles;
DROP POLICY IF EXISTS "handles_insert" ON handles;
DROP POLICY IF EXISTS "handles_update" ON handles;
DROP POLICY IF EXISTS "handles_delete" ON handles;
CREATE POLICY "handles_select" ON handles FOR SELECT USING (true);
CREATE POLICY "handles_insert" ON handles FOR INSERT WITH CHECK (true);
CREATE POLICY "handles_update" ON handles FOR UPDATE USING (false);  -- explicit deny
CREATE POLICY "handles_delete" ON handles FOR DELETE USING (false);  -- explicit deny

-- completions: anyone can view; anyone can insert; no updates or deletes
DROP POLICY IF EXISTS "completions_select" ON completions;
DROP POLICY IF EXISTS "completions_insert" ON completions;
DROP POLICY IF EXISTS "completions_update" ON completions;
DROP POLICY IF EXISTS "completions_delete" ON completions;
CREATE POLICY "completions_select" ON completions FOR SELECT USING (true);
CREATE POLICY "completions_insert" ON completions FOR INSERT WITH CHECK (true);
CREATE POLICY "completions_update" ON completions FOR UPDATE USING (false);  -- explicit deny
CREATE POLICY "completions_delete" ON completions FOR DELETE USING (false);  -- explicit deny

-- ============================================================
-- 4. REALTIME — enable live leaderboard updates
-- ============================================================

DO $$
BEGIN
  -- handles must NOT be in realtime: its change payloads include every column
  -- (incl. uid), which would leak around the column-level grant in section 6.
  IF EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'handles'
  ) THEN
    ALTER PUBLICATION supabase_realtime DROP TABLE handles;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'completions'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE completions;
  END IF;
END $$;

-- ============================================================
-- 5. PHOTO UPLOADS
-- Step 1: Create the storage bucket manually in Supabase Dashboard
--   Storage → New bucket → Name: challenge-photos → Public: ON
-- Step 2: Run the statements below in the SQL Editor
-- ============================================================

ALTER TABLE completions ADD COLUMN IF NOT EXISTS photo_url TEXT;

DROP POLICY IF EXISTS "challenge_photos_insert" ON storage.objects;
DROP POLICY IF EXISTS "challenge_photos_select" ON storage.objects;

-- Restrict uploads to the exact path format the app produces:
--   <handle>/<challenge-id>/<unix-timestamp>.jpg
-- Prevents uploading to arbitrary paths even if someone calls the API directly.
CREATE POLICY "challenge_photos_insert" ON storage.objects
  FOR INSERT TO anon
  WITH CHECK (
    bucket_id = 'challenge-photos' AND
    name ~ '^[A-Za-z0-9_\-\.]{1,64}/[A-Za-z0-9_\-]{1,32}/[0-9]{10,16}\.jpg$'
  );

CREATE POLICY "challenge_photos_select" ON storage.objects
  FOR SELECT TO anon
  USING (bucket_id = 'challenge-photos');

-- ============================================================
-- 6. YEAR IV GAMES — unique IDs, timer, per-game passwords, malware
-- ============================================================

-- 6a. handles: unique participant ID + game timer bounds
ALTER TABLE handles ADD COLUMN IF NOT EXISTS uid         TEXT;
ALTER TABLE handles ADD COLUMN IF NOT EXISTS started_at  TIMESTAMPTZ;
ALTER TABLE handles ADD COLUMN IF NOT EXISTS finished_at TIMESTAMPTZ;
CREATE UNIQUE INDEX IF NOT EXISTS handles_uid_key ON handles(uid);

-- The uid must never be bulk-readable from the browser, or anyone could dump
-- every participant's Unique ID and defeat the malware mechanic. Remove the
-- table-wide SELECT and re-grant only the non-secret columns. The owner-run
-- SECURITY DEFINER functions (resolve_malware, admin_roster) still see uid.
REVOKE SELECT ON handles FROM anon, authenticated;
GRANT  SELECT (handle, created_at, points, started_at, finished_at)
  ON handles TO anon, authenticated;

-- 6b. settings — the three game passwords + admin password.
-- RLS is enabled with NO policies, so the anon (public) role can never read
-- or write this table from the browser. Only the SECURITY DEFINER functions
-- below can touch it. CHANGE PASSWORDS by editing the rows in the Supabase
-- Table Editor (Dashboard -> Table editor -> app_settings).
CREATE TABLE IF NOT EXISTS app_settings (
  key   TEXT PRIMARY KEY,
  value TEXT
);
-- !! CHANGE THESE in the Supabase Table Editor before the event. admin_pw in
-- particular must be long + random: it is checked via an RPC, so a weak value
-- can be brute-forced over the API.
INSERT INTO app_settings (key, value) VALUES
  ('pw_ne-1', 'alpha'),
  ('pw_ne-2', 'bravo'),
  ('pw_ne-3', 'charlie'),
  ('admin_pw', 'CHANGE-ME-7QF2-kx93-Vn5p'),
  ('games_locked', 'false')   -- 'true' to lock all games behind their passwords
ON CONFLICT DO NOTHING;
ALTER TABLE app_settings ENABLE ROW LEVEL SECURITY;  -- no policies => no anon access

-- 6c. malware events — one row per "attack", tagged to the target handle
CREATE TABLE IF NOT EXISTS malware_events (
  id            UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  target_handle TEXT REFERENCES handles(handle) ON DELETE CASCADE,
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  resolved_at   TIMESTAMPTZ,
  timed_out     BOOLEAN DEFAULT FALSE,
  wrong_guesses INT DEFAULT 0
);
ALTER TABLE malware_events ADD COLUMN IF NOT EXISTS wrong_guesses INT DEFAULT 0;
ALTER TABLE malware_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "malware_select" ON malware_events;
CREATE POLICY "malware_select" ON malware_events FOR SELECT USING (true);
-- inserts/updates happen only through the SECURITY DEFINER functions below
-- (no INSERT/UPDATE/DELETE policy => anon cannot write directly).

-- ---------- functions ----------

-- 6-char unambiguous code (no 0/O/1/I/L)
CREATE OR REPLACE FUNCTION gen_uid() RETURNS TEXT AS $$
DECLARE
  alphabet TEXT := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  out TEXT := '';
  i INT;
BEGIN
  FOR i IN 1..6 LOOP
    out := out || substr(alphabet, 1 + floor(random()*length(alphabet))::int, 1);
  END LOOP;
  RETURN out;
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

-- register a handle and assign a unique uid; returns the handle + uid
CREATE OR REPLACE FUNCTION register_handle(p_handle TEXT)
RETURNS TABLE(handle TEXT, uid TEXT) AS $$
DECLARE
  v_uid TEXT;
  tries INT := 0;
BEGIN
  IF EXISTS (SELECT 1 FROM handles h WHERE h.handle = p_handle) THEN
    RAISE EXCEPTION 'handle_exists';
  END IF;
  LOOP
    v_uid := gen_uid();
    BEGIN
      INSERT INTO handles(handle, uid) VALUES (p_handle, v_uid);
      EXIT;
    EXCEPTION WHEN unique_violation THEN
      tries := tries + 1;
      IF EXISTS (SELECT 1 FROM handles h WHERE h.handle = p_handle) THEN
        RAISE EXCEPTION 'handle_exists';
      END IF;
      IF tries > 25 THEN RAISE EXCEPTION 'uid_gen_failed'; END IF;
    END;
  END LOOP;
  RETURN QUERY SELECT p_handle, v_uid;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- check a game password without ever sending it to the browser
CREATE OR REPLACE FUNCTION verify_game_password(p_game TEXT, p_password TEXT)
RETURNS BOOLEAN AS $$
DECLARE v TEXT;
BEGIN
  SELECT value INTO v FROM app_settings WHERE key = 'pw_' || p_game;
  RETURN v IS NOT NULL AND v = p_password;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- Per-game timing: one row per (handle, game). Total time = sum of each
-- game's (finished_at - started_at). Readable by all; written only via the
-- SECURITY DEFINER functions below.
CREATE TABLE IF NOT EXISTS game_times (
  handle      TEXT REFERENCES handles(handle) ON DELETE CASCADE,
  game_id     TEXT,
  started_at  TIMESTAMPTZ,
  finished_at TIMESTAMPTZ,
  PRIMARY KEY (handle, game_id)
);
ALTER TABLE game_times ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "game_times_select" ON game_times;
CREATE POLICY "game_times_select" ON game_times FOR SELECT USING (true);

-- start a single game's clock (when its password is accepted) — idempotent
CREATE OR REPLACE FUNCTION start_game(p_handle TEXT, p_game TEXT)
RETURNS VOID AS $$
BEGIN
  INSERT INTO game_times (handle, game_id, started_at)
  VALUES (p_handle, p_game, NOW())
  ON CONFLICT (handle, game_id) DO NOTHING;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- stop a single game's clock (when it is cleared) — idempotent.
-- Only stops if the game was started AND a matching completion exists, so a
-- caller cannot record a time without actually finishing the game.
CREATE OR REPLACE FUNCTION finish_game(p_handle TEXT, p_game TEXT)
RETURNS VOID AS $$
BEGIN
  UPDATE game_times SET finished_at = NOW()
   WHERE handle = p_handle AND game_id = p_game
     AND started_at IS NOT NULL AND finished_at IS NULL
     AND EXISTS (
       SELECT 1 FROM completions c
       WHERE c.handle = p_handle AND c.challenge_id = p_game
     );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- admin password check
CREATE OR REPLACE FUNCTION admin_ok(p_pw TEXT) RETURNS BOOLEAN AS $$
DECLARE v TEXT;
BEGIN
  SELECT value INTO v FROM app_settings WHERE key = 'admin_pw';
  RETURN v IS NOT NULL AND v = p_pw;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- live games-locked flag (read by everyone, flipped by the admin)
CREATE OR REPLACE FUNCTION get_games_locked() RETURNS BOOLEAN AS $$
DECLARE v TEXT;
BEGIN
  SELECT value INTO v FROM app_settings WHERE key = 'games_locked';
  RETURN lower(coalesce(v, 'false')) IN ('true','1','yes','on');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION set_games_locked(p_locked BOOLEAN, p_admin_pw TEXT)
RETURNS BOOLEAN AS $$
BEGIN
  IF NOT admin_ok(p_admin_pw) THEN RAISE EXCEPTION 'unauthorized'; END IF;
  UPDATE app_settings SET value = CASE WHEN p_locked THEN 'true' ELSE 'false' END
   WHERE key = 'games_locked';
  IF NOT FOUND THEN
    INSERT INTO app_settings(key, value)
    VALUES ('games_locked', CASE WHEN p_locked THEN 'true' ELSE 'false' END);
  END IF;
  RETURN p_locked;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- admin: inject malware on one handle (reuses a live attack if already active)
CREATE OR REPLACE FUNCTION send_malware(p_target_handle TEXT, p_admin_pw TEXT)
RETURNS UUID AS $$
DECLARE v_id UUID;
BEGIN
  IF NOT admin_ok(p_admin_pw) THEN RAISE EXCEPTION 'unauthorized'; END IF;
  IF NOT EXISTS (SELECT 1 FROM handles WHERE handle = p_target_handle) THEN
    RAISE EXCEPTION 'no_such_handle';
  END IF;
  SELECT id INTO v_id FROM malware_events
    WHERE target_handle = p_target_handle AND resolved_at IS NULL
      AND NOW() - created_at < interval '5 minutes' LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  INSERT INTO malware_events(target_handle) VALUES (p_target_handle) RETURNING id INTO v_id;
  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- admin: inject malware on everyone
CREATE OR REPLACE FUNCTION send_malware_all(p_admin_pw TEXT)
RETURNS INT AS $$
DECLARE n INT := 0; r RECORD;
BEGIN
  IF NOT admin_ok(p_admin_pw) THEN RAISE EXCEPTION 'unauthorized'; END IF;
  FOR r IN SELECT handle FROM handles LOOP
    PERFORM send_malware(r.handle, p_admin_pw);
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- resolve an attack by entering ANY OTHER participant's uid
CREATE OR REPLACE FUNCTION resolve_malware(p_event_id UUID, p_uid TEXT)
RETURNS BOOLEAN AS $$
DECLARE v_target TEXT; v_owner TEXT;
BEGIN
  SELECT target_handle INTO v_target FROM malware_events
    WHERE id = p_event_id AND resolved_at IS NULL;
  IF v_target IS NULL THEN RETURN FALSE; END IF;
  SELECT handle INTO v_owner FROM handles WHERE uid = upper(trim(p_uid));
  IF v_owner IS NULL OR v_owner = v_target THEN RETURN FALSE; END IF;
  UPDATE malware_events SET resolved_at = NOW()
    WHERE id = p_event_id AND resolved_at IS NULL;
  RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- record a wrong Unique ID guess against a live attack — adds a 60s penalty
-- (only counts while the event is still unresolved)
CREATE OR REPLACE FUNCTION record_wrong_guess(p_event_id UUID)
RETURNS BOOLEAN AS $$
BEGIN
  UPDATE malware_events SET wrong_guesses = wrong_guesses + 1
   WHERE id = p_event_id AND resolved_at IS NULL;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- mark an attack as timed-out (only if genuinely >= 5 min old)
CREATE OR REPLACE FUNCTION timeout_malware(p_event_id UUID)
RETURNS BOOLEAN AS $$
BEGIN
  UPDATE malware_events SET resolved_at = NOW(), timed_out = TRUE
   WHERE id = p_event_id AND resolved_at IS NULL
     AND NOW() - created_at >= interval '5 minutes';
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- admin: full roster incl. uid (uid is not readable via plain REST). The admin
-- console calls this instead of selecting handles directly.
CREATE OR REPLACE FUNCTION admin_roster(p_admin_pw TEXT)
RETURNS TABLE(handle TEXT, uid TEXT)
AS $$
BEGIN
  IF NOT admin_ok(p_admin_pw) THEN RAISE EXCEPTION 'unauthorized'; END IF;
  RETURN QUERY SELECT h.handle, h.uid FROM handles h;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

GRANT EXECUTE ON FUNCTION
  register_handle(TEXT), verify_game_password(TEXT,TEXT),
  start_game(TEXT,TEXT), finish_game(TEXT,TEXT), admin_ok(TEXT),
  get_games_locked(), set_games_locked(BOOLEAN,TEXT),
  send_malware(TEXT,TEXT), send_malware_all(TEXT),
  resolve_malware(UUID,TEXT), timeout_malware(UUID),
  record_wrong_guess(UUID),
  admin_roster(TEXT)
  TO anon, authenticated;

-- realtime for instant malware delivery
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'malware_events'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE malware_events;
  END IF;
END $$;
