-- Local place-search checks; fixtures are rolled back.
begin;
insert into public.osm_places (id, name, address, geom) values
  ('test:search-near', 'Resonate Search Fixture Kroger', 'Literal % address',
    extensions.st_setsrid(extensions.st_makepoint(-84.3964, 33.7748), 4326)::extensions.geography),
  ('test:search-far', 'Resonate Search Fixture Kroger', 'Farther address',
    extensions.st_setsrid(extensions.st_makepoint(-84.36, 33.79), 4326)::extensions.geography);
set local role anon;
do $$
declare first_id text; matches integer;
begin
  select id into first_id from public.search_osm_places('resonate search fixture kro', 33.7748, -84.3964, 1);
  if first_id is distinct from 'test:search-near' then raise exception 'Partial names must match, nearest first'; end if;
  select count(*) into matches from public.search_osm_places('Resonate Search Fixture', 40.7, -74.0, 5);
  if matches <> 0 then raise exception 'Out-of-Georgia origins must be rejected'; end if;
  select id into first_id from public.search_osm_places('Literal % address', 33.7748, -84.3964, 1);
  if first_id is distinct from 'test:search-near' then raise exception 'Search must treat wildcard characters literally'; end if;
  select count(*) into matches from public.search_osm_places('', 33.7748, -84.3964, 5);
  if matches <> 0 then raise exception 'Empty queries must not match every place'; end if;
  begin
    delete from public.osm_places where id = 'test:search-near';
    raise exception 'Anonymous users must not modify OSM data';
  exception when insufficient_privilege then null;
  end;
end $$;
rollback;
