-- Some authors opt out of receiving negative reactions: the dislike button is
-- hidden under their posts (client-side), and — enforced here so the UI can't
-- be bypassed by a direct API call — a `dislike` on their posts is rejected at
-- the database level.
--
-- The flag is a *generic* per-user boolean. Nothing in the app code or in this
-- migration names a specific account, so a decompiled build or this public repo
-- reveal only the mechanism, never who is protected. Which accounts get the
-- flag is set by a separate data update that intentionally never lands here.
alter table public.users
  add column dislikes_disabled boolean not null default false;

-- Guard shared by the insert/update paths: true when a dislike is being placed
-- on a post whose author has opted out. `reactions.type` is the row being
-- written; the posts/users subqueries run as the current user, so they see the
-- same rows the reactor already can (the post is in their feed, profiles are
-- world-readable to authenticated users).

-- Reject *inserting* a dislike on a protected author's post. Recreated with the
-- extra guard; the like/neutral paths and the visibility check are unchanged.
drop policy "Users can like posts they can see" on public.reactions;
create policy "Users can like posts they can see"
on public.reactions for insert
to authenticated
with check (
  user_id = auth.uid()
  and exists (select 1 from posts p where p.id = reactions.post_id)
  and not (
    reactions.type = 'dislike'
    and exists (
      select 1
      from posts p
      join users u on u.id = p.author_id
      where p.id = reactions.post_id and u.dislikes_disabled
    )
  )
);

-- Same guard for *switching* an existing reaction to a dislike (the repository's
-- upsert resolves to an UPDATE via ON CONFLICT).
drop policy "Users can change their own reaction" on public.reactions;
create policy "Users can change their own reaction"
on public.reactions for update
to authenticated
using (user_id = auth.uid())
with check (
  user_id = auth.uid()
  and not (
    reactions.type = 'dislike'
    and exists (
      select 1
      from posts p
      join users u on u.id = p.author_id
      where p.id = reactions.post_id and u.dislikes_disabled
    )
  )
);
