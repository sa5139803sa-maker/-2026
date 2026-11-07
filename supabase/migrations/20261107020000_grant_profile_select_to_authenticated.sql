-- The web login and every protected web route must read the caller's
-- own profile. RLS remains the row-level boundary; this grant does not
-- permit writes or reveal other profiles beyond existing SELECT policies.
GRANT SELECT ON TABLE public.profiles TO authenticated;
