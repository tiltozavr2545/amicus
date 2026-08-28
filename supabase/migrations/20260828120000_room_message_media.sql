-- =====================================================================
-- Медиа в сообщениях комнаты: до 10 фото/видео на сообщение.
--
-- Отдельной таблицы под элементы НЕТ, и это единственное место в проекте,
-- где медиа живёт колонкой, а не строками. Причин три, и все три — про
-- разницу между постом и сообщением:
--
--   1. **Realtime отдаёт СТРОКУ.** Подписчик получает `room_messages` и
--      больше ничего: строки второй таблицы приехали бы отдельным запросом,
--      которого у подписки нет, и пузырь с фотографией появлялся бы у
--      остальных пустым, пока экран не переоткроют. Внутри одной строки
--      вложения приезжают вместе с сообщением — как и положено сообщению.
--   2. **CHECK наконец выражается.** «Пусто нельзя: либо текст, либо
--      вложения» — условие ОДНОЙ строки, если медиа лежит в ней же. У поста
--      это же правило пришлось проверять процедурно внутри
--      `create_post_with_media()` (20260823120000) именно потому, что строки
--      `post_media` приезжают отдельно и CHECK их не видит.
--   3. **Обратного пути от файла к строке не нужно.** У поста storage-политика
--      идёт от пути к строке `post_media` и дальше к самому посту
--      (`post_media_path_visible()`), потому что видимость поста —
--      вычисляемая. У сообщения видимость — это членство в комнате, а комната
--      написана в самом пути: `messages/<room_id>/<author_id>/…`. Индексы по
--      `storage_path`, ради которых у поста заведена таблица, здесь не нужны
--      вовсе.
--
-- Отправка остаётся обычным `insert`: вставлять нечего, кроме одной строки, а
-- идемпотентность по-прежнему держат частичный уникальный индекс
-- `(author_id, client_token)` и обработка 23505 на клиенте (см. «`upsert` из
-- PostgREST требует НЕчастичного индекса» в CLAUDE.md).
-- =====================================================================


-- =====================================================================
-- 1. Форма вложений
-- =====================================================================
-- Проверять форму приходится функцией: в CHECK нельзя ни подзапрос, ни
-- set-returning вызов вроде `jsonb_array_elements`, а внутри `language sql`
-- immutable-функции — можно. Immutable она честно: смотрит только на свои
-- аргументы и к таблицам не ходит.
--
-- Путь проверяется ЗДЕСЬ, а не в INSERT-политике, и это осознанно: политика
-- ограничивает вызывающего, CHECK — саму строку, то есть правило переживёт
-- и будущую `security definer`-функцию, которая начнёт писать сообщения в
-- обход политики. Форма пути та же, что у storage-политик ниже: у каждой
-- стороны своя копия вопроса «чей это файл», и сходятся они на префиксе.
CREATE OR REPLACE FUNCTION public.room_message_media_ok(p_room_id uuid, p_author_id uuid, p_media jsonb)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select jsonb_typeof(p_media) = 'array'
     and jsonb_array_length(p_media) <= 10
     and not exists (
       select 1
         from jsonb_array_elements(p_media) item
        where (item.value ->> 'media_type') is distinct from 'image'
              and (item.value ->> 'media_type') is distinct from 'video'
           or coalesce(item.value ->> 'storage_path', '') not like
              ('messages/' || p_room_id::text || '/' || p_author_id::text || '/%')
           or (
             nullif(item.value ->> 'poster_path', '') is not null
             and (item.value ->> 'poster_path') not like
                 ('messages/' || p_room_id::text || '/' || p_author_id::text || '/%')
           )
     );
$function$;

alter table public.room_messages
  add column media jsonb default '[]'::jsonb not null;

alter table public.room_messages
  add constraint room_messages_media_shape
  check (public.room_message_media_ok(room_id, author_id, media));

