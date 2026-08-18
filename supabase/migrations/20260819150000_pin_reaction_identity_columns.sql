-- 20260819130000 hardened reactions against the existence-oracle class of bug
-- via INSERT (id excluded from the write grant, created_at pinned by value),
-- but its own comment dismissed the UPDATE path — "that path can't reproduce
-- the same oracle" — which turns out to be wrong: the UPDATE policy
-- ("Users can change their own reaction", 20260710140000) pins only user_id,
-- never post_id, and the column grant on UPDATE was never touched at all.
--
-- Reproduced on the live schema (RLS simulation, rolled back): a user can
-- PATCH their own reaction, changing post_id to a post hidden from them by
-- is_author_visible(). If that post id doesn't exist, the FK raises a
-- distinct error; if it exists but is hidden, the UPDATE succeeds (RLS only
-- checked user_id) with an empty RETURNING (the reactions SELECT policy now
-- fails for the row, since it depends on the post being visible). Success
-- vs. FK-violation distinguishes "post exists, just hidden from me" from
-- "post doesn't exist" — the same oracle shape already closed for `id`.
--
-- Not fixed by restricting the UPDATE column grant to `type` only: verified
-- on the live schema that the client's actual upsert (`.upsert({post_id,
-- user_id, type}, onConflict: 'post_id, user_id')`) generates an
-- `ON CONFLICT DO UPDATE SET post_id = excluded.post_id, user_id =
-- excluded.user_id, type = excluded.type` — i.e. every payload column, not
-- just the ones that actually change — so narrowing the grant to `type`
-- would reject the legitimate "switch my reaction" flow outright.
--
-- Fixed instead with a BEFORE UPDATE trigger that pins id/post_id/user_id/
-- created_at back to their current values regardless of what's submitted,
-- the same "column is writable but its value can't actually move" shape a
-- grant-only approach can't express. `type` is the only column a legitimate
-- update ever changes, so this is a no-op for every real request and a
-- silent no-op (not an error) for a forged one — verified on the live schema:
-- a switch-only upsert still lands correctly, and a forged post_id/created_at
-- in the same statement is discarded, with the row keeping its original
-- values in both cases.

create or replace function public.pin_reaction_identity()
returns trigger
language plpgsql
as $$
begin
  new.id := old.id;
  new.post_id := old.post_id;
  new.user_id := old.user_id;
  new.created_at := old.created_at;
  return new;
end;
$$;

create trigger reactions_pin_identity_before_update
before update on public.reactions
for each row execute function public.pin_reaction_identity();
