-- The local console uploads staged objects first and commits the post and
-- its attachment rows in this single transaction.
create function public.save_system_news_post(
  p_author_id uuid,
  p_post_id uuid,
  p_client_token uuid,
  p_text text,
  p_items jsonb
)
returns uuid
language plpgsql
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_id uuid;
  v_text text := nullif(btrim(p_text), '');
  v_prefix text := 'posts/' || p_author_id::text || '/%';
begin
  if not exists (select 1 from public.system_account_ids() as s(id) where s.id = p_author_id) then
    raise exception 'News author must be a system account' using errcode = 'PT422';
  end if;

  if jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'Media list must be an array' using errcode = 'PT422';
  end if;

  if jsonb_array_length(p_items) > 20 then
    raise exception 'post_media_limit_exceeded' using errcode = 'P0001';
  end if;

  if v_text is null and jsonb_array_length(p_items) = 0 then
    raise exception 'A post needs text or media' using errcode = 'PT422';
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_items) as i(item)
     where coalesce(i.item ->> 'storage_path', '') not like v_prefix
        or (nullif(i.item ->> 'poster_path', '') not like v_prefix)
  ) then
    raise exception 'Media path outside the news account prefix' using errcode = 'PT422';
  end if;

  if p_post_id is null then
    if p_client_token is null then
      raise exception 'client_token is required' using errcode = 'PT422';
    end if;

    insert into public.posts (author_id, client_token, text, visibility)
    values (p_author_id, p_client_token, v_text, 'connections')
    on conflict (author_id, client_token) do update set text = excluded.text
    returning id into v_id;
  else
    update public.posts
       set text = v_text
     where id = p_post_id and author_id = p_author_id
    returning id into v_id;
    if not found then
      raise exception 'News post not found' using errcode = 'PT404';
    end if;
  end if;

  delete from public.post_media where post_id = v_id;

  insert into public.post_media (post_id, position, media_type, storage_path, poster_path)
  select v_id, (i.idx - 1)::smallint, i.item ->> 'media_type',
         i.item ->> 'storage_path', nullif(i.item ->> 'poster_path', '')
    from jsonb_array_elements(p_items) with ordinality as i(item, idx);

  return v_id;
end;
$function$;

revoke all on function public.save_system_news_post(uuid, uuid, uuid, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.save_system_news_post(uuid, uuid, uuid, text, jsonb)
  to service_role;
