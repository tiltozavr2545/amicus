-- =====================================================================
-- Прочитано/доставлено у каждого сообщения (было открытым вопросом в
-- future-development.md).
--
-- Отдельной таблицы под галочки не заводится — как и с непрочитанными
-- (20260826200000), это повторяло бы (room_id, user_id). Вместо этого рядом
-- с `last_read_at` заводится `last_delivered_at`: тот же приём, вторая
-- временная метка на той же строке участника.
--
-- Статус конкретного сообщения — не хранимое значение, а сравнение на
-- клиенте: сообщение прочитано участником, если его `last_read_at` не
-- раньше `created_at` сообщения (аналогично для `last_delivered_at`).
-- Server отдаёт только сами метки (`room_members` уже читаема
-- сособеседниками — политика "Room members are viewable by fellow
-- members" из 20260826180000), а разворачивает их в галочки/агрегат
-- «прочитано N/M» клиент.
--
-- «Доставлено» в этом приложении не значит «долетело до устройства»: пуш-
-- подтверждений нет, и заводить их — отдельная инфраструктура ради
-- галочки. Здесь это означает «клиент синхронизировал список комнат» —
-- события, которое и так происходит на каждое открытие вкладки комнат.
-- Слабее настоящей доставки, но честно: именно это приложение и знает.
--
-- Что заводится:
--   1. `room_members.last_delivered_at`;
--   2. `mark_room_read()` пересоздана: чтение подразумевает доставку, значит
--      обе метки продвигаются вместе;
--   3. `mark_rooms_delivered()` — новая RPC, продвигает `last_delivered_at`
--      сразу во всех комнатах вызывающего;
--   4. `room_members` добавлена в публикацию realtime, чтобы галочка могла
--      перевернуться, пока отправитель ещё смотрит на экран.
-- =====================================================================


-- =====================================================================
-- 1. Метка доставки
-- =====================================================================
-- `default now()` по той же причине, что у `last_read_at`: новый участник не
-- получает всю историю комнаты «недоставленной».
alter table public.room_members
  add column last_delivered_at timestamp with time zone default now() not null;


-- =====================================================================
-- 2. Отметки читаются вместе
-- =====================================================================
-- Прочитанное сообщение не может быть недоставленным, поэтому чтение
-- продвигает обе метки. Сигнатура не меняется — `create or replace` вместо
-- drop+create, как и раньше для этой функции.
CREATE OR REPLACE FUNCTION public.mark_room_read(p_room_id uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update room_members m
     set last_read_at = now(),
         last_delivered_at = now()
   where m.room_id = p_room_id
     and m.user_id = auth.uid();
$function$;

-- Продвигает «доставлено» во всех комнатах вызывающего разом. Аргументов
-- нет — фильтр `auth.uid()` встроен, так что грант `authenticated` не
-- отвечает ни на чей вопрос, кроме вопроса о самом вызывающем.
CREATE OR REPLACE FUNCTION public.mark_rooms_delivered()
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update room_members m
     set last_delivered_at = now()
   where m.user_id = auth.uid();
$function$;


-- =====================================================================
-- 3. Realtime
-- =====================================================================
-- Второе использование realtime в проекте (первое — `room_messages` в
-- 20260826200000). Политика SELECT на `room_members` та же, что и у
-- обычного чтения — чужая комната через подписку не потечёт.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'room_members'
  ) then
    alter publication supabase_realtime add table public.room_members;
  end if;
end;
$$;


-- =====================================================================
-- 4. Гранты
-- =====================================================================
revoke execute on function public.mark_rooms_delivered() from public, anon, authenticated;
grant execute on function public.mark_rooms_delivered() to authenticated;


-- =====================================================================
-- 5. Проверки после наката
-- =====================================================================
do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name = 'room_members'
       and column_name = 'last_delivered_at'
  ) then
    raise exception 'room_members.last_delivered_at не появилась';
  end if;

  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'room_members'
  ) then
    raise exception 'room_members не попала в публикацию realtime';
  end if;

  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'mark_rooms_delivered') <> 1 then
    raise exception 'mark_rooms_delivered() размножилась перегрузками';
  end if;

  if not has_function_privilege('authenticated', 'public.mark_rooms_delivered()', 'execute') then
    raise exception 'mark_rooms_delivered() потеряла грант';
  end if;

  if has_function_privilege('anon', 'public.mark_rooms_delivered()', 'execute') then
    raise exception 'mark_rooms_delivered() открыта anon';
  end if;
end;
$$;
