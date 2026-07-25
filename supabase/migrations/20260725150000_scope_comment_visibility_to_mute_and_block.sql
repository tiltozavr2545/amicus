-- Mute and block (0.9.0) only ever affected *posts*: the comments SELECT
-- policy asked "can I see the post, and is the commenter me or a Connection",
-- and never consulted muted_users/blocked_users. So a muted or blocked person's
-- comments kept showing up under a mutual connection's post — the one place
-- where two people who have hidden each other still meet.
--
-- The rule being implemented, one level of nesting in mind:
--   * a root comment is visible when its author is visible to me;
--   * a reply is visible when its author is visible, AND the root of its thread
--     has a visible author, AND the comment it addresses has a visible author.
-- In other words nothing hangs off, or talks to, someone I've muted or blocked.

-- "Visible author" in one place: my own comments always, otherwise a Connection
-- I have neither muted nor blocked (in either direction).
--
-- SECURITY DEFINER for two independent reasons. First, is_blocked_pair()'s
-- lesson from 0.9.0: an inline subquery over blocked_users is itself subject to
-- that table's RLS, which silently drops the "the other person blocked me" side.
-- Second, this function is called from the comments policy *about another
-- comment's author*, so it must not be re-filtered by the very policy it helps
-- evaluate.
create or replace function public.is_comment_author_visible(p_author uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_author = auth.uid()
      or (
        exists (
          select 1 from connections c
          where (c.user_a_id = auth.uid() and c.user_b_id = p_author)
             or (c.user_b_id = auth.uid() and c.user_a_id = p_author)
        )
        and not exists (
          select 1 from muted_users m
          where m.muter_id = auth.uid() and m.muted_id = p_author
        )
        and not public.is_blocked_pair(auth.uid(), p_author)
      );
$$;

revoke execute on function public.is_comment_author_visible(uuid) from public, anon;
grant execute on function public.is_comment_author_visible(uuid) to authenticated;

-- Reading another comment's author from inside comments' own policy would
-- recurse through that policy, so the lookup is a definer function too. Depth
-- is capped at one level, so parent_comment_id always names the thread root and
-- a single hop is enough — no recursive walk.
create or replace function public.comment_author(p_comment_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select author_id from comments where id = p_comment_id;
$$;

revoke execute on function public.comment_author(uuid) from public, anon;
grant execute on function public.comment_author(uuid) to authenticated;

drop policy "Comments are viewable by the viewer's own connections" on public.comments;

create policy "Comments are viewable by the viewer's unmuted connections"
on public.comments for select
to authenticated
using (
  exists (select 1 from posts p where p.id = comments.post_id)
  and public.is_comment_author_visible(comments.author_id)
  and (
    comments.parent_comment_id is null
    or public.is_comment_author_visible(
         public.comment_author(comments.parent_comment_id))
  )
  and (
    comments.reply_to_id is null
    or public.is_comment_author_visible(
         public.comment_author(comments.reply_to_id))
  )
);

-- Writing gets the same treatment: a reply may only attach to, or address, a
-- comment the author can actually see. The UI can't offer otherwise (there is
-- no Reply button on something that isn't on screen), but a direct API call
-- could have parked replies under a blocked person's comment.
drop policy "Users can comment on posts they can see" on public.comments;

create policy "Users can comment on posts and comments they can see"
on public.comments for insert
to authenticated
with check (
  author_id = auth.uid()
  and exists (select 1 from posts p where p.id = comments.post_id)
  and (
    parent_comment_id is null
    or public.is_comment_author_visible(public.comment_author(parent_comment_id))
  )
  and (
    reply_to_id is null
    or public.is_comment_author_visible(public.comment_author(reply_to_id))
  )
);
