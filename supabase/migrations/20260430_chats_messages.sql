-- Chat tables (replaces Firestore-based chats from web).
-- chatId is deterministic: '<uidA>_<uidB>' with uids sorted ascending.

CREATE TABLE IF NOT EXISTS chats (
  id text PRIMARY KEY,
  participants uuid[] NOT NULL,
  task_id uuid REFERENCES tasks(id) ON DELETE SET NULL,
  task_title text,
  last_message text,
  last_message_at timestamptz,
  unread jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS chats_participants_gin ON chats USING GIN (participants);
CREATE INDEX IF NOT EXISTS chats_last_message_at_idx ON chats (last_message_at DESC);

CREATE TABLE IF NOT EXISTS messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chat_id text NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  sender_id uuid NOT NULL,
  type text NOT NULL DEFAULT 'text',
  content text,
  media_url text,
  media_mime text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS messages_chat_created_idx ON messages (chat_id, created_at DESC);

ALTER TABLE chats ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "chats select participants" ON chats;
CREATE POLICY "chats select participants" ON chats
  FOR SELECT USING (auth.uid() = ANY(participants));

DROP POLICY IF EXISTS "chats update participants" ON chats;
CREATE POLICY "chats update participants" ON chats
  FOR UPDATE USING (auth.uid() = ANY(participants));

DROP POLICY IF EXISTS "chats insert participants" ON chats;
CREATE POLICY "chats insert participants" ON chats
  FOR INSERT WITH CHECK (auth.uid() = ANY(participants));

DROP POLICY IF EXISTS "messages select my chats" ON messages;
CREATE POLICY "messages select my chats" ON messages
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM chats
      WHERE chats.id = messages.chat_id
        AND auth.uid() = ANY(chats.participants)
    )
  );

DROP POLICY IF EXISTS "messages insert by sender" ON messages;
CREATE POLICY "messages insert by sender" ON messages
  FOR INSERT WITH CHECK (auth.uid() = sender_id);

-- Realtime publication so Supabase Realtime emits INSERT/UPDATE
ALTER PUBLICATION supabase_realtime ADD TABLE messages;
ALTER PUBLICATION supabase_realtime ADD TABLE chats;
