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

-- Individual challenge completions
CREATE TABLE IF NOT EXISTS completions (
  id           UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  handle       TEXT REFERENCES handles(handle) ON DELETE CASCADE,
  challenge_id TEXT        NOT NULL,
  points       INT         NOT NULL DEFAULT 0,
  completed_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(handle, challenge_id)   -- prevents double-submission
);

-- ============================================================
-- 2. TRIGGER — keep handles.points in sync
-- ============================================================

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
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS after_completion_insert ON completions;
CREATE TRIGGER after_completion_insert
  AFTER INSERT ON completions
  FOR EACH ROW EXECUTE FUNCTION update_handle_points();

-- ============================================================
-- 3. ROW LEVEL SECURITY
-- ============================================================

ALTER TABLE handles     ENABLE ROW LEVEL SECURITY;
ALTER TABLE completions ENABLE ROW LEVEL SECURITY;

-- handles: anyone can register a new handle and view the list
CREATE POLICY "handles_select" ON handles FOR SELECT USING (true);
CREATE POLICY "handles_insert" ON handles FOR INSERT WITH CHECK (true);

-- completions: anyone can view; anyone can insert their own
CREATE POLICY "completions_select" ON completions FOR SELECT USING (true);
CREATE POLICY "completions_insert" ON completions FOR INSERT WITH CHECK (true);

-- ============================================================
-- 4. REALTIME — enable live leaderboard updates
-- ============================================================

ALTER PUBLICATION supabase_realtime ADD TABLE handles;
ALTER PUBLICATION supabase_realtime ADD TABLE completions;
