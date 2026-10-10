#!/usr/bin/env bash
# Starts everything the Resonate app needs on this Mac, for running on your iPhone from Xcode.
# Free: routing (Valhalla) and the Edge Functions run locally; place search uses the public
# OpenStreetMap Nominatim service (fine for personal use, about one search per second at most).
#
#   server/scripts/dev_up.sh      # start (safe to run again)
#   server/scripts/dev_down.sh    # stop
#
# The iPhone reaches this Mac at http://<mac-name>.local:54321, so both must be on the same Wi-Fi
# (or connect the Mac to the iPhone's Personal Hotspot). Keep the Mac awake while you use the app.
set -euo pipefail
cd "$(dirname "$0")/../.."

LOG=/tmp/resonate-functions.log
MAC_NAME="$(scutil --get LocalHostName).local"

if ! docker info >/dev/null 2>&1; then
  echo "→ Starting Docker Desktop…"
  open -a Docker
  until docker info >/dev/null 2>&1; do sleep 2; done
fi

echo "→ Routing server (Valhalla)…"
(cd server && DOMAIN=localhost RESONATE_UPSTREAM_KEY=dev NOMINATIM_DB_PASSWORD=dev docker compose up -d valhalla >/dev/null)
echo "   first run downloads Georgia and builds tiles (~5–20 min)"
until curl -fs http://127.0.0.1:8002/status >/dev/null; do sleep 5; done

echo "→ Local Supabase (database + functions gateway)…"
npx --yes supabase start -x realtime,storage-api,imgproxy,mailpit,postgres-meta,studio,logflare,vector,supavisor >/dev/null

COUNT=$(docker exec supabase_db_resonate psql -U postgres -d postgres -tAc "select count(*) from public.osm_access_points" 2>/dev/null || echo 0)
if [[ "${COUNT:-0}" -eq 0 ]]; then
  echo "→ Loading curb ramps, crossings, and steps from OpenStreetMap (~2 min)…"
  server/scripts/load_access_points.sh >/dev/null
fi

echo "→ Edge Functions (geocode, route)…"
pkill -f "supabase functions serve" 2>/dev/null || true
nohup npx supabase functions serve --env-file supabase/functions/.env.local --no-verify-jwt >"$LOG" 2>&1 &
KEY=$(npx supabase status -o json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['PUBLISHABLE_KEY'])")
until curl -fs -o /dev/null -X OPTIONS "http://127.0.0.1:54321/functions/v1/route" -H "apikey: $KEY"; do sleep 2; done
until [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:54321/functions/v1/route" -H "apikey: $KEY" -H 'Content-Type: application/json' -d '{}')" == "400" ]]; do sleep 2; done

# Make sure the app's config points here.
CONFIG=Resonate/Resources/ResonateConfig.plist
URL="http://$MAC_NAME:54321/functions/v1"
if [[ -f "$CONFIG" ]]; then
  plutil -replace FunctionsURL -string "$URL" "$CONFIG"
  plutil -replace FunctionsKey -string "$KEY" "$CONFIG"
fi

echo
echo "✓ Ready. The app uses $URL"
echo "  (Rebuild in Xcode if this is the first time or the Mac's name changed.)"
echo "  Functions log: $LOG"
