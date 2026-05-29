#!/usr/bin/env bash
set -euo pipefail

# Export a remote Cloudflare D1 database to a timestamped SQL backup.
#
# Usage:
#   ./scripts/backup-d1.sh [database_name] [output_dir]
#
# Examples:
#   ./scripts/backup-d1.sh
#   ./scripts/backup-d1.sh vault-db
#   ./scripts/backup-d1.sh vault-db /path/to/backups/d1
#
# Environment overrides:
#   D1_DATABASE_NAME=vault-db
#   BACKUP_DIR=/path/to/backups/d1

DEFAULT_D1_DATABASE_NAME="vault-db"

DB_NAME="${D1_DATABASE_NAME:-${1:-$DEFAULT_D1_DATABASE_NAME}}"
BACKUP_DIR="${BACKUP_DIR:-${2:-backups/d1}}"
TIMESTAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
SAFE_DB_NAME="${DB_NAME//[^A-Za-z0-9_.-]/_}"
OUTPUT_SQL="$BACKUP_DIR/${SAFE_DB_NAME}_${TIMESTAMP}.sql"

if [[ -z "$DB_NAME" ]]; then
  echo "ERROR: database_name is required" >&2
  exit 1
fi

if ! command -v npx >/dev/null 2>&1 && ! command -v wrangler >/dev/null 2>&1 && [[ ! -x ./node_modules/.bin/wrangler ]]; then
  echo "ERROR: wrangler is required. Install dependencies with npm ci or install wrangler globally." >&2
  exit 1
fi

if [[ -x ./node_modules/.bin/wrangler ]]; then
  WRANGLER_CMD=(./node_modules/.bin/wrangler)
elif command -v wrangler >/dev/null 2>&1; then
  WRANGLER_CMD=(wrangler)
else
  WRANGLER_CMD=(npx wrangler)
fi

mkdir -p "$BACKUP_DIR"

echo "==> Exporting remote D1 database"
echo "    database: $DB_NAME"
echo "    output:   $OUTPUT_SQL"

"${WRANGLER_CMD[@]}" d1 export "$DB_NAME" --remote --output "$OUTPUT_SQL"

if [[ ! -s "$OUTPUT_SQL" ]]; then
  echo "ERROR: backup file was not created or is empty: $OUTPUT_SQL" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$OUTPUT_SQL" > "$OUTPUT_SQL.sha256"
elif command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$OUTPUT_SQL" > "$OUTPUT_SQL.sha256"
fi

if command -v gzip >/dev/null 2>&1; then
  gzip -kf "$OUTPUT_SQL"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$OUTPUT_SQL.gz" > "$OUTPUT_SQL.gz.sha256"
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$OUTPUT_SQL.gz" > "$OUTPUT_SQL.gz.sha256"
  fi
fi

echo "==> Backup complete"
echo "    sql: $OUTPUT_SQL"
if [[ -f "$OUTPUT_SQL.gz" ]]; then
  echo "    gzip: $OUTPUT_SQL.gz"
fi
if [[ -f "$OUTPUT_SQL.sha256" ]]; then
  echo "    checksum: $OUTPUT_SQL.sha256"
fi
