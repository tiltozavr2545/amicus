-- comment_summary(): server-side comment counts for the feed page.
--
-- The client used to fetch one {post_id} row per *visible* comment across a
-- whole feed page (up to hundreds of rows, ~40 KB) purely to `.length` them
-- client-side. Unlike reaction_summary() this is `security invoker`, not
-- `definer`: the comments SELECT policy already grants exactly the rows this
-- count needs (author visibility via visible_author_ids(), mute/block,
-- reply-visibility, tombstones), so RLS applies to the function's own scan
-- with no need to re-implement the visibility rule a second time here. Wire
-- size drops from one row per comment to one row per post; server time is
-- unchanged (same policy, same index), the win is purely on the wire — see
-- "Безопасность и приватность" in docs/future-development.md.
create or replace function public.comment_summary(p_post_ids uuid[])
returns table (
  post_id uuid,
  comment_count bigint
)
language sql
stable
security invoker
set search_path = public
as $$
  select comments.post_id, count(*)
  from comments
  where comments.post_id = any (p_post_ids)
    and comments.deleted_at is null
  group by comments.post_id;
$$;

revoke execute on function public.comment_summary(uuid[]) from public, anon;
grant execute on function public.comment_summary(uuid[]) to authenticated;
