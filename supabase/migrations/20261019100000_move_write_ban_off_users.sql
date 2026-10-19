-- IMM-541: `users.write_banned_until` читал каждый, кому RLS показывает
-- строку `users`, — сам человек, его Connections, соседи по комнате,
-- комментаторы под постом владельца и все про системный аккаунт. Хватало
-- `GET /rest/v1/users?select=id,write_banned_until`.
--
-- 20260913100000 считала, что «`grant select` у users выдан поколоночно»,
-- но он был и остаётся табличным (`authenticated=rm`), так что колонку
-- видел всякий. Решение модерации наружу отдавать нельзя — ради этого
-- 20260924100000 и закрыла `is_write_banned(uuid)`, — а сама колонка
-- уходила.
--
-- Почему не поколоночный SELECT, как предлагал тикет: `fetchProfile()` в
-- клиенте зовёт `.select()` без списка колонок, то есть `select=*`, а
-- `select *` при поколоночном гранте отбивается 42501 целиком, даже если
-- запретная колонка в ответе никому не нужна. Профиль перестал бы
-- открываться у всех уже выложенных версий, пока люди не обновятся. Вынос
-- колонки в отдельную таблицу закрывает дыру одним накатом и ничего не
-- требует от клиента: `select=*` на `users` просто перестаёт её включать.
--
-- Заодно `users` остаётся таблицей, которую можно читать звёздочкой, а у
-- решения модерации появляется место, где оно по умолчанию закрыто: у
-- `user_moderation` нет ни одного гранта для `authenticated` и ни одной
-- политики, поэтому любое будущее поле модерации рядом с баном будет
-- закрыто, пока его явно не откроют, а не наоборот.

-- Строка есть только у тех, кого хоть раз банили писать: таблица
-- разреженная, и отсутствие строки значит ровно то же, что NULL, —
-- «не забанен». Ставит и снимает только консоль под service_role.
create table public.user_moderation (
  user_id uuid not null,
  write_banned_until timestamp with time zone,
  constraint user_moderation_pkey primary key (user_id),
  constraint user_moderation_user_id_fkey foreign key (user_id)
    references public.users(id) on delete cascade
);

comment on table public.user_moderation is
  'Решения модерации об аккаунте. Клиенту не видна вовсе (IMM-541): ни грантов у authenticated, ни политик.';
comment on column public.user_moderation.write_banned_until is
  'Запрет писать до этого момента. NULL или нет строки — не забанен. Ставит только консоль под service_role.';

-- Дефолтные привилегии схемы выдают новой таблице полный набор
-- `authenticated` (см. «Новая таблица и новая функция в `public`
-- приезжают с полными правами» в AGENTS.md). RLS без единой политики и так
-- отбила бы всё, но грант, под которым ничего нет, — это мина для
-- следующей политики, поэтому снимается и он.
revoke all on table public.user_moderation from public, anon, authenticated;
alter table public.user_moderation enable row level security;

insert into public.user_moderation (user_id, write_banned_until)
select id, write_banned_until
  from public.users
 where write_banned_until is not null;

-- Тела взяты из baseline 20261018000000 — последнего, кто трогал обе
-- функции, — и отличаются только источником даты.

-- Под запретом ли писать — про ЛЮБОЙ аккаунт по uuid. Живых вызовов нет;
-- закрыта для всех, включая PUBLIC (20260924100000): решение модерации
-- наружу не отдаётся. `create or replace` гранты сохраняет.
CREATE OR REPLACE FUNCTION public.is_write_banned(p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1 from user_moderation m
     where m.user_id = p_user and m.write_banned_until > now()
  );
$function$;

-- Шапка — в baseline, у той же функции. Изменился только SELECT даты:
-- `users` → `user_moderation`. Нет строки — `v_until` остаётся NULL, и
-- ветка ниже проходит как «не забанен».
CREATE OR REPLACE FUNCTION public.reject_write_when_banned()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_until timestamp with time zone;
  v_author uuid;
