-- The digest ("N posts piled up") counted posts from a running tally that
-- never checked whether the viewer had actually opened the app in between —
-- pending_post_counts just kept incrementing across logins, so a digest could
-- fire for posts the viewer had already scrolled past in their feed days ago.
-- Switched to "how many posts from your non-favorited Connections have
-- appeared since you last opened the app" — genuinely unseen, not a raw
-- counter.
--
-- "Opened the app" needs a client-side signal — Supabase's own
-- auth.users.last_sign_in_at barely moves once the refresh token keeps a
-- session alive for weeks, so it would read as "since account creation" for
-- almost everyone. touch_user_activity() below is that signal: called once
-- per app open (see MainShellScreen on the client), same shape as the
-- device-token registration that already happens there.

create table public.user_activity (
  user_id uuid primary key references public.users (id) on delete cascade,
  last_active_at timestamptz not null default now()
);

alter table public.user_activity enable row level security;

-- No policy granted to `authenticated` at all — the only write path is
-- touch_user_activity() below, security definer and bound to auth.uid(), so
-- a raw table grant (and the "pin last_active_at to now() somehow" dance
-- that would need) is unnecessary. Same reasoning notification_outbox and
-- pending_post_counts already used for "server-internal, no direct access".
revoke all on public.user_activity from anon, authenticated;

create or replace function public.touch_user_activity()
returns void
language sql
security definer
set search_path = public
as $$
  insert into user_activity (user_id, last_active_at)
  values (auth.uid(), now())
  on conflict (user_id) do update set last_active_at = now();
$$;

revoke execute on function public.touch_user_activity() from public, anon;
grant execute on function public.touch_user_activity() to authenticated;

-- The new digest query filters posts by author and created_at together; the
-- only index posts had before this was the primary key.
create index posts_author_id_created_at_idx on public.posts (author_id, created_at);

drop table public.pending_post_counts;

create or replace function public.enqueue_post_notifications()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_author_name text;
  v_viewer_id uuid;
  v_window_start timestamptz;
  v_unseen_count int;
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
    where u.id <> new.author_id
      and coalesce(
        (select notify_system_account from notification_preferences where user_id = u.id),
        true
      );
    return new;
  end if;

  insert into notification_outbox (user_id, kind, payload)
  select f.user_id, 'new_post',
    jsonb_build_object(
      'author_id', new.author_id,
      'author_name', v_author_name,
      'post_id', new.id
    )
  from favorite_users f
  where f.favorite_id = new.author_id
    and public.are_connected(f.user_id, new.author_id)
    and not public.has_muted(f.user_id, new.author_id)
    and not public.is_blocked_pair(f.user_id, new.author_id)
    and coalesce(
      (select notify_favorites from notification_preferences where user_id = f.user_id),
      true
    );

  for v_viewer_id in
    select case when c.user_a_id = new.author_id then c.user_b_id else c.user_a_id end as viewer_id
      from connections c
     where c.user_a_id = new.author_id or c.user_b_id = new.author_id
     order by viewer_id
  loop
    continue when public.has_muted(v_viewer_id, new.author_id);
    continue when public.is_blocked_pair(v_viewer_id, new.author_id);
    continue when exists (
      select 1 from favorite_users f
      where f.user_id = v_viewer_id and f.favorite_id = new.author_id
    );
    continue when not coalesce(
      (select notify_digest from notification_preferences where user_id = v_viewer_id),
      true
    );

    -- Never having opened the (updated) app yet reads as "just became
    -- active" — nothing counts as unseen until we actually know otherwise.
    -- Rolling this out to existing users this way means nobody gets a burst
    -- digest for their entire post history on the first post after deploy.
    select coalesce(
      (select last_active_at from user_activity where user_id = v_viewer_id),
      now()
    ) into v_window_start;

    -- Already sent a digest since they were last active — the count can only
    -- have grown since, so nothing new to decide until they open the app
    -- again and this window moves forward.
    continue when exists (
      select 1 from notification_outbox n
      where n.user_id = v_viewer_id
        and n.kind = 'digest'
        and n.created_at > v_window_start
    );

    -- Direct joins against the base tables rather than has_muted()/
    -- is_blocked_pair() per row — those are fine called once per viewer
    -- (above), but calling a SECURITY DEFINER function per candidate post
    -- here is exactly the row-filter cost CLAUDE.md's "Грабли" warns about.
    select count(*) into v_unseen_count
    from posts p
    join connections c
      on (c.user_a_id = v_viewer_id and c.user_b_id = p.author_id)
      or (c.user_b_id = v_viewer_id and c.user_a_id = p.author_id)
    where p.created_at > v_window_start
      and not exists (
        select 1 from muted_users m
        where m.muter_id = v_viewer_id and m.muted_id = p.author_id
      )
      and not exists (
        select 1 from blocked_users b
        where (b.blocker_id = v_viewer_id and b.blocked_id = p.author_id)
           or (b.blocker_id = p.author_id and b.blocked_id = v_viewer_id)
      )
      and not exists (
        select 1 from favorite_users f
        where f.user_id = v_viewer_id and f.favorite_id = p.author_id
      );

    if v_unseen_count >= 7 then
      insert into notification_outbox (user_id, kind, payload)
      values (v_viewer_id, 'digest', jsonb_build_object('count', v_unseen_count));
    end if;
  end loop;

  return new;
end;
$$;
