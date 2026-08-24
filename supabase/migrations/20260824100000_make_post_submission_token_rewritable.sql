-- Повторная отправка с тем же `client_token` перестаёт быть no-op и приводит
-- пост к тому состоянию, которое прислали.
--
-- Идемпотентность на `(author_id, client_token)` (20260818120000) закрывала
-- ровно один сценарий: «ретрай ТОГО ЖЕ содержимого не должен создать второй
-- пост». Композер поэтому чеканил токен не на сессию, а на КОНТЕНТ — при любой
-- правке текста или списка медиа `_pendingFingerprint` менялся и токен
-- чеканился заново (create_post_screen.dart). Иначе сервер молча оставил бы
-- старую версию, а экран закрылся бы как будто сохранил новую.
--
-- У этого выбора есть обратная сторона, и она хуже того, от чего он защищал.
-- `.timeout()` перестаёт ждать, не отменяя запрос, поэтому `create_post_with_media`
-- регулярно коммитится ПОСЛЕ того, как композер показал «не удалось
-- опубликовать»: пост уже живой в ленте у всех знакомых, пуш «новый пост от X»
-- уже ушёл из enqueue_post_notifications(). Композер при этом остаётся открытым
-- с черновиком, и человек делает единственное разумное — правит опечатку или
-- убирает лишнюю фотографию и жмёт «Опубликовать» ещё раз. Отпечаток изменился,
-- значит токен новый, значит уникальный индекс больше ни с чем не совпадает —
-- и вставляется ВТОРОЙ пост, со вторым пушем на каждого знакомого. Первый,
-- который автор считает неопубликованным, остаётся висеть.
--
-- Починка — не в клиенте. Требовать от клиента «сначала выясни, не долетела ли
-- прошлая попытка» значит завести на горячем пути лишний round trip и вторую
-- копию правила о том, что считать одной и той же отправкой. Правило принадлежит
-- функции: один `client_token` — одна публикация, и её содержимое — то, что
-- прислали последним. Тогда клиенту достаточно чеканить токен один раз за
-- сессию композера и не думать про отпечатки вовсе.
--
-- Что делает ветка ретрая теперь: доводит текст и переписывает набор медиа
-- целиком, ровно как set_post_media() (20260822170000). Переписывает, а не
-- «доливает недостающие», и это не перестраховка — `on conflict (post_id,
-- storage_path) do nothing` сохраняет СТАРУЮ `position` у уже существующей
-- строки, так что перестановка слайдов между попытками молча не применялась бы,
-- а удаление слайда оставляло бы его в посте.
--
-- ЧЕГО ЭТО НЕ ДЕЛАЕТ. Функция не становится вторым путём редактирования: токен
-- живёт ровно столько, сколько открыт композер, наружу не отдаётся и
-- предъявляется вместе с `author_id = auth.uid()`, поэтому переписать через неё
-- можно только собственный пост собственной незакрытой сессии. Экран правки
-- по-прежнему ходит в set_post_media().
--
-- Объекты удалённых на ретрае медиа остаются в бакете сиротами — их заберёт
-- reap_orphaned_media() (20260823110000) через сутки. Это та же цена, что уже
-- платит любой брошенный черновик, и та же сторона правила
-- app/lib/shared/delete_order.dart: строка, ссылающаяся на удалённый объект,
-- хуже байтов, на которые никто не ссылается.
--
-- Сборкам в Play эта правка не видна: `create_post_with_media()` появилась в
-- 20260823120000 и зовёт её только build 42, которого в Play ещё нет
-- (`select min(app_build) from device_tokens` = 41). Build 41 публикует старой
-- тройкой запросов и живёт со своим дубликатом до обновления — починить это в
-- уже установленном APK нечем.
--
-- Тело взято из 20260823120000 — миграции, которая трогала эту функцию
-- последней (см. «Грабли» в CLAUDE.md про `create or replace`; сверено с
-- `prosrc` живой базы перед накатом, расхождений нет) — и отличается от неё
-- одним блоком в ветке `v_post_id is null`.

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

    -- Набор медиа переписывается целиком, а не доливается: см. заголовок.
    -- `position` ниже раздаётся по порядку массива, поэтому старые строки
    -- обязаны уйти, иначе `on conflict do nothing` оставит им прежние места.
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

  return v_post_id;
end;
$$;

-- Грант не меняется — сигнатура та же, оба аргумента по-прежнему про самого
-- вызывающего. Повторён здесь только чтобы `create or replace` не оставил
-- функцию с дефолтным `execute to public`, если её когда-нибудь пересоздадут с
-- нуля по этому файлу.
revoke execute on function public.create_post_with_media(uuid, text, jsonb) from public, anon;
grant execute on function public.create_post_with_media(uuid, text, jsonb) to authenticated;
