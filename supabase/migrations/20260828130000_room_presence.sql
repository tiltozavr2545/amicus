-- =====================================================================
-- «Печатает…» и «в сети» — presence-канал комнаты.
--
-- Ни таблицы, ни колонки: и то и другое живо ровно столько, сколько открыт
-- экран, а значение, которое устаревает через секунду после записи, хранить
-- негде — presence Realtime держит его в памяти и раздаёт подписчикам сам.
-- Отсюда и граница фичи: «в сети» здесь значит «сейчас в этом чате», а не
-- «заходил в приложение», и «был в сети в 12:40» так не получить — для этого
-- нужна колонка `last_seen_at` и отдельный разговор про приватность.
--
-- Канал ПРИВАТНЫЙ, и это главное решение миграции. Обычный канал Realtime
-- открыт любому, кто знает его имя: presence и broadcast, в отличие от
-- Postgres Changes, не проверяют RLS ни на что — они ничего и не читают из
-- таблиц. Приватный канал проверяет: подписка и отправка идут через
-- `realtime.messages`, у которой RLS включена, а политик до сих пор не было
-- ни одной, то есть приватные каналы были запрещены целиком. Ниже — ровно
-- две политики, и обе про один вопрос: «эта тема — комната, в которой я
-- состою?».
--
-- Имя темы — `room:<room_id>`. Каналы Postgres Changes (`room_messages:…`,
-- `room_members_receipts:…`) остаются публичными и этих политик не касаются:
-- у них своя проверка, построчная, той же SELECT-политикой таблицы.
-- =====================================================================


-- =====================================================================
-- 1. Предикат темы
-- =====================================================================
-- Регулярка перед приведением типа — не украшение: тема приезжает строкой от
-- клиента, и `'room:мусор'::uuid` был бы не «false», а ошибкой прямо внутри
-- политики. `case` даёт порядок вычисления, на который можно положиться, —
-- в отличие от `and`, где планировщик волен переставить операнды.
CREATE OR REPLACE FUNCTION public.is_my_room_topic(p_topic text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case
    when p_topic ~ '^room:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then substring(p_topic from 6)::uuid in (select public.my_room_ids())
    else false
  end;
$function$;


-- =====================================================================
-- 2. Политики канала
-- =====================================================================
-- SELECT — это «подписаться и слышать», INSERT — «сказать» (и presence, и
-- broadcast приезжают сюда одним и тем же путём). Оба разрешены участнику
-- комнаты и никому больше; UPDATE и DELETE не нужны ни одному из них.
create policy "Room presence is readable by room members"
  on realtime.messages
  for select
  to authenticated
  using (public.is_my_room_topic((select realtime.topic())));

create policy "Room members can announce their presence"
  on realtime.messages
  for insert
  to authenticated
  with check (public.is_my_room_topic((select realtime.topic())));


-- =====================================================================
-- 3. Гранты
-- =====================================================================
-- Аргумент про самого вызывающего («моя ли это тема»), для чужой комнаты
-- всегда false — то же правило, по которому выдана `shares_room_with_caller()`.
-- Грант нужен и потому, что политика выше вычисляется правами подписчика.
revoke execute on function public.is_my_room_topic(p_topic text) from public, anon;
grant execute on function public.is_my_room_topic(p_topic text) to authenticated;


-- =====================================================================
-- 4. Проверки после наката
-- =====================================================================
do $$
begin
  if (select count(*) from pg_policy where polrelid = 'realtime.messages'::regclass) <> 2 then
    raise exception 'политик на realtime.messages не две';
  end if;

  if not has_function_privilege('authenticated', 'public.is_my_room_topic(text)', 'execute') then
    raise exception 'is_my_room_topic() не выдана authenticated';
  end if;

  -- Мусор в теме — это false, а не ошибка: иначе первый же кривой topic
  -- ронял бы политику, а не отказывал по ней.
  if public.is_my_room_topic('room:не-uuid') is not false
     or public.is_my_room_topic('') is not false
     or public.is_my_room_topic('room_messages:00000000-0000-0000-0000-000000000000') is not false then
    raise exception 'is_my_room_topic() принимает мусор';
  end if;
end;
$$;
