#!/bin/bash
# Exercises a running PhoneBridge app: notify, icon upload, second notify, dismiss.
# Usage: fake-phone.sh [port]
set -euo pipefail

DIR="$HOME/Library/Application Support/PhoneBridge"
TOKEN=$(cat "$DIR/token")
PORT="${1:-52735}"
BASE="https://localhost:$PORT"
CURL=(curl -sS --cacert "$DIR/cert.pem"
      -H "Authorization: Bearer $TOKEN"
      -H "Content-Type: application/json")

KEY="fake|$$|$(date +%s)"

echo "== notify (no icon yet) =="
"${CURL[@]}" -d "{\"v\":1,\"key\":\"$KEY\",\"pkg\":\"com.fake\",\"appName\":\"FakePhone\",\
\"title\":\"Test notification\",\"text\":\"Hello from fake-phone.sh\",\
\"postedAt\":$(date +%s)000,\"iconHash\":\"sha256:fakeicon\"}" "$BASE/notify"
echo

echo "== icon upload =="
# 1x1 red PNG.
PNG="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="
"${CURL[@]}" -d "{\"iconHash\":\"sha256:fakeicon\",\"png\":\"$PNG\"}" "$BASE/icon"
echo

echo "== notify again (icon now cached, expect needIcon false) =="
"${CURL[@]}" -d "{\"v\":1,\"key\":\"$KEY-2\",\"pkg\":\"com.fake\",\"appName\":\"FakePhone\",\
\"title\":\"With icon\",\"text\":\"This one has a thumbnail\",\
\"postedAt\":$(date +%s)000,\"iconHash\":\"sha256:fakeicon\"}" "$BASE/notify"
echo

echo "== dismiss the second one in 3 seconds =="
sleep 3
"${CURL[@]}" -d "{\"key\":\"$KEY-2\"}" "$BASE/dismiss"
echo
echo "Done. First banner should remain, second should be gone."
