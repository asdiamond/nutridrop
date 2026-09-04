CREATE TABLE nutrition_records (
  id TEXT PRIMARY KEY,
  workos_user_id TEXT NOT NULL,
  client_record_id TEXT NOT NULL,
  consumed_at TEXT NOT NULL,
  consumed_utc_offset_minutes INTEGER NOT NULL,
  meal_label TEXT,
  nutrition_data TEXT NOT NULL CHECK (json_valid(nutrition_data)),
  schema_version INTEGER NOT NULL DEFAULT 1 CHECK (schema_version = 1),
  created_at TEXT NOT NULL,
  UNIQUE (workos_user_id, client_record_id)
) STRICT;

CREATE INDEX nutrition_records_user_created_at_idx
  ON nutrition_records (workos_user_id, created_at DESC);
