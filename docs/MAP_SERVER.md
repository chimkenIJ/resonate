# Map server: search and routing

Destination search and accessible routing run on Georgia OpenStreetMap data, on a server you host.

```text
iPhone app ──► Supabase Edge Functions (geocode, route) ──► your server (Caddy gateway)
                       │                                         ├─ Nominatim  (place search)
                       └─ Postgres: osm_access_points            └─ Valhalla   (walking routes)
```

- The app only talks to the Edge Functions, which hold the server's key. Guests can search and route
  too: the functions accept the publishable key, and a JWT isn't required.
- **Valhalla** builds walking routes with the `blind` pedestrian profile. That profile names landmarks
  you can confirm with a cane ("Pass the gate", "Pass Atlantic Drive"). Routes avoid steps (with a heavy
  penalty) and grades steeper than the user's limit (elevation data is included).
- **Nominatim** finds places. The function searches near the user first, then all of Georgia, and sorts
  by distance.
- **`osm_access_points`** in Supabase holds curb ramps, raised curbs, tactile paving, audio crossing
  signals, crossings, elevators and steps. The route function checks each route against it for the
  feature chips and spoken notes ("There's a curb ramp").

---

## Running on your iPhone for free (no cloud server)

Your Mac is the map server. The iPhone reaches it over Wi-Fi at `http://<mac-name>.local:54321`.

```sh
server/scripts/dev_up.sh     # starts Docker, Valhalla, local Supabase, and the functions; updates the app config
server/scripts/dev_down.sh   # stops everything (data is kept)
```

Then run the app from Xcode on your phone (USB or wireless). Notes:

- **Same network.** The phone and the Mac must be on the same Wi-Fi. Campus networks (eduroam, GTother)
  often block phone-to-laptop traffic. If search says it can't reach the map server, turn on the iPhone's
  **Personal Hotspot** and connect the Mac to it. Nothing else changes.
- **Local Network permission.** The first time, iOS asks to let Resonate find devices on your local
  network. Tap **Allow**, or later turn it on in Settings → Privacy & Security → Local Network → Resonate.
- **Keep the Mac awake** with the lid open, or run `caffeinate -i` in a terminal.
- **Search** uses the public OpenStreetMap Nominatim service. It's free for light personal use (about
  one search per second), but not for publishing an app.
- **Accounts and saved places** still use your hosted Supabase project (free tier). Only search and
  routing run on the Mac.

## Local development details

```sh
# Valhalla only (Nominatim needs ~20 GB, too much for most laptops)
cd server && DOMAIN=localhost RESONATE_UPSTREAM_KEY=dev NOMINATIM_DB_PASSWORD=dev docker compose up -d valhalla

# Local Supabase with the gateway and functions runtime
npx supabase start -x realtime,storage-api,imgproxy,mailpit,postgres-meta,studio,logflare,vector,supavisor
server/scripts/load_access_points.sh            # ~2 min, loads ~140k features
npx supabase functions serve --env-file supabase/functions/.env.local --no-verify-jwt
```

`supabase/functions/.env.local` (gitignored) points the functions at the local Valhalla. Locally, search
goes to the **public** OSM Nominatim. That is fine for a few test searches, but its usage policy forbids
app traffic.

To make the simulator use the local functions, add these to `Resonate/Resources/ResonateConfig.plist`:

```xml
<key>FunctionsURL</key><string>http://127.0.0.1:54321/functions/v1</string>
<key>FunctionsKey</key><string>(PUBLISHABLE_KEY from `npx supabase status`)</string>
```

Remove both to go back to the hosted functions.

Useful checks:

```sh
curl -s localhost:8002/status                       # Valhalla is up
K=$(npx supabase status -o json | python3 -c "import sys,json;print(json.load(sys.stdin)['PUBLISHABLE_KEY'])")
curl -s http://127.0.0.1:54321/functions/v1/route -H "apikey: $K" -H 'Content-Type: application/json' \
  -d '{"origin":{"latitude":33.7748,"longitude":-84.3964},"destination":{"latitude":33.7774,"longitude":-84.3989}}'
```

Simulated walk for testing turn-by-turn in the simulator:

```sh
xcrun simctl location booted start --speed=1.4 33.7748,-84.3964 33.7752,-84.3961 ...   # route polyline points
```

---

## Production

### 1. A server

Any Linux VM with **8 GB RAM, 4 vCPUs, 60 GB disk** (for example Hetzner CPX31 or a DigitalOcean 8 GB
droplet, about $15–50/month). Install Docker. Point a DNS name at it, for example `maps.yourdomain.com`.

```sh
git clone <this repo> && cd resonate/server
cp .env.example .env     # set DOMAIN, RESONATE_UPSTREAM_KEY (openssl rand -hex 32), NOMINATIM_DB_PASSWORD
docker compose up -d     # first start: Valhalla ~20 min, Nominatim ~1 h to import Georgia
```

Caddy gets an HTTPS certificate on its own. Every request without the `X-Resonate-Key` header gets a
401, so the server isn't open to the internet.

```sh
curl -s https://maps.yourdomain.com/valhalla/status -H "X-Resonate-Key: $RESONATE_UPSTREAM_KEY"
```

For a hackathon demo without a VM, run the full compose on your Mac and expose port 443 with a tunnel
(for example `cloudflared tunnel --url https://localhost`). Note that Nominatim still needs about 20 GB of disk.

### 2. Supabase

```sh
npx supabase login
npx supabase link --project-ref hhxdxyaflxzgibtsjmei
npx supabase db push                     # adds osm_access_points and the route lookup functions
server/scripts/load_access_points.sh "postgresql://postgres.hhxdxyaflxzgibtsjmei:DB_PASSWORD@aws-0-us-east-1.pooler.supabase.com:5432/postgres"
```

(Copy the exact connection string from **Project Settings → Database → Connection string → Session pooler**.)

### 3. Edge Functions

```sh
npx supabase secrets set \
  VALHALLA_URL=https://maps.yourdomain.com/valhalla \
  NOMINATIM_URL=https://maps.yourdomain.com/nominatim \
  RESONATE_UPSTREAM_KEY=<same value as on the server>
npx supabase functions deploy geocode route
```

`verify_jwt = false` for both functions is set in `supabase/config.toml`.

### 4. Keeping data fresh

OSM changes daily. Every week or so:

- **Valhalla:** `docker compose restart valhalla` with `update_existing_config=True` and the PBF deleted,
  or just remove the `valhalla-data` volume and let it rebuild (~20 min).
- **Nominatim:** `UPDATE_MODE: once` applies Geofabrik diffs on restart.
- **Access points:** rerun `server/scripts/load_access_points.sh` against the hosted database.

---

## Limits to know about

- **OSM coverage is uneven.** Atlanta has about 28k curb ramps and 16k tactile paving points tagged, but
  only 58 audio crossing signals. When a crossing has no curb tag, the route shows "Some curbs unverified"
  rather than claiming it's accessible.
- **Some destinations are only reachable by stairs** (for example, a building on a raised plaza).
  Valhalla still avoids steps everywhere it can. The route then says "has steps", and turn-by-turn says
  "Take the stairs".
- **GPS is 5–15 m off among Midtown's tall buildings.** Turn-by-turn widens its thresholds when accuracy
  is poor and waits 8 seconds before deciding you're off route.
