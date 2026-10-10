-- Accessibility features from OpenStreetMap (Georgia extract), used to describe routes:
-- curb ramps, raised curbs, tactile paving, audio crossing signals, crossings, elevators, steps.
-- Valhalla routes around steps and steep grades itself but does not read kerb or tactile_paving tags,
-- so the route Edge Function looks these up along the returned path.
--
-- Loaded by server/scripts/load_access_points.sh. Public OSM data, readable by everyone.

create table public.osm_access_points (
  id bigint generated always as identity primary key,
  osm_id bigint not null,
  kind text not null check (kind in (
    'curb_ramp', 'raised_curb', 'tactile_paving', 'audio_signal', 'crossing', 'elevator', 'steps'
  )),
  geom extensions.geography(geometry, 4326) not null
);

create index osm_access_points_geom_idx on public.osm_access_points using gist (geom);
create index osm_access_points_kind_idx on public.osm_access_points (kind);

alter table public.osm_access_points enable row level security;

create policy "Anyone can read OSM access points" on public.osm_access_points
  for select to anon, authenticated using (true);

revoke insert, update, delete on public.osm_access_points from anon, authenticated;
grant select on public.osm_access_points to anon, authenticated;

-- Features within p_buffer_m meters of a route.
-- p_route is a GeoJSON LineString with [longitude, latitude] positions.
-- `fraction` is how far along the route (0 = start, 1 = end) the feature sits, so the app can
-- announce it at the right moment. `distance_m` is how far it is from the route line.
create or replace function public.route_access_features(p_route jsonb, p_buffer_m double precision default 8)
returns table (
  kind text, osm_id bigint, latitude double precision, longitude double precision,
  fraction double precision, distance_m double precision
)
language sql
stable
set search_path = ''
as $$
  with route as (
    select extensions.st_setsrid(extensions.st_geomfromgeojson(p_route::text), 4326) as line
  ),
  hits as (
    select p.kind, p.osm_id,
           extensions.st_centroid(p.geom::extensions.geometry) as center,
           extensions.st_distance(p.geom, r.line::extensions.geography) as distance_m
    from public.osm_access_points p, route r
    where extensions.st_dwithin(p.geom, r.line::extensions.geography, p_buffer_m)
  )
  select distinct on (h.kind, h.osm_id)
         h.kind, h.osm_id,
         extensions.st_y(h.center), extensions.st_x(h.center),
         extensions.st_linelocatepoint(r.line, h.center),
         h.distance_m
  from hits h, route r
  order by h.kind, h.osm_id
$$;

-- Steps near the route that the route did not use, shown on the map as "Stairs avoided".
create or replace function public.route_avoided_steps(
  p_route jsonb,
  p_near_m double precision default 60,
  p_on_route_m double precision default 4
)
returns table (osm_id bigint, latitude double precision, longitude double precision)
language sql
stable
set search_path = ''
as $$
  with route as (
    select extensions.st_setsrid(extensions.st_geomfromgeojson(p_route::text), 4326) as line
  )
  select p.osm_id,
         extensions.st_y(extensions.st_centroid(p.geom::extensions.geometry)),
         extensions.st_x(extensions.st_centroid(p.geom::extensions.geometry))
  from public.osm_access_points p, route r
  where p.kind = 'steps'
    and extensions.st_dwithin(p.geom, r.line::extensions.geography, p_near_m)
    and not extensions.st_dwithin(p.geom, r.line::extensions.geography, p_on_route_m)
  order by extensions.st_distance(p.geom, r.line::extensions.geography)
  limit 3
$$;

grant execute on function public.route_access_features(jsonb, double precision) to anon, authenticated;
grant execute on function public.route_avoided_steps(jsonb, double precision, double precision) to anon, authenticated;
