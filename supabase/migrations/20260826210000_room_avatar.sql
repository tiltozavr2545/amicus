-- =====================================================================
-- Своя аватарка у групповой комнаты.
--
-- Ложится поверх 20260826200000.
--
-- Только у групповой: парная комната — это второй участник, у неё и имя
-- чужое (`rooms_direct_shape` требует `name is null`), и аватарка должна
-- оставаться его же. Ставит владелец, видят участники.
--
-- Файл лежит в бакете `media` под префиксом `rooms/<room_id>/…` — рядом с
-- `avatars/<user_id>/…` и `posts/<author_id>/…`, по той же схеме «первая
-- папка — что это, вторая — чьё». Отличие в том, что вторая папка здесь не
-- пользователь, а комната, поэтому и права считаются не сравнением с
-- `auth.uid()`, а вопросом «владею ли я этой комнатой».
-- =====================================================================


-- =====================================================================
-- 1. Колонка
-- =====================================================================
-- CHECK держит сразу оба инварианта: у парной комнаты аватарки нет вовсе, а
-- путь всегда лежит под префиксом СВОЕЙ комнаты. Второе — не украшение:
-- без него владелец одной комнаты мог бы записать в свою строку путь к
-- файлу чужой, и клиент участника послушно пошёл бы его скачивать.
alter table public.rooms add column avatar_path text;

alter table public.rooms add constraint rooms_avatar_shape check (
  avatar_path is null
  or ((not is_direct) and avatar_path like ('rooms/' || id::text || '/%'))
);


-- =====================================================================
-- 2. «Владею ли я этой комнатой»
-- =====================================================================
-- Однонаправленная обёртка над `room_owner_id()`, ровно по той же причине,
-- по которой у `are_connected()` есть `is_connected_to_caller()`: сама
-- `room_owner_id()` отвечает на вопрос «кто владелец вот этой комнаты» про
-- ЛЮБУЮ комнату, поэтому она не выдана `authenticated` и остаётся
-- внутренней. Эта — про вызывающего, её выдать безопасно, а без гранта её
-- нельзя было бы позвать из storage-политики.
CREATE OR REPLACE FUNCTION public.owns_room(p_room_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public.room_owner_id(p_room_id) = auth.uid();
$function$;


-- =====================================================================
-- 3. Запись пути
-- =====================================================================
-- UPDATE-гранта на `rooms` нет и не будет: политика на UPDATE не умеет
-- ограничить, КАКИЕ колонки меняются, и вместе с аватаркой открыла бы
-- `is_direct` и пару `direct_a`/`direct_b`, на которых стоит уникальность
-- парной комнаты. Поэтому путь пишет RPC.
--
-- Возвращает путь, который перестал быть нужен, — как это делает
-- `create_post_with_media()`. Клиент сносит объект ПОСЛЕ того, как строка
-- записана (см. `deleteRowsThenObjects`): строка, указывающая на удалённый
-- файл, — это дырка в интерфейсе у всех участников, а файл, на который
-- никто не указывает, — просто байты.
CREATE OR REPLACE FUNCTION public.set_room_avatar(p_room_id uuid, p_avatar_path text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_old text;
  v_new text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not exists (select 1 from rooms r where r.id = p_room_id) then
    raise exception 'Room not found' using errcode = 'PT404';
  end if;

  if not public.owns_room(p_room_id) then
    raise exception 'Only the room owner can do that' using errcode = 'PT403';
  end if;

  if exists (select 1 from rooms r where r.id = p_room_id and r.is_direct) then
    raise exception 'A one-to-one room has no avatar of its own' using errcode = 'PT422';
  end if;

  -- Пустая строка от клиента — это «убрать аватарку», а не путь.
  v_new := nullif(btrim(coalesce(p_avatar_path, '')), '');

  if v_new is not null and v_new not like ('rooms/' || p_room_id::text || '/%') then
    raise exception 'Avatar path outside the room prefix' using errcode = 'PT422';
  end if;

  select r.avatar_path into v_old from rooms r where r.id = p_room_id;

  update rooms set avatar_path = v_new where id = p_room_id;

  -- Ретрай с тем же путём ничего не осиротил — и сносить нечего.
  return case when v_old is distinct from v_new then v_old end;
end;
$function$;


-- =====================================================================
-- 4. Список комнат
-- =====================================================================
-- Третье пересоздание `my_rooms()` за два дня и по той же причине: меняется
-- набор OUT-колонок, а `create or replace` его менять не умеет. Грант — заново.
drop function if exists public.my_rooms();

CREATE OR REPLACE FUNCTION public.my_rooms()
 RETURNS TABLE(id uuid, name text, avatar_path text, is_direct boolean, owner_id uuid, created_at timestamp with time zone, last_post_at timestamp with time zone, last_message_at timestamp with time zone, last_message_text text, last_message_author_id uuid, unread_count integer, members jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select r.id,
         r.name,
         r.avatar_path,
         r.is_direct,
         public.room_owner_id(r.id),
         r.created_at,
         a.last_post_at,
         msg.created_at,
         msg.text,
         msg.author_id,
         unread.n,
         mem.members
    from rooms r
    join room_members me on me.room_id = r.id and me.user_id = auth.uid()
    cross join lateral (
      select max(p.created_at) as last_post_at
        from post_rooms pr
        join posts p on p.id = pr.post_id
       where pr.room_id = r.id
    ) a
    left join lateral (
      select m.created_at, m.text, m.author_id
        from room_messages m
       where m.room_id = r.id and m.deleted_at is null
       order by m.created_at desc, m.id desc
       limit 1
    ) msg on true
    cross join lateral (
      -- Свои сообщения непрочитанными не считаются никогда: отправка их же
      -- и порождает, и счётчик на собственной кнопке был бы шумом.
      select count(*)::int as n
        from room_messages m
       where m.room_id = r.id
         and m.deleted_at is null
         and m.author_id <> auth.uid()
         and m.created_at > me.last_read_at
    ) unread
    cross join lateral (
      select jsonb_agg(
               jsonb_build_object('id', u.id, 'name', u.name, 'avatar_path', u.avatar_path)
               order by m2.seq
             ) as members
        from room_members m2
        join users u on u.id = m2.user_id
       where m2.room_id = r.id
    ) mem
   order by coalesce(greatest(a.last_post_at, msg.created_at), r.created_at) desc, r.id desc;
$function$;


-- =====================================================================
-- 5. Storage
-- =====================================================================
-- Читают участники, пишет и сносит владелец. UPDATE-политики нет ни у
-- одного префикса в этом бакете (20260822210000): замена файла — всегда
-- новый объект под свежим путём плюс delete старого.
create policy "Room avatars are viewable by room members"
  on storage.objects
  for select
  to authenticated
  using (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'rooms'::text)
    AND (((storage.foldername(name))[2])::uuid IN ( SELECT my_room_ids() AS my_room_ids))));

create policy "Room owners can upload a room avatar"
  on storage.objects
  for insert
  to authenticated
  with check (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'rooms'::text)
    AND public.owns_room(((storage.foldername(name))[2])::uuid)));

