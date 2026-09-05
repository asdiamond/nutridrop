ALTER TABLE nutrition_records ADD COLUMN healthkit_acknowledged_at TEXT;

CREATE INDEX nutrition_records_pending_idx
  ON nutrition_records (workos_user_id, created_at, id)
  WHERE healthkit_acknowledged_at IS NULL;
