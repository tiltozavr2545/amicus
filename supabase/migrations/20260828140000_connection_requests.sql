-- =====================================================================
-- Заявка на знакомство — второй способ завести Connection.
--
-- До сих пор способ был ровно один: инвайт-код, который показывают вживую
-- (`activate_invite_link()`). Он и остаётся основным — знакомство в этом
-- приложении про людей, которых знают лично. Но комнаты завели ситуацию, в
-- которой этого мало: владелец собирает комнату из СВОИХ знакомых, и её
-- участники друг другу знакомыми быть не обязаны. Люди уже сидят в одном
-- чате, видят имена и лица друг друга — а обменяться кодом им негде.
--
-- Поэтому заявку можно отправить ТОЛЬКО тому, с кем есть общая комната.
-- Это и есть та узкая дверь, которая отличает эту фичу от «поиска людей»:
-- ни каталога, ни адресной книги, ни возможности написать незнакомцу здесь
-- не появляется. Условие проверяется на сервере (`shares_room_with_caller()`),
-- а не в клиенте.
--
-- Пара может иметь только ОДНУ заявку за всё время, в любом статусе. Отказ
-- окончателен для отказавшего направления — и это осознанно: возможность
-- просить снова превращает отказ в переговоры. Передумавший может отправить
-- СВОЮ заявку в обратную сторону, и она законна: это уже его решение, а не
-- повторная просьба.
-- =====================================================================


-- =====================================================================
-- 1. Таблица
-- =====================================================================
-- Пара здесь НЕ упорядочена (в отличие от `connections_ordered_pair`): у
-- заявки есть направление, и кто кого позвал — существенная её часть.
-- Уникальность поэтому по (requester, recipient), а «одна заявка на пару за
-- всё время» держит второй, симметричный индекс ниже.
create table public.connection_requests (
  id uuid default gen_random_uuid() not null,
  requester_id uuid not null,
  recipient_id uuid not null,
  status text default 'pending'::text not null,
  created_at timestamp with time zone default now() not null,
  responded_at timestamp with time zone,
  constraint connection_requests_pkey primary key (id),
  constraint connection_requests_status_check
    check (status = any (array['pending'::text, 'accepted'::text, 'declined'::text])),
  -- Отвечено ⇔ есть время ответа. Без этого «принята» без даты выглядела бы
  -- как принятая только что.
  constraint connection_requests_responded_shape
    check ((status = 'pending') = (responded_at is null)),
  constraint connection_requests_not_self check (requester_id <> recipient_id),
  constraint connection_requests_requester_id_fkey
    foreign key (requester_id) references public.users(id) on delete cascade,
  constraint connection_requests_recipient_id_fkey
    foreign key (recipient_id) references public.users(id) on delete cascade
);

create unique index connection_requests_pair_key
  on public.connection_requests using btree (requester_id, recipient_id);

-- Обе стороны читают свои заявки списком: получатель — входящие, отправитель
-- — чтобы не звать второй раз.
create index connection_requests_recipient_idx
  on public.connection_requests using btree (recipient_id, status);
create index connection_requests_requester_idx
  on public.connection_requests using btree (requester_id, status);

alter table public.connection_requests enable row level security;

-- Видит только та пара, которой заявка касается. Ни INSERT, ни UPDATE, ни
-- DELETE: весь путь записи — через RPC ниже, где проверяются общая комната,
-- блок и отсутствие уже готового Connection. Политика такого не умеет: она
-- разрешает запись, но не объясняет отказ и не смотрит на соседние таблицы
-- так, как нужно объяснению.
create policy "Connection requests are visible to both sides"
  on public.connection_requests
  for select
  to authenticated
  using ((requester_id = auth.uid()) or (recipient_id = auth.uid()));

-- Третий способ завести ряд — рядом с инвайтом и ручной вставкой.
alter table public.connections drop constraint connections_method_check;
alter table public.connections add constraint connections_method_check
  CHECK ((method = ANY (ARRAY['invite_link'::text, 'qr_code'::text, 'manual'::text,
                             'connection_request'::text])));


