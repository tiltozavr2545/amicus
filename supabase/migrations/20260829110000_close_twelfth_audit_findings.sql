-- =====================================================================
-- Двенадцатый полный аудит: серверная половина.
--
-- Ложится поверх 20260829100000_post_visibility.sql. Тела обеих
-- пересоздаваемых ниже функций взяты из `prosrc` ЖИВОЙ схемы и сверены с
-- миграциями, которые трогали их последними (20260828120000 обе), — они
-- совпали построчно, так что источник здесь схема, а не память
-- (см. «`create or replace` переписывает ВСЁ тело» в CLAUDE.md).
--
-- Три находки:
--   1. мёртвый грант публиковал /rpc/is_favorited_by — ручку, отвечающую на
--      вопрос о ЧУЖОМ избранном;
--   2. сборщик сирот не знал префикс `rooms/`, и аватарка удалённой комнаты
--      оставалась в бакете навсегда;
--   3. у `room_messages.media` не было потолка размера — единственная
--      клиентская колонка проекта без него, и единственная, которая
--      рассылается всем участникам через realtime.
--
-- ЧЕГО ЗДЕСЬ НЕТ. Четвёртая находка того же аудита — «кнопка „позвать“
-- возвращается после отказа и всегда отвечает PT409» — целиком клиентская:
-- сервер ведёт себя ровно так, как задумано (`connection_requests_pair_key`
-- не даёт просить дважды в одну сторону), а неправильно вело себя
-- приложение, которое читало только заявки со статусом `pending`. Правка в
-- app/lib, схема не меняется.
-- =====================================================================


-- =====================================================================
-- 1. Мёртвый грант на is_favorited_by()
-- =====================================================================
-- Тот же класс находки, что и `is_author_visible()` в 20260826120000, но с
-- обратным знаком: там грант был лишним и безобидным, здесь — лишним и нет.
--
-- Лишний он потому, что единственный вызывающий у функции один —
-- `is_post_visible()`, а она сама `security definer` и никому не выдана:
-- внутри неё вызов исполняется правами владельца, которому грант не нужен.
-- Проверено запросом к `prosrc` по всей схеме, других вызывающих нет.
-- Некоррелированное множество для политики — это `authors_who_favorited_me()`,
-- и грант нужен ЕЙ, а не этой (см. пункт ниже).
--
-- А небезобидный потому, что каждая функция в `public` — эндпоинт PostgREST
-- (CLAUDE.md, «Грабли»), и этот отвечал на вопрос
-- «держит ли p_author меня в избранном» про ЛЮБОГО p_author. Правило проекта
-- («выдавать, только если каждый аргумент про самого вызывающего») формально
-- соблюдалось — ответ и правда только про пару «он и я», — но `favorite_users`
-- закрыта RLS до строк одного владельца именно затем, чтобы этот бит не был
-- доступен второй стороне. `security definer` проносил запрос мимо той самой
-- политики, ради которой он там стоит.
revoke execute on function public.is_favorited_by(p_author uuid) from authenticated;

-- `authors_who_favorited_me()` грант СОХРАНЯЕТ и не может его потерять:
-- SELECT-политика `posts` вычисляется правами читающего, а функция стоит в
-- ней некоррелированным `IN (SELECT …)` — то есть построчный вызов вместо неё
-- вернул бы регрессию 20260726180000 (217 мс против 3.5 мс на ленте).
--
-- Отсюда следствие, которое 20260829100000 назвала неверно, и это стоит
-- записать здесь, а не молча: её шапка (и docs/data-model.md следом)
-- утверждала, что «узнать, что ты у кого-то в избранном, по-прежнему
-- нельзя». После неё — можно: `select * from authors_who_favorited_me()` без
-- аргументов перечисляет всех, кто добавил вызывающего к себе. Это цена
-- аудитории «только избранные», а не оплошность реализации: обратной
-- совместимости с прежней приватностью у этой фичи быть не может, пока
-- список решает, что человек увидит. Меняется формулировка инварианта, не
-- код; docs/data-model.md приведён в соответствие.


