# Dexgram Vault API (Cloudflare Worker + D1)

Multi-tenant storage API for mobile clients that need secure uploads/downloads to S3-compatible buckets, including Garage, without embedding long-term S3 credentials in apps.

## Long-term direction

Our long-term goal is to interconnect this S3 proxy with https://github.com/SiaFoundation/s3d and the decentralized Sia network. We are waiting for the project to become more reliable before making it part of the production storage path, but we see decentralized storage as the future of the DEX.

## Features

- **Client-code login** (`POST /auth/login`) backed by Internal API (`/v1/admin/users`) as source of truth.
- **Signed session token** (HMAC) for authenticated calls.
- **Bucket sharding per user** via `bucket_id` in D1 and bucket config from environment secrets.
- **Presigned S3 URLs** for uploads/downloads with short expiration.
- **Garage-compatible storage** using Garage's documented S3 compatibility: https://garagehq.deuxfleurs.fr/documentation/reference-manual/s3-compatibility/
- **Quota/subscription enforcement** based on Internal API source of truth before upload authorization.
- **Metadata + usage tracking** in D1 (`used_bytes`, upload/download counters, file index).
- **No long-term S3 credentials in mobile app.**
- **End-to-end encryption is handled entirely on the client side; the server never encrypts, decrypts, or manages encryption keys.**

## Project layout

- `src/index.ts` - Worker API and auth middleware.
- `src/utils/clientCode.ts` - client code normalization/parsing helper.
- `src/utils/token.ts` - HMAC token signing/verification.
- `src/utils/s3.ts` - AWS SigV4 presigning for custom S3-compatible endpoints.
- `migrations/0001_initial.sql` - D1 schema.
- `wrangler.toml.example` - Wrangler template (no secrets).

## D1 schema

Apply migrations from `migrations/` (see commands below). Core tables:

- `users`
  - local projection for runtime counters and bucket mapping
  - account entitlement fields (`quota_gb`, `subscription_expires_at`) are refreshed from Internal API on login/authenticated requests
- `files`
  - `file_id` (uuid, PK)
  - `client_code`
  - `object_key`
  - `size_bytes`, `mime_type`
  - `status` (`pending`/`active`/`deleted`)
  - `created_at`, `deleted_at`
- `file_replicas`
  - mirror/backup tracking only
  - does not count toward the user quota in `users.used_bytes`
  - records which bucket slot has a verified copy for each `file_id`

## Environment variables / secrets

Set with Worker secrets or GitHub Actions secrets:

- `SESSION_SECRET`: random long HMAC secret for session tokens.
- `INTERNALAPI`: internal API base URL (example: `https://internal-api.example.com/`).
- `INTERNALAPI_SECRET`: shared admin secret sent as `X-Admin-Secret` to Internal API.
- `BUCKET_MAIN`: active bucket slot for normal user uploads/downloads/deletes (`1`, `2`, etc.).
- `PROTECTED_DELETE_BUCKET_SLOTS`: comma-separated bucket slots that admin cleanup is not allowed to delete from (example: `1`).
- `BACKUP_READ_SECRET`: admin secret for backup planning and marking copied replicas.
- `BACKUP_DELETE_SECRET`: admin secret for cleanup planning and marking deleted replicas on non-protected bucket slots.
- Indexed bucket secrets (no JSON). For each bucket slot `N` (1..20), configure:
  - `BUCKET_ID_N` (must match `users.bucket_id` in D1)
  - `BUCKET_NAME_N`
  - `BUCKET_ENDPOINT_N`
  - `BUCKET_REGION_N`
  - `BUCKET_ACCESS_KEY_N`
  - `BUCKET_SECRET_KEY_N`

Example for one bucket:

```bash
BUCKET_ID_1=
BUCKET_NAME_1=vault
BUCKET_ENDPOINT_1=
BUCKET_REGION_1=
BUCKET_ACCESS_KEY_1=...
BUCKET_SECRET_KEY_1=...
BUCKET_MAIN=1
PROTECTED_DELETE_BUCKET_SLOTS=1
```

Optional non-secret vars:

