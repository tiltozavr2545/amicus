-- One rule, one place: "whose content can I see".
--
-- The rule — myself, or a Connection I have neither muted nor blocked (in
-- either direction) — was written out three times: inline in the posts SELECT
-- policy, inline again inside reaction_summary(), and a third time as
-- is_comment_author_visible(). When 0.9.0 added mute/block it updated the first
-- copy and (in 0.10.1) wrote the third, but never touched the one inside
-- reaction_summary(), which still said only "author or Connection".
--
-- That copy is SECURITY DEFINER, so it reads `posts` with the owner's
-- privileges and the posts policy never gets a say. A blocked user who still
-- holds the blocker's post ids — they were in their feed before the block —
-- could call /rpc/reaction_summary with them and get back live reaction counts
-- for posts RLS is supposed to hide. Same for a muted author.
--
-- The fix is not to patch the third copy but to delete all three: everything
-- now calls is_author_visible(), so the next change to the rule can't miss a
-- site. is_comment_author_visible() was exactly this function under a
-- comment-specific name and is dropped in favour of it.

create or replace function public.is_author_visible(p_author uuid)
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

revoke execute on function public.is_author_visible(uuid) from public, anon;
grant execute on function public.is_author_visible(uuid) to authenticated;

-- 1) Posts. Same predicate as before, now by reference instead of by copy
-- (is_author_visible already covers the author-is-me case).
drop policy "Posts are viewable by author and their connections" on public.posts;

create policy "Posts are viewable by author and their connections"
on public.posts for select
to authenticated
using (public.is_author_visible(posts.author_id));

-- 2) reaction_summary. This is the copy that was out of date; the body is
-- otherwise unchanged from 20260712100000.
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
    and public.is_author_visible(p.author_id)
  group by p.id;
$$;

revoke execute on function public.reaction_summary(uuid[]) from public, anon;
grant execute on function public.reaction_summary(uuid[]) to authenticated;

-- 3) Comments. Identical predicates to 20260725150000, with the third copy of
-- the rule swapped for the shared function.
drop policy "Comments are viewable by the viewer's unmuted connections" on public.comments;

create policy "Comments are viewable by the viewer's unmuted connections"
on public.comments for select
to authenticated
using (
  exists (select 1 from posts p where p.id = comments.post_id)
  and public.is_author_visible(comments.author_id)
  and (
    comments.parent_comment_id is null
    or public.is_author_visible(public.comment_author(comments.parent_comment_id))
  )
  and (
    comments.reply_to_id is null
    or public.is_author_visible(public.comment_author(comments.reply_to_id))
  )
);

drop policy "Users can comment on posts and comments they can see" on public.comments;

create policy "Users can comment on posts and comments they can see"
on public.comments for insert
to authenticated
with check (
  author_id = auth.uid()
  and exists (select 1 from posts p where p.id = comments.post_id)
  and (
    parent_comment_id is null
    or public.is_author_visible(public.comment_author(parent_comment_id))
  )
  and (
    reply_to_id is null
    or public.is_author_visible(public.comment_author(reply_to_id))
  )
);

-- Nothing references it any more.
drop function public.is_comment_author_visible(uuid);
