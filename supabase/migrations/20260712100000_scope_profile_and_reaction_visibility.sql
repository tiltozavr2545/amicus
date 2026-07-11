-- Two visibility tightenings with one goal: a user shouldn't be able to harvest
-- data about people they haven't actually met.
--
-- Background that makes this safe: an earlier migration already restricted
-- *comments* to the viewer's own connections, so every profile the app ever
-- displays (post authors, comment authors, the connections list) belongs to the
-- viewer or one of their connections. Nothing legitimate needs the whole users
-- table, and reaction *counts* never needed per-reactor identity.

-- 1) Profiles: replace the blanket "any authenticated user sees every profile"
-- policy with "own profile or a connection's". This closes bulk enumeration of
-- the users table, and as a side effect the dislikes_disabled flag becomes
-- readable only to the author's own connections.
drop policy "Profiles are viewable by authenticated users" on public.users;
create policy "Profiles are viewable by the user and their connections"
on public.users for select
to authenticated
using (
  id = auth.uid()
  or exists (
    select 1 from connections c
    where (c.user_a_id = auth.uid() and c.user_b_id = users.id)
       or (c.user_b_id = auth.uid() and c.user_a_id = users.id)
  )
);

-- 2) Reactions: the true per-post totals stay public to anyone who can see the
-- post, but *who* reacted must not leak. Restrict direct reads to the caller's
-- own rows (so the who-disliked-what list can't be pulled via the REST API),
-- and expose the aggregate totals through a function that returns only numbers.
drop policy "Reactions are viewable by anyone who can see the post" on public.reactions;
create policy "Users can view their own reactions"
on public.reactions for select
to authenticated
using (user_id = auth.uid());

-- Per-post reaction counts plus the caller's own reaction. SECURITY DEFINER so
-- it can count rows the caller can no longer read directly; because that
-- bypasses RLS, it re-checks post visibility itself (author or a connection of
-- the author) and never returns any other user's id.
create or replace function public.reaction_summary(p_post_ids uuid[])
returns table (
  post_id uuid,
  like_count bigint,
  neutral_count bigint,
  dislike_count bigint,
  my_reaction text
)
language sql
security definer
set search_path = public
as $$
  select
    p.id,
    count(*) filter (where r.type = 'like'),
    count(*) filter (where r.type = 'neutral'),
    count(*) filter (where r.type = 'dislike'),
    max(r.type) filter (where r.user_id = auth.uid())
  from posts p
  left join reactions r on r.post_id = p.id
  where p.id = any (p_post_ids)
    and (
      p.author_id = auth.uid()
      or exists (
        select 1 from connections c
        where (c.user_a_id = auth.uid() and c.user_b_id = p.author_id)
           or (c.user_b_id = auth.uid() and c.user_a_id = p.author_id)
      )
    )
  group by p.id;
$$;

-- Default EXECUTE grant is to PUBLIC; scope it to authenticated only (anon has
-- no auth.uid() and would get nothing anyway, but the grant should say so).
revoke execute on function public.reaction_summary(uuid[]) from public, anon;
grant execute on function public.reaction_summary(uuid[]) to authenticated;
