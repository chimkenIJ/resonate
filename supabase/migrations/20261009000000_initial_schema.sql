-- Resonate initial schema.
--
-- Users sign in with Auth0, connected to Supabase as a third-party auth provider.
-- Every request carries the Auth0 access token, so `auth.jwt() ->> 'sub'` is the
-- Auth0 user ID (for example "auth0|65f..."). It is text, not a UUID, and there is
-- no row in auth.users, so user_id columns are text and have no foreign key to auth.

create extension if not exists postgis with schema extensions;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- The signed-in user's Auth0 ID, or null for anonymous requests.
create or replace function public.requesting_user_id()
returns text
language sql
stable
set search_path = ''
as $$
  select nullif(auth.jwt() ->> 'sub', '')
$$;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Service area: the US state of Georgia (Geofabrik north-america/us/georgia).
-- Seeded with the state's bounding box. Replace with the real outline from
-- Census TIGER (see docs/BACKEND_SETUP.md) for an exact border check.
-- ---------------------------------------------------------------------------

create table public.service_areas (
  name text primary key,
  boundary extensions.geography(multipolygon, 4326) not null
);

insert into public.service_areas (name, boundary)
values (
  'georgia',
  extensions.st_multi(extensions.st_makeenvelope(-85.6052, 30.3558, -80.7514, 35.0008, 4326))::extensions.geography
);

