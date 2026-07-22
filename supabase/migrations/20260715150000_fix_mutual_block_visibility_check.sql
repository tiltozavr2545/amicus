-- Bugfix: the posts SELECT policy checked for a block in either direction
-- with a plain `exists (select ... from blocked_users where (blocker_id =
-- auth.uid() and blocked_id = author_id) or (blocker_id = author_id and
-- blocked_id = auth.uid()))`. That inline subquery is itself subject to
-- blocked_users' own RLS policy ("blocker_id = auth.uid()"), so the second
-- branch — which needs to see a row where blocker_id = author_id (someone
-- else, not the caller) — was silently filtered out by RLS before the OR
-- even ran. Net effect: the blocked person could still see the blocker's
-- posts (mute was unaffected — its check is always self-referential on
-- muter_id = auth.uid(), which already satisfies muted_users' RLS).
--
-- Fix: move the mutual-block check into a security definer function (same
-- pattern as reaction_summary()) so it reads blocked_users with the
-- function owner's privileges, bypassing that table's RLS for this one
-- narrow boolean check.

create or replace function public.is_blocked_pair(user_a uuid, user_b uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from blocked_users b
    where (b.blocker_id = user_a and b.blocked_id = user_b)
       or (b.blocker_id = user_b and b.blocked_id = user_a)
  );
$$;

revoke execute on function public.is_blocked_pair(uuid, uuid) from public, anon;
grant execute on function public.is_blocked_pair(uuid, uuid) to authenticated;

drop policy "Posts are viewable by author and their connections" on public.posts;

create policy "Posts are viewable by author and their connections"
on public.posts for select
to authenticated
using (
  author_id = auth.uid()
  or (
    exists (
      select 1 from connections c
      where (c.user_a_id = auth.uid() and c.user_b_id = posts.author_id)
         or (c.user_b_id = auth.uid() and c.user_a_id = posts.author_id)
    )
    and not exists (
      select 1 from muted_users m
      where m.muter_id = auth.uid() and m.muted_id = posts.author_id
    )
    and not public.is_blocked_pair(auth.uid(), posts.author_id)
  )
);
