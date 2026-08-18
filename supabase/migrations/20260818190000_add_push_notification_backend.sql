-- Push notifications, server side. Three triggers, one shared outbox:
--
--   1. New post from the system account or a favorite -> notify every
--      recipient who can still see that author (mute/block still applies —
--      favoriting is personal preference, not an override of privacy).
--   2. New post from anyone else (visible, not favorited) -> bump a per-viewer
--      pending counter; crossing 6 enqueues a digest and resets it.
--   3. No post from a user in 7+ days -> daily cron nudge, at most one every
--      7 days per person, skipped for accounts younger than a week.
--
-- Everything here only ever writes to notification_outbox. Nothing in this
-- migration calls FCM — that needs a Firebase project (external account, not
-- something this session can provision) and lands as a follow-up: an Edge
-- Function that drains the outbox and a pg_net trigger or cron job to invoke
-- it. Splitting it this way means the event/threshold logic is fully testable
-- against the live schema today, independent of whether that account exists
-- yet.

create extension if not exists pg_cron with schema extensions;
create extension if not exists pg_net with schema extensions;

-- One row per (user, installation). A user with the app on two devices gets
-- both notified; re-registering the same token (reinstall, token refresh)
-- upserts in place.
create table public.device_tokens (
  user_id uuid not null references public.users (id) on delete cascade,
  fcm_token text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, fcm_token)
);

alter table public.device_tokens enable row level security;

create policy "Users manage their own device tokens"
on public.device_tokens for all
to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

revoke all on public.device_tokens from anon;

-- Purely internal — written by the trigger/cron functions below (which run
-- SECURITY DEFINER), drained by the not-yet-written Edge Function using
-- service_role (which bypasses RLS regardless of policy). No policy is
-- granted to `authenticated` on purpose: nothing about a push queued for one
-- user is any other caller's business, including the recipient's own client.
create table public.notification_outbox (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,
  kind text not null check (kind in ('new_post', 'inactive_week', 'digest')),
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);

alter table public.notification_outbox enable row level security;

revoke all on public.notification_outbox from anon, authenticated;

create index notification_outbox_unsent_idx on public.notification_outbox (created_at)
where sent_at is null;

-- Per-viewer running count of visible posts from authors they have NOT
-- favorited (system-account and favorite posts skip this entirely — they
-- always notify immediately, never batch). Same access story as the outbox:
-- internal only.
create table public.pending_post_counts (
  user_id uuid primary key references public.users (id) on delete cascade,
  pending_count int not null default 0,
  updated_at timestamptz not null default now()
);

alter table public.pending_post_counts enable row level security;

revoke all on public.pending_post_counts from anon, authenticated;

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

  -- Favoriters who haven't muted/blocked this author: notify immediately.
  insert into notification_outbox (user_id, kind, payload)
  select f.user_id, 'new_post',
    jsonb_build_object(
      'author_id', new.author_id,
      'author_name', v_author_name,
      'post_id', new.id
    )
  from favorite_users f
  where f.favorite_id = new.author_id
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
  for v_viewer_id in
    select case when c.user_a_id = new.author_id then c.user_b_id else c.user_a_id end
      from connections c
     where c.user_a_id = new.author_id or c.user_b_id = new.author_id
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

create trigger on_post_created_enqueue_notifications
  after insert on public.posts
  for each row execute function public.enqueue_post_notifications();

-- Daily cron: nudge anyone quiet for 7+ days, skipping accounts younger than
-- that (nothing to nudge them about yet) and anyone already nudged in the
-- last 7 days (so this can run daily without spamming).
create or replace function public.enqueue_inactive_week_notifications()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into notification_outbox (user_id, kind, payload)
  select u.id, 'inactive_week', '{}'::jsonb
  from users u
  where not public.is_system_account(u.id)
    and u.created_at < now() - interval '7 days'
    and not exists (
      select 1 from posts p
      where p.author_id = u.id and p.created_at > now() - interval '7 days'
    )
    and not exists (
      select 1 from notification_outbox n
      where n.user_id = u.id
        and n.kind = 'inactive_week'
        and n.created_at > now() - interval '7 days'
    );
end;
$$;

revoke execute on function public.enqueue_inactive_week_notifications() from public, anon, authenticated;

select cron.schedule(
  'inactive-week-nudge',
  '0 12 * * *',
  $$select public.enqueue_inactive_week_notifications();$$
);
