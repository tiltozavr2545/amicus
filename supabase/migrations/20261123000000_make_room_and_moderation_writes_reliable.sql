-- Keep the original RPC available to installed clients. Serialize attempts
-- scoped to the caller, and commit the room and its retry record together.
create table public.room_creation_requests (
  user_id uuid not null references public.users(id) on delete cascade,
  client_token uuid not null,
  room_id uuid references public.rooms(id) on delete set null,
  primary key (user_id, client_token)
);
alter table public.room_creation_requests enable row level security;
revoke all on public.room_creation_requests from public, anon, authenticated;

create function public.create_room_once(
  p_member_ids uuid[], p_name text, p_client_token uuid
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user uuid := auth.uid();
  v_room uuid;
begin
  if v_user is null or p_client_token is null then
    raise exception 'A signed-in user and client token are required' using errcode = 'PT422';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'create_room:' || v_user::text || ':' || p_client_token::text, 0
  ));
  select room_id into v_room from public.room_creation_requests
    where user_id = v_user and client_token = p_client_token;
  if found then
    if v_room is null then
      raise exception 'Room no longer exists' using errcode = 'PT404';
    end if;
    return v_room;
  end if;

  v_room := public.create_room(p_member_ids, p_name);
  insert into public.room_creation_requests (user_id, client_token, room_id)
  values (v_user, p_client_token, v_room);
  return v_room;
end;
$function$;

revoke all on function public.create_room_once(uuid[], text, uuid) from public, anon, authenticated;
grant execute on function public.create_room_once(uuid[], text, uuid) to authenticated;

-- A failed outbox insert rolls back the moderation action as well.
create function public.moderate_content(
  p_kind text, p_target_id uuid, p_action text, p_notify_author boolean, p_note text
)
returns void
language plpgsql
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_table text := case p_kind
    when 'post' then 'posts'
    when 'comment' then 'comments'
    when 'room_message' then 'room_messages'
  end;
  v_author uuid;
begin
  if v_table is null or p_action is null or p_action not in ('hide', 'unhide', 'delete') then
    raise exception 'Invalid moderation action' using errcode = 'PT422';
  end if;

  if p_action in ('hide', 'unhide') then
    execute format('update public.%I set hidden_at = $2 where id = $1 returning author_id', v_table)
       into v_author using p_target_id, case when p_action = 'hide' then now() end;
  elsif p_kind = 'post' then
    delete from public.posts where id = p_target_id returning author_id into v_author;
  elsif p_kind = 'comment' then
    update public.comments set deleted_at = now(), text = ''
     where id = p_target_id returning author_id into v_author;
  else
    update public.room_messages set deleted_at = now(), text = '', media = '[]'::jsonb
     where id = p_target_id returning author_id into v_author;
  end if;

  if v_author is null then
    raise exception 'Content not found' using errcode = 'PT404';
  end if;

  if p_notify_author and p_action <> 'unhide' then
    insert into public.notification_outbox (user_id, kind, payload)
    values (v_author, 'moderation_notice',
      case when nullif(btrim(p_note), '') is null then '{}'::jsonb
           else jsonb_build_object('note', btrim(p_note)) end);
  end if;
end;
$function$;

revoke all on function public.moderate_content(text, uuid, text, boolean, text) from public, anon, authenticated;
grant execute on function public.moderate_content(text, uuid, text, boolean, text) to service_role;

-- Return one row per requested post, regardless of its engagement.
create function public.news_engagement(p_post_ids uuid[])
returns table(post_id uuid, comment_count bigint, reaction_count bigint)
language sql
stable
set search_path to 'public', 'pg_temp'
as $function$
  select p.id, coalesce(c.comment_count, 0), coalesce(r.reaction_count, 0)
    from public.posts p
    left join public.comment_summary(p_post_ids) c on c.post_id = p.id
    left join (
      select reactions.post_id, count(*) as reaction_count
        from public.reactions
       where reactions.post_id = any (p_post_ids)
       group by reactions.post_id
    ) r on r.post_id = p.id
   where p.id = any (p_post_ids);
$function$;

-- The news aggregate runs as service_role, including its nested call.
grant execute on function public.comment_summary(uuid[]) to service_role;
revoke all on function public.news_engagement(uuid[]) from public, anon, authenticated;
grant execute on function public.news_engagement(uuid[]) to service_role;
