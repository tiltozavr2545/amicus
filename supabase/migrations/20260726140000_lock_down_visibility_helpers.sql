-- The definer helpers were reachable as RPCs, and two of them answered
-- questions that were never the caller's to ask.
--
-- Every function in an exposed schema is a PostgREST endpoint, so
-- `grant execute ... to authenticated` means "any logged-in user can call this
-- with any arguments it accepts". That is fine for is_author_visible(), whose
-- answer is always about the caller ("is X visible *to me*") and never tells
-- them anything they couldn't read out of connections/muted_users/blocked_users
-- themselves. It was not fine for the other two:
--
--   is_blocked_pair(a, b)  constrains neither argument to auth.uid(), so
--                          /rpc/is_blocked_pair told any user whether two
--                          *other* people had blocked each other — the exact
--                          fact blocked_users' RLS ("blocker_id = auth.uid()")
--                          exists to hide. Verified on the live schema: a
--                          caller who could read 0 rows of blocked_users still
--                          got `true` for someone else's pair.
--   comment_author(id)     returns the author of any comment, bypassing the
--                          comments SELECT policy.
--
-- Neither needs to be callable directly. is_blocked_pair() has had no caller
-- outside is_author_visible() since 20260726120000, and a SECURITY DEFINER
-- function runs its body as the owner, so the nested call is checked against
-- postgres, not against the caller — the grant can simply go.
--
-- comment_author() is different: it is called straight from the comments
-- policies, and a policy is evaluated with the *querying* role's privileges, so
-- it genuinely needed the grant. The fix is to stop exposing the identity at
-- all: fold the lookup and the visibility test into one function that returns a
-- boolean, and drop comment_author(). "Is the author of comment X visible to
-- me" leaks nothing about who that author is.

create or replace function public.is_author_of_comment_visible(p_comment_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_author_visible(
    (select author_id from comments where id = p_comment_id)
  );
$$;

revoke execute on function public.is_author_of_comment_visible(uuid) from public, anon;
grant execute on function public.is_author_of_comment_visible(uuid) to authenticated;

-- Same predicates as 20260726120000, with the two-step
-- is_author_visible(comment_author(x)) collapsed into one call. A missing
-- comment still yields NULL -> denied, exactly as before.
drop policy "Comments are viewable by the viewer's unmuted connections" on public.comments;

create policy "Comments are viewable by the viewer's unmuted connections"
on public.comments for select
to authenticated
using (
  exists (select 1 from posts p where p.id = comments.post_id)
  and public.is_author_visible(comments.author_id)
  and (
    comments.parent_comment_id is null
    or public.is_author_of_comment_visible(comments.parent_comment_id)
  )
  and (
    comments.reply_to_id is null
    or public.is_author_of_comment_visible(comments.reply_to_id)
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
    or public.is_author_of_comment_visible(parent_comment_id)
  )
  and (
    reply_to_id is null
    or public.is_author_of_comment_visible(reply_to_id)
  )
);

drop function public.comment_author(uuid);

-- Reachable only from inside is_author_visible() now, which runs as its owner.
revoke execute on function public.is_blocked_pair(uuid, uuid) from authenticated;
