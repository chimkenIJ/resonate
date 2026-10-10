#!/usr/bin/env bash
# Stops the local map server, Supabase, and functions started by dev_up.sh. Data is kept.
set -uo pipefail
cd "$(dirname "$0")/../.."
pkill -f "supabase functions serve" 2>/dev/null
npx supabase stop >/dev/null 2>&1
(cd server && DOMAIN=localhost RESONATE_UPSTREAM_KEY=dev NOMINATIM_DB_PASSWORD=dev docker compose stop valhalla >/dev/null 2>&1)
echo "✓ Stopped. Start again with server/scripts/dev_up.sh"