-- Пустым сообщение по-прежнему быть не может, но «непусто» стало шире:
-- фотография без подписи — это сообщение, а пустая строка рядом с ней не
-- мусор, а отсутствие текста. Заглушка удалённого остаётся третьим законным
-- случаем пустоты — у неё снимается и медиа (см. ниже).
alter table public.room_messages drop constraint room_messages_text_not_blank;
alter table public.room_messages add constraint room_messages_text_not_blank
  check ((deleted_at is not null)
         or (btrim(text) <> ''::text)
         or (jsonb_array_length(media) > 0));


-- =====================================================================
-- 2. Удаление сообщения
-- =====================================================================
-- Заглушка теперь снимает и вложения — иначе после удаления в бакете
-- остались бы файлы, на которые ссылается строка, которую никто уже не
-- показывает. Функция возвращает осиротевшие пути, чтобы клиент снёс объекты
-- ПОСЛЕ записи строки (тот же `deleteRowsThenObjects`, что у аватарки
-- комнаты и у медиа поста): объект без строки — просто байты, строка без
-- объекта — дырка в чате у всех участников.
--
-- Строка сначала читается `for update`, и только потом гасится: `returning`
-- отдаёт НОВОЕ значение колонки, а нужно старое — именно оно и есть список
-- того, что осталось без ссылок.
--
-- Меняется тип возврата, поэтому дроп перед созданием, а грант — заново.
drop function if exists public.delete_own_room_message(uuid);

CREATE OR REPLACE FUNCTION public.delete_own_room_message(p_message_id uuid)
 RETURNS TABLE(storage_path text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_media jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select m.media into v_media
    from room_messages m
   where m.id = p_message_id
     and m.author_id = auth.uid()
     and m.deleted_at is null
   for update;

  -- Повторное удаление уже удалённого — не ошибка: ретрай должен быть тихим,
  -- и сносить в этот раз уже нечего. А вот «строки нет» и «строка чужая» —
  -- один PT404 на оба случая: различать их значит отвечать на вопрос «жива
  -- ли строка» про то, что RLS обязана скрывать целиком.
  if not found then
    if not exists (
      select 1 from room_messages
       where id = p_message_id and author_id = auth.uid()
    ) then
      raise exception 'Message not found' using errcode = 'PT404';
    end if;
    return;
  end if;

  update room_messages
     set deleted_at = now(),
         text = '',
         media = '[]'::jsonb
   where id = p_message_id;

  return query
    select path
      from (
        select item.value ->> 'storage_path' as path
          from jsonb_array_elements(v_media) item
        union all
        select nullif(item.value ->> 'poster_path', '')
          from jsonb_array_elements(v_media) item
      ) gone
     where path is not null;
end;
$function$;


-- =====================================================================
-- 3. Storage
-- =====================================================================
-- `messages/<room_id>/<author_id>/<токен отправки>/<токен файла>.<ext>`.
-- Первые две папки — это и есть право: комната отвечает на «кому видно»,
-- автор — на «кому можно писать». Третья группирует одну отправку, как
-- `postClientToken` у поста: ретрай адресует те же объекты, а не плодит
-- копии.
--
-- UPDATE-политики нет ни у одного префикса в этом бакете (20260822210000):
-- замена файла — всегда новый объект под свежим путём плюс delete старого.
create policy "Message media are viewable by room members"
  on storage.objects
  for select
  to authenticated
  using (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'messages'::text)
    AND (((storage.foldername(name))[2])::uuid IN ( SELECT my_room_ids() AS my_room_ids))));

-- Заливает только участник комнаты и только под своим именем. Второе
-- условие — не формальность: без него участник мог бы положить файл в чужую
-- папку внутри общей комнаты, и CHECK на строке (он сверяет путь с
-- `author_id`) отверг бы только СВОЮ строку, а объект остался бы лежать.
create policy "Room members can upload message media"
  on storage.objects
  for insert
  to authenticated
  with check (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'messages'::text)
    AND (((storage.foldername(name))[2])::uuid IN ( SELECT my_room_ids() AS my_room_ids))
    AND ((storage.foldername(name))[3] = (auth.uid())::text)));

