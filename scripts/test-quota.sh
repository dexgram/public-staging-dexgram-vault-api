#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./scripts/test-quota.sh <client_code> [api_base]
#
# Example:
#   ./scripts/test-quota.sh <client_code>

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

CLIENT_CODE="${1:-}"
API_BASE="${2:-https://test-vaultdb.dexgram.app}"

if [[ -z "$CLIENT_CODE" ]]; then
  echo "Usage: $0 <client_code> [api_base]" >&2
  exit 1
fi

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

TOKEN="$(login)"

curl -sS "$API_BASE/usage" \
  -H "authorization: Bearer $TOKEN" \
  | jq .
