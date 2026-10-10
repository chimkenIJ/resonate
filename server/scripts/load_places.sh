#!/usr/bin/env bash
# Index named places from the existing Georgia OSM extract for search and autocomplete.
# shortcut: this indexes named places; add address geocoding when unnamed street addresses are needed.
set -euo pipefail
DB_URL="${1:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
CONTAINER_DB_URL="${DB_URL/127.0.0.1/host.docker.internal}"
CONTAINER_DB_URL="${CONTAINER_DB_URL/localhost/host.docker.internal}"
gdal() { docker run --rm -v resonate-maps_valhalla-data:/osm:ro ghcr.io/osgeo/gdal:ubuntu-small-3.13.3 "$@"; }
psql_run() { docker run --rm -i postgres:17-alpine psql "$CONTAINER_DB_URL" -v ON_ERROR_STOP=1 -q; }

echo 'create schema if not exists osm_places_import;' | psql_run
for layer in points multipolygons; do
  echo "→ Importing named Georgia ${layer}…"
  gdal ogr2ogr -f PostgreSQL "PG:$CONTAINER_DB_URL" /osm/georgia-latest.osm.pbf "$layer" \
    -nln "osm_places_import.$layer" -overwrite -lco GEOMETRY_NAME=geom -lco SPATIAL_INDEX=NONE \
    -where "name IS NOT NULL AND name <> ''"
done

psql_run <<'SQL'
begin;
truncate public.osm_places;
with places as (
  select 'osm:node:' || osm_id as id, name, other_tags, geom from osm_places_import.points
  union all
  select case when osm_way_id is not null then 'osm:way:' || osm_way_id else 'osm:relation:' || osm_id end,
    name, other_tags, extensions.st_centroid(geom) from osm_places_import.multipolygons
), formatted as (
  select id, name, concat_ws(', ',
    nullif(concat_ws(' ', substring(other_tags from '"addr:housenumber"=>"([^"]+)"'),
      substring(other_tags from '"addr:street"=>"([^"]+)"')), ''),
    substring(other_tags from '"addr:city"=>"([^"]+)"')) as address,
    extensions.st_setsrid(geom, 4326)::extensions.geography as geom
  from places where id is not null and geom is not null
)
insert into public.osm_places (id, name, address, geom)
select id, name, address, geom from formatted where public.in_service_area(geom)
on conflict (id) do nothing;
drop schema osm_places_import cascade;
commit;
analyze public.osm_places;
notify pgrst, 'reload schema';
select count(*) as indexed_georgia_places from public.osm_places;
SQL
