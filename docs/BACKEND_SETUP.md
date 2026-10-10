# Backend setup: Auth0 + Supabase

The app runs on mock services until `Resonate/Resources/ResonateConfig.plist` is filled in.
This guide gets real sign-in and saved places working. It takes about 20 minutes.

How it fits together:

- **Auth0** handles sign-in (Universal Login). The app gets an Auth0 **access token** (a JWT).
- **Supabase** accepts that token as a [third-party auth](https://supabase.com/docs/guides/auth/third-party/auth0) token.
  Postgres sees the Auth0 user ID in `auth.jwt() ->> 'sub'`, and every table's RLS policy checks it.
- Guests (no account) keep saved places and preferences on the phone only.

---

## 1. Auth0

### 1a. Native application

1. Auth0 Dashboard → **Applications → Create Application** → name it `Resonate iOS` → **Native**.
2. On the **Settings** tab, note the **Domain** and **Client ID**.
3. Add these to both **Allowed Callback URLs** and **Allowed Logout URLs** (replace the domain with yours):

   ```text
   com.ishajain.Resonate://YOUR_TENANT.us.auth0.com/ios/com.ishajain.Resonate/callback
   ```

   The app registers the `com.ishajain.Resonate` URL scheme in `Resonate-Info.plist`. If you change the
   bundle ID, update this URL too.
4. **Save**.

### 1b. API (so the access token is a JWT)

Without an API audience, Auth0 issues an opaque access token that Supabase can't verify.

1. **Applications → APIs → Create API**.
2. Name: `Resonate API`. Identifier: `https://api.resonate.app` (any URL-shaped string; it is never called).
   Signing algorithm: **RS256**.
3. On the API's **Settings** tab, turn on **Allow Offline Access** so the app gets a refresh token and
   stays signed in.

### 1c. Action that adds the Supabase role

1. **Actions → Library → Create Action → Build from scratch**. Name `Add Supabase role`, trigger **Login / Post Login**.
2. Paste the code from [`auth0/actions/add-supabase-role.js`](../auth0/actions/add-supabase-role.js) and **Deploy**.
3. **Actions → Triggers → post-login**: drag the action into the flow and **Apply**.

### 1d. Sign-in methods (recommended for blind and low-vision users)

Passwords are the hardest part of logging in with a screen reader. Under **Authentication**, consider:

- **Database → Username-Password-Authentication → Authentication Methods**: turn on **Passkeys**.
- **Social → Apple**: Sign in with Apple. App Store rules require it if you add other social logins.

The app opens Universal Login in a private browser session. That skips the "wants to use auth0.com to
sign in" alert, which is one less dialog for VoiceOver users.

---

## 2. Supabase

### 2a. Project and keys

1. Create a project at [supabase.com](https://supabase.com). Pick the **East US** region (closest to Atlanta).
2. **Project Settings → API**: note the **Project URL** and the **publishable** key (`sb_publishable_…`;
   on older projects use the `anon` key). This key is meant for the app. **Never put the `service_role`
   or secret key in the app.**

### 2b. Connect Auth0

Dashboard: **Authentication → Sign In / Providers → Third-Party Auth → Add provider → Auth0**, then enter
your tenant ID (the part before `.us.auth0.com`) and region.

If you use the Supabase CLI locally, add the same to `supabase/config.toml`:

```toml
[auth.third_party.auth0]
enabled = true
tenant = "YOUR_TENANT"
tenant_region = "us"
```

### 2c. Run the migration

With the [Supabase CLI](https://supabase.com/docs/guides/cli):

```sh
supabase link --project-ref YOUR_PROJECT_REF
supabase db push
```

Or paste [`supabase/migrations/20261009000000_initial_schema.sql`](../supabase/migrations/20261009000000_initial_schema.sql)
into **SQL Editor** and run it.

It creates:

| Table | Holds |
|---|---|
| `users` | One row per Auth0 user (`id` = Auth0 `sub`) |
| `preferences` | Needs, alert channels, routing options |
| `folders` | Saved-place folders (name, color, icon) |
| `saved_routes` | Places in folders, with a PostGIS `location` |
| `service_areas` | The Georgia boundary used to reject out-of-area places |

There is also a `folders_with_counts` view, and an `ensure_user()` function that the app calls after sign-in.
It creates the user row and the six starter folders. RLS is on for every table, and each user can only read
and write their own rows.

### 2d. Check RLS (optional, recommended)

Against a local Supabase (`supabase start`):

```sh
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/rls_check.sql
```

It should print `RLS checks passed`. It creates two users and checks:

- each user sees only their own data;
- one user can't write into another user's folder;
- places outside Georgia are rejected;
- anonymous requests can't read anything.

Everything is rolled back afterwards.

### 2e. Exact Georgia border (optional)

The migration seeds `service_areas` with Georgia's bounding box. That box also takes in slivers of
neighboring states. For the real outline, load the Census TIGER state boundary (STATEFP `13`):

```sh
curl -LO https://www2.census.gov/geo/tiger/TIGER2024/STATE/tl_2024_us_state.zip && unzip tl_2024_us_state.zip
ogr2ogr -f PostgreSQL "$DATABASE_URL" tl_2024_us_state.shp -where "STATEFP='13'" -nln georgia_import -t_srs EPSG:4326 -nlt MULTIPOLYGON
psql "$DATABASE_URL" -c "update public.service_areas set boundary = (select geom::geography from georgia_import) where name = 'georgia'; drop table georgia_import;"
```

---

## 3. App config

```sh
cp config/ResonateConfig.example.plist Resonate/Resources/ResonateConfig.plist
```

Fill in `SupabaseURL`, `SupabaseKey`, `Auth0Domain`, `Auth0ClientID` and `Auth0Audience` (the API
identifier from 1b). The file is gitignored. If any value is missing or still says `YOUR_`, the app logs
a message and falls back to mock services.

## 4. Try it

1. Run the app and tap **Sign in**. Universal Login opens.
2. After signing in, the app calls `ensure_user()`. In Supabase **Table Editor**, `users` now has your
   Auth0 ID and `folders` has the six starter folders.
3. Search for a place and save it. It shows up in `saved_routes`.
4. Settings changes are written to `preferences`.

### Troubleshooting

| Symptom | Likely cause |
|---|---|
| Login sheet closes with "callback URL mismatch" | Callback URL in 1a doesn't exactly match the bundle ID and domain |
| 401 `PGRST301` "No suitable key was found to decode the JWT" | Auth0 not added under Third-Party Auth in the **hosted** project (2b). `config.toml` only affects local |
| Requests fail with 401 after that is fixed | The token has no `role` claim: the Action (1c) isn't deployed or attached to the Login flow |
| Requests succeed but return no rows | The token's `sub` doesn't match `user_id`, or `ensure_user()` never ran |
| Signed out on every launch | **Allow Offline Access** is off on the API (1b), so there's no refresh token |

### Voice choices and snapshot narration

Apply `20261010000001_voice_preferences.sql` and redeploy the `speak` and
`describe` Edge Functions for the onboarding voice picker and snapshot wording.
The voice picker loads the voices available to the configured ElevenLabs API key;
no voice IDs or API keys need to be bundled into the iOS app.