-- Сносит автор — за собой: и брошенную заливку (сообщение так и не ушло), и
-- вложения удалённого сообщения, пути которых вернула
-- `delete_own_room_message()`.
create policy "Authors can delete their own message media"
  on storage.objects
  for delete
  to authenticated
  using (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'messages'::text)
    AND (((storage.foldername(name))[2])::uuid IN ( SELECT my_room_ids() AS my_room_ids))
    AND ((storage.foldername(name))[3] = (auth.uid())::text)));


-- =====================================================================
-- 4. Сборщик сирот
-- =====================================================================
-- Клиент сносит объекты сам и первым делом, но это best-effort: приложение
-- закрыли между заливкой и отправкой, сеть отвалилась на `remove`. Раньше
-- сборщик знал только `posts/` и `avatars/`, поэтому брошенное вложение
-- сообщения не подобрал бы никто и никогда.
--
-- Ветки разные, потому что разный вопрос «на этот файл ещё кто-нибудь
-- ссылается»: у поста — строки `post_media`, у сообщения — jsonb внутри
-- `room_messages`. Порог в сутки общий и по той же причине: только что
-- залитый файл почти всегда ещё не имеет строки — она появится через
-- секунду, когда сообщение уйдёт.
CREATE OR REPLACE FUNCTION public.orphaned_media_paths()
 RETURNS SETOF text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select o.name
    from storage.objects o
   where o.bucket_id = 'media'
     and o.created_at < now() - interval '24 hours'
     and (
       (
         (storage.foldername(o.name))[1] in ('posts', 'avatars')
         and (storage.foldername(o.name))[2] ~
             '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         and not exists (
           select 1 from post_media m
            where m.storage_path = o.name or m.poster_path = o.name
         )
         and not exists (
           select 1 from profile_photos p where p.storage_path = o.name
         )
         -- Избыточно, пока sync_avatar_path_from_profile_photos() держит колонку в
         -- синхроне с profile_photos, — но именно на эту колонку смотрит весь
         -- остальной клиент, и она переживала уже одну миграцию формата
         -- (20260820100000). Проверить её стоит один exists.
         and not exists (
           select 1 from users u where u.avatar_path = o.name
         )
       )
       or (
         (storage.foldername(o.name))[1] = 'messages'
         and (storage.foldername(o.name))[2] ~
             '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         and not exists (
           select 1
             from room_messages m,
                  lateral jsonb_array_elements(m.media) item
            where m.room_id::text = (storage.foldername(o.name))[2]
              and (item.value ->> 'storage_path' = o.name
                   or item.value ->> 'poster_path' = o.name)
         )
       )
     )
   order by o.name
   limit 100;
$function$;


-- =====================================================================
-- 5. Список комнат
-- =====================================================================
-- Шестое пересоздание `my_rooms()` (набор OUT-колонок). Строке списка нужен
-- не сам список вложений, а один бит: сообщение без текста — это не пустая
-- строка в превью, а «фотография». Что именно писать вместо неё, решает
-- клиент — на его языке.
drop function if exists public.my_rooms();