- `TOKEN_TTL_SECONDS` (default `86400`)
- `URL_TTL_SECONDS` (default `300`)
- `MAX_UPLOAD_BYTES` (default `5368709120`)
- `RATE_LIMIT_MAX_REQUESTS` (default `60`)
- `RATE_LIMIT_WINDOW_MS` (default `60000`)

## Local development

1. Install dependencies:
   ```bash
   npm install
   ```
2. Copy template:
   ```bash
   cp wrangler.toml.example wrangler.toml
   ```
3. Create D1 DB and set `database_id` in `wrangler.toml`.
4. Apply migrations locally:
   ```bash
   npx wrangler d1 migrations apply vault-db --local
   ```
5. Add secrets:
   ```bash
   npx wrangler secret put SESSION_SECRET
   npx wrangler secret put INTERNALAPI
   npx wrangler secret put INTERNALAPI_SECRET
   npx wrangler secret put BUCKET_ID_1
   npx wrangler secret put BUCKET_NAME_1
   npx wrangler secret put BUCKET_ENDPOINT_1
   npx wrangler secret put BUCKET_REGION_1
   npx wrangler secret put BUCKET_ACCESS_KEY_1
   npx wrangler secret put BUCKET_SECRET_KEY_1
   ```
6. Run Worker:
   ```bash
   npm run dev
   ```

## API

### 1) Login

`POST /auth/login`

Body:
```json
{ "clientCode": "<client_code>" }
```

Returns token + usage stats. Login first refreshes the user entitlement from Internal API and upserts local projection row in D1.

### 2) Request upload URL

`POST /uploads/request` (auth required)

Body:
```json
{ "mimeType": "image/jpeg", "sizeBytes": 98304 }
```

Returns:

- `fileId`
- `objectKey` (always `_digits/yyyy/mm/uuid`)
- short-lived `uploadUrl` (presigned PUT)
- required headers (`content-type`, `content-length`)

### 3) Complete upload

`POST /uploads/complete` (auth required)

Body:
```json
{ "fileId": "uuid" }
```

Worker verifies object exists via `HEAD`, finalizes metadata, updates counters.

### 4) List files

`GET /files` (auth required)

Returns file list from D1 only.

### 5) Request download URL

`GET /files/:fileId/download` (auth required)

Returns short-lived presigned GET URL and increments `downloads_count`.

### 6) Replace/overwrite an existing file

`POST /files/:fileId/replace/request` (auth required)

Body:
```json
{ "mimeType": "text/plain", "sizeBytes": 2048 }
```

Returns a presigned PUT URL targeting the existing object key for that `fileId`.

Then call:

`POST /files/:fileId/replace/complete` (auth required)

Worker verifies the new object and updates usage (`used_bytes`) using the size delta.

### 7) Get client usage

`GET /usage` (auth required)

Returns:
- `usedBytes` (tracked counter in `users`)
- `actualActiveBytes` (sum of active file sizes in `files`)
- `activeFilesCount`

### 8) Delete file

`DELETE /files/:fileId` (auth required)

Yes: delete is done by `fileId`. The API marks row as deleted, decrements `used_bytes`, and attempts async object deletion from storage.

## Main bucket, mirror bucket, and protected admin deletes

`BUCKET_MAIN` selects the active bucket slot used by normal user traffic. Set it to the slot you want as primary:

```bash
BUCKET_MAIN=1
```

or:

```bash
BUCKET_MAIN=2
```

User uploads, downloads, replacements, and user-initiated deletes use `BUCKET_MAIN`. The other bucket can be used as a mirror by the backup scripts.

For customer data protection, the full bucket contents are duplicated to another region, in a separate datacenter, using a completely different storage provider from the primary bucket. This keeps an independent copy of customer files outside the primary provider and region.

Example replication command from primary bucket slot `1` to mirror bucket slot `2`:

```bash
BACKUP_READ_SECRET=... ./scripts/backup-bucket-replica.sh https://test-vaultdb.dexgram.app 1 2
```

The script requests a backup plan from the API, copies each active object from the source bucket to the target bucket, verifies the copied object, and marks the replica as copied in `file_replicas`.

