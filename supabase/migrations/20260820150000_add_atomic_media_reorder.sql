-- Reorder галереи и медиа поста перестаёт быть двумя отдельными запросами, в
-- разрыв между которыми помещается потеря данных.
--
-- И `profile_photos`, и `post_media` намеренно живут без UPDATE-политики:
-- перестановка моделируется как delete+insert строк (20260819200000,
-- 20260819240000). Само по себе это верно — но клиент шлёт DELETE и INSERT
-- ДВУМЯ запросами PostgREST, то есть двумя транзакциями, и между ними нет
-- ничего. Если второй не доехал (а `.timeout()` в Dart не отменяет запрос, он
-- лишь перестаёт ждать), у пользователя не «порядок не сохранился», а
-- **строк больше нет**.
--
-- Для галереи это самый дорогой случай в схеме: 80 удалённых строк, а вдобавок
-- триггер `sync_avatar_path_from_profile_photos()` отработал на DELETE и
-- обнулил `users.avatar_path` — аватарка пропадает из ленты, из списка
-- знакомых и с экрана «Заблокированные» у всех сразу. Объекты в Storage при
-- этом целы, но на них больше не ссылается ни одна строка, и достать их
-- нечем: ровно то сиротство, ради разбора которого пришлось писать
-- 20260820100000.
--
-- Транзакцией это можно сделать только на сервере — PostgREST одним вызовом
-- выполняет ровно один запрос. Отсюда RPC. `security definer` — по той же
-- причине, что у `delete_own_comment()` (20260725120000): решение
-- «что и в каком порядке» принимает сервер, а клиентской UPDATE-политики,
-- которую пришлось бы для этого завести, по-прежнему нет. Оба аргумента — про
-- самого вызывающего (владение проверяется внутри по `auth.uid()`), поэтому
-- грант `authenticated` безопасен по правилу из CLAUDE.md.
--
-- Требуется передать ВЕСЬ набор, а не подмножество: позиции переписываются в
-- плотный 0..N-1, и перестановка половины строк налезла бы позициями на
-- нетронутую половину (`unique (user_id, position)`). Клиент и так всегда
-- держит на экране весь список. Несовпадение — `PT422`, тот же приём стабильных
-- кодов, что у `activate_invite_link()` (20260726170000).
--
-- Backstop-триггеры лимита не мешают: DELETE и INSERT идут в одной транзакции
-- и в этом порядке, так что на момент вставки счётчик уже нулевой.

create or replace function public.reorder_profile_photos(p_photo_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_paths text[];
  v_total int;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  -- Пути в порядке, который прислал клиент, и только по СВОИМ строкам.
  -- `with ordinality` — чтобы порядок задавался массивом, а не таблицей.
  select array_agg(pp.storage_path order by ord.idx)
    into v_paths
    from unnest(p_photo_ids) with ordinality as ord(id, idx)
    join profile_photos pp on pp.id = ord.id and pp.user_id = auth.uid();

  select count(*) into v_total
    from profile_photos where user_id = auth.uid();

  -- Чужая или несуществующая строка отваливается на join выше, поэтому
  -- расхождение длин ловит и её тоже — отдельной проверки владения не нужно.
  if coalesce(array_length(v_paths, 1), 0) <> coalesce(array_length(p_photo_ids, 1), 0)
     or coalesce(array_length(p_photo_ids, 1), 0) <> v_total then
    raise exception 'Photo set does not match your gallery' using errcode = 'PT422';
  end if;

  delete from profile_photos where user_id = auth.uid();

  insert into profile_photos (user_id, position, storage_path)
  select auth.uid(), i - 1, v_paths[i]
    from generate_series(1, array_length(v_paths, 1)) as i;
end;
$$;

revoke execute on function public.reorder_profile_photos(uuid[]) from public, anon;
grant execute on function public.reorder_profile_photos(uuid[]) to authenticated;

-- То же для медиа поста. Здесь набор не просто переставляется, а задаётся
-- целиком: часть элементов остаётся от старого поста, часть только что
-- загружена, часть исчезает. Поэтому вход — не список id, а желаемое конечное
-- состояние (`[{media_type, storage_path, poster_path}, …]` в порядке показа),
-- а на выходе — пути в Storage, на которые больше никто не ссылается: клиент
-- удаляет объекты ПОСЛЕ того, как строки уже переписаны. Порядок важен —
-- осиротевший объект это просто потраченное место, а удалённый объект при
-- живой строке рисуется в ленте битой картинкой.
--
-- `returns table`, а не `returns setof text`: у скалярного setof форма ответа
-- PostgREST отличается от «массива объектов», к которой приведены все
-- остальные RPC проекта (`reaction_summary`, `comment_summary`,
-- `activate_invite_link`). Одна форма на все RPC — одна форма разбора на
-- клиенте, и не надо помнить, у какой функции она другая.
drop function if exists public.set_post_media(uuid, jsonb);

create or replace function public.set_post_media(p_post_id uuid, p_items jsonb)
returns table (storage_path text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_removed text[];
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not exists (
    select 1 from posts p where p.id = p_post_id and p.author_id = auth.uid()
  ) then
    -- Тот же существование-оракул, что и везде: «не мой» и «не существует»
    -- обязаны быть неотличимы, поэтому один код на оба случая.
    raise exception 'Post not found' using errcode = 'PT404';
  end if;

  if jsonb_typeof(p_items) <> 'array' then
    raise exception 'Media list must be an array' using errcode = 'PT422';
  end if;

  if jsonb_array_length(p_items) > 20 then
    raise exception 'post_media_limit_exceeded' using errcode = 'P0001';
  end if;

  -- Что было и не осталось — вместе с постерами видео.
  select array_agg(path) into v_removed
    from (
      select pm.storage_path as path
        from post_media pm
       where pm.post_id = p_post_id
         and not exists (
           select 1 from jsonb_array_elements(p_items) item
            where item ->> 'storage_path' = pm.storage_path
         )
      union all
      select pm.poster_path
        from post_media pm
       where pm.post_id = p_post_id
         and pm.poster_path is not null
         and not exists (
           select 1 from jsonb_array_elements(p_items) item
            where item ->> 'storage_path' = pm.storage_path
         )
    ) gone;

  delete from post_media where post_id = p_post_id;

  insert into post_media (post_id, position, media_type, storage_path, poster_path)
  select
    p_post_id,
    (item.idx - 1)::smallint,
    item.value ->> 'media_type',
    item.value ->> 'storage_path',
    nullif(item.value ->> 'poster_path', '')
  from jsonb_array_elements(p_items) with ordinality as item(value, idx);

  return query select unnest(coalesce(v_removed, array[]::text[])) as storage_path;
end;
$$;

revoke execute on function public.set_post_media(uuid, jsonb) from public, anon;
grant execute on function public.set_post_media(uuid, jsonb) to authenticated;
