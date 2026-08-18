-- Amicus's posts are visible to (and commentable by) everyone, not just
-- Connections — the whole point of 20260818150000. But comments SELECT and
-- users SELECT both still gate on "is this person a Connection of mine", so a
-- stranger's comment under Amicus's post was invisible to Amicus itself:
-- comments.author_id wasn't in visible_author_ids() (no Connection), and even
-- if it were, embedding the commenter's name via `.select('*, author:users
-- (name)')` would return null for the exact reason 20260818160000 fixed for
-- posts — the users policy doesn't know about them either.
--
-- Not an Amicus-only gap once you look straight at it: comments INSERT never
-- required the commenter to be a Connection of the post's author (only that
-- the post exists, and for a reply, that its parent is visible) — a stranger
-- could already comment on anyone's post given the id, and that post's own
-- author had no way to see it. Amicus just made the scenario reachable
-- through the ordinary UI instead of a crafted request.
--
-- Fixed as the general rule it actually is: a post's author can see every
-- comment on their own post, and every commenter's profile, regardless of
-- Connection — but not regardless of their own mute/block, which still
-- applies (blocking someone hides them from your own posts too, not just
-- theirs; see 20260726130000's "аватарки сужать не надо" note for why that
-- one exception stays exactly as narrow as the system account, no wider).

create or replace function public.is_comment_visible_to_post_owner(p_comment_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from comments c
    join posts p on p.id = c.post_id
    where c.id = p_comment_id
      and p.author_id = auth.uid()
      and not exists (
        select 1 from muted_users m
        where m.muter_id = auth.uid() and m.muted_id = c.author_id
      )
      and not public.is_blocked_pair(auth.uid(), c.author_id)
  );
$$;

revoke execute on function public.is_comment_visible_to_post_owner(uuid) from public, anon;
grant execute on function public.is_comment_visible_to_post_owner(uuid) to authenticated;

create or replace function public.is_commenter_visible_to_post_owner(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from comments c
    join posts p on p.id = c.post_id
    where c.author_id = p_user_id
      and p.author_id = auth.uid()
  )
  and not exists (
    select 1 from muted_users m
    where m.muter_id = auth.uid() and m.muted_id = p_user_id
  )
  and not public.is_blocked_pair(auth.uid(), p_user_id);
$$;

revoke execute on function public.is_commenter_visible_to_post_owner(uuid) from public, anon;
grant execute on function public.is_commenter_visible_to_post_owner(uuid) to authenticated;

drop policy "Comments are viewable by the viewer's unmuted connections" on public.comments;

create policy "Comments are viewable by the viewer's unmuted connections"
on public.comments for select
to authenticated
using (
  exists (select 1 from posts p where p.id = comments.post_id)
  and (
    comments.author_id in (select public.visible_author_ids())
    or public.is_comment_visible_to_post_owner(comments.id)
  )
  and (
    comments.parent_comment_id is null
    or public.is_author_of_comment_visible(comments.parent_comment_id)
    or public.is_comment_visible_to_post_owner(comments.parent_comment_id)
  )
  and (
    comments.reply_to_id is null
    or public.is_author_of_comment_visible(comments.reply_to_id)
    or public.is_comment_visible_to_post_owner(comments.reply_to_id)
  )
);

drop policy "Profiles are viewable by the user, their connections, and the system account" on public.users;

create policy "Profiles are viewable by the user, their connections, the system account, and their own commenters"
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
  or public.is_commenter_visible_to_post_owner(users.id)
);
