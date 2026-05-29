#!/usr/bin/env bash
set -euo pipefail

# Replicate active vault objects from one configured bucket slot to another.
#
# Usage:
#   BACKUP_READ_SECRET=... ./scripts/backup-bucket-replica.sh [api_base] [from_slot] [to_slot]
#
# Examples:
#   BACKUP_READ_SECRET=... ./scripts/backup-bucket-replica.sh
#   BACKUP_READ_SECRET=... ./scripts/backup-bucket-replica.sh https://test-vaultdb.dexgram.app 1 2
#   BACKUP_READ_SECRET=... ./scripts/backup-bucket-replica.sh https://test-vaultdb.dexgram.app 2 1

API_BASE="${1:-${API_BASE:-https://test-vaultdb.dexgram.app}}"
FROM_SLOT="${2:-${FROM_SLOT:-}}"
TO_SLOT="${3:-${TO_SLOT:-}}"
LIMIT="${LIMIT:-100}"
TTL_SECONDS="${TTL_SECONDS:-1800}"
BACKUP_READ_SECRET="${BACKUP_READ_SECRET:-}"

if [[ -z "$BACKUP_READ_SECRET" ]]; then
  echo "ERROR: BACKUP_READ_SECRET is required" >&2
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

compute_size() {
  local path="$1"

  if stat --version >/dev/null 2>&1; then
    stat -c%s "$path"
  else
    stat -f%z "$path"
  fi
}

curl_to_file() {
  local url="$1"
  local output_file="$2"
  local error_file="$3"
  local status

  status="$(curl -L -sS -w '%{http_code}' "$url" -o "$output_file" 2>"$error_file")"
  if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
    echo "$status"
    return 1
  fi
}

curl_put_file() {
  local url="$1"
  local content_type="$2"
  local content_length="$3"
  local input_file="$4"
  local response_file="$5"
  local error_file="$6"
  local status

  status="$(curl -sS -w '%{http_code}' -X PUT "$url" \
    -H "content-type: $content_type" \
    -H "content-length: $content_length" \
    --data-binary "@$input_file" \
    -o "$response_file" 2>"$error_file")"
  if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
    echo "$status"
    return 1
  fi
}

mark_copied() {
  local file_id="$1"
  local to_slot="$2"
  local response_file="$3"
  local error_file="$4"
  local status

  status="$(curl -sS -w '%{http_code}' "${API_BASE%/}/admin/backup/mark-copied" \
    -H "x-backup-secret: $BACKUP_READ_SECRET" \
    -H 'content-type: application/json' \
    -d "$(jq -nc --arg fileId "$file_id" --arg toSlot "$to_slot" '{fileId:$fileId,toSlot:$toSlot}')" \
    -o "$response_file" 2>"$error_file")"
  if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
    echo "$status"
    return 1
  fi
}

query_param() {
  local name="$1"
  local value="$2"
  if [[ -n "$value" ]]; then
    printf '&%s=%s' "$name" "$value"
  fi
}

offset=0
copied=0

while true; do
  plan_url="${API_BASE%/}/admin/backup/plan?limit=${LIMIT}&offset=${offset}&ttl=${TTL_SECONDS}"
  plan_url="${plan_url}$(query_param from "$FROM_SLOT")$(query_param to "$TO_SLOT")"

  plan="$(curl -sS "$plan_url" -H "x-backup-secret: $BACKUP_READ_SECRET")"

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
    expected_size="$(echo "$file" | jq -r '.requiredHeaders["content-length"]')"
    content_type="$(echo "$file" | jq -r '.requiredHeaders["content-type"]')"
    download_url="$(echo "$file" | jq -r '.downloadUrl')"
    upload_url="$(echo "$file" | jq -r '.uploadUrl')"

    tmp_file="$(mktemp)"
    response_file="$(mktemp)"
    error_file="$(mktemp)"

    echo "copying file_id=$file_id object_key=$object_key size=$expected_size"

    if ! status="$(curl_to_file "$download_url" "$tmp_file" "$error_file")"; then
      echo "ERROR: source download failed for file_id=$file_id object_key=$object_key http_status=$status" >&2
      cat "$error_file" >&2
      cat "$tmp_file" >&2
      rm -f "$tmp_file" "$response_file" "$error_file"
      exit 1
    fi

    actual_size="$(compute_size "$tmp_file")"
    if [[ "$actual_size" != "$expected_size" ]]; then
      echo "ERROR: size mismatch for $file_id ($object_key): expected $expected_size, got $actual_size" >&2
      rm -f "$tmp_file" "$response_file" "$error_file"
      exit 1
    fi

    if ! status="$(curl_put_file "$upload_url" "$content_type" "$expected_size" "$tmp_file" "$response_file" "$error_file")"; then
      echo "ERROR: destination upload failed for file_id=$file_id object_key=$object_key http_status=$status" >&2
      cat "$error_file" >&2
      cat "$response_file" >&2
      rm -f "$tmp_file" "$response_file" "$error_file"
      exit 1
    fi

    if [[ -n "$effective_to_slot" && "$effective_to_slot" != "null" ]]; then
      if ! status="$(mark_copied "$file_id" "$effective_to_slot" "$response_file" "$error_file")"; then
        echo "ERROR: replica verification failed for file_id=$file_id object_key=$object_key http_status=$status" >&2
        cat "$error_file" >&2
        cat "$response_file" >&2
        rm -f "$tmp_file" "$response_file" "$error_file"
        exit 1
      fi
    fi

    rm -f "$tmp_file" "$response_file" "$error_file"

    copied=$((copied + 1))
    echo "copied file_id=$file_id object_key=$object_key size=$expected_size"
  done < <(echo "$plan" | jq -c '.files[]')

  next_offset="$(echo "$plan" | jq -r '.nextOffset // empty')"
  if [[ -z "$next_offset" ]]; then
    break
  fi
  offset="$next_offset"
done

echo "backup replica complete: copied=$copied"