-- =====================================================================
-- 2. Сборщик сирот: префикс `rooms/`
-- =====================================================================
-- 20260828120000 научила `orphaned_media_paths()` префиксу `messages/` и
-- рассуждала ровно про этот риск — «раньше сборщик знал только `posts/` и
-- `avatars/`, поэтому брошенное вложение не подобрал бы никто и никогда», —
-- но `rooms/`, заведённый на два дня раньше (20260826210000), в тот перечень
-- не попал.
--
-- Для аватарки комнаты это хуже, чем для вложения, потому что она не просто
-- не собирается, а становится НЕДОСТИЖИМОЙ. Обе storage-политики префикса
-- считают право через `owns_room()`, то есть через `room_owner_id()`, то есть
-- через строку в `room_members`. Комната пустеет — `cleanup_orphaned_room()`
-- сносит `rooms`, каскад уносит `room_members`, `room_owner_id()` начинает
-- отдавать NULL, и `NULL = auth.uid()` не истинно ни для кого: объект нельзя
-- ни прочитать, ни удалить, и до сих пор его некому было и найти.
--
-- Второй путь в ту же точку — замена аватарки: `set_room_avatar()` возвращает
-- осиротевший путь, а сносит объект клиент, best-effort
-- (`deleteRowsThenObjects`). Не дошло — и файл остался тем же вечным мусором,
-- только комната при этом жива. Про такие вызовы CLAUDE.md говорит прямо:
-- спрашивать надо не «вызывает ли кто-то очистку», а «что будет, если этот
-- вызов не состоится ни разу».
--
-- Ветвь третья и по форме своя, потому что свой и вопрос «на этот файл ещё
-- кто-нибудь ссылается»: у поста это строки `post_media`, у сообщения — jsonb
-- внутри `room_messages`, у комнаты — одна колонка `rooms.avatar_path`.
-- Проверять существование самой комнаты отдельно не надо: если её нет, нет и
-- строки, которая могла бы сослаться, — то есть объект сирота, чего мы и
-- добиваемся. Общий порог в сутки защищает свежую заливку, чей
-- `set_room_avatar()` ещё не доехал, — та же роль, что и у двух других ветвей.
CREATE OR REPLACE FUNCTION public.orphaned_media_paths()
 RETURNS SETOF text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select o.name
    from storage.objects o
   where o.bucket_id = 'media'
     and o.created_at < now() - interval '24 hours'
     and (
       (
         (storage.foldername(o.name))[1] in ('posts', 'avatars')
         and (storage.foldername(o.name))[2] ~
             '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         and not exists (
           select 1 from post_media m
            where m.storage_path = o.name or m.poster_path = o.name
         )
         and not exists (
           select 1 from profile_photos p where p.storage_path = o.name
         )
         -- Избыточно, пока sync_avatar_path_from_profile_photos() держит колонку в
         -- синхроне с profile_photos, — но именно на эту колонку смотрит весь
         -- остальной клиент, и она переживала уже одну миграцию формата
         -- (20260820100000). Проверить её стоит один exists.
         and not exists (
           select 1 from users u where u.avatar_path = o.name
         )
       )
       or (
         (storage.foldername(o.name))[1] = 'messages'
         and (storage.foldername(o.name))[2] ~
             '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         and not exists (
           select 1
             from room_messages m,
                  lateral jsonb_array_elements(m.media) item
            where m.room_id::text = (storage.foldername(o.name))[2]
              and (item.value ->> 'storage_path' = o.name
                   or item.value ->> 'poster_path' = o.name)
         )
       )
       or (
         -- Аватарка комнаты (20260826210000). Ссылка на неё ровно одна —
         -- `rooms.avatar_path`, и CHECK `rooms_avatar_shape` гарантирует, что
         -- живой путь всегда лежит под префиксом СВОЕЙ комнаты, поэтому
         -- сравнения с колонкой достаточно и лишний join к `rooms` по id из
         -- пути ничего бы не добавил.
         (storage.foldername(o.name))[1] = 'rooms'
         and (storage.foldername(o.name))[2] ~
             '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         and not exists (
           select 1 from rooms r where r.avatar_path = o.name
         )
       )
     )
   order by o.name
   limit 100;
$function$;


