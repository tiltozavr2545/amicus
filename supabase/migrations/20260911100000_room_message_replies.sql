-- =====================================================================
-- Ответ на конкретное сообщение в чате.
--
-- Ложится поверх 20260826200000 (room_chat) и 20260828120000 (медиа в
-- сообщениях) — INSERT-политика и INSERT-грант room_messages пересоздаются
-- целиком с добавленной колонкой, как у media в 20260828120000.
--
-- `reply_to_id` — самоссылка на room_messages, nullable. `on delete set
-- null`, а не `cascade`: строки room_messages никогда не удаляются физически
-- (только tombstone через deleted_at, см. 20260826200000), так что эта ветка
-- не сработает никогда на практике — но если это когда-нибудь изменится,
-- ответ должен пережить исчезновение оригинала, а не утащить его за собой.
--
-- Обратного индекса («какие сообщения отвечают на это») не заводится: клиент
-- никогда не задаёт такой запрос — цитата резолвится по id (первичный ключ),
-- а не поиском обратных ссылок.
-- =====================================================================

alter table public.room_messages
  add column reply_to_id uuid references public.room_messages(id) on delete set null;

-- Проверка «reply_to_id, если задан, указывает на сообщение ИЗ ТОЙ ЖЕ
-- комнаты» обязана идти через security definer, а не голым EXISTS прямо в
-- политике. Первая накатка сделала именно так — EXISTS к room_messages
-- внутри INSERT-политики САМОЙ room_messages — и это уронило вообще любую
-- отправку сообщения (даже без reply_to_id) на 42P17 «infinite recursion
-- detected in policy»: RLS-планировщик обязан построить план подзапроса для
-- любой вставляемой строки независимо от того, что там лежит в reply_to_id,
-- а подзапрос к той же таблице внутри её же политики компилируется в цикл
-- (см. «RLS применяется и к подзапросам внутри политики» в AGENTS.md — та
-- же причина, по которой my_room_ids()/is_comment_visible() уже security
-- definer). Внутри функции RLS не действует вовсе, цикла не возникает.
CREATE OR REPLACE FUNCTION public.room_message_in_room(p_message_id uuid, p_room_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from room_messages rm where rm.id = p_message_id and rm.room_id = p_room_id
  );
$function$;

drop policy "Room members can write in their rooms" on public.room_messages;
create policy "Room members can write in their rooms"
  on public.room_messages
  for insert
  to authenticated
  with check (((author_id = auth.uid()) AND (created_at = now()) AND (deleted_at IS NULL)
    AND (room_id IN ( SELECT my_room_ids() AS my_room_ids))
    AND (reply_to_id IS NULL OR public.room_message_in_room(reply_to_id, room_id))));

-- Новая колонка в INSERT-гранте названа явно: колоночные гранты новую
-- колонку сами не подхватывают (см. «Дефолтные гранты Supabase» в AGENTS.md),
-- а без неё отправка ответа отвечала бы 42501.
grant insert (author_id, client_token, created_at, room_id, text, media, reply_to_id)
  on table public.room_messages to authenticated;

-- Функцию зовёт политика (то есть тот, кто пишет строку), не только клиент
-- напрямую — без гранта отправка ЛЮБОГО сообщения падала бы 42501
-- «permission denied for function», ровно как у room_message_media_ok()
-- в 20260828120000.
revoke execute on function public.room_message_in_room(uuid, uuid) from public, anon;
grant execute on function public.room_message_in_room(uuid, uuid) to authenticated;


-- =====================================================================
-- Проверки после наката
-- =====================================================================
do $$
declare
  v_bad text;
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'room_messages' and column_name = 'reply_to_id'
  ) then
    raise exception 'room_messages.reply_to_id не завелась';
  end if;

  if not exists (
    select 1 from information_schema.column_privileges
     where table_schema = 'public' and table_name = 'room_messages'
       and column_name = 'reply_to_id' and grantee = 'authenticated' and privilege_type = 'INSERT'
  ) then
    raise exception 'INSERT-грант на room_messages.reply_to_id не выдан';
  end if;

  if not has_function_privilege('authenticated', 'public.room_message_in_room(uuid, uuid)', 'execute') then
    raise exception 'room_message_in_room() не выдан execute authenticated';
  end if;

  -- UPDATE/DELETE у `authenticated` по-прежнему не появились: пересоздание
  -- политики их не должно было задеть, но это тот самый грабельный случай
  -- («create or replace переписывает ВСЁ»), только для политики — проверить
  -- дешевле, чем гадать.
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

  if (select count(*) from pg_policy
       where polrelid = 'public.room_messages'::regclass
         and polname = 'Room members can write in their rooms') <> 1 then
    raise exception 'INSERT-политика room_messages не пересоздалась ровно один раз';
  end if;
end;
$$;
