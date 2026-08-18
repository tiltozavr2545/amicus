-- 20260818170000 taught the comments SELECT policy that a post owner can see
-- every comment on their own post via is_comment_visible_to_post_owner(),
-- regardless of Connection — but left the INSERT policy's parent_comment_id/
-- reply_to_id checks untouched, still gated purely on
-- is_author_of_comment_visible() (Connection-only, per 20260726140000).
--
-- Net effect: a post owner can read a stranger's comment on their own post
-- (that migration's whole point — comments were always open to non-Connections,
-- 20260818170000 just made the resulting thread actually visible to the post's
-- author) but tapping Reply silently fails RLS, because the reply's
-- parent_comment_id/reply_to_id points at someone is_author_of_comment_visible()
-- doesn't know about. Fixed by adding the same is_comment_visible_to_post_owner()
-- exception the SELECT policy already grants, so INSERT and SELECT agree on
-- who's visible for exactly the same reason.

drop policy "Users can comment on posts and comments they can see" on public.comments;

create policy "Users can comment on posts and comments they can see"
on public.comments for insert
to authenticated
with check (
  author_id = auth.uid()
  and created_at = now()
  and deleted_at is null
  and exists (select 1 from posts p where p.id = comments.post_id)
  and (
    parent_comment_id is null
    or public.is_author_of_comment_visible(parent_comment_id)
    or public.is_comment_visible_to_post_owner(parent_comment_id)
  )
  and (
    reply_to_id is null
    or public.is_author_of_comment_visible(reply_to_id)
    or public.is_comment_visible_to_post_owner(reply_to_id)
  )
);
