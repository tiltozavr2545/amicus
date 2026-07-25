-- A tombstone is server-owned state, but nothing said so on the way in.
--
-- 20260725120000 closed every path that could *revive* a tombstone (the INSERT
-- policy pins author_id, the trigger rejects replies to a deleted parent) and
-- its closing comment claimed there was therefore no path that creates one
-- outside delete_own_comment(). There was: the INSERT policy never mentioned
-- deleted_at, and Supabase's default grants let `authenticated` write every
-- column, so a comment could simply be born a tombstone.
--
-- Verified on the live schema — a plain insert with `deleted_at => now()` was
-- accepted. Such a row renders to everyone as the italic "deleted comment"
-- placeholder instead of its text, is skipped by the feed's comment counter
-- (feed_repository.dart, `.isFilter('deleted_at', null)`), cannot be replied
-- to, and cannot be cleaned up as a childless tombstone by anyone but its own
-- author. Nothing catastrophic — mostly a way to confuse the people reading the
-- thread — but the state is meant to be reachable only through
-- delete_own_comment(), and now it is.

drop policy "Users can comment on posts and comments they can see" on public.comments;

create policy "Users can comment on posts and comments they can see"
on public.comments for insert
to authenticated
with check (
  author_id = auth.uid()
  and deleted_at is null
  and exists (select 1 from posts p where p.id = comments.post_id)
  and (
    parent_comment_id is null
    or public.is_author_of_comment_visible(parent_comment_id)
  )
  and (
    reply_to_id is null
    or public.is_author_of_comment_visible(reply_to_id)
  )
);
