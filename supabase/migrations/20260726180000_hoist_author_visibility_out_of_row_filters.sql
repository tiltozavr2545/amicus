-- is_author_visible() was being asked the same handful of questions once per
-- row, in the two hottest queries in the app.
--
-- A SECURITY DEFINER function cannot be inlined by the planner — it has to run
-- as its owner, so it stays an opaque per-row call. Written as
-- `using (is_author_visible(author_id))`, a policy therefore invokes it for
-- every row the scan touches, and each invocation runs its own scans of
-- connections, muted_users and blocked_users. Measured on a copy of the live
-- schema (all figures from EXPLAIN ANALYZE inside a rolled-back transaction):
--
--   feed, first page, 2 000 posts     217 ms, 10 216 buffers
--   feed comment counts, 1 000 rows   115 ms,  5 135 buffers
--
-- Note what the feed number means: the filter runs across the *whole* posts
-- table, not the 20 rows of the page, because it has to decide visibility
-- before LIMIT can apply. The cost grows with everything ever posted.
--
-- The rule only ever depends on the caller, never on the row, so it can be
-- answered once per query instead of once per row: visible_author_ids()
-- enumerates the caller's own connections — bounded by how many people they
-- know, not by how much anyone has posted — and an uncorrelated
-- `IN (SELECT ...)` is evaluated once and hashed. Same figures after:
--
--   feed, first page, 2 000 posts       6 ms,    435 buffers   (36x)
--   feed comment counts, 1 000 rows     5 ms,    314 buffers   (23x)
--
-- Crucially this is not a second copy of the rule: the enumeration still asks
-- is_author_visible() about each connection, so 20260726120000's "one source of
-- truth" holds. What changed is only how often it is asked.
--
-- The predicate is equivalent by construction — the set is {me} plus every
-- connection the function approves, and for anyone who is neither, both forms
-- are false. With auth.uid() NULL both are NULL, i.e. denied, as before.

create or replace function public.visible_author_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid()
  union
  select other.id
    from (
      select case when c.user_a_id = auth.uid() then c.user_b_id else c.user_a_id end as id
        from connections c
       where c.user_a_id = auth.uid() or c.user_b_id = auth.uid()
    ) other
   where public.is_author_visible(other.id);
$$;

revoke execute on function public.visible_author_ids() from public, anon;
grant execute on function public.visible_author_ids() to authenticated;

drop policy "Posts are viewable by author and their connections" on public.posts;

create policy "Posts are viewable by author and their connections"
on public.posts for select
to authenticated
using (posts.author_id in (select public.visible_author_ids()));

drop policy "Comments are viewable by the viewer's unmuted connections" on public.comments;

create policy "Comments are viewable by the viewer's unmuted connections"
on public.comments for select
to authenticated
using (
  exists (select 1 from posts p where p.id = comments.post_id)
  and comments.author_id in (select public.visible_author_ids())
  and (
    comments.parent_comment_id is null
    or public.is_author_of_comment_visible(comments.parent_comment_id)
  )
  and (
    comments.reply_to_id is null
    or public.is_author_of_comment_visible(comments.reply_to_id)
  )
);

-- Same shape, same reason: storage.objects is a table that only grows.
drop policy "Post photos are viewable by author and their connections" on storage.objects;

create policy "Post photos are viewable by author and their connections"
on storage.objects for select
to authenticated
using (
  bucket_id = 'media'
  and (storage.foldername(name))[1] = 'posts'
  and ((storage.foldername(name))[2])::uuid in (select public.visible_author_ids())
);

-- The parent/reply_to clauses above stay per-row on purpose. They only fire for
-- replies, they short-circuit on NULL for every root comment, and hoisting them
-- would mean materialising the id of every comment with a visible author —
-- trading a bounded per-row cost for an unbounded per-query one.
--
-- reaction_summary() is left alone too: its `p.id = any(p_post_ids)` narrows to
-- one page through the primary key before the visibility filter is reached.