The user quota is counted once from the logical active files in D1 (`users.used_bytes`). A mirrored copy in `file_replicas` does not count a second time against the user's quota. For example, a 1 GB active file counts as 1 GB for the user even if it is physically present in two buckets.

`PROTECTED_DELETE_BUCKET_SLOTS` blocks admin cleanup deletes on selected bucket slots:

```bash
PROTECTED_DELETE_BUCKET_SLOTS=1
```

With that setting, admin cleanup endpoints cannot generate DELETE URLs for bucket slot `1`, and they cannot mark bucket slot `1` replicas as deleted. This protects bucket `1` from accidental or compromised admin cleanup actions. The normal authenticated user delete still works against the current `BUCKET_MAIN`.

Typical setup:

```bash
BUCKET_MAIN=1
PROTECTED_DELETE_BUCKET_SLOTS=1
```

In this mode, bucket `1` is the primary user bucket and cannot be physically deleted through the admin cleanup mode. The mirror bucket can still be cleaned by admin cleanup if it is not listed in `PROTECTED_DELETE_BUCKET_SLOTS`.

To disable admin cleanup deletes on every configured bucket, list every protected slot:

```bash
PROTECTED_DELETE_BUCKET_SLOTS=1,2
```

## Example cURL

```bash
# 1) Login
TOKEN=$(curl -s https://test-vaultdb.dexgram.app/auth/login \
  -H 'content-type: application/json' \
  -d '{"clientCode":"<client_code>"}' | jq -r .token)

# 2) Request upload URL
curl -s https://test-vaultdb.dexgram.app/uploads/request \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"mimeType":"image/jpeg","sizeBytes":1024}'

# 3) List files
curl -s https://test-vaultdb.dexgram.app/files \
  -H "authorization: Bearer $TOKEN"

# 4) Usage by client
curl -s https://test-vaultdb.dexgram.app/usage \
  -H "authorization: Bearer $TOKEN"

# 5) Delete one file by file_id
curl -s -X DELETE https://test-vaultdb.dexgram.app/files/<file_id> \
  -H "authorization: Bearer $TOKEN"

# 6) Overwrite a file (same file_id)
REPLACE=$(curl -s https://test-vaultdb.dexgram.app/files/<file_id>/replace/request \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"mimeType":"text/plain","sizeBytes":15}')

UPLOAD_URL=$(echo "$REPLACE" | jq -r '.uploadUrl')
CT=$(echo "$REPLACE" | jq -r '.requiredHeaders["content-type"]')
CL=$(echo "$REPLACE" | jq -r '.requiredHeaders["content-length"]')

curl -s -X PUT "$UPLOAD_URL" \
  -H "content-type: $CT" \
  -H "content-length: $CL" \
  --data-binary '@./toto.txt'

curl -s -X POST https://test-vaultdb.dexgram.app/files/<file_id>/replace/complete \
  -H "authorization: Bearer $TOKEN"
```

## Demo script: upload / replace / usage / delete

Yes: the client should validate file metadata **before** requesting a presigned upload URL.

- detect/choose `mimeType`
- compute exact `sizeBytes`
- apply local product rules (e.g. max size, allowed types)

The API also revalidates plan/quota/subscription and returns the exact signed headers required for PUT (`content-type`, `content-length`).

Use the included demo script to run the full flow from start to finish:

```bash
# create a small demo file
echo -n "hello world!" > hello.txt

# run end-to-end demo
./scripts/demo-upload.sh upload "<client_code>" ./hello.txt

# show usage
./scripts/demo-upload.sh usage "<client_code>"

# overwrite an existing file_id
./scripts/demo-upload.sh replace "<client_code>" ./hello-v2.txt --file-id <file_id>

# delete by file_id
./scripts/demo-upload.sh delete "<client_code>" --file-id <file_id>
```

What the script does:

1. validates local file (exists, size > 0, basic MIME allowlist)
2. logs in (`POST /auth/login`)
3. requests upload URL (`POST /uploads/request`)
4. uploads file bytes to `uploadUrl` with required headers (PUT)
5. completes upload (`POST /uploads/complete`)
6. lists files (`GET /files`)

