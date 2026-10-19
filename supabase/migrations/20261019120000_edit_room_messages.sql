-- IMM-208: правка отправленного сообщения в чате комнаты — текст и
-- вложения, 48 часов с отправки, только своё. Остальные видят пометку
-- «изменено», прежние версии не хранятся.
--
-- Путь один — RPC `edit_own_room_message()`, а не UPDATE-грант с политикой:
-- политика не умеет ограничить, КАКИЕ колонки меняются, и открыла бы
-- правку своей строки целиком, включая `created_at`, по которому считаются
-- непрочитанные и галочки (та же причина, по которой удаление — RPC,
-- 20260826200000). Правка приезжает остальным обычным realtime UPDATE —
-- целой строкой, через ту же SELECT-политику, что и заглушка удалённого.

-- Когда сообщение правили в последний раз. NULL — не правили. Ставит
-- только RPC: в INSERT-гранте колонки нет, UPDATE-гранта нет вовсе.
alter table public.room_messages add column edited_at timestamp with time zone;

comment on column public.room_messages.edited_at is
  'Время последней правки (edit_own_room_message). NULL — не правили. Клиент рисует по нему «изменено».';

-- Правка своего сообщения. Отвечает так же, как удаление: «нет такого»,
-- «есть, но чужое» и «скрыто модерацией» — один PT404. Скрытое не видно
-- никому, включая автора, и различать эти случаи значит отвечать на вопрос
-- «жива ли строка» про то, что RLS скрывает целиком. Заглушку удалённого
-- автор видит, так что ей — PT422: правят не её, а живое сообщение.
--
-- Окно в 48 часов — свой SQLSTATE `AME01`, чтобы клиент сказал «время
-- вышло», а не «не получилось». Считается от `created_at`, а не от прошлой
-- правки: иначе правкой раз в двое суток окно не закрывалось бы никогда.
--
-- Членства не требует, как и удаление: сообщение остаётся своим и после
-- ухода из комнаты. Форму вложений и непустоту держат CHECK самой строки
-- (`room_messages_media_shape`, `room_messages_text_not_blank`,
-- `room_messages_text_length`) — они срабатывают на UPDATE так же, как на
-- вставке, и вторая копия правила здесь разошлась бы с ними к третьей
-- правке. Запрет писать — триггер ниже, по той же причине.
--
-- Возвращает пути, на которые больше ничто не ссылается: вложения, которые
-- правка убрала. Объекты клиент сносит сам, ПОСЛЕ строки, как и при
-- удалении. Правка без изменений — пустой ответ и без пометки «изменено».
CREATE OR REPLACE FUNCTION public.edit_own_room_message(p_message_id uuid, p_text text, p_media jsonb)
 RETURNS TABLE(storage_path text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_row room_messages%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if p_text is null or p_media is null then
    raise exception 'Text and media are required' using errcode = 'PT422';
  end if;

  select m.* into v_row
    from room_messages m
   where m.id = p_message_id
     and m.author_id = auth.uid()
     and m.hidden_at is null
   for update;

  if not found then
    raise exception 'Message not found' using errcode = 'PT404';
  end if;

  if v_row.deleted_at is not null then
    raise exception 'A deleted message cannot be edited' using errcode = 'PT422';
  end if;

  if v_row.created_at < now() - interval '48 hours' then
    raise exception 'The edit window has passed' using errcode = 'AME01';
  end if;

  if v_row.text = p_text and v_row.media = p_media then
    return;
  end if;

  update room_messages
     set text = p_text,
         media = p_media,
         edited_at = now()
   where id = p_message_id;

  -- Что было в строке и чего в ней больше нет — и файл, и постер видео.
  -- Сравнение по путям, а не по элементам: тот же файл может вернуться с
  -- другими полями, и сносить его тогда нельзя.
  return query
    with old_paths as (
      select item ->> 'storage_path' as p
        from jsonb_array_elements(v_row.media) item
      union
      select item ->> 'poster_path'
        from jsonb_array_elements(v_row.media) item
    ),
    new_paths as (
      select item ->> 'storage_path' as p
        from jsonb_array_elements(p_media) item
      union
      select item ->> 'poster_path'
        from jsonb_array_elements(p_media) item
    )
    select o.p from old_paths o
     where o.p is not null and o.p <> ''
       and o.p not in (select n.p from new_paths n where n.p is not null);
end;
$function$;

revoke all on function public.edit_own_room_message(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.edit_own_room_message(uuid, text, jsonb) to authenticated;

-- Правка — тоже запись (см. «„Запись“ — это не только INSERT» в
-- AGENTS.md): забанённый не должен переписывать старое так же, как не
-- может писать новое. Поколоночный триггер, как у `posts.text`, плюс
-- условие на заглушку: удаление тоже переписывает `text` и `media`, а
-- снести своё сообщение под баном можно (IMM-208). Автора
-- `reject_write_when_banned()` находит по `author_id`.
create trigger reject_write_when_banned_on_edit
  before update of text, media on public.room_messages
  for each row
  when (new.deleted_at is null)
  execute function public.reject_write_when_banned();

do $check$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'room_messages'
                    and column_name = 'edited_at') then
    raise exception 'room_messages.edited_at не заведена';
  end if;

  if has_function_privilege('anon', 'public.edit_own_room_message(uuid, text, jsonb)', 'execute') then
    raise exception 'edit_own_room_message открыта anon';
  end if;
  if not has_function_privilege('authenticated', 'public.edit_own_room_message(uuid, text, jsonb)', 'execute') then
    raise exception 'edit_own_room_message не выдана authenticated';
  end if;

  -- Правка идёт только через RPC: у клиента не должно появиться права
  -- писать строку напрямую, ни целиком, ни по колонкам.
  if has_table_privilege('authenticated', 'public.room_messages', 'update')
     or has_any_column_privilege('authenticated', 'public.room_messages', 'update')
     or has_column_privilege('authenticated', 'public.room_messages', 'edited_at', 'insert') then
    raise exception 'room_messages пишется клиентом мимо RPC';
  end if;

  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.room_messages'::regclass
                    and tgname = 'reject_write_when_banned_on_edit') then
    raise exception 'триггер бана на правку не повешен';
  end if;
end
$check$;
