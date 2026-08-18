-- favorite_users and device_tokens (both added 20260818) never restricted
-- their writable columns, so Supabase's default grant still lets
-- `authenticated` set created_at/updated_at directly on insert.
--
-- Not fixed with a `created_at = now()` with-check pin, unlike posts/comments
-- (20260726190000): both tables' only client writes are idempotent upserts
-- with no `onConflict` given, defaulting to the primary key
-- (user_id, favorite_id) / (user_id, fcm_token). Favoriting/registering a
-- device twice hits the ON CONFLICT DO UPDATE branch, which never mentions
-- created_at (the client payload doesn't send it) — a value pin would then
-- compare the *original* row's created_at against `now()` on every repeat
-- upsert and fail it, breaking an operation that works fine today. A column
-- grant, by contrast, only constrains the INSERT branch, which is exactly
-- where the forgeable value would be introduced; the UPDATE branch was never
-- the problem and is left untouched.
--
-- Low-impact gap either way — neither timestamp drives an ordering or trust
-- decision yet — but it's the same forgeable-server-column class the project
-- has fixed twice already for posts/comments, so it doesn't get left open
-- just because these two tables are new.

revoke insert on public.favorite_users from authenticated;
grant insert (user_id, favorite_id) on public.favorite_users to authenticated;

revoke insert on public.device_tokens from authenticated;
grant insert (user_id, fcm_token) on public.device_tokens to authenticated;
