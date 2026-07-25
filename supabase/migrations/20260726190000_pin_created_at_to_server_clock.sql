-- created_at was client-writable, and both feed order and thread order are
-- built on it.
--
-- Supabase's default grants let `authenticated` write every column, and neither
-- INSERT policy said anything about created_at, so the DEFAULT now() only
-- applied when the client chose to stay quiet. Verified on the live schema: a
-- post inserted with created_at => '2099-01-01' was accepted, and a comment
-- with created_at => '2000-01-01' likewise.
--
-- The post case is the sharp one. The feed is ordered `created_at desc` with
-- keyset paging, so a post dated far in the future sits at the top of the feed
-- of everyone connected to its author, permanently, and cannot be scrolled
-- past. The comment case is milder — threadComments() sorts a branch by
-- createdAt, so a backdated reply pins itself to the top of its thread.
--
-- Fixed as a value constraint rather than by taking the column privilege away:
-- restricting a column requires revoking the table-level INSERT from
-- `authenticated` and re-granting every other column by name, which then has to
-- be maintained by hand on every future column. `created_at = now()` keeps the
-- whole rule in the mechanism this schema already uses everywhere, and holds
-- for legitimate inserts by construction — now() is transaction_timestamp(),
-- the same value the DEFAULT evaluates to inside that same transaction. A
-- client that omits the column (both repositories do) passes; a client that
-- sends today's timestamp explicitly passes too, since that is a no-op; only a
-- forged one is rejected.
--
-- Note this makes the DEFAULT load-bearing: change it to clock_timestamp() and
-- every insert starts failing. Loudly, at least, and in the first test.

drop policy "Users can create their own posts" on public.posts;

create policy "Users can create their own posts"
on public.posts for insert
to authenticated
with check (
  author_id = auth.uid()
  and created_at = now()
);

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
  )
  and (
    reply_to_id is null
    or public.is_author_of_comment_visible(reply_to_id)
  )
);
