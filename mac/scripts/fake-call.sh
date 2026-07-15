#!/bin/bash
# Simulates a ringing phone: shows the actionable call banner, then waits
# for the button click and prints which action came back.
set -euo pipefail

DIR="$HOME/Library/Application Support/PhoneBridge"
TOKEN=$(cat "$DIR/token")
PORT="${1:-52735}"
BASE="https://localhost:$PORT"
CURL=(curl -sS --cacert "$DIR/cert.pem"
      -H "Authorization: Bearer $TOKEN"
      -H "Content-Type: application/json")

KEY="fakecall|$$"

echo "== call banner =="
"${CURL[@]}" -d "{\"v\":1,\"key\":\"$KEY\",\"caller\":\"Fake Caller\",\"postedAt\":$(date +%s)000}" "$BASE/call"
echo
echo "== waiting up to 45s: click Reject or Silence on the banner =="
"${CURL[@]}" --max-time 55 -d "{\"key\":\"$KEY\"}" "$BASE/call/wait"
echo
