/**
 * Auth0 post-login Action: lets Supabase accept Auth0 access tokens.
 *
 * Supabase third-party auth requires a `role` claim. "authenticated" maps the request to
 * the Postgres role that the RLS policies in supabase/migrations are written for.
 */
exports.onExecutePostLogin = async (event, api) => {
  api.accessToken.setCustomClaim('role', 'authenticated');
};
