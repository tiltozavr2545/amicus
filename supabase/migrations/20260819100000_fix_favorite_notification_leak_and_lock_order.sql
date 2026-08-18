-- Two independent fixes to enqueue_post_notifications(), same reasoning as
-- 20260726150000 for bundling both into one migration: both touch the same
-- function body, so replacing it twice in one sitting is pointless churn.
--
-- 1) Favoriting a non-Connection leaked their post activity via push.
--
--    favorite_users.favorite_id was never required to be an actual Connection
--    (20260818180000 says so explicitly), which is fine as long as nothing
--    downstream treats a favorite as proof of visibility. This function did:
--    the favorite branch checked mute/block but never checked that the
--    favoriter (f.user_id) has a live Connection to the author at all — it
--    re-derived "can this person be notified about this author" from scratch
--    instead of asking the one place that answer already lives.
--
--    A blocked user doesn't lose the connections row (block is reversible by
--    design, same note as 20260726130000's "аватарки сужать не надо"), so a
--    user who already knows another's id from before being blocked could
--    insert a favorite_users row naming them and keep receiving "they just
--    posted" pushes — author name and post id — with zero Connection required
--    on either side, running around the entire premise of the app (feed and
--    is_author_visible() both correctly hide the post itself; this queue
--    never asked either of them).
--
--    Fixed by requiring the same connections-table proof of a live
--    relationship that the "everyone else" loop below already uses (it can't
--    reuse is_author_visible()/visible_author_ids() directly — those answer
--    "is X visible to auth.uid()", but auth.uid() here is the poster, not the
--    favoriter).
--
-- 2) Unordered per-viewer locking could deadlock and abort the post itself.
--
--    The digest loop takes a row lock on pending_post_counts per viewer via
--    `on conflict do update ... returning`, iterating `connections` with no
--    order by. Two authors who share two or more mutual connections, posting
--    within the same window, can have their triggers acquire those per-viewer
--    locks in opposite orders -- a textbook lock-order deadlock. This runs
--    AFTER INSERT ON posts in the same transaction as the post itself, so
--    Postgres's deadlock detector killing one side doesn't just drop a
--    notification, it fails the user's "publish" for a reason that has
--    nothing to do with their post.
--
--    Fixed the standard way: acquire the locks in a fixed, global order
--    (sorted by viewer id) so no two concurrent triggers can ever want them
--    in opposite sequences.

create or replace function public.enqueue_post_notifications()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_author_name text;
  v_viewer_id uuid;
  v_new_count int;
begin
  select name into v_author_name from users where id = new.author_id;

  if public.is_system_account(new.author_id) then
    insert into notification_outbox (user_id, kind, payload)
    select u.id, 'new_post',
      jsonb_build_object(
        'author_id', new.author_id,
        'author_name', v_author_name,
        'post_id', new.id
      )
    from users u
    where u.id <> new.author_id;
    return new;
  end if;

  -- Favoriters who are still a live Connection and haven't muted/blocked this
  -- author: notify immediately. The Connection check is what closes fix (1).
  insert into notification_outbox (user_id, kind, payload)
  select f.user_id, 'new_post',
    jsonb_build_object(
      'author_id', new.author_id,
      'author_name', v_author_name,
      'post_id', new.id
    )
  from favorite_users f
  where f.favorite_id = new.author_id
    and exists (
      select 1 from connections c
      where (c.user_a_id = f.user_id and c.user_b_id = new.author_id)
         or (c.user_b_id = f.user_id and c.user_a_id = new.author_id)
    )
    and not exists (
      select 1 from muted_users m
      where m.muter_id = f.user_id and m.muted_id = new.author_id
    )
    and not public.is_blocked_pair(f.user_id, new.author_id);

  -- Everyone else who can see this author (a Connection, unmuted, unblocked)
  -- but hasn't favorited them: bump the digest counter instead. Crossing 6
  -- (i.e. reaching 7) fires the digest and resets to 0.
  --
  -- Explicit loop rather than one chained CTE (insert-on-conflict feeding a
  -- second UPDATE on the same table): a single statement modifying the same
  -- row twice has unspecified/no-op behaviour in Postgres for the second
  -- write. Caught live — the bumped-and-reset version left pending_count at 7
  -- after the digest fired instead of 0, verified with a per-post trace
  -- against the live schema. Splitting the bump and the reset into two
  -- statements per viewer avoids the ambiguity entirely.
  --
  -- `order by viewer_id`: fix (2) above. Every trigger invocation, for any
  -- author, now walks viewers in the same global order, so two concurrent
  -- posts can never lock a shared pair of pending_post_counts rows in
  -- opposite sequences.
  for v_viewer_id in
    select case when c.user_a_id = new.author_id then c.user_b_id else c.user_a_id end as viewer_id
      from connections c
     where c.user_a_id = new.author_id or c.user_b_id = new.author_id
     order by viewer_id
  loop
    continue when exists (
      select 1 from muted_users m
      where m.muter_id = v_viewer_id and m.muted_id = new.author_id
    );
    continue when public.is_blocked_pair(v_viewer_id, new.author_id);
    continue when exists (
      select 1 from favorite_users f
      where f.user_id = v_viewer_id and f.favorite_id = new.author_id
    );

    insert into pending_post_counts (user_id, pending_count, updated_at)
    values (v_viewer_id, 1, now())
    on conflict (user_id) do update
      set pending_count = pending_post_counts.pending_count + 1,
          updated_at = now()
    returning pending_count into v_new_count;

    if v_new_count > 6 then
      insert into notification_outbox (user_id, kind, payload)
      values (v_viewer_id, 'digest', jsonb_build_object('count', v_new_count));

      update pending_post_counts
      set pending_count = 0, updated_at = now()
      where user_id = v_viewer_id;
    end if;
  end loop;

  return new;
end;
$$;
