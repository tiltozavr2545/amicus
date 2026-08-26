-- =====================================================================
-- Комнаты, этап 2: чат.
--
-- Ложится поверх 20260826180000 (комнаты и лента) и 20260826190000.
--
-- Что заводится:
--   1. `room_messages` — сообщения комнаты;
--   2. `room_members.last_read_at` + `mark_room_read()` — непрочитанные;
--   3. `delete_own_room_message()` — мягкое удаление своего сообщения;
--   4. `my_rooms()` пересоздана: отдаёт ещё и последнее сообщение с
--      непрочитанными, чтобы список комнат был списком чатов;
--   5. пуши: два новых kind, две новые настройки, триггер с подавлением
--      очереди;
--   6. `room_messages` добавлена в публикацию realtime.
--
-- Видимость сообщений отдельного правила НЕ заводит: сообщение видно тому,
-- кто в комнате, и точка — `room_id in (select my_room_ids())`. Ни mute, ни
-- блок её не сужают (осознанное решение этапа 1), и это единственный
-- разумный вариант: дыры в переписке читаются хуже, чем присутствие
-- неприятного человека.
-- =====================================================================


-- =====================================================================
-- 1. Сообщения
-- =====================================================================
-- `client_token` — та же идемпотентность отправки, что у постов и
-- комментариев: ретрай после таймаута не должен раздваивать сообщение.
-- `deleted_at` — заглушка вместо реального delete, как у комментариев, и
-- по своей причине: подписка realtime отдаёт DELETE без содержимого строки
-- (replica identity default — только ключ), проверить по нему RLS нечем, а
-- UPDATE приезжает целой строкой и фильтруется политикой как обычный
-- SELECT. Гасить строку на клиенте по UPDATE — то же самое, что убирать
-- её, только без слепого пятна.
create table public.room_messages (
  id uuid default gen_random_uuid() not null,
  room_id uuid not null,
  author_id uuid not null,
  text text not null,
  created_at timestamp with time zone default now() not null,
  client_token uuid,
  deleted_at timestamp with time zone,
  constraint room_messages_pkey primary key (id),
  constraint room_messages_text_length check (char_length(text) <= 5000),
  -- Пустой текст законен ровно у заглушки — там это и есть значение
  -- «текста больше нет» (тот же приём, что в comments_text_not_blank).
  constraint room_messages_text_not_blank check ((deleted_at is not null) or (btrim(text) <> ''::text)),
  constraint room_messages_room_id_fkey foreign key (room_id) references public.rooms(id) on delete cascade,
  constraint room_messages_author_id_fkey foreign key (author_id) references public.users(id) on delete cascade
);

-- Отправка идемпотентна по (автор, токен) — ровно как посты.
create unique index room_messages_author_client_token_key
  on public.room_messages using btree (author_id, client_token)
  where client_token is not null;

-- Чат читается страницами от свежих к старым.
create index room_messages_room_created_idx
  on public.room_messages using btree (room_id, created_at desc, id desc);

alter table public.room_messages enable row level security;

create policy "Room messages are viewable by room members"
  on public.room_messages
  for select
  to authenticated
  using ((room_id in ( SELECT my_room_ids() AS my_room_ids)));

-- Писать может только участник и только от своего имени. `created_at = now()`
-- — тот же приём, что у постов и комментариев: клиент не назначает время сам.
create policy "Room members can write in their rooms"
  on public.room_messages
  for insert
  to authenticated
  with check (((author_id = auth.uid()) AND (created_at = now()) AND (deleted_at IS NULL)
    AND (room_id IN ( SELECT my_room_ids() AS my_room_ids))));

-- UPDATE- и DELETE-политик нет: удаление идёт только через
-- `delete_own_room_message()`, где заглушка ставится атомарно вместе с
-- очисткой текста. Политика на UPDATE не умеет ограничить, КАКИЕ колонки
-- меняются, и открыла бы правку чужой… нет, своей строки целиком —
-- включая `created_at`, по которому считаются непрочитанные.

-- Докуда участник дочитал. Живёт на строке участника, потому что она уже
-- есть: отдельная таблица «прочитано» повторяла бы (room_id, user_id) один
-- в один. `default now()` — новый участник не получает в наследство всю
-- переписку как непрочитанную.
alter table public.room_members add column last_read_at timestamp with time zone default now() not null;


