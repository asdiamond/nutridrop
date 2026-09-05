CREATE TABLE push_tokens (
  workos_user_id TEXT PRIMARY KEY,
  token TEXT NOT NULL,
  environment TEXT NOT NULL CHECK (environment IN ('sandbox', 'production')),
  updated_at TEXT NOT NULL,
  UNIQUE (environment, token)
) STRICT;