begin
  -- У всех восьми таблиц колонка автора называется по-разному, а тело одно.
  -- Берётся из NEW через to_jsonb, чтобы не плодить восемь функций.
  v_author := coalesce(
    (to_jsonb(new) ->> 'author_id')::uuid,
    (to_jsonb(new) ->> 'user_id')::uuid,
    (to_jsonb(new) ->> 'owner_id')::uuid,
    (to_jsonb(new) ->> 'requester_id')::uuid,
    -- `public.users` — единственная таблица, где автор строки это её
    -- первичный ключ. Поэтому ветка условная по имени таблицы, а не просто
    -- `id` пятым элементом цепочки: `id` есть и у `posts`, и у `comments`, и
    -- у `rooms`, и там это НЕ человек — безусловный `id` превратил бы функцию
    -- в проверку бана «пользователя с id поста». Без этой ветки триггер на
    -- `users` срабатывал, не находил автора и выходил как «пишет сервер» —
    -- то есть смена имени забанённому оставалась разрешённой (поймано пробой,
    -- а не рассуждением).
    case
      when tg_table_schema = 'public' and tg_table_name = 'users'
        then (to_jsonb(new) ->> 'id')::uuid
    end
  );
  -- `is distinct from`, а не `<>`: см. шапку пункта 3.
  if v_author is distinct from auth.uid() then
    -- Не наше дело: строку пишет не сам пользователь (сервер, миграция,
    -- консоль) либо автор в ней не назван. Чужие вставки этот триггер не
    -- судит — за них отвечают политики и гранты.
    return new;
  end if;

  select m.write_banned_until into v_until
    from user_moderation m where m.user_id = v_author;

  if v_until is not null and v_until > now() then
    -- Свой SQLSTATE, чтобы клиент отличил бан от отказа политики (42501) и
    -- от сетевой ошибки. Дата уезжает в DETAIL: текст клиент рисует свой,
    -- локализованный, а из ответа ему нужна только она.
    raise exception 'Writing is restricted for this account'
      using errcode = 'AMB01',
            detail = to_char(v_until at time zone 'UTC',
                             'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  end if;

  return new;
end;
$function$;

-- Индекс `users_write_banned_idx` уходит вместе с колонкой. Новому он не
-- нужен: таблица разреженная, и ищут в ней только по первичному ключу.
alter table public.users drop column write_banned_until;

-- Проверки. Тексты функций сверяются по `prosrc`, а не по факту наката:
-- `check_function_bodies` проверяет plpgsql только синтаксически, и тело,
-- которое ищет дату в `users`, накатилось бы молча и падало бы на каждой
-- записи (см. «`create or replace function` переписывает ВСЁ тело» в
-- AGENTS.md).
do $check$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'users'
                and column_name = 'write_banned_until') then
    raise exception 'users.write_banned_until всё ещё на месте';
  end if;

  if has_table_privilege('authenticated', 'public.user_moderation', 'select')
     or has_table_privilege('authenticated', 'public.user_moderation', 'insert')
     or has_table_privilege('authenticated', 'public.user_moderation', 'update')
     or has_table_privilege('authenticated', 'public.user_moderation', 'delete')
     or has_any_column_privilege('authenticated', 'public.user_moderation', 'select')
     or has_any_column_privilege('anon', 'public.user_moderation', 'select') then
    raise exception 'user_moderation открыта клиенту';
  end if;

  if not (select relrowsecurity from pg_class
           where oid = 'public.user_moderation'::regclass) then
    raise exception 'user_moderation без RLS';
  end if;

  if exists (select 1 from pg_proc
              where pronamespace = 'public'::regnamespace
                and proname in ('is_write_banned', 'reject_write_when_banned')
                and prosrc !~ 'user_moderation') then
    raise exception 'функция бана читает дату не из user_moderation';
  end if;

  if has_function_privilege('authenticated', 'public.is_write_banned(uuid)', 'execute')
     or has_function_privilege('anon', 'public.is_write_banned(uuid)', 'execute') then
    raise exception 'is_write_banned(uuid) снова открыта клиенту';
  end if;
end
$check$;
