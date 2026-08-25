-- Ветка перезаписи в `create_post_with_media()` начинает отдавать пути
-- объектов, на которые после неё никто не ссылается.
--
-- С 20260824100000 повторная отправка с тем же `client_token` не no-op, а
-- перезапись: набор медиа сносится целиком и вставляется тот, что прислали.
-- Отдать наружу список выбывших она при этом забыла, а `createPost`
-- (feed_repository.dart) возвращает `void` и ничего не чистит. Между тем
-- ровно этот сценарий — не редкость, а штатный путь, ради которого
-- переписываемый токен и заводили: `.timeout()` перестаёт ждать, не отменяя
-- запрос, публикация коммитится уже после того, как композер показал «не
-- удалось опубликовать», автор убирает одну фотографию и жмёт «Опубликовать»
-- ещё раз. Строка `post_media` для убранного файла исчезает, объект в бакете
-- остаётся, и назвать его больше некому.
--
-- `update_post_with_media()` (20260824120000) на своей половине это делает —
-- возвращает `table (storage_path text)`, а клиент прогоняет уборку через
-- [deleteRowsThenObjects]. Здесь была вторая половина того же правила, и она
-- отставала.
--
-- Сутки такой объект живёт в любом случае: `reap_orphaned_media()`
-- (20260823110000) забирает только то, что старше 24 часов, и не больше 100
-- объектов за запуск. Это последний рубеж на случай, когда клиент до уборки
-- не дожил, а не первый — и для клипа на 100 МБ, который автор убрал из
-- черновика секунду назад, разница между «сейчас» и «завтра, если очередь
-- дойдёт» вполне ощутима.
--
-- Тип возврата меняется с `uuid` на таблицу, поэтому `create or replace` тут
-- недостаточно — нужен drop. Прежний `uuid` (id поста) не читал никто:
-- `createPost` игнорировал результат, других вызовов у функции нет. Гранты
-- drop уносит с собой, ниже они выставляются заново.

drop function if exists public.create_post_with_media(uuid, text, jsonb);

create function public.create_post_with_media(
  p_client_token uuid,
  p_text text default null,
  p_items jsonb default '[]'::jsonb
)
returns table (storage_path text)
language plpgsql
security definer
set search_path = public
as $$
-- `returns table (storage_path text)` заводит OUT-параметр `storage_path`, а
-- он для plpgsql — переменная, видимая во всём теле. Ниже есть
-- `on conflict (post_id, storage_path)`, и цель конфликта обязана быть голым
-- ИМЕНЕМ КОЛОНКИ: квалифицировать её нельзя синтаксически, а неквалифицированная
-- натыкается на переменную и падает с 42702 «column reference is ambiguous».
-- Директива разрешает такие столкновения в пользу колонки — то, что здесь нужно
-- везде: сама переменная не читается ни разу, наружу список уходит через
-- `return query`. `set_post_media()` с той же сигнатурой живёт без директивы
-- только потому, что не пишет `storage_path` без префикса таблицы ни в одном
-- месте; полагаться на это в функции, которую ещё будут править, не стоит.
#variable_conflict use_column
declare
  v_post_id uuid;
  v_prefix text;
  v_text text;
  v_removed text[];
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if p_client_token is null then
    raise exception 'client_token is required' using errcode = 'PT422';
  end if;

  if jsonb_typeof(p_items) <> 'array' then
    raise exception 'Media list must be an array' using errcode = 'PT422';
  end if;

  if jsonb_array_length(p_items) > 20 then
    raise exception 'post_media_limit_exceeded' using errcode = 'P0001';
  end if;

  -- Тот же nullif(btrim(...)) что и в posts_text_not_blank (20260822200000):
  -- пустая строка от клиента — это отсутствие текста, а не текст.
  v_text := nullif(btrim(coalesce(p_text, '')), '');

  -- Условие, которое синхронным CHECK'ом выразить было нельзя, пока пост и его
  -- медиа приезжали разными транзакциями (см. data-model.md). Теперь они
  -- приезжают одной, и проверить его наконец можно здесь, а не через час
  -- кроном.
  if v_text is null and jsonb_array_length(p_items) = 0 then
    raise exception 'A post needs text or media' using errcode = 'PT422';
  end if;

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

  insert into posts (author_id, text, client_token)
  values (auth.uid(), v_text, p_client_token)
  on conflict (author_id, client_token) do nothing
  returning id into v_post_id;

  -- `do nothing` не возвращает строку, когда конфликт случился, — значит это
  -- ретрай и пост уже вставлен предыдущей попыткой. Читаем его id и приводим
  -- пост к присланному состоянию: содержимое отправки определяет последний
  -- вызов с этим токеном, а не первый.
  if v_post_id is null then
    select id into v_post_id
      from posts
     where author_id = auth.uid() and client_token = p_client_token;

    if v_post_id is null then
      raise exception 'Post not found' using errcode = 'PT404';
    end if;

    update posts
       set text = v_text
     where id = v_post_id
       and text is distinct from v_text;

    -- Считается ДО `delete`: после него строки уже не спросишь. Ровно та же
    -- выборка, что и в `set_post_media()` — выбывшим считается медиа, чей
    -- `storage_path` не пришёл в этот раз, и вместе с ним уходит его постер.
    select array_agg(path) into v_removed
      from (
        select pm.storage_path as path
          from post_media pm
         where pm.post_id = v_post_id
           and not exists (
             select 1 from jsonb_array_elements(p_items) item
              where item ->> 'storage_path' = pm.storage_path
           )
        union all
        select pm.poster_path
          from post_media pm
         where pm.post_id = v_post_id
           and pm.poster_path is not null
           and not exists (
             select 1 from jsonb_array_elements(p_items) item
              where item ->> 'storage_path' = pm.storage_path
           )
      ) gone;

    -- Набор медиа переписывается целиком, а не доливается: см. заголовок
    -- 20260824100000. `position` ниже раздаётся по порядку массива, поэтому
    -- старые строки обязаны уйти, иначе `on conflict do nothing` оставит им
    -- прежние места.
    delete from post_media where post_id = v_post_id;
  end if;

  insert into post_media (post_id, position, media_type, storage_path, poster_path)
  select
    v_post_id,
    (item.idx - 1)::smallint,
    item.value ->> 'media_type',
    item.value ->> 'storage_path',
    nullif(item.value ->> 'poster_path', '')
  from jsonb_array_elements(p_items) with ordinality as item(value, idx)
  on conflict (post_id, storage_path) do nothing;

  -- На первой публикации сносить нечего, и функция возвращает ноль строк —
  -- клиенту это читается как пустой список, а не как ошибка.
  return query select unnest(coalesce(v_removed, array[]::text[]));
end;
$$;

revoke execute on function public.create_post_with_media(uuid, text, jsonb) from public, anon;
grant execute on function public.create_post_with_media(uuid, text, jsonb) to authenticated;
