CREATE TABLE IF NOT EXISTS file_replicas (
  file_id       TEXT NOT NULL,
  bucket_slot   TEXT NOT NULL,
  object_key    TEXT NOT NULL,
  size_bytes    INTEGER NOT NULL,
  etag          TEXT,
  status        TEXT NOT NULL DEFAULT 'verified',
  replicated_at TEXT NOT NULL,
  verified_at   TEXT,
  last_error     TEXT,
  PRIMARY KEY (file_id, bucket_slot),
  FOREIGN KEY (file_id) REFERENCES files(file_id)
);

CREATE INDEX IF NOT EXISTS idx_file_replicas_bucket_status ON file_replicas(bucket_slot, status, verified_at DESC);
