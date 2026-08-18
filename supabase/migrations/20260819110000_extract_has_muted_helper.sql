-- Dedupe the mute check the way is_blocked_pair() already deduped the block
-- check (20260715150000). Five call sites now hand-write the identical
-- predicate:
--   is_author_visible()                 (20260818150000)
--   is_comment_visible_to_post_owner()  (20260818170000)
--   is_commenter_visible_to_post_owner()(20260818170000)
--   enqueue_post_notifications(), twice (20260819100000)
-- CLAUDE.md is explicit that this project has exactly one rule for content
-- visibility and it gets changed in exactly one place, precisely because a
-- duplicated version of this same rule already rotted into a real hole once
-- (0.11.0, see CHANGELOG.md). The mute half of the check was never given the
-- same treatment as the block half — this closes that gap before, not after,
-- it drifts.
--
-- Named has_muted(), not is_muted_pair(): unlike blocking, muting isn't
-- symmetric — A muting B says nothing about whether B muted A — so a name
-- implying a bidirectional pair would be misleading. Same access story as
-- is_blocked_pair(): every existing caller is itself a security definer
-- function, so this is never granted to PostgREST roles directly.

create or replace function public.has_muted(p_muter uuid, p_muted uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from muted_users m
    where m.muter_id = p_muter and m.muted_id = p_muted
  );
$$;

revoke execute on function public.has_muted(uuid, uuid) from public, anon, authenticated;

create or replace function public.is_author_visible(p_author uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_author = auth.uid()
      or public.is_system_account(p_author)
      or (
        exists (
          select 1 from connections c
          where (c.user_a_id = auth.uid() and c.user_b_id = p_author)
             or (c.user_b_id = auth.uid() and c.user_a_id = p_author)
        )
        and not public.has_muted(auth.uid(), p_author)
        and not public.is_blocked_pair(auth.uid(), p_author)
      );
$$;

create or replace function public.is_comment_visible_to_post_owner(p_comment_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from comments c
    join posts p on p.id = c.post_id
    where c.id = p_comment_id
      and p.author_id = auth.uid()
      and not public.has_muted(auth.uid(), c.author_id)
      and not public.is_blocked_pair(auth.uid(), c.author_id)
  );
$$;

create or replace function public.is_commenter_visible_to_post_owner(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from comments c
    join posts p on p.id = c.post_id
    where c.author_id = p_user_id
      and p.author_id = auth.uid()
  )
  and not public.has_muted(auth.uid(), p_user_id)
  and not public.is_blocked_pair(auth.uid(), p_user_id);
$$;

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
    and not public.has_muted(f.user_id, new.author_id)
    and not public.is_blocked_pair(f.user_id, new.author_id);

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
