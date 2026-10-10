-- Checks that Row Level Security isolates users. Run against a local database after the migration:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rls_check.sql
-- Everything runs in a transaction that is rolled back, so it leaves no data behind.

begin;

-- Act as Auth0 user A.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"auth0|user-a","role":"authenticated"}', true);
select public.ensure_user('User A', 'a@example.com');
insert into public.saved_routes (folder_id, place_id, name, latitude, longitude)
select id, 'test:skiles', 'Skiles', 33.7737, -84.3962 from public.folders where name = 'Classes';

do $$
begin
  if (select count(*) from public.folders) <> 6 then
    raise exception 'User A should have 6 starter folders';
  end if;
  if (select place_count from public.folders_with_counts where name = 'Classes') <> 1 then
    raise exception 'folders_with_counts should count User A''s saved place';
  end if;
end $$;

-- Outside Georgia (Chattanooga, TN) must be rejected.
do $$
begin
  insert into public.saved_routes (folder_id, place_id, name, latitude, longitude)
  select id, 'test:chattanooga', 'Chattanooga', 35.0456, -85.3097 from public.folders where name = 'Home';
  raise exception 'Insert outside Georgia should have failed';
exception when check_violation then
  null; -- expected
end $$;

-- Act as user B: must see none of A's data and must not write into A's folders.
select set_config('request.jwt.claims', '{"sub":"auth0|user-b","role":"authenticated"}', true);
select public.ensure_user('User B', null);

do $$
declare
  a_folder uuid;
begin
  if exists (select 1 from public.saved_routes where name = 'Skiles') then
    raise exception 'User B can see User A''s saved route';
  end if;
  if (select count(*) from public.folders) <> 6 then
    raise exception 'User B should only see their own 6 folders';
  end if;

  reset role;
  select id into a_folder from public.folders where user_id = 'auth0|user-a' and name = 'Classes';
  set local role authenticated;

  begin
    insert into public.saved_routes (folder_id, place_id, name, latitude, longitude)
    values (a_folder, 'test:x', 'Sneaky', 33.77, -84.39);
    raise exception 'User B wrote into User A''s folder';
  exception when foreign_key_violation or insufficient_privilege then
    null; -- expected
  end;
end $$;

-- Anonymous requests see no user data.
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
do $$
begin
  perform 1 from public.folders;
  raise exception 'anon should not be able to read folders';
exception when insufficient_privilege then
  null; -- expected
end $$;

select 'RLS checks passed' as result;
rollback;
