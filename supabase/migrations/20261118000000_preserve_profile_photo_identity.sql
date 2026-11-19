-- Keep photo IDs stable across reorders. A deferrable position constraint
-- checks the final permutation at the end of the UPDATE statement.
alter table public.profile_photos
  drop constraint profile_photos_user_position_key,
  add constraint profile_photos_user_position_key
    unique (user_id, position) deferrable initially immediate;

create or replace function public.reorder_profile_photos(p_photo_ids uuid[])
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user uuid := auth.uid();
  v_total integer;
  v_requested integer := cardinality(coalesce(p_photo_ids, array[]::uuid[]));
begin
  if v_user is null then
    raise exception 'Not authenticated';
  end if;

  -- Lock existing rows before validating the set. A concurrent deletion
  -- either completes first or waits for the reorder to commit.
  perform 1 from public.profile_photos
    where user_id = v_user order by id for update;
  get diagnostics v_total = row_count;

  if v_requested <> v_total or v_requested <> (
    select count(distinct p.id)
      from public.profile_photos p where p.user_id = v_user
        and p.id = any(p_photo_ids)
  ) then
    raise exception 'Photo set does not match your gallery' using errcode = 'PT422';
  end if;

  update public.profile_photos p
     set position = ord.idx - 1
    from unnest(p_photo_ids) with ordinality as ord(id, idx)
   where p.user_id = v_user and p.id = ord.id;
end;
$function$;

-- Reorder previously reached the gallery's INSERT ban trigger.
create trigger reject_write_when_banned_on_reorder
  before update of position on public.profile_photos
  for each row execute function public.reject_write_when_banned();
