-- Share the per-gallery lock with direct inserts from older clients so that
-- allocation and the gallery limit use a consistent view of existing rows.
create or replace function public.enforce_profile_photos_limit()
returns trigger
language plpgsql
set search_path to 'public', 'pg_temp'
as $function$
begin
  perform pg_advisory_xact_lock(hashtextextended('profile_photos:' || new.user_id::text, 0));

  if exists (
    select 1 from public.profile_photos
    where user_id = new.user_id and storage_path = new.storage_path
  ) then
    return new;
  end if;

  if (select count(*) from public.profile_photos where user_id = new.user_id) >= 80 then
    raise exception 'profile_photos_limit_exceeded' using errcode = 'P0001';
  end if;
  return new;
end;
$function$;

-- Keep the RPC signature for installed clients. New paths go first in picker
-- order, and the existing avatar trigger picks up the first fresh photo.
create or replace function public.append_profile_photos(p_items jsonb)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user uuid := auth.uid();
  v_new_paths text[];
begin
  if v_user is null then
    raise exception 'Not authenticated';
  end if;

  if jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'Photo list must be an array' using errcode = 'PT422';
  end if;

  if jsonb_array_length(p_items) = 0 then
    return;
  end if;

  if exists (
    select 1
      from jsonb_array_elements(p_items) item
     where coalesce(item.value ->> 'storage_path', '')
           not like 'avatars/' || v_user::text || '/%'
  ) then
    raise exception 'Photo path outside your own prefix' using errcode = 'PT422';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('profile_photos:' || v_user::text, 0));
  -- Match the reorder RPC's lock order and hold the existing rows against deletes.
  perform 1 from public.profile_photos
    where user_id = v_user order by id for update;

  select array_agg(fresh.storage_path order by fresh.first_index) into v_new_paths
  from (
    select item.value ->> 'storage_path' as storage_path, min(item.idx) as first_index
    from jsonb_array_elements(p_items) with ordinality as item(value, idx)
    where not exists (
      select 1 from public.profile_photos p
      where p.user_id = v_user and p.storage_path = item.value ->> 'storage_path'
    )
    group by item.value ->> 'storage_path'
  ) fresh;

  -- A retry after a committed upload leaves any later avatar or reorder intact.
  if v_new_paths is null then
    return;
  end if;

  -- Renumber by rank so even old galleries with gaps or outlying positions fit.
  update public.profile_photos p
     set position = ordered.position
    from (
      select id, cardinality(v_new_paths) + row_number() over (order by position) - 1 as position
      from public.profile_photos where user_id = v_user
    ) ordered
   where p.id = ordered.id and p.position <> ordered.position;

  insert into public.profile_photos (user_id, position, storage_path)
  select v_user, item.idx - 1, item.storage_path
  from unnest(v_new_paths) with ordinality as item(storage_path, idx);
end;
$function$;
