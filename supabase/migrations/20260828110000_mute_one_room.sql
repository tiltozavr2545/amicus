-- =====================================================================
-- Mute одной комнаты.
--
-- Настройка `notify_room_messages` — общая на все комнаты: она отвечает на
-- вопрос «хочу ли я вообще пуши из чатов», а не «хочу ли я пуши вот из
-- этого». Оживший групповой чат глушат целиком вместе с перепиской, которая
-- нужна, — то есть настройкой не пользуются вовсе.
--
-- Флаг живёт на строке `room_members`, там же, где `last_read_at` и
-- `last_delivered_at`: отношение «человек ↔ комната» уже описано этой
-- строкой, и отдельная таблица повторяла бы её ключ (room_id, user_id) один
-- в один. Это третья метка на той же строке и третий раз, когда так дешевле
-- (20260826200000, 20260827100000).
--
-- Mute — это про ПУШИ и только про них. Непрочитанные считаются
-- по-прежнему, значок на строке списка остаётся: замьютить комнату — не то
-- же самое, что перестать её читать, и человек, который заглушил рабочий
-- чат на выходные, всё равно хочет видеть, что там накопилось.
-- =====================================================================


-- =====================================================================
-- 1. Флаг
-- =====================================================================
-- `default false` — все существующие комнаты остаются со звуком: молча
-- заглушить то, что человек уже читает, хуже, чем ничего не менять.
alter table public.room_members
  add column notifications_muted boolean default false not null;


-- =====================================================================
-- 2. Переключатель
-- =====================================================================
-- RPC, а не UPDATE-политика, по той же причине, что и у `mark_room_read()`:
-- политика не умеет ограничить, КАКИЕ колонки меняются, и вместе с этим
-- флагом открыла бы `last_read_at`/`last_delivered_at` — а по ним считаются
-- непрочитанные и рисуются галочки. UPDATE-гранта у таблицы нет вовсе, и
-- эта миграция его не заводит.
--
-- Своя строка и только своя: `user_id = auth.uid()` в `where`. Чужую
-- комнату спрашивать бессмысленно — строки нет, `update` не заденет ничего,
-- и ответ «ничего не изменилось» ничем не отличается от «такой комнаты не
-- существует», что и требуется: RLS обязана скрывать её целиком.
CREATE OR REPLACE FUNCTION public.set_room_muted(p_room_id uuid, p_muted boolean)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update room_members m
     set notifications_muted = coalesce(p_muted, false)
   where m.room_id = p_room_id
     and m.user_id = auth.uid();
$function$;


-- =====================================================================
-- 3. Пуш о сообщении
-- =====================================================================
-- Тело взято из `prosrc` живой схемы (совпадает с 20260826200000), меняется
-- ровно одна строка — предохранителей становится три вместо двух. Порядок
-- условий значения не имеет, но флаг стоит рядом с `last_read_at`: оба —
-- про строку участника, и читаются вместе.
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
    -- Эта комната заглушена лично этим человеком (20260828110000). Общая
    -- настройка выше отвечает на вопрос «хочу ли я пуши из чатов вообще»,
    -- а флаг — «хочу ли я их из ЭТОГО чата»; непрочитанные при этом
    -- считаются по-прежнему.
    and not m.notifications_muted
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


-- =====================================================================
-- 4. Список комнат
-- =====================================================================
-- Пятое пересоздание `my_rooms()`, и опять из-за набора OUT-колонок, менять
-- который `create or replace` не умеет. Флаг едет в списке, а не отдельным
-- запросом к `room_members`: список и так уже читает эту строку (по ней
-- считаются непрочитанные), а экран комнаты рисует переключатель сразу, без
-- второго round trip.
drop function if exists public.my_rooms();

CREATE OR REPLACE FUNCTION public.my_rooms()
 RETURNS TABLE(id uuid, name text, avatar_path text, is_direct boolean, owner_id uuid, created_at timestamp with time zone, last_message_at timestamp with time zone, last_message_text text, last_message_author_id uuid, unread_count integer, notifications_muted boolean, members jsonb)
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
         unread.n,
         me.notifications_muted,
         mem.members
    from rooms r
    join room_members me on me.room_id = r.id and me.user_id = auth.uid()
    left join lateral (
      select m.created_at, m.text, m.author_id
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
-- 5. Гранты
-- =====================================================================
revoke execute on function public.set_room_muted(p_room_id uuid, p_muted boolean) from public, anon, authenticated;
grant execute on function public.set_room_muted(p_room_id uuid, p_muted boolean) to authenticated;

-- Грант уходит вместе с пересозданной функцией.
revoke execute on function public.my_rooms() from public, anon, authenticated;
grant execute on function public.my_rooms() to authenticated;


-- =====================================================================
-- 6. Проверки после наката
-- =====================================================================
do $$
declare
  v_src text;
  v_bad text;
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'room_members'
       and column_name = 'notifications_muted'
  ) then
    raise exception 'room_members.notifications_muted не завелась';
  end if;

  -- UPDATE на room_members не появился ни у кого: единственный путь записи —
  -- RPC выше и `mark_room_read()`/`mark_rooms_delivered()` рядом с ней.
  select string_agg(format('%s:%s', grantee, privilege_type), ', ')
    into v_bad
    from information_schema.role_table_grants
   where table_schema = 'public'
     and table_name = 'room_members'
     and (grantee = 'anon'
          or (grantee = 'authenticated' and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')));
  if v_bad is not null then
    raise exception 'Лишние гранты на room_members: %', v_bad;
  end if;

  -- Не «применилось ли», а `prosrc` на признаки старого тела: у этой
  -- функции есть два предохранителя, которые легко потерять пересозданием
  -- из более раннего текста.
  select prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'enqueue_room_message_notifications';
  if v_src not ilike '%notifications_muted%' then
    raise exception 'enqueue_room_message_notifications() не знает про mute';
  end if;
  if v_src not ilike '%last_read_at < now() - interval%'
     or v_src not ilike '%sent_at is null%' then
    raise exception 'enqueue_room_message_notifications() пересоздана из неполного тела';
  end if;

  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'my_rooms') <> 1 then
    raise exception 'my_rooms() размножилась перегрузками';
  end if;

  if not has_function_privilege('authenticated', 'public.my_rooms()', 'execute') then
    raise exception 'my_rooms() потеряла грант после пересоздания';
  end if;

  if not has_function_privilege('authenticated', 'public.set_room_muted(uuid, boolean)', 'execute') then
    raise exception 'set_room_muted() не выдана authenticated';
  end if;
end;
$$;
