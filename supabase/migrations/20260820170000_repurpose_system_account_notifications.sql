-- System-account posts now enqueue an 'app_update' notification instead of
-- 'new_post' — same trigger, same notify_system_account preference, new kind
-- and copy (see send-push/index.ts TEXTS.app_update). Everything else in
-- enqueue_post_notifications() (favorites, digest) is unchanged.

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
    select u.id, 'app_update',
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
