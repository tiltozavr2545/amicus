-- Dedupe "are these two users connected" the way is_blocked_pair()/has_muted()
-- already deduped the block/mute checks. Three current call sites hand-write
-- the identical bidirectional exists-check: is_author_visible()
-- (20260726120000), the users SELECT policy (20260818160000/170000), and the
-- favorite branch of enqueue_post_notifications() (20260819100000, added in
-- this same batch — ironic, given this batch's own has_muted() extraction was
-- meant to close exactly this kind of duplication, just for the mute half).
--
-- Two functions, not one, because of the exact mistake is_blocked_pair()
-- already made and had to be walked back from (20260726140000: "told any
-- user whether two *other* people had blocked each other"). A plain
-- are_connected(a, b) with both arguments arbitrary is unsafe to grant to
-- `authenticated` directly — PostgREST would expose "are X and Y connected"
-- for any two people, not just the caller. is_author_visible() and
-- enqueue_post_notifications() are both already `security definer`, so they
-- can call the unrestricted two-argument form directly without exposing it.
-- The users policy is a raw `using` clause with no such wrapper — it needs a
-- version whose only argument is about the caller, same shape as
-- is_author_visible(p_author) itself, so that's the only one granted to
-- PostgREST roles.

create or replace function public.are_connected(p_user_a uuid, p_user_b uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from connections c
    where (c.user_a_id = p_user_a and c.user_b_id = p_user_b)
       or (c.user_b_id = p_user_a and c.user_a_id = p_user_b)
  );
$$;

revoke execute on function public.are_connected(uuid, uuid) from public, anon, authenticated;

create or replace function public.is_connected_to_caller(p_other uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.are_connected(auth.uid(), p_other);
$$;

revoke execute on function public.is_connected_to_caller(uuid) from public, anon;
grant execute on function public.is_connected_to_caller(uuid) to authenticated;

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
        public.are_connected(auth.uid(), p_author)
        and not public.has_muted(auth.uid(), p_author)
        and not public.is_blocked_pair(auth.uid(), p_author)
      );
$$;

drop policy "Profiles are viewable by the user, their connections, the system account, and their own commenters" on public.users;

create policy "Profiles are viewable by the user, their connections, the system account, and their own commenters"
on public.users for select
to authenticated
using (
  id = auth.uid()
  or public.is_system_account(id)
  or public.is_connected_to_caller(id)
  or public.is_commenter_visible_to_post_owner(id)
);

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
    and public.are_connected(f.user_id, new.author_id)
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