-- =====================================================================
-- 3. Потолок размера у room_messages.media
-- =====================================================================
-- `room_messages_media_shape` ограничивала ЧИСЛО элементов (10) и префикс
-- каждого пути, но не длину самих строк и не объём jsonb целиком. Между тем
-- это единственная в схеме клиентская колонка без потолка: `posts.text`,
-- `comments.text` и `room_messages.text` — по 5000, `users.name` — 100,
-- `rooms.name` — 100. И единственная, которая уезжает не в ответ на запрос, а
-- сама, всем участникам комнаты сразу: `room_messages` лежит в публикации
-- realtime (20260826200000), и подписчик получает СТРОКУ.
--
-- То есть участник с правленым клиентом мог сложить десять путей, каждый из
-- которых начинается с законного префикса и продолжается мегабайтом набивки,
-- и разослать это всем в комнате одной отправкой, повторяя сколько угодно.
-- Ни одна проверка на пути записи такую строку не отвергала.
--
-- Числа с запасом ровно вдвое, а не «на глаз». Самый длинный ЗАКОННЫЙ путь —
-- `messages/<uuid>/<uuid>/<uuid>/<uuid>.<ext>`, где ext клиент обрезает до
-- пяти символов (`fileExtension()`): 9 + 37 + 37 + 37 + 41 = 161 символ, у
-- постера (`<uuid>_poster.jpg`) — 168. Десять элементов со всеми тремя полями
-- дают около 3970 байт jsonb. Потолки 400 на путь и 8000 на всю колонку
-- пропускают это с двойным запасом и при этом остаются жёсткой границей.
--
-- `not valid` не нужен и невозможен: ограничение уже стоит, меняется только
-- тело функции, которую оно зовёт, а `create or replace` существующие строки
-- не перепроверяет. Живых строк с медиа на момент наката нет вовсе
-- (`max(length(media::text)) = 2`, то есть везде `[]`), так что расхождения
-- между старой и новой трактовкой ограничения не возникает даже теоретически.
CREATE OR REPLACE FUNCTION public.room_message_media_ok(p_room_id uuid, p_author_id uuid, p_media jsonb)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select jsonb_typeof(p_media) = 'array'
     and jsonb_array_length(p_media) <= 10
     -- Потолок на колонку целиком: десять законных вложений с постерами — это
     -- около 3970 байт, всё сверх восьми тысяч не бывает следствием отправки,
     -- сделанной этим приложением.
     and length(p_media::text) <= 8000
     and not exists (
       select 1
         from jsonb_array_elements(p_media) item
        where (item.value ->> 'media_type') is distinct from 'image'
              and (item.value ->> 'media_type') is distinct from 'video'
           or coalesce(item.value ->> 'storage_path', '') not like
              ('messages/' || p_room_id::text || '/' || p_author_id::text || '/%')
           or (
             nullif(item.value ->> 'poster_path', '') is not null
             and (item.value ->> 'poster_path') not like
                 ('messages/' || p_room_id::text || '/' || p_author_id::text || '/%')
           )
           -- И на каждый путь по отдельности. Потолок выше уже ограничивает
           -- сумму, но именно эти строки уходят в `createSignedUrls` и в
           -- `storage.remove()`, а там длина одного элемента — своя величина.
           or char_length(coalesce(item.value ->> 'storage_path', '')) > 400
           or char_length(coalesce(item.value ->> 'poster_path', '')) > 400
     );
$function$;


-- =====================================================================
-- 4. Проверки после наката
-- =====================================================================
-- Не «применилось ли», а «то ли применилось»: у обеих пересозданных функций
-- `prosrc` проверяется на признаки И нового, И старого тела — `create or
-- replace` переписывает всё целиком, и пересоздание из более раннего текста
-- уже дважды выключало в этом проекте целую фичу (см. «Грабли» в CLAUDE.md).
do $$
declare
  v_src text;
