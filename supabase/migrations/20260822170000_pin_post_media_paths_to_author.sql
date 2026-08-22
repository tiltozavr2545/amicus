-- set_post_media() перестаёт принимать произвольный storage_path.
--
-- Функция `security definer` (20260820150000), то есть пишет в post_media в
-- обход и INSERT-политики "Users can attach media to their own posts", и
-- колоночного гранта — обе проверки остаются только на прямом пути вставки
-- (createPost). Владение постом внутри проверяется, а вот сами пути кладутся
-- в строку как пришли.
--
-- Инвариант, который при этом теряется, назван несущим в самом клиенте
-- (`postMediaPath()`: «первые два сегмента — то, на что матчат storage-политики»)
-- и в docs/data-model.md: медиа поста лежит по
-- `posts/<author_id>/<post_client_token>/<media_client_token>.<ext>`. Через
-- RPC можно было прицепить к своему посту строку с путём
-- `posts/<чужой-uuid>/…` или `avatars/<чужой-uuid>/…`.
--
-- Утечкой на чтение это не было и не является: подписать объект просит уже
-- зритель, а storage-политика на SELECT матчит второй сегмент пути против
-- `visible_author_ids()` этого зрителя, поэтому чужой объект ему всё равно не
-- подпишут; удалить чужое тоже нельзя — DELETE-политика требует
-- `foldername[2] = auth.uid()`. Но инвариант перестаёт быть инвариантом, а на
-- него уже опирается всё, что выводит автора или группировку поста из
-- storage_path — и каждый следующий потребитель унаследует строку, содержимое
-- которой выбрал клиент.
--
-- Проверка ровно та же, что делает storage-политика на INSERT, только по
-- строке в БД: префикс `posts/<auth.uid()>/`. Не сверяем третий сегмент с
-- `posts.client_token` намеренно — у постов, заведённых до 20260818120000,
-- его нет вовсе, и клиент чеканит для такой правки свежий токен
-- (см. Post.clientToken).
--
-- `like` без экранирования безопасен: в текстовом виде uuid — только hex и
-- дефисы, ни `%`, ни `_` там появиться не может.

-- Сначала убедиться, что живые строки правилу удовлетворяют. Если нет —
-- накат обязан упасть здесь, а не превратиться в PT422 у пользователя,
-- который открыл на редактирование старый пост. Легаси-строки, перенесённые
-- из posts.image_path (20260819220000), под правило подходят: storage-политика
-- на INSERT (20260708172235) с самого начала требовала `posts/<auth.uid()>/…`,
-- так что другого префикса у объектов в бакете просто не бывало.
do $$
declare
  v_bad bigint;
begin
  select count(*) into v_bad
    from public.post_media pm
    join public.posts p on p.id = pm.post_id
   where pm.storage_path not like 'posts/' || p.author_id::text || '/%'
      or (pm.poster_path is not null
          and pm.poster_path not like 'posts/' || p.author_id::text || '/%');

  if v_bad > 0 then
    raise exception
      'post_media: % row(s) sit outside posts/<author_id>/…; fix them before applying this migration',
      v_bad;
  end if;
end
$$;

-- Тело взято из 20260820150000 — миграции, которая трогала set_post_media()
-- последней (см. «Грабли» в CLAUDE.md про `create or replace`), и отличается
-- от неё одним добавленным блоком проверки путей.
create or replace function public.set_post_media(p_post_id uuid, p_items jsonb)
returns table (storage_path text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_removed text[];
  v_prefix text;
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

  -- Ни один путь не должен выходить за собственный префикс автора. То же
  -- условие, что и у storage-политики на INSERT, — просто здесь оно проверяется
  -- для строки в БД, которую `security definer` проносит мимо политики
  -- post_media.
  v_prefix := 'posts/' || auth.uid()::text || '/%';

  if exists (
    select 1
      from jsonb_array_elements(p_items) item
     where coalesce(item.value ->> 'storage_path', '') not like v_prefix
        or (
          nullif(item.value ->> 'poster_path', '') is not null
          and item.value ->> 'poster_path' not like v_prefix
        )
  ) then
    raise exception 'Media path outside your own prefix' using errcode = 'PT422';
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
