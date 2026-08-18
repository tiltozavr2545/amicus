-- Per-user notification preferences — the "Вкладка настроек" item of
-- future-development.md, notifications half only (app-version display is
-- still open). Five independent on/off switches, one per producer already
-- writing to notification_outbox:
--   notify_system_account   posts from the Amicus account
--   notify_favorites        posts from favorited Connections
--   notify_comments         post_comment + comment_reply (20260819170000)
--   notify_digest           the "N posts piled up" digest
--   notify_inactive_week    the "you've been quiet" nudge
--
-- One row per user, all default true (opt-out, not opt-in — matches how
-- every one of these already behaves today for everyone). No row at all
-- means "never touched Settings", read as all-true via coalesce() at every
-- call site rather than backfilling a row per existing user.

create table public.notification_preferences (
  user_id uuid primary key references public.users (id) on delete cascade,
  notify_system_account boolean not null default true,
  notify_favorites boolean not null default true,
  notify_comments boolean not null default true,
  notify_digest boolean not null default true,
  notify_inactive_week boolean not null default true
);

alter table public.notification_preferences enable row level security;

create policy "Users manage their own notification preferences"
on public.notification_preferences for all
to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

revoke all on public.notification_preferences from anon;

-- Every column here is something the owning user is meant to set themselves
-- (unlike favorite_users.created_at/device_tokens.created_at, fixed in
-- 20260819140000) — no server-authoritative column to lock down.

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

    insert into pending_post_counts (user_id, pending_count, updated_at)
    values (v_viewer_id, 1, now())
    on conflict (user_id) do update
      set pending_count = pending_post_counts.pending_count + 1,
          updated_at = now()
    returning pending_count into v_new_count;

    if v_new_count > 6 then
      -- The counter resets either way: a disabled digest preference means
      -- "don't send this one", not "stop counting". Re-enabling it later
      -- picks back up from a fresh 7, rather than firing immediately with
      -- whatever had piled up while it was off.
      if coalesce(
        (select notify_digest from notification_preferences where user_id = v_viewer_id),
        true
      ) then
        insert into notification_outbox (user_id, kind, payload)
        values (v_viewer_id, 'digest', jsonb_build_object('count', v_new_count));
      end if;

      update pending_post_counts
      set pending_count = 0, updated_at = now()
      where user_id = v_viewer_id;
    end if;
  end loop;

  return new;
end;
$$;

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
    )
    and coalesce(
      (select notify_inactive_week from notification_preferences where user_id = u.id),
      true
    );
end;
$$;

revoke execute on function public.enqueue_inactive_week_notifications() from public, anon, authenticated;

create or replace function public.enqueue_comment_notifications()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_commenter_name text;
  v_post_owner uuid;
  v_reply_target_author uuid;
begin
  select name into v_commenter_name from users where id = new.author_id;
  select author_id into v_post_owner from posts where id = new.post_id;

  if new.reply_to_id is not null then
    select author_id into v_reply_target_author from comments where id = new.reply_to_id;

    if v_reply_target_author is not null
       and v_reply_target_author <> new.author_id
       and not public.is_system_account(v_reply_target_author)
       and not public.has_muted(v_reply_target_author, new.author_id)
       and not public.is_blocked_pair(v_reply_target_author, new.author_id)
       and coalesce(
         (select notify_comments from notification_preferences where user_id = v_reply_target_author),
         true
       )
    then
      insert into notification_outbox (user_id, kind, payload)
      values (
        v_reply_target_author,
        'comment_reply',
        jsonb_build_object(
          'author_name', v_commenter_name,
          'post_id', new.post_id,
          'comment_id', new.id
        )
      );
    end if;

    if v_reply_target_author = v_post_owner then
      return new;
    end if;
  end if;

  if v_post_owner is not null
     and v_post_owner <> new.author_id
     and not public.is_system_account(v_post_owner)
     and not public.has_muted(v_post_owner, new.author_id)
     and not public.is_blocked_pair(v_post_owner, new.author_id)
     and coalesce(
       (select notify_comments from notification_preferences where user_id = v_post_owner),
       true
     )
  then
    insert into notification_outbox (user_id, kind, payload)
    values (
      v_post_owner,
      'post_comment',
      jsonb_build_object(
        'author_name', v_commenter_name,
        'post_id', new.post_id,
        'comment_id', new.id
      )
    );
  end if;

  return new;
end;
$$;