begin
  -- (1) Грант снят у `authenticated` — и только у него: внутренний вызов из
  -- `is_post_visible()` идёт правами владельца и ломаться не должен.
  if has_function_privilege('authenticated', 'public.is_favorited_by(uuid)', 'execute') then
    raise exception 'is_favorited_by() всё ещё выдана authenticated';
  end if;
  if not has_function_privilege('postgres', 'public.is_favorited_by(uuid)', 'execute') then
    raise exception 'is_favorited_by() потеряла право исполнения у владельца';
  end if;

  -- Парная ей функция грант СОХРАНЯЕТ: без него SELECT-политика posts
  -- отказывает читателю на каждой строке, то есть лента пустеет у всех.
  if not has_function_privilege('authenticated', 'public.authors_who_favorited_me()', 'execute') then
    raise exception 'authors_who_favorited_me() потеряла грант — лента выключена';
  end if;

  -- (2) Сборщик знает все три префикса, а не только новый.
  select prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'orphaned_media_paths';
  if v_src not ilike '%''rooms''%' then
    raise exception 'orphaned_media_paths() не знает про rooms/';
  end if;
  if v_src not ilike '%''messages''%' or v_src not ilike '%''posts'', ''avatars''%' then
    raise exception 'orphaned_media_paths() пересоздана из неполного тела';
  end if;
  if v_src not ilike '%limit 100%' then
    raise exception 'orphaned_media_paths() потеряла ограничение размера батча';
  end if;

  -- (3) Потолки на месте, а прежние проверки формы никуда не делись.
  select prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'room_message_media_ok';
  if v_src not ilike '%length(p_media::text) <= 8000%'
     or v_src not ilike '%> 400%' then
    raise exception 'room_message_media_ok() не знает про потолки размера';
  end if;
  if v_src not ilike '%jsonb_array_length(p_media) <= 10%'
     or v_src not ilike '%messages/%' then
    raise exception 'room_message_media_ok() пересоздана из неполного тела';
  end if;

  -- Ограничение по-прежнему стоит на таблице и зовёт именно эту функцию:
  -- `create or replace` зависимость не рвёт, но проверить это дешевле, чем
  -- узнать о разрыве от первой отправки с вложением.
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.room_messages'::regclass
       and conname = 'room_messages_media_shape'
  ) then
    raise exception 'room_messages_media_shape пропало с таблицы';
  end if;
end;
$$;

-- Функциональная проверка обоих потолков — на значениях, а не на тексте тела.
-- `p_media` тут не связан ни с одной строкой: функция чистая и к таблицам не
-- ходит, поэтому её можно спросить напрямую.
do $$
declare
  v_room uuid := '00000000-0000-0000-0000-000000000001';
  v_author uuid := '00000000-0000-0000-0000-000000000002';
  v_prefix text := 'messages/00000000-0000-0000-0000-000000000001/00000000-0000-0000-0000-000000000002/';
  -- Путь ровно в 400 символов: он проходит поэлементный потолок впритык, и
  -- потому изолирует второй потолок — набивку, размазанную по десяти
  -- элементам так, что каждый по отдельности законен.
  v_at_limit text := v_prefix || repeat('x', 400 - char_length(v_prefix) - 4) || '.jpg';
  v_padded jsonb;
begin
  if char_length(v_at_limit) <> 400 then
    raise exception 'проверка собрана неверно: путь не 400 символов';
  end if;

  -- Законная отправка проходит.
  if not public.room_message_media_ok(v_room, v_author, jsonb_build_array(
       jsonb_build_object('media_type', 'image', 'storage_path', v_prefix || 'a/b.jpg')
     )) then
    raise exception 'room_message_media_ok() отвергает законное вложение';
  end if;

  -- Путь длиннее 400 под законным префиксом — нет.
  if public.room_message_media_ok(v_room, v_author, jsonb_build_array(
       jsonb_build_object('media_type', 'image',
                          'storage_path', v_prefix || repeat('x', 500) || '.jpg')
     )) then
    raise exception 'room_message_media_ok() принимает путь длиннее 400';
  end if;

  -- Десять элементов, каждый из двух путей по 400, — около 8.6 КБ. Каждый
  -- путь по отдельности законен, отбивает именно потолок на колонку.
  select jsonb_agg(jsonb_build_object(
           'media_type', 'video',
           'storage_path', v_at_limit,
           'poster_path', v_at_limit))
    into v_padded
    from generate_series(1, 10);

  if length(v_padded::text) <= 8000 then
    raise exception 'проверка собрана неверно: набивка вышла меньше потолка (%)',
      length(v_padded::text);
  end if;
  if public.room_message_media_ok(v_room, v_author, v_padded) then
    raise exception 'room_message_media_ok() принимает колонку больше 8000 байт';
  end if;
end;
$$;
