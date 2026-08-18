-- 20260818150000 taught posts/comments/storage visibility about the system
-- account, but missed a fourth place the rule lives: the users SELECT policy
-- itself. That policy was never folded into is_author_visible() in the first
-- place (20260726120000 unified posts/reaction_summary/comments, not users) —
-- deliberately, per that migration's own note: mute/block must NOT narrow
-- profile visibility, or the "Заблокированные" screen and the mute list in
-- "Знакомства" couldn't show the very names/avatars they list. So `users` has
-- always been its own hand-written predicate: self or Connection, full stop.
--
-- The system account has no Connection with anyone, so nobody but itself could
-- read its own users row. posts already showed its author_id to everyone
-- (via 20260818150000), but the embedded `author:users(name, dislikes_disabled)`
-- PostgREST does on every feed query came back null for exactly that row —
-- caught live on a physical device: `Post.fromRow` does `row['author'] as
-- Map<String, dynamic>`, and a null failed that cast for every viewer, unable
-- to load the feed at all the moment the account's first post existed.
--
-- Confirms 20260818150000's own worry in a very concrete way: hardcoding one
-- exception into is_author_visible() does not automatically cover every place
-- "who can see this profile" is asked — this schema apparently asks it twice,
-- with different answers on purpose. Recorded here rather than folding users
-- into visible_author_ids(), since that would be the wrong fix, not just an
-- incomplete one.
-- is_author_visible()/visible_author_ids() are SECURITY DEFINER, so their
-- internal call to is_system_account() runs as the function owner and needed
-- no grant. An RLS `using` clause has no such wrapper — it runs as the
-- querying role itself, so `authenticated` needs direct EXECUTE here. Argument
-- is a bare uuid, not tied to auth.uid(), which is normally a reason to keep a
-- function un-granted (CLAUDE.md: "каждый аргумент про самого вызывающего") —
-- but this one discloses nothing a caller doesn't already have: the system
-- account's id is the `author_id` on every post it makes, already visible to
-- everyone before this grant existed.
grant execute on function public.is_system_account(uuid) to authenticated;

drop policy "Profiles are viewable by the user and their connections" on public.users;

create policy "Profiles are viewable by the user, their connections, and the system account"
on public.users for select
to authenticated
using (
  id = auth.uid()
  or public.is_system_account(id)
  or exists (
    select 1 from connections c
    where (c.user_a_id = auth.uid() and c.user_b_id = users.id)
       or (c.user_b_id = auth.uid() and c.user_a_id = users.id)
  )
);