-- True when the point is inside Georgia. Used by triggers here and by the Edge Functions.
create or replace function public.in_service_area(point extensions.geography)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.service_areas
    where name = 'georgia' and extensions.st_covers(boundary, point)
  )
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.users (
  id text primary key default public.requesting_user_id(),
  display_name text check (char_length(display_name) <= 120),
  email text check (char_length(email) <= 320),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.preferences (
  user_id text primary key default public.requesting_user_id()
    references public.users (id) on delete cascade,
  needs text[] not null default '{gettingAround}'
    check (needs <@ array['gettingAround', 'colors'] and cardinality(needs) > 0),
  alert_channels text[] not null default '{voice,buzzes}'
    check (alert_channels <@ array['voice', 'buzzes', 'tones'] and cardinality(alert_channels) > 0),
  avoid_steps boolean not null default true,
  max_incline numeric(4, 3) not null default 0.08 check (max_incline between 0 and 0.3),
  prefer_tactile_paving boolean not null default true,
  prefer_audio_signals boolean not null default true,
  updated_at timestamptz not null default now()
);

create table public.folders (
  id uuid primary key default gen_random_uuid(),
  user_id text not null default public.requesting_user_id()
    references public.users (id) on delete cascade,
  name text not null check (char_length(trim(name)) between 1 and 60),
  accent text not null check (accent in ('sand', 'sage', 'slate', 'clay', 'mauve', 'rose')),
  icon text not null,
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Lets saved_routes reference (id, user_id) so a place can only go in its owner's folder.
  unique (id, user_id)
);

create table public.saved_routes (
  id uuid primary key default gen_random_uuid(),
  user_id text not null default public.requesting_user_id(),
  folder_id uuid not null,
  place_id text not null,
  name text not null check (char_length(trim(name)) between 1 and 200),
  address text not null default '',
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  location extensions.geography(point, 4326) generated always as (
    extensions.st_setsrid(extensions.st_makepoint(longitude, latitude), 4326)::extensions.geography
  ) stored,
  route_summary text check (char_length(route_summary) <= 120),
  created_at timestamptz not null default now(),
  foreign key (folder_id, user_id) references public.folders (id, user_id) on delete cascade
);

create index folders_user_id_idx on public.folders (user_id, position);
create index saved_routes_folder_idx on public.saved_routes (folder_id, created_at);
create index saved_routes_user_id_idx on public.saved_routes (user_id);
create index saved_routes_location_idx on public.saved_routes using gist (location);

create trigger users_updated_at before update on public.users
  for each row execute function public.set_updated_at();
create trigger preferences_updated_at before update on public.preferences
  for each row execute function public.set_updated_at();
create trigger folders_updated_at before update on public.folders
  for each row execute function public.set_updated_at();

-- Saved places must be inside Georgia.
-- Stored generated columns are computed AFTER before-triggers run, so new.location
-- is still null here. Build the point from latitude/longitude instead.
create or replace function public.check_saved_route_area()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  pt extensions.geography := extensions.st_setsrid(
    extensions.st_makepoint(new.longitude, new.latitude), 4326
  )::extensions.geography;
begin
  if not public.in_service_area(pt) then
    raise exception 'That place is outside Georgia. Resonate only has maps for Georgia right now.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger saved_routes_in_georgia before insert or update on public.saved_routes
  for each row execute function public.check_saved_route_area();

-- Folders with how many places each holds. security_invoker keeps RLS in force.
create view public.folders_with_counts
with (security_invoker = true)
as
select f.id, f.name, f.accent, f.icon, f.position, f.created_at,
       count(r.id)::integer as place_count
from public.folders f
left join public.saved_routes r on r.folder_id = f.id
group by f.id;

-- ---------------------------------------------------------------------------
-- Row Level Security: every table, owner-only access.
-- `(select ...)` makes Postgres evaluate the user ID once per query, not per row.
-- ---------------------------------------------------------------------------

alter table public.users enable row level security;
alter table public.preferences enable row level security;
alter table public.folders enable row level security;
alter table public.saved_routes enable row level security;
alter table public.service_areas enable row level security;

create policy "Users can read their own row" on public.users
  for select to authenticated using (id = (select public.requesting_user_id()));
create policy "Users can create their own row" on public.users
  for insert to authenticated with check (id = (select public.requesting_user_id()));
create policy "Users can update their own row" on public.users
  for update to authenticated
  using (id = (select public.requesting_user_id()))
  with check (id = (select public.requesting_user_id()));
create policy "Users can delete their own row" on public.users
  for delete to authenticated using (id = (select public.requesting_user_id()));

create policy "Users can read their preferences" on public.preferences
  for select to authenticated using (user_id = (select public.requesting_user_id()));
create policy "Users can create their preferences" on public.preferences
  for insert to authenticated with check (user_id = (select public.requesting_user_id()));
create policy "Users can update their preferences" on public.preferences
  for update to authenticated
  using (user_id = (select public.requesting_user_id()))
  with check (user_id = (select public.requesting_user_id()));
create policy "Users can delete their preferences" on public.preferences
  for delete to authenticated using (user_id = (select public.requesting_user_id()));

create policy "Users can read their folders" on public.folders
  for select to authenticated using (user_id = (select public.requesting_user_id()));
create policy "Users can create folders" on public.folders
  for insert to authenticated with check (user_id = (select public.requesting_user_id()));
create policy "Users can update their folders" on public.folders
  for update to authenticated
  using (user_id = (select public.requesting_user_id()))
  with check (user_id = (select public.requesting_user_id()));
create policy "Users can delete their folders" on public.folders
  for delete to authenticated using (user_id = (select public.requesting_user_id()));

create policy "Users can read their saved routes" on public.saved_routes
  for select to authenticated using (user_id = (select public.requesting_user_id()));
create policy "Users can create saved routes" on public.saved_routes
  for insert to authenticated with check (user_id = (select public.requesting_user_id()));
create policy "Users can update their saved routes" on public.saved_routes
  for update to authenticated
  using (user_id = (select public.requesting_user_id()))
  with check (user_id = (select public.requesting_user_id()));
create policy "Users can delete their saved routes" on public.saved_routes
  for delete to authenticated using (user_id = (select public.requesting_user_id()));

create policy "Anyone can read the service area" on public.service_areas
  for select to anon, authenticated using (true);

-- Anonymous requests get nothing beyond the service area.
revoke all on public.users, public.preferences, public.folders, public.saved_routes, public.folders_with_counts from anon;
grant select on public.service_areas to anon, authenticated;
grant select, insert, update, delete on public.users, public.preferences, public.folders, public.saved_routes to authenticated;
grant select on public.folders_with_counts to authenticated;

-- ---------------------------------------------------------------------------
-- RPC: called by the app after sign-in.
-- Creates the user row (from token claims) and the starter folders on first sign-in.
-- security invoker, so RLS still applies.
-- ---------------------------------------------------------------------------

create or replace function public.ensure_user(p_display_name text default null, p_email text default null)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  uid text := public.requesting_user_id();
begin
  if uid is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;

  insert into public.users (id, display_name, email)
  values (uid, p_display_name, p_email)
  on conflict (id) do update
    set display_name = coalesce(excluded.display_name, public.users.display_name),
        email = coalesce(excluded.email, public.users.email);

  if not exists (select 1 from public.folders where user_id = uid) then
    insert into public.folders (user_id, name, accent, icon, position) values
      (uid, 'Classes', 'slate', 'graduationcap', 0),
      (uid, 'Home', 'sand', 'house', 1),
      (uid, 'Food', 'clay', 'cup.and.saucer', 2),
      (uid, 'Gym', 'mauve', 'waveform.path.ecg', 3),
      (uid, 'Friends', 'rose', 'person.2', 4),
      (uid, 'Errands', 'sage', 'cart', 5);
  end if;
end;
$$;

revoke execute on function public.ensure_user(text, text) from anon, public;
grant execute on function public.ensure_user(text, text) to authenticated;
grant execute on function public.in_service_area(extensions.geography) to anon, authenticated;