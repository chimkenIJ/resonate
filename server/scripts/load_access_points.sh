#!/usr/bin/env bash
# Loads accessibility features from the Georgia OSM extract into public.osm_access_points.
#
# Usage:
#   server/scripts/load_access_points.sh [DATABASE_URL]
#
# DATABASE_URL defaults to the local Supabase database. For the hosted project use the direct
# connection string from Supabase → Project Settings → Database (it needs the database password).
#
# Reads the .osm.pbf that the Valhalla container already downloaded (docker volume
# resonate-maps_valhalla-data), or downloads it if PBF=/path/to/file is not set. Uses the official
# GDAL image, so nothing needs installing. Safe to re-run: it replaces the table's contents.
set -euo pipefail

DB_URL="${1:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
GDAL_IMAGE="ghcr.io/osgeo/gdal:ubuntu-small-3.13.3"
PSQL_IMAGE="postgres:17-alpine"
VOLUME="resonate-maps_valhalla-data"

# Containers reach the host's local database through host.docker.internal.
CONTAINER_DB_URL="${DB_URL/127.0.0.1/host.docker.internal}"
CONTAINER_DB_URL="${CONTAINER_DB_URL/localhost/host.docker.internal}"

if [[ -n "${PBF:-}" ]]; then
  MOUNT=(-v "$(cd "$(dirname "$PBF")" && pwd):/osm:ro"); PBF_IN="/osm/$(basename "$PBF")"
else
  MOUNT=(-v "$VOLUME:/osm:ro"); PBF_IN="/osm/georgia-latest.osm.pbf"
fi

gdal() { docker run --rm "${MOUNT[@]}" "$GDAL_IMAGE" "$@"; }
psql_run() { docker run --rm -i "$PSQL_IMAGE" psql "$CONTAINER_DB_URL" -v ON_ERROR_STOP=1 -q; }

echo "→ Staging OSM points (crossings, kerbs, tactile paving, sound signals, elevators)…"
echo "create schema if not exists osm_import;" | psql_run
gdal ogr2ogr -f PostgreSQL "PG:$CONTAINER_DB_URL" "$PBF_IN" points \
  -nln osm_import.points -overwrite -lco GEOMETRY_NAME=geom -lco SPATIAL_INDEX=NONE \
  -where "highway IN ('crossing','elevator','traffic_signals') OR other_tags LIKE '%\"kerb\"%' OR other_tags LIKE '%tactile_paving%' OR other_tags LIKE '%:sound%' OR other_tags LIKE '%\"crossing\"%'"

echo "→ Staging OSM steps and elevator ways…"
gdal ogr2ogr -f PostgreSQL "PG:$CONTAINER_DB_URL" "$PBF_IN" lines \
  -nln osm_import.lines -overwrite -lco GEOMETRY_NAME=geom -lco SPATIAL_INDEX=NONE \
  -where "highway IN ('steps','elevator')"

echo "→ Classifying into public.osm_access_points…"
psql_run <<'SQL'
begin;
truncate public.osm_access_points;

insert into public.osm_access_points (osm_id, kind, geom)
select p.osm_id::bigint, v.kind, extensions.st_setsrid(p.geom, 4326)::extensions.geography
from osm_import.points p
cross join lateral (values
  (case when p.other_tags ~ '"kerb"=>"(lowered|flush|no)"' then 'curb_ramp' end),
  (case when p.other_tags ~ '"kerb"=>"raised"' then 'raised_curb' end),
  (case when p.other_tags ~ '"tactile_paving"=>"(yes|contrasted|primitive)"' then 'tactile_paving' end),
  (case when p.other_tags ~ '"(traffic_signals:sound|crossing:signals:sound)"=>"(yes|walk|locate)"' then 'audio_signal' end),
  (case when p.highway = 'crossing' or p.other_tags ~ '"crossing"=>' then 'crossing' end),
  (case when p.highway = 'elevator' then 'elevator' end)
) as v(kind)
where v.kind is not null and p.osm_id ~ '^[0-9]+$';

insert into public.osm_access_points (osm_id, kind, geom)
select l.osm_id::bigint,
       case when l.highway = 'steps' then 'steps' else 'elevator' end,
       extensions.st_setsrid(l.geom, 4326)::extensions.geography
from osm_import.lines l
where l.osm_id ~ '^[0-9]+$';

drop schema osm_import cascade;
commit;

analyze public.osm_access_points;
select kind, count(*) from public.osm_access_points group by kind order by kind;
SQL
echo "✓ Done."