-- =====================================================================
-- 2. Отправка заявки
-- =====================================================================
-- Возвращает 'requested' или 'connected' — второе, когда встречная заявка
-- уже лежала: два человека, попросившие друг друга, согласны оба, и
-- заставлять кого-то из них ещё и нажать «принять» было бы церемонией ради
-- церемонии.
--
-- Блок и отсутствие общей комнаты отвечают ОДНИМ PT403. Различать их значит
-- отвечать на вопрос «а он меня заблокировал?», который блок обязан скрывать.
CREATE OR REPLACE FUNCTION public.request_connection(p_user_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me uuid := auth.uid();
  v_incoming connection_requests%rowtype;
  v_inserted int;
  v_my_name text;
begin
  if v_me is null then
    raise exception 'Not authenticated';
  end if;

  if p_user_id is null or p_user_id = v_me then
    raise exception 'Cannot request yourself' using errcode = 'PT422';
  end if;

  if not public.shares_room_with_caller(p_user_id)
     or public.is_blocked_pair(v_me, p_user_id) then
    raise exception 'Not available' using errcode = 'PT403';
  end if;

  if public.are_connected(v_me, p_user_id) then
    raise exception 'Already connected' using errcode = 'PT409';
  end if;

  select name into v_my_name from users where id = v_me;

  -- Встречная заявка: принимаем её вместо того, чтобы заводить вторую.
  select * into v_incoming
    from connection_requests
   where requester_id = p_user_id
     and recipient_id = v_me
     and status = 'pending'
   for update;

  if found then
    insert into connections (user_a_id, user_b_id, method)
    values (least(v_me, p_user_id), greatest(v_me, p_user_id), 'connection_request')
    on conflict (user_a_id, user_b_id) do nothing;

    update connection_requests
       set status = 'accepted', responded_at = now()
     where id = v_incoming.id;

    insert into notification_outbox (user_id, kind, payload)
    values (p_user_id, 'connection_accepted',
            jsonb_build_object('user_id', v_me, 'user_name', v_my_name));

    return 'connected';
  end if;

  insert into connection_requests (requester_id, recipient_id)
  values (v_me, p_user_id)
  on conflict (requester_id, recipient_id) do nothing;

  get diagnostics v_inserted = row_count;

  -- Уже просили — неважно, ждёт эта заявка ответа или получила отказ.
  -- Отказ окончателен, и «попросить ещё раз» отличается от «уговаривать»
  -- только словом.
  if v_inserted = 0 then
    raise exception 'Already requested' using errcode = 'PT409';
  end if;

  insert into notification_outbox (user_id, kind, payload)
  values (p_user_id, 'connection_request',
          jsonb_build_object('user_id', v_me, 'user_name', v_my_name));

  return 'requested';
end;
$function$;


-- =====================================================================
-- 3. Ответ на заявку
-- =====================================================================
-- Только получатель и только по ждущей ответа заявке. «Нет такой» и «чужая»
-- отвечают одним PT404 — тот же принцип, что у `delete_own_comment()`.
--
-- Отказ уведомления НЕ порождает: сообщать «вам отказали» значит превращать
-- тихий отказ в событие. Отправитель увидит это сам — кнопка «позвать» к
-- нему не вернётся.
CREATE OR REPLACE FUNCTION public.respond_to_connection_request(p_request_id uuid, p_accept boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me uuid := auth.uid();
  v_request connection_requests%rowtype;
  v_my_name text;
begin
  if v_me is null then
    raise exception 'Not authenticated';
  end if;

  select * into v_request
    from connection_requests
   where id = p_request_id
     and recipient_id = v_me
     and status = 'pending'
   for update;

  if not found then
    raise exception 'Request not found' using errcode = 'PT404';
  end if;

  if not coalesce(p_accept, false) then
    update connection_requests
       set status = 'declined', responded_at = now()
     where id = v_request.id;
    return;
  end if;

  -- Блок мог появиться после отправки заявки — согласиться с ним нельзя.
  if public.is_blocked_pair(v_me, v_request.requester_id) then
    raise exception 'Not available' using errcode = 'PT403';
  end if;

  insert into connections (user_a_id, user_b_id, method)
  values (least(v_me, v_request.requester_id), greatest(v_me, v_request.requester_id),
          'connection_request')
  on conflict (user_a_id, user_b_id) do nothing;

  update connection_requests
     set status = 'accepted', responded_at = now()
   where id = v_request.id;

  select name into v_my_name from users where id = v_me;

  insert into notification_outbox (user_id, kind, payload)
  values (v_request.requester_id, 'connection_accepted',
          jsonb_build_object('user_id', v_me, 'user_name', v_my_name));
end;
$function$;


-- =====================================================================
-- 4. Уведомления
-- =====================================================================
-- Два вида и НИ ОДНОЙ настройки к ним — единственные такие, кроме
-- `app_update`. Заявка адресована лично и приходит раз в несколько месяцев;
-- выключатель к ней означал бы «я больше никогда не узнаю, что меня позвали»,
-- и узнать об этом было бы неоткуда. Настройки заводятся там, где поток
-- шумит: посты, комментарии, сообщения.
--
-- Тексты — ВСЕГДА вторая правка: `kind` здесь и `TEXTS` в send-push, иначе
-- строка в очереди молча пропускается (см. «Что остаётся руками» в
-- operations.md).
alter table public.notification_outbox drop constraint notification_outbox_kind_check;
alter table public.notification_outbox add constraint notification_outbox_kind_check
  CHECK ((kind = ANY (ARRAY['new_post'::text, 'inactive_week'::text, 'digest'::text,
                            'post_comment'::text, 'comment_reply'::text, 'app_update'::text,
                            'room_message'::text, 'app_update_important'::text,
                            'connection_request'::text, 'connection_accepted'::text])));


-- =====================================================================
-- 5. Гранты
-- =====================================================================
revoke all on table public.connection_requests from anon, authenticated;
grant maintain, select on table public.connection_requests to authenticated;

revoke execute on function public.request_connection(p_user_id uuid) from public, anon, authenticated;
grant execute on function public.request_connection(p_user_id uuid) to authenticated;

revoke execute on function public.respond_to_connection_request(p_request_id uuid, p_accept boolean) from public, anon, authenticated;
grant execute on function public.respond_to_connection_request(p_request_id uuid, p_accept boolean) to authenticated;


-- =====================================================================
-- 6. Проверки после наката
-- =====================================================================
do $$
declare
  v_bad text;
begin
  select string_agg(format('%s:%s', grantee, privilege_type), ', ')
    into v_bad
    from information_schema.role_table_grants
   where table_schema = 'public'
     and table_name = 'connection_requests'
     and (grantee = 'anon'
          or (grantee = 'authenticated' and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')));
  if v_bad is not null then
    raise exception 'Лишние гранты на connection_requests: %', v_bad;
  end if;

  if (select count(*) from pg_policy where polrelid = 'public.connection_requests'::regclass) <> 1 then
    raise exception 'политик на connection_requests не одна';
  end if;

  if not has_function_privilege('authenticated', 'public.request_connection(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.respond_to_connection_request(uuid, boolean)', 'execute') then
    raise exception 'RPC заявок не выданы authenticated';
  end if;
end;
$$;
