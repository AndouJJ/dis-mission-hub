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
  ('exp-1', 10), ('exp-2', 70), ('exp-3', 80), ('exp-4', 100)
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

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
$$ LANGUAGE plpgsql SECURITY DEFINER;

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
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'handles'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE handles;
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
CREATE POLICY "challenge_photos_insert" ON storage.objects
  FOR INSERT TO anon
  WITH CHECK (bucket_id = 'challenge-photos');

CREATE POLICY "challenge_photos_select" ON storage.objects
  FOR SELECT TO anon
  USING (bucket_id = 'challenge-photos');
