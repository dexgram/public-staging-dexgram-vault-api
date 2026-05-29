#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./scripts/test-file.sh upload <client_code> <file_path> [api_base]
#   ./scripts/test-file.sh list <client_code> [api_base]
#   ./scripts/test-file.sh delete <client_code> <file_id> [api_base]
#
# Examples:
#   ./scripts/test-file.sh upload <client_code> ./hello.txt
#   ./scripts/test-file.sh list <client_code>
#   ./scripts/test-file.sh delete <client_code> <file_id>

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

ACTION="${1:-}"
CLIENT_CODE="${2:-}"
API_BASE="https://test-vaultdb.dexgram.app"
FILE_PATH=""
FILE_ID=""

usage() {
  echo "Usage:" >&2
  echo "  $0 upload <client_code> <file_path> [api_base]" >&2
  echo "  $0 list <client_code> [api_base]" >&2
  echo "  $0 delete <client_code> <file_id> [api_base]" >&2
}

if [[ -z "$ACTION" || -z "$CLIENT_CODE" ]]; then
  usage
  exit 1
fi

shift 2

case "$ACTION" in
  upload)
    FILE_PATH="${1:-}"
    API_BASE="${2:-$API_BASE}"
    if [[ -z "$FILE_PATH" || ! -f "$FILE_PATH" ]]; then
      echo "ERROR: file_path is required and must exist" >&2
      exit 1
    fi
    ;;
  list)
    API_BASE="${1:-$API_BASE}"
    ;;
  delete)
    FILE_ID="${1:-}"
    API_BASE="${2:-$API_BASE}"
    if [[ -z "$FILE_ID" ]]; then
      echo "ERROR: file_id is required" >&2
      exit 1
    fi
    ;;
  *)
    usage
    exit 1
    ;;
esac

compute_size() {
  local path="$1"

  if ! command -v stat >/dev/null 2>&1; then
    echo "ERROR: stat is required" >&2
    exit 1
  fi

  if stat --version >/dev/null 2>&1; then
    stat -c%s "$path"
  else
    stat -f%z "$path"
  fi
}

detect_mime() {
  local path="$1"

  if command -v file >/dev/null 2>&1; then
    file --mime-type -b "$path"
  else
    echo "application/octet-stream"
  fi
}

login() {
  local resp token

  resp="$(curl -sS "$API_BASE/auth/login" \
    -H 'content-type: application/json' \
    -d "$(jq -nc --arg cc "$CLIENT_CODE" '{clientCode:$cc}')")"

  token="$(echo "$resp" | jq -r '.token')"
  if [[ -z "$token" || "$token" == "null" ]]; then
    echo "ERROR: login failed" >&2
    echo "$resp" | jq . >&2
    exit 1
  fi

  echo "$token"
}

put_binary() {
  local url="$1"
  local content_type="$2"
  local content_length="$3"
  local file_path="$4"
  local response_file status

  response_file="$(mktemp)"
  status="$(curl -sS -o "$response_file" -w '%{http_code}' -X PUT "$url" \
    -H "content-type: $content_type" \
    -H "content-length: $content_length" \
    --data-binary "@$file_path")"

  if [[ "$status" != "200" ]]; then
    echo "ERROR: binary upload failed with HTTP $status" >&2
    cat "$response_file" >&2
    rm -f "$response_file"
    exit 1
  fi

  rm -f "$response_file"
}

TOKEN="$(login)"

case "$ACTION" in
  upload)
    SIZE_BYTES="$(compute_size "$FILE_PATH")"
    MIME_TYPE="$(detect_mime "$FILE_PATH")"

    REQUEST_RESP="$(curl -sS "$API_BASE/uploads/request" \
      -H "authorization: Bearer $TOKEN" \
      -H 'content-type: application/json' \
      -d "$(jq -nc --arg mime "$MIME_TYPE" --argjson size "$SIZE_BYTES" '{mimeType:$mime,sizeBytes:$size}')")"

    FILE_ID_CREATED="$(echo "$REQUEST_RESP" | jq -r '.fileId')"
    UPLOAD_URL="$(echo "$REQUEST_RESP" | jq -r '.uploadUrl')"
    REQ_CONTENT_TYPE="$(echo "$REQUEST_RESP" | jq -r '.requiredHeaders["content-type"]')"
    REQ_CONTENT_LENGTH="$(echo "$REQUEST_RESP" | jq -r '.requiredHeaders["content-length"]')"

    if [[ -z "$FILE_ID_CREATED" || "$FILE_ID_CREATED" == "null" || -z "$UPLOAD_URL" || "$UPLOAD_URL" == "null" ]]; then
      echo "ERROR: upload request failed" >&2
      echo "$REQUEST_RESP" | jq . >&2
      exit 1
    fi

    put_binary "$UPLOAD_URL" "$REQ_CONTENT_TYPE" "$REQ_CONTENT_LENGTH" "$FILE_PATH"

    curl -sS "$API_BASE/uploads/complete" \
      -H "authorization: Bearer $TOKEN" \
      -H 'content-type: application/json' \
      -d "$(jq -nc --arg fid "$FILE_ID_CREATED" '{fileId:$fid}')" \
      | jq .
    ;;

  list)
    curl -sS "$API_BASE/files" \
      -H "authorization: Bearer $TOKEN" \
      | jq .
    ;;

  delete)
    curl -sS -X DELETE "$API_BASE/files/$FILE_ID" \
      -H "authorization: Bearer $TOKEN" \
      | jq .
    ;;
esac
