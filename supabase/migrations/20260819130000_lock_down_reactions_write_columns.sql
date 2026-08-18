-- reactions never received the id/created_at hardening 20260818130000 and
-- 20260726190000 gave posts/comments.
--
-- id: Supabase's default grant still lets `authenticated` write it directly.
-- reactions' own SELECT policy scopes reads to the caller's own rows, so
-- learning another user's reaction id is harder than it was for posts/
-- comments — but not impossible (a leaked log, a future feature that echoes
-- one back), and once known, the same existence-oracle applies: insert a
-- reaction of your own reusing that id and read "row exists" (23505) off
-- "row absent" (success), regardless of what RLS would otherwise hide. Same
-- fix as posts/comments: take the table-level INSERT grant away and re-grant
-- only the columns a legitimate insert ever needs, id excluded.
--
-- created_at: pinned by value rather than by excluding the column, same
-- reasoning 20260726190000 gave for posts/comments — a value pin is cheaper
-- to maintain than a hand-kept column list, and the client never sends this
-- column anyway (the DEFAULT already satisfies `= now()`). Left out of scope
-- here: reactions.type via UPDATE (switching a reaction) — that path can't
-- reproduce the same oracle (RLS already scopes which row the UPDATE can
-- touch, and a no-op UPDATE and a real one look identical either way), so
-- narrowing it isn't addressing a vulnerability, just risk without a matching
-- payoff.

drop policy "Users can like posts they can see" on public.reactions;

create policy "Users can like posts they can see"
on public.reactions for insert
to authenticated
with check (
  user_id = auth.uid()
  and created_at = now()
  and exists (select 1 from posts p where p.id = reactions.post_id)
);

revoke insert on public.reactions from authenticated;
grant insert (post_id, user_id, created_at, type) on public.reactions to authenticated;
