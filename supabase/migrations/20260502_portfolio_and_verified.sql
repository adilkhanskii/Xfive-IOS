-- Portfolio items table (matches web hubService.ts shape).
CREATE TABLE IF NOT EXISTS portfolio_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type text NOT NULL DEFAULT 'image',
  title text,
  description text,
  media_url text,
  thumbnail_url text,
  link text,
  sort_order int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS portfolio_items_user_idx ON portfolio_items (user_id, sort_order);

ALTER TABLE portfolio_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "portfolio public read" ON portfolio_items;
CREATE POLICY "portfolio public read" ON portfolio_items FOR SELECT USING (true);

DROP POLICY IF EXISTS "portfolio owner write" ON portfolio_items;
CREATE POLICY "portfolio owner write" ON portfolio_items
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- Storage bucket for portfolio media (idempotent).
INSERT INTO storage.buckets (id, name, public)
VALUES ('portfolio', 'portfolio', true)
ON CONFLICT (id) DO NOTHING;

-- Verified badge fields on profiles
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS is_verified boolean NOT NULL DEFAULT false;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS verified_until timestamptz;
