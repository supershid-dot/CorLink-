-- ============================================================
-- NON-PRODUCTION. Local disposable-Postgres test harness only.
-- Applied ONLY by apply-canonical-schema.sh --local-test-harness,
-- right after 00-auth-shim.sql and before schema.sql. NEVER apply
-- this against a real Supabase project — the real `storage` schema
-- (Supabase Storage extension) already exists there with its full,
-- real shape; this is a bare-minimum stand-in with just the columns
-- storage-policies.sql's own DDL (CREATE POLICY ON storage.objects,
-- UPDATE storage.buckets) touches, so that file's own SQL can be
-- proven syntactically valid and internally consistent against a
-- disposable Postgres instance that has no Storage extension at all.
-- ============================================================
CREATE SCHEMA IF NOT EXISTS storage;

CREATE TABLE IF NOT EXISTS storage.buckets (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  public BOOLEAN NOT NULL DEFAULT FALSE,
  file_size_limit BIGINT,
  allowed_mime_types TEXT[]
);

CREATE TABLE IF NOT EXISTS storage.objects (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id TEXT REFERENCES storage.buckets(id),
  name TEXT,
  owner UUID
);

ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION storage.foldername(name TEXT) RETURNS TEXT[]
LANGUAGE sql IMMUTABLE AS $$
  SELECT string_to_array(name, '/');
$$;

INSERT INTO storage.buckets (id, name, public) VALUES
  ('attachments', 'attachments', FALSE),
  ('prisoner-letters', 'prisoner-letters', FALSE),
  ('org-logos', 'org-logos', TRUE)
ON CONFLICT (id) DO NOTHING;
