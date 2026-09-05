CREATE INDEX nutrition_records_user_cursor_idx
  ON nutrition_records (workos_user_id, created_at, id);
