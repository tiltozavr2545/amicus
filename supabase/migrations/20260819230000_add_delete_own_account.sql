-- Self-service account deletion (closes item 1 of "Ближайший план" in
-- future-development.md — until now an account could only be removed
-- manually by the admin on request).
--
-- Every table in the schema FKs to `public.users` (or to `auth.users`
-- directly, for `connections`/`invite_links`) with `on delete cascade` — see
-- docs/data-model.md — except one: `invite_links.used_by_id` had no `on
-- delete` action at all. That's fine for the *owner* side (cascade already
-- covers it), but the activator of someone else's invite link had no cascade
-- path: deleting that user would hit a bare foreign key violation on an
-- unrelated person's invite row. Fixed to `set null` — the invite is the
-- owner's bookkeeping, not something the activator's deletion should be
-- blocked by.
alter table public.invite_links
  drop constraint invite_links_used_by_id_fkey;
alter table public.invite_links
  add constraint invite_links_used_by_id_fkey
    foreign key (used_by_id) references auth.users (id) on delete set null;

-- delete_own_account(): hard-deletes the caller's own row from `auth.users`.
-- That single delete fans out through every FK above and removes the
-- profile, posts/comments/reactions, connections, mutes/blocks, favorites,
-- device tokens, notification preferences/digest state, and invite links in
-- one transaction — nothing else in the schema needs to be touched here.
-- `security definer` is required: `authenticated` has no grants on the
-- `auth` schema at all (by design), so this only works because the function
-- runs as its owner. Zero arguments, scoped to `auth.uid()` internally, so
-- granting `authenticated` execute can't be used to delete anyone else — same
-- shape as every other self-scoped RPC in this schema.
--
-- What this does *not* reach: Storage objects (avatar, post photos/videos)
-- aren't linked via a DB foreign key, so cascade never touches them. The
-- client removes its own avatar/post media (it already holds delete grants
-- for both prefixes) before calling this — best-effort, since a leftover
-- object becomes unreachable the moment this commits anyway (every storage
-- policy on those prefixes requires `connections`/`users` rows that no
-- longer exist), not a live privacy leak, just wasted bucket space.
create function public.delete_own_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  delete from auth.users where id = auth.uid();
end;
$$;

revoke execute on function public.delete_own_account() from public, anon;
grant execute on function public.delete_own_account() to authenticated;
