-- Публикация поста вместе с его медиа — одной транзакцией.
--
-- До сих пор createPost делал три запроса PostgREST подряд: upsert в `posts`,
-- чтение `id` обратно и upsert в `post_media`. Три запроса — это три
-- транзакции, а `.timeout()` перестаёт ждать, не отменяя запрос (см. заметку
-- на самом createPost). Достаточно первому закоммититься, а второму или
-- третьему не дойти — и пост уже живой в ленте у всех знакомых, пуш
-- «новый пост от X» уже ушёл из enqueue_post_notifications(), а композер
-- показал «не удалось опубликовать».
--
-- purge_empty_posts() (20260822200000) это не ловит и не может: он удаляет
-- посты, у которых `text is null` И нет ни одной строки медиа. Пост с текстом
-- и без фотографий под это условие не подходит — он остаётся навсегда, и
-- остаётся именно в том виде, в котором автор его не публиковал. Ретрай всё
-- лечит, но ретрай зависит от того, нажмёт ли человек «ещё раз» на экране,
-- который только что соврал ему, что ничего не сохранилось.
--
-- Ровно эту форму — «две половины одной записи двумя транзакциями» — уже
-- вычищала 20260820150000 из пути РЕДАКТИРОВАНИЯ, заведя set_post_media().
-- Путь СОЗДАНИЯ она не тронула, хотя разрыв там тот же и последствия хуже:
-- при редактировании обрыв оставлял пост без медиа, тут — публикует пост,
-- которого автор не публиковал.
--
-- Идемпотентность остаётся ровно та же, на которой она стояла: уникальный
-- индекс `(author_id, client_token)` (20260818120000) плюс
-- `(post_id, storage_path)` у post_media. Обе вставки идут через
-- `on conflict do nothing`, так что повторный вызов с тем же токеном — no-op,
-- а не второй пост. Оракулом существования это не становится по той же
-- причине, что и в 20260818120000: `author_id` внутри прибит к `auth.uid()`,
-- значит конфликт возможен только с собственной строкой.
--
-- Проверка префикса путей повторяет set_post_media() (20260822170000) слово в
-- слово и по той же причине: `security definer` проносит эту вставку мимо
-- INSERT-политики post_media, поэтому условие надо проверить самой. Это не
-- третья копия правила — это второй вызов одного и того же условия на втором
-- пути записи, ровно как у 20260822180000 с политикой.
--
-- Старые гранты на прямой INSERT в `posts`/`post_media` НЕ снимаются, хотя
-- клиент ими больше не пользуется. В Play лежат установленные сборки, которые
-- публикуют по-старому; снять грант — значит сломать публикацию у всех, кто
-- ещё не обновился, то есть сделать ровно то, ради предотвращения чего в
-- проекте живёт вся машинерия device_tokens.app_build и
-- enqueue_app_update_notifications(). Убрать их можно будет, когда
-- `select min(app_build) from device_tokens` перевалит за сборку с этой
-- функцией.

create or replace function public.create_post_with_media(
  p_client_token uuid,
  p_text text default null,
  p_items jsonb default '[]'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_post_id uuid;
  v_prefix text;
  v_text text;
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
  -- ретрай и пост уже вставлен предыдущей попыткой. Читаем его id и
  -- доливаем медиа, которых могло не хватить.
  if v_post_id is null then
    select id into v_post_id
      from posts
     where author_id = auth.uid() and client_token = p_client_token;

    if v_post_id is null then
      raise exception 'Post not found' using errcode = 'PT404';
    end if;
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

  return v_post_id;
end;
$$;

-- Оба аргумента про самого вызывающего: author_id внутри всегда auth.uid(),
-- client_token сравнивается только с собственными строками. См. «Каждая
-- функция в public — эндпоинт PostgREST» в CLAUDE.md.
revoke execute on function public.create_post_with_media(uuid, text, jsonb) from public, anon;
grant execute on function public.create_post_with_media(uuid, text, jsonb) to authenticated;
