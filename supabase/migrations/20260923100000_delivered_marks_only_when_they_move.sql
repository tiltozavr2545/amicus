-- =====================================================================
-- `mark_rooms_delivered()` перестаёт писать строки, которым нечего
-- доставлять.
--
-- Функция с 20260827100000 продвигала `last_delivered_at` во ВСЕХ комнатах
-- вызывающего безусловно, а зовётся она из `fetchRooms()`, то есть на каждый
-- перезапрос списка комнат. Само по себе это выглядело дёшево — один UPDATE
-- по нескольким строкам, — но `room_members` лежит в публикации realtime (там
-- же, п.4), и каждая переписанная строка превращается в событие, которое
-- прилетает ВСЕМ участникам этой комнаты. Дальше складывалось так:
--
--   открытый чат получает сообщение
--     -> клиент зовёт mark_room_read() и дёргает перезапрос списка комнат
--     -> fetchRooms() зовёт mark_rooms_delivered()
--     -> переписываются все N строк room_members этого человека
--     -> N событий realtime разлетаются по всем его комнатам
--     -> у каждого получателя дёргается подписка на отметки, то есть
--        setState на открытом экране чата
--
-- То есть одно сообщение стоило тем дороже, чем больше у людей общих комнат,
-- и стоимость была взаимной: чужие перезапросы точно так же будили нас.
-- Клиентская половина (перезапрос списка на каждое входящее) убрана в том же
-- изменении; эта миграция закрывает серверную, и она важнее — список комнат
-- перезапрашивается и по другим поводам, а писать строку, значение в которой
-- ничего не меняет, не стоит делать ни по какому поводу.
--
-- Что именно значит «нечего доставлять»: в комнате нет ни одного живого
-- сообщения от кого-то другого, которое новее текущей отметки. Тогда
-- продвижение отметки ненаблюдаемо — галочка «доставлено» рисуется сравнением
-- `last_delivered_at` с `created_at` сообщения (см. `_buildStatus` на экране
-- чата), и любое сообщение старше отметки уже считается доставленным, куда бы
-- её ни двинули дальше.
--
-- Свои сообщения из условия исключены намеренно: галочки на своём сообщении
-- рисуются по ЧУЖИМ отметкам, а собственная не участвует ни в них, ни в
-- счётчике непрочитанного (он меряется от `last_read_at`). Значит собственная
-- отправка — не повод переписывать строку и будить ею всю комнату.
--
-- Индекс для `exists` уже есть: `room_messages_room_created_idx`
-- (room_id, created_at desc, id desc) из 20260826200000.
--
-- Сигнатура не меняется, поэтому `create or replace`, а не drop+create —
-- грант при этом остаётся, но ниже он всё равно проверяется.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.mark_rooms_delivered()
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update room_members m
     set last_delivered_at = now()
   where m.user_id = auth.uid()
     and exists (
       select 1
         from room_messages msg
        where msg.room_id = m.room_id
          and msg.author_id <> m.user_id
          and msg.deleted_at is null
          and msg.created_at > m.last_delivered_at
     );
$function$;


-- =====================================================================
-- Проверки после наката
-- =====================================================================
-- Проверяется `prosrc`, а не «применилось ли»: `create or replace`
-- переписывает всё тело целиком, и накат из устаревшего текста проходит
-- молча — см. «Грабли» в AGENTS.md.
do $$
declare
  v_src text;
begin
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'mark_rooms_delivered') <> 1 then
    raise exception 'mark_rooms_delivered() размножилась перегрузками';
  end if;

  select prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'mark_rooms_delivered';

  if v_src not ilike '%exists%' then
    raise exception 'mark_rooms_delivered() всё ещё пишет безусловно';
  end if;

  if v_src not ilike '%author_id <> m.user_id%' then
    raise exception 'mark_rooms_delivered() считает своими сообщениями чужие';
  end if;

  -- Грант переживает `create or replace`, но проверить дешевле, чем узнать
  -- от пользователя: без него список комнат отвечает 42501 на каждый запрос.
  if not has_function_privilege('authenticated', 'public.mark_rooms_delivered()', 'execute') then
    raise exception 'mark_rooms_delivered() потеряла грант';
  end if;

  if has_function_privilege('anon', 'public.mark_rooms_delivered()', 'execute') then
    raise exception 'mark_rooms_delivered() открыта anon';
  end if;
end;
$$;