CREATE OR REPLACE FUNCTION public.my_rooms()
 RETURNS TABLE(id uuid, name text, avatar_path text, is_direct boolean, owner_id uuid, created_at timestamp with time zone, last_message_at timestamp with time zone, last_message_text text, last_message_author_id uuid, last_message_has_media boolean, unread_count integer, notifications_muted boolean, members jsonb)
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
         msg.created_at,
         msg.text,
         msg.author_id,
         msg.has_media,
         unread.n,
         me.notifications_muted,
         mem.members
    from rooms r
    join room_members me on me.room_id = r.id and me.user_id = auth.uid()
    left join lateral (
      select m.created_at, m.text, m.author_id, jsonb_array_length(m.media) > 0 as has_media
        from room_messages m
       where m.room_id = r.id and m.deleted_at is null
       order by m.created_at desc, m.id desc
       limit 1
    ) msg on true
    cross join lateral (
      -- Свои сообщения непрочитанными не считаются никогда: отправка их же
      -- и порождает, и счётчик на собственной кнопке был бы шумом. Mute на
      -- этот счёт не влияет — он про пуши, а не про чтение.
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
   order by coalesce(msg.created_at, r.created_at) desc, r.id desc;
$function$;


-- =====================================================================
-- 6. Гранты
-- =====================================================================
-- Новая колонка в INSERT-гранте названа явно: колоночные гранты новую
-- колонку сами не подхватывают (см. «Дефолтные гранты Supabase» в CLAUDE.md),
-- а без неё отправка сообщения с вложением отвечала бы 42501.
grant insert (author_id, client_token, created_at, room_id, text, media) on table public.room_messages to authenticated;

-- Единственная функция проекта, выданная `authenticated` не потому, что её
-- зовёт клиент, а потому, что её зовёт CHECK: ограничение вычисляется
-- правами того, кто пишет строку, и без гранта отправка сообщения падала бы
-- 42501 «permission denied for function». Обычное правило («выдавать только
-- то, чей каждый аргумент про самого вызывающего») она при этом не нарушает
-- с другой стороны: функция не ходит ни в одну таблицу, она чистая функция
-- своих аргументов — как эндпоинт PostgREST она умеет ответить лишь на
-- вопрос «правильно ли составлен этот json», который спрашивающий и так
-- знает.
revoke execute on function public.room_message_media_ok(p_room_id uuid, p_author_id uuid, p_media jsonb) from public, anon;
grant execute on function public.room_message_media_ok(p_room_id uuid, p_author_id uuid, p_media jsonb) to authenticated;

revoke execute on function public.delete_own_room_message(p_message_id uuid) from public, anon, authenticated;
grant execute on function public.delete_own_room_message(p_message_id uuid) to authenticated;

revoke execute on function public.my_rooms() from public, anon, authenticated;
grant execute on function public.my_rooms() to authenticated;

revoke execute on function public.orphaned_media_paths() from public, anon, authenticated;


-- =====================================================================
-- 7. Проверки после наката
-- =====================================================================
do $$
declare
  v_bad text;
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'room_messages' and column_name = 'media'
  ) then
    raise exception 'room_messages.media не завелась';
  end if;

  -- UPDATE/DELETE у `authenticated` не появились: путь записи один — insert
  -- и `delete_own_room_message()`.
  select string_agg(format('%s:%s', grantee, privilege_type), ', ')
    into v_bad
    from information_schema.role_table_grants
   where table_schema = 'public'
     and table_name = 'room_messages'
     and (grantee = 'anon'
          or (grantee = 'authenticated' and privilege_type in ('UPDATE', 'DELETE', 'TRUNCATE')));
  if v_bad is not null then
    raise exception 'Лишние гранты на room_messages: %', v_bad;
  end if;

  if not exists (
    select 1 from information_schema.column_privileges
     where table_schema = 'public' and table_name = 'room_messages'
       and column_name = 'media' and grantee = 'authenticated' and privilege_type = 'INSERT'
  ) then
    raise exception 'INSERT-грант на room_messages.media не выдан';
  end if;

  if (select count(*) from pg_policy where polrelid = 'storage.objects'::regclass
       and polname in ('Message media are viewable by room members',
                       'Room members can upload message media',
                       'Authors can delete their own message media')) <> 3 then
    raise exception 'storage-политики сообщений не завелись';
  end if;

  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname in ('my_rooms', 'delete_own_room_message')) <> 2 then
    raise exception 'my_rooms()/delete_own_room_message() размножились перегрузками';
  end if;

  if not has_function_privilege('authenticated', 'public.my_rooms()', 'execute')
     or not has_function_privilege('authenticated', 'public.delete_own_room_message(uuid)', 'execute') then
    raise exception 'функция потеряла грант после пересоздания';
  end if;

  -- Сборщик сирот знает про новый префикс: без этого брошенное вложение не
  -- подобрал бы никто.
  if (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'orphaned_media_paths') not ilike '%messages%' then
    raise exception 'orphaned_media_paths() не знает про messages/';
  end if;
end;
$$;
