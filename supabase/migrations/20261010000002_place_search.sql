create extension if not exists pg_trgm with schema extensions;

create table public.osm_places (
  id text primary key,
  name text not null,
  address text not null default '',
  geom extensions.geography(Point, 4326) not null
);
create index osm_places_search_idx on public.osm_places
  using gin ((name || ' ' || address) extensions.gin_trgm_ops);
alter table public.osm_places enable row level security;
create policy "Anyone can read Georgia OSM places" on public.osm_places
  for select to anon, authenticated using (true);
grant select on public.osm_places to anon, authenticated;
revoke insert, update, delete on public.osm_places from anon, authenticated;

create or replace function public.search_osm_places(
  p_query text, p_latitude double precision, p_longitude double precision, p_limit integer default 5
)
returns table (id text, name text, address text, latitude double precision, longitude double precision, distance_m double precision)
language sql stable
set search_path = ''
as $$
  with input as (
    select extensions.st_setsrid(extensions.st_makepoint(p_longitude, p_latitude), 4326)::extensions.geography as origin,
      replace(replace(replace(trim(p_query), '\', '\\'), '%', '\%'), '_', '\_') as needle
  )
  select p.id, p.name, p.address,
    extensions.st_y(p.geom::extensions.geometry), extensions.st_x(p.geom::extensions.geometry),
    round(extensions.st_distance(p.geom, input.origin))
  from public.osm_places p cross join input
  where length(trim(p_query)) between 1 and 200
    and public.in_service_area(input.origin)
    and (p.name || ' ' || p.address) ilike '%' || input.needle || '%'
  order by extensions.st_distance(p.geom, input.origin), p.id
  limit greatest(1, least(coalesce(p_limit, 5), 10));
$$;
grant execute on function public.search_osm_places(text, double precision, double precision, integer) to anon, authenticated;