-- =====================================================================
-- 2. Непрочитанные и удаление
-- =====================================================================

CREATE OR REPLACE FUNCTION public.mark_room_read(p_room_id uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update room_members m
     set last_read_at = now()
   where m.room_id = p_room_id
     and m.user_id = auth.uid();
$function$;

-- Своё сообщение, и только своё. «Нет такого» и «есть, но чужое» отвечают
-- одним PT404 — различать их значит отвечать на вопрос «жива ли строка» про
-- то, что RLS обязана скрывать целиком (тот же принцип, что в
-- `delete_own_comment()`).
CREATE OR REPLACE FUNCTION public.delete_own_room_message(p_message_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_updated int;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  update room_messages
     set deleted_at = now(),
         text = ''
   where id = p_message_id
     and author_id = auth.uid()
     and deleted_at is null;

  get diagnostics v_updated = row_count;

  -- Повторное удаление уже удалённого — не ошибка: ретрай должен быть
  -- тихим. А вот «строки нет» и «строка чужая» — PT404 на оба случая.
  if v_updated = 0 and not exists (
    select 1 from room_messages
     where id = p_message_id and author_id = auth.uid()
  ) then
    raise exception 'Message not found' using errcode = 'PT404';
  end if;
end;
$function$;


-- =====================================================================
-- 3. Список комнат = список чатов
-- =====================================================================
-- Сигнатура возвращаемой таблицы меняется, поэтому функция дропается: у
-- `create or replace` нет права менять OUT-колонки («cannot change return
-- type of existing function»). Грант выдаётся заново — он уходит вместе с
-- функцией (то же правило, что для create_post_with_media в 20260826180000).
drop function if exists public.my_rooms();

CREATE OR REPLACE FUNCTION public.my_rooms()
 RETURNS TABLE(id uuid, name text, is_direct boolean, owner_id uuid, created_at timestamp with time zone, last_post_at timestamp with time zone, last_message_at timestamp with time zone, last_message_text text, last_message_author_id uuid, unread_count integer, members jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select r.id,
         r.name,
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
-- 4. Уведомления
-- =====================================================================
-- Две настройки, а не одна: сообщения приходят часто, посты в комнате —
-- редко, и глушить первое, теряя второе, никто не захочет.
alter table public.notification_preferences
  add column notify_room_messages boolean default true not null,
  add column notify_room_posts boolean default true not null;

alter table public.notification_outbox drop constraint notification_outbox_kind_check;
alter table public.notification_outbox add constraint notification_outbox_kind_check
  CHECK ((kind = ANY (ARRAY['new_post'::text, 'inactive_week'::text, 'digest'::text,
                            'post_comment'::text, 'comment_reply'::text, 'app_update'::text,
                            'room_message'::text, 'room_post'::text])));

-- Имя комнаты в пуш НЕ кладётся намеренно. Оно у каждого своё (у комнаты
-- без названия — перечисление остальных участников), считает его клиент, и
-- вторая копия этого правила на сервере разошлась бы с первой при первом же
-- переименовании. В payload едет `room_id` — с ним пуш когда-нибудь станет
-- deep link'ом, а текст обходится именем автора.
CREATE OR REPLACE FUNCTION public.enqueue_room_message_notifications()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_author_name text;
begin
  select name into v_author_name from users where id = new.author_id;

  insert into notification_outbox (user_id, kind, payload)
  select m.user_id, 'room_message',
    jsonb_build_object(
      'author_name', v_author_name,
      'room_id', new.room_id,
      'message_id', new.id
    )
  from room_members m
  where m.room_id = new.room_id
    and m.user_id <> new.author_id
    and coalesce(
      (select np.notify_room_messages from notification_preferences np where np.user_id = m.user_id),
      true
    )
    -- Человек сейчас в этом чате: экран отмечает прочитанным каждое
    -- входящее сообщение, так что свежая `last_read_at` — это и есть
    -- «читает прямо сейчас». Пуш о сообщении, которое уже на экране,
    -- бесполезен.
    and m.last_read_at < now() - interval '1 minute'
    -- Очередь схлопывается: пока предыдущий пуш из этой комнаты не ушёл,
    -- второй не заводится. Иначе оживший чат превращается в очередь из
    -- сорока одинаковых уведомлений, которые все придут разом.
    and not exists (
      select 1 from notification_outbox n
       where n.user_id = m.user_id
         and n.kind = 'room_message'
         and n.sent_at is null
         and n.payload ->> 'room_id' = new.room_id::text
    );

  return new;
end;
$function$;

create trigger room_messages_enqueue_notifications_after_insert
  after insert on public.room_messages
  for each row execute function public.enqueue_room_message_notifications();

-- Пост в комнату наконец получает своё уведомление — участникам комнаты и
-- никому больше. Триггер на `post_rooms`, а не на `posts`: в момент вставки
-- поста адресатов ещё нет, они приезжают следующим оператором той же
-- транзакции (см. `create_post_with_media()`).
CREATE OR REPLACE FUNCTION public.enqueue_room_post_notifications()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_author_id uuid;
  v_author_name text;
begin
  select p.author_id into v_author_id from posts p where p.id = new.post_id;
  if v_author_id is null or public.is_system_account(v_author_id) then
    return new;
  end if;

  select name into v_author_name from users where id = v_author_id;

  insert into notification_outbox (user_id, kind, payload)
  select m.user_id, 'room_post',
    jsonb_build_object(
      'author_name', v_author_name,
      'room_id', new.room_id,
      'post_id', new.post_id
    )
  from room_members m
  where m.room_id = new.room_id
    and m.user_id <> v_author_id
    and coalesce(
      (select np.notify_room_posts from notification_preferences np where np.user_id = m.user_id),
      true
    )
    -- Одно уведомление на пост на человека — ЛЮБОГО вида. Закрывает сразу
    -- два случая: ретрай с тем же client_token, который переписывает
    -- адресатов через `delete`+`insert` (уведомление уже уходило), и пост
    -- сразу в общую ленту и в комнату — участник, который вдобавок держит
    -- автора в избранном, получил бы и `new_post`, и `room_post` об одном и
    -- том же. Порядок здесь на нашей стороне: триггер на `posts` отрабатывает
    -- раньше, чем появляются строки `post_rooms`.
    and not exists (
      select 1 from notification_outbox n
       where n.user_id = m.user_id
         and n.payload ->> 'post_id' = new.post_id::text
    );

  return new;
end;
$function$;

create trigger post_rooms_enqueue_notifications_after_insert
  after insert on public.post_rooms
  for each row execute function public.enqueue_room_post_notifications();


-- =====================================================================
-- 5. Realtime
-- =====================================================================
-- Первое использование realtime в проекте. Postgres Changes проверяет
-- SELECT-политику подписчика для каждой строки, то есть чужие комнаты
-- через подписку не потекут — политика та же, что и у обычного чтения.
-- `add table` идемпотентности не имеет, поэтому проверка на членство.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'room_messages'
  ) then
    alter publication supabase_realtime add table public.room_messages;
  end if;
end;
$$;


-- =====================================================================
-- 6. Гранты
-- =====================================================================
revoke all on table public.room_messages from anon, authenticated;
grant maintain, select on table public.room_messages to authenticated;
grant insert (author_id, client_token, created_at, room_id, text) on table public.room_messages to authenticated;

revoke execute on function public.enqueue_room_message_notifications() from anon;
revoke execute on function public.enqueue_room_post_notifications() from anon;

revoke execute on function public.mark_room_read(p_room_id uuid) from public, anon, authenticated;
grant execute on function public.mark_room_read(p_room_id uuid) to authenticated;

revoke execute on function public.delete_own_room_message(p_message_id uuid) from public, anon, authenticated;
grant execute on function public.delete_own_room_message(p_message_id uuid) to authenticated;

revoke execute on function public.my_rooms() from public, anon, authenticated;
grant execute on function public.my_rooms() to authenticated;


-- =====================================================================
-- 7. Проверки после наката
-- =====================================================================
do $$
declare
  v_bad text;
begin
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
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'room_messages'
  ) then
    raise exception 'room_messages не попала в публикацию realtime';
  end if;

  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'my_rooms') <> 1 then
    raise exception 'my_rooms() размножилась перегрузками';
  end if;

  if not has_function_privilege('authenticated', 'public.my_rooms()', 'execute') then
    raise exception 'my_rooms() потеряла грант после пересоздания';
  end if;
end;
$$;
