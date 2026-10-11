-- Building entrances from OpenStreetMap (entrance=* nodes), so walking routes end at a door
-- instead of the middle of a building. Loaded by server/scripts/load_access_points.sh.

alter table public.osm_access_points drop constraint if exists osm_access_points_kind_check;
alter table public.osm_access_points add constraint osm_access_points_kind_check check (kind in (
  'curb_ramp', 'raised_curb', 'tactile_paving', 'audio_signal', 'crossing', 'elevator', 'steps', 'entrance'
));

-- entrance=main|yes|…, door=automatic|hinged|sliding|revolving|…, automatic_door=yes|button|motion
alter table public.osm_access_points add column if not exists entrance text;
alter table public.osm_access_points add column if not exists door text;

-- The best entrance near a destination: the closest one, with main entrances counted 15 m closer
-- (a far "main" entrance may belong to a neighboring building). Skips entrances
-- people can't use to go in (service, emergency, exit-only, garage).
create or replace function public.nearest_entrance(
  p_latitude double precision,
  p_longitude double precision,
  p_radius_m double precision default 45
)
returns table (
  osm_id bigint, latitude double precision, longitude double precision,
  entrance text, door text, distance_m double precision
)
language sql
stable
set search_path = ''
as $$
  with target as (
    select extensions.st_setsrid(extensions.st_makepoint(p_longitude, p_latitude), 4326)::extensions.geography as g
  )
  select p.osm_id,
         extensions.st_y(p.geom::extensions.geometry),
         extensions.st_x(p.geom::extensions.geometry),
         p.entrance, p.door,
         extensions.st_distance(p.geom, t.g)
  from public.osm_access_points p, target t
  where p.kind = 'entrance'
    and coalesce(p.entrance, 'yes') not in ('service', 'emergency', 'exit', 'garage', 'no')
    and extensions.st_dwithin(p.geom, t.g, p_radius_m)
  order by extensions.st_distance(p.geom, t.g) - case when p.entrance = 'main' then 15 else 0 end
  limit 1
$$;

grant execute on function public.nearest_entrance(double precision, double precision, double precision) to anon, authenticated;