create policy "Room owners can delete a room avatar"
  on storage.objects
  for delete
  to authenticated
  using (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'rooms'::text)
    AND public.owns_room(((storage.foldername(name))[2])::uuid)));


-- =====================================================================
-- 6. Гранты
-- =====================================================================
revoke execute on function public.owns_room(p_room_id uuid) from public, anon, authenticated;
grant execute on function public.owns_room(p_room_id uuid) to authenticated;

revoke execute on function public.set_room_avatar(p_room_id uuid, p_avatar_path text) from public, anon, authenticated;
grant execute on function public.set_room_avatar(p_room_id uuid, p_avatar_path text) to authenticated;

revoke execute on function public.my_rooms() from public, anon, authenticated;
grant execute on function public.my_rooms() to authenticated;


-- =====================================================================
-- 7. Проверки после наката
-- =====================================================================
do $$
begin
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'my_rooms') <> 1 then
    raise exception 'my_rooms() размножилась перегрузками';
  end if;

  if not has_function_privilege('authenticated', 'public.my_rooms()', 'execute') then
    raise exception 'my_rooms() потеряла грант после пересоздания';
  end if;

  if has_function_privilege('authenticated', 'public.room_owner_id(uuid)', 'execute') then
    raise exception 'room_owner_id() выдана клиенту — она отвечает про любую комнату';
  end if;

  -- Скобки здесь обязательны: `and` связывает крепче `or`, и без них
  -- условие считало бы политики 'Room owners%' на любой таблице.
  if (select count(*) from pg_policy
       where polrelid = 'storage.objects'::regclass
         and (polname like 'Room avatars%' or polname like 'Room owners%')) <> 3 then
    raise exception 'Политики аватарки комнаты завелись не полностью';
  end if;
end;
$$;
