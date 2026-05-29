#!/usr/bin/env bash
set -euo pipefail

# Delete replica objects that were deleted in the API at least 72h ago by default.
#
# Usage:
#   BACKUP_DELETE_SECRET=... ./scripts/backup-bucket-cleanup.sh [api_base] [from_slot] [to_slot]
#
# Examples:
#   BACKUP_DELETE_SECRET=... ./scripts/backup-bucket-cleanup.sh
#   BACKUP_DELETE_SECRET=... ./scripts/backup-bucket-cleanup.sh https://test-vaultdb.dexgram.app 1 2
#   OLDER_THAN_HOURS=168 BACKUP_DELETE_SECRET=... ./scripts/backup-bucket-cleanup.sh https://test-vaultdb.dexgram.app 2 1

API_BASE="${1:-${API_BASE:-https://test-vaultdb.dexgram.app}}"
FROM_SLOT="${2:-${FROM_SLOT:-}}"
TO_SLOT="${3:-${TO_SLOT:-}}"
LIMIT="${LIMIT:-100}"
TTL_SECONDS="${TTL_SECONDS:-900}"
OLDER_THAN_HOURS="${OLDER_THAN_HOURS:-72}"
BACKUP_DELETE_SECRET="${BACKUP_DELETE_SECRET:-}"

if [[ -z "$BACKUP_DELETE_SECRET" ]]; then
  echo "ERROR: BACKUP_DELETE_SECRET is required" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

query_param() {
  local name="$1"
  local value="$2"
  if [[ -n "$value" ]]; then
    printf '&%s=%s' "$name" "$value"
  fi
}

mark_deleted() {
  local file_id="$1"
  local to_slot="$2"
  local response_file="$3"
  local error_file="$4"
  local status

  status="$(curl -sS -w '%{http_code}' "${API_BASE%/}/admin/backup/mark-deleted" \
    -H "x-backup-secret: $BACKUP_DELETE_SECRET" \
    -H 'content-type: application/json' \
    -d "$(jq -nc --arg fileId "$file_id" --arg toSlot "$to_slot" '{fileId:$fileId,toSlot:$toSlot}')" \
    -o "$response_file" 2>"$error_file")"
  if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
    echo "$status"
    return 1
  fi
}

offset=0
deleted=0

while true; do
  plan_url="${API_BASE%/}/admin/backup/delete-plan?limit=${LIMIT}&offset=${offset}&ttl=${TTL_SECONDS}&olderThanHours=${OLDER_THAN_HOURS}"
  plan_url="${plan_url}$(query_param from "$FROM_SLOT")$(query_param to "$TO_SLOT")"

  plan="$(curl -sS "$plan_url" -H "x-backup-secret: $BACKUP_DELETE_SECRET")"

  if echo "$plan" | jq -e '.error' >/dev/null 2>&1; then
    echo "$plan" | jq . >&2
    exit 1
  fi

  batch_count="$(echo "$plan" | jq '.files | length')"
  if [[ "$batch_count" -eq 0 ]]; then
    break
  fi
  effective_to_slot="$(echo "$plan" | jq -r '.toSlot')"

  while IFS= read -r file; do
    file_id="$(echo "$file" | jq -r '.fileId')"
    object_key="$(echo "$file" | jq -r '.objectKey')"
    delete_url="$(echo "$file" | jq -r '.deleteUrl')"

    response_file="$(mktemp)"
    error_file="$(mktemp)"

    curl -f -sS -X DELETE "$delete_url" -o /dev/null

    if [[ -n "$effective_to_slot" && "$effective_to_slot" != "null" ]]; then
      if ! status="$(mark_deleted "$file_id" "$effective_to_slot" "$response_file" "$error_file")"; then
        echo "ERROR: replica delete mark failed for file_id=$file_id object_key=$object_key http_status=$status" >&2
        cat "$error_file" >&2
        cat "$response_file" >&2
        rm -f "$response_file" "$error_file"
        exit 1
      fi
    fi

    rm -f "$response_file" "$error_file"

    deleted=$((deleted + 1))
    echo "deleted replica file_id=$file_id object_key=$object_key"
  done < <(echo "$plan" | jq -c '.files[]')

  next_offset="$(echo "$plan" | jq -r '.nextOffset // empty')"
  if [[ -z "$next_offset" ]]; then
    break
  fi
  offset="$next_offset"
done

echo "backup cleanup complete: deleted=$deleted"