## Test scripts: quota and files

The smaller test scripts are useful when you want to check one user quickly without running the full demo flow.

Both scripts use the test API endpoint by default:

```bash
https://test-vaultdb.dexgram.app
```

You can pass another API base URL as the last argument.

### Check user quota

```bash
./scripts/test-quota.sh <client_code> [api_base]
```

Example:

```bash
./scripts/test-quota.sh "<client_code>"
```

This logs in with the client code, calls `GET /usage`, and prints the quota, used bytes, active file count, upload count, download count, and subscription status.

### Upload, list, and delete files

```bash
./scripts/test-file.sh upload <client_code> <file_path> [api_base]
./scripts/test-file.sh list <client_code> [api_base]
./scripts/test-file.sh delete <client_code> <file_id> [api_base]
```

Examples:

```bash
# create a small test file
echo -n "hello world!" > hello.txt

# upload the file for one user
./scripts/test-file.sh upload "<client_code>" ./hello.txt

# list active files for that user
./scripts/test-file.sh list "<client_code>"

# delete one file by file_id
./scripts/test-file.sh delete "<client_code>" <file_id>
```

The `upload` command prints the API response from `POST /uploads/complete`, including the created `fileId` and updated usage values. Use that `fileId` for delete tests.

## Troubleshooting

### `error code: 1101` on Cloudflare

Cloudflare `1101` means the Worker crashed with an unhandled runtime exception.
In this project, common causes are:

- missing or incomplete indexed bucket secrets (`BUCKET_ID_N`, `BUCKET_NAME_N`, `BUCKET_ENDPOINT_N`, `BUCKET_REGION_N`, `BUCKET_ACCESS_KEY_N`, `BUCKET_SECRET_KEY_N`)
- missing/misconfigured `DB` binding
- unexpected data shape from D1 that triggers an exception

Useful commands:

```bash
# stream production logs to see the real stack trace
npx wrangler tail --env prod

# verify secrets exist
npx wrangler secret list --env prod
```

### Add/update a user manually with Wrangler (D1)

`users.client_code` is stored as digits only, without spaces.

```bash
# create or update a user in production
npx wrangler d1 execute vault-db --remote --command "
INSERT INTO users (client_code, bucket_id, quota_gb, subscription_expires_at)
VALUES ('<client_code_digits>', 'bucket-1', 20, '2026-12-31T23:59:59.000Z')
ON CONFLICT(client_code) DO UPDATE SET
  bucket_id = excluded.bucket_id,
  quota_gb = excluded.quota_gb,
  subscription_expires_at = excluded.subscription_expires_at;
"

# verify
npx wrangler d1 execute vault-db --remote --command "
SELECT client_code, bucket_id, quota_gb, used_bytes, subscription_expires_at
FROM users
WHERE client_code = '<client_code_digits>';
"
```

## GitHub Actions secret injection

In CI/CD, the workflow `.github/workflows/deploy-prod.yml` syncs GitHub secrets to Cloudflare on every deploy.

Configure these GitHub secrets in the `prod` environment:

- `wrangler secret put SESSION_SECRET`
- `wrangler secret put INTERNALAPI`
- `wrangler secret put INTERNALAPI_SECRET`
- `wrangler secret put BUCKET_MAIN`
- `wrangler secret put PROTECTED_DELETE_BUCKET_SLOTS`
- `wrangler secret put BACKUP_READ_SECRET`
- `wrangler secret put BACKUP_DELETE_SECRET`
- `wrangler secret put BUCKET_ID_1`
- `wrangler secret put BUCKET_NAME_1`
- `wrangler secret put BUCKET_ENDPOINT_1`
- `wrangler secret put BUCKET_REGION_1`
- `wrangler secret put BUCKET_ACCESS_KEY_1`
- `wrangler secret put BUCKET_SECRET_KEY_1`

For additional bucket slots, duplicate the same pattern (`_2`, `_3`, etc.) in both GitHub environment secrets and workflow sync steps.
