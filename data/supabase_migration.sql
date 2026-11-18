-- ====================================================
-- Supabase All-in-One Migration for Domino Masri
-- ====================================================

-- 1. App Users (PIN Authentication)
CREATE TABLE IF NOT EXISTS app_users (
  id TEXT PRIMARY KEY,
  username TEXT NOT NULL,
  display_name TEXT NOT NULL,
  salt TEXT NOT NULL,
  pin_hash TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. User Sessions
CREATE TABLE IF NOT EXISTS user_sessions (
  token TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3. Match History
CREATE TABLE IF NOT EXISTS match_history (
  id TEXT PRIMARY KEY,
  match_key TEXT UNIQUE,
  room_code TEXT,
  target_score INT DEFAULT 31,
  rounds_played INT DEFAULT 1,
  winner_name TEXT,
  players JSONB NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_match_history_created_at ON match_history(created_at DESC);

-- 4. Live Multiplayer Game Rooms
CREATE TABLE IF NOT EXISTS game_rooms (
  code TEXT PRIMARY KEY,
  creator_token TEXT,
  target_score INT DEFAULT 31,
  round_number INT DEFAULT 1,
  match_seq INT DEFAULT 1,
  started BOOLEAN DEFAULT FALSE,
  players JSONB NOT NULL DEFAULT '[]'::jsonb,
  watchers JSONB NOT NULL DEFAULT '[]'::jsonb,
  deal JSONB,
  actions JSONB NOT NULL DEFAULT '[]'::jsonb,
  next_round_votes JSONB NOT NULL DEFAULT '{}'::jsonb,
  turn_started_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Enable Realtime for Live Rooms
ALTER PUBLICATION supabase_realtime ADD TABLE game_rooms;

-- Row Level Security & Public Policies for Client Access
ALTER TABLE app_users ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Allow public all on app_users" ON app_users;
CREATE POLICY "Allow public all on app_users" ON app_users FOR ALL USING (true) WITH CHECK (true);

ALTER TABLE user_sessions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Allow public all on user_sessions" ON user_sessions;
CREATE POLICY "Allow public all on user_sessions" ON user_sessions FOR ALL USING (true) WITH CHECK (true);

ALTER TABLE match_history ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Allow public all on match_history" ON match_history;
CREATE POLICY "Allow public all on match_history" ON match_history FOR ALL USING (true) WITH CHECK (true);

ALTER TABLE game_rooms ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Allow public all on game_rooms" ON game_rooms;
CREATE POLICY "Allow public all on game_rooms" ON game_rooms FOR ALL USING (true) WITH CHECK (true);
