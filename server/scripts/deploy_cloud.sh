#!/usr/bin/env bash
# Moves Resonate's server to the hosted Supabase project, so the app works on cellular with the Mac off.
#
#   Edge Functions  → hosted Supabase (free tier)
#   Database        → hosted Supabase: schema migrations + OSM accessibility points and entrances
#   Walking routes  → Stadia Maps' hosted Valhalla (free tier, same engine as the local container)
#   Addresses       → Stadia Maps' hosted geocoder (OSM data; public Nominatim blocks cloud servers)
#   Voice, scenes   → ElevenLabs and Gemini, keys copied from supabase/functions/.env.local
#
# Usage: fill in server/.env.cloud (see server/.env.cloud.example), then
#   server/scripts/deploy_cloud.sh            # everything
#   server/scripts/deploy_cloud.sh functions  # just secrets + functions (after code changes)
#
# Secrets are read from files and passed straight to Supabase; they're never printed.
set -euo pipefail
cd "$(dirname "$0")/../.."

PROJECT_REF="${PROJECT_REF:-hhxdxyaflxzgibtsjmei}"
STEP="${1:-all}"

set -a
# shellcheck disable=SC1091
source server/.env.cloud
set +a
for name in SUPABASE_ACCESS_TOKEN SUPABASE_DB_URL STADIA_API_KEY; do
  if [[ -z "${!name:-}" ]]; then echo "✗ $name is empty in server/.env.cloud" >&2; exit 1; fi
done
export SUPABASE_ACCESS_TOKEN

if [[ "$STEP" == "all" ]]; then
  echo "→ Database schema (migrations not yet applied)…"
  npx supabase db push --db-url "$SUPABASE_DB_URL" --include-all

  echo "→ OSM accessibility points and entrances…"
  server/scripts/load_access_points.sh "$SUPABASE_DB_URL"
fi

echo "→ Function secrets…"
secrets="$(mktemp)"
trap 'rm -f "$secrets"' EXIT
# Keys from local development, minus the local-only routing address.
grep -E '^(ELEVENLABS_API_KEY|ELEVENLABS_VOICE_ID|GEMINI_API_KEY|GEMINI_MODEL|NOMINATIM_URL|UPSTREAM_USER_AGENT)=' \
  supabase/functions/.env.local > "$secrets"
{
  echo "VALHALLA_URL=https://api.stadiamaps.com"
  echo "VALHALLA_API_KEY=$STADIA_API_KEY"
  echo "STADIA_API_KEY=$STADIA_API_KEY"
} >> "$secrets"
npx supabase secrets set --project-ref "$PROJECT_REF" --env-file "$secrets" > /dev/null
echo "  set: $(cut -d= -f1 "$secrets" | tr '\n' ' ')"

echo "→ Edge Functions…"
npx supabase functions deploy --project-ref "$PROJECT_REF"

echo "✓ Deployed to https://$PROJECT_REF.supabase.co/functions/v1"
