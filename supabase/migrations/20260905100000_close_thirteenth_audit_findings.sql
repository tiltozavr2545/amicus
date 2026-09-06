-- =====================================================================
-- Тринадцатый полный аудит: серверная половина.
--
-- Ложится поверх 20260829130000_mute_is_a_feed_filter.sql. Тела всех пяти
-- пересоздаваемых ниже функций взяты из `prosrc` ЖИВОЙ схемы и сверены с
-- миграциями, которые трогали их последними (20260826180000 — три RPC
-- комнаты, 20260826210000 — `set_room_avatar()`, 20260829100000 —
-- `create_post_with_media()`); все пять совпали построчно, так что источник
-- здесь схема, а не память (см. «`create or replace` переписывает ВСЁ тело»
-- в CLAUDE.md).
--
-- Пять находок:
--   1. storage-политика `avatars/` отдавала соседу по комнате ВЕСЬ префикс
--      пользователя, то есть всю галерею профиля, которую RLS на
--      `profile_photos` показывает только Connections;
--   2. мёртвый грант публиковал /rpc/set_post_media — единственный
--      оставшийся путь записи мимо инварианта «текст или медиа»;
--   3. ретрай публикации, СУЖАЮЩИЙ аудиторию, не отзывал уже поставленные в
--      очередь пуши о посте;
--   4. четыре RPC комнаты отвечали PT404 на несуществующую комнату и PT403
--      на чужую — оракул существования по любому uuid;
--   5. лишний поколоночный грант `select (visibility)` на `posts`.
--
-- ЧЕГО ЗДЕСЬ НЕТ. Две находки того же аудита целиком клиентские и в схеме
-- ничего не меняют: (а) `ConnectionRequest.fromRow` кастовал вложенный
-- `users` к non-nullable и ронял весь список заявок, когда пара переставала
-- делить комнату; (б) три экрана звали `ref` после `await` до проверки
-- `mounted`. Обе правки — в `app/lib`.
--
-- `purge_empty_posts()` и его крон НЕ снимаются вместе с грантом из пункта 2:
-- прямой INSERT в `posts` у `authenticated` остаётся (колонки
-- `author_id, client_token, created_at, text`), то есть пост без текста и без
-- медиа всё ещё может приехать мимо RPC. Крон был заведён шире, чем под одну
-- эту функцию, и остаётся нужен.
-- =====================================================================


-- =====================================================================
-- 1. Аватарка соседа по комнате — это ОДИН объект, а не весь префикс
-- =====================================================================
-- 20260826180000 добавила в SELECT-политику `avatars/` ветвь
-- `shares_room_with_caller(foldername[2]::uuid)`, чтобы у соседа по комнате
-- не было пустого кружка в списке участников. Ветвь получилась
-- ПРЕФИКСНОЙ — она отвечает «да» про любой объект под `avatars/<uid>/`, а
-- там лежит вся галерея профиля, до 80 фотографий.
--
-- RLS на `profile_photos` при этом соседа по комнате не пускает вовсе
-- (`user_id = auth.uid() or is_system_account(...) or
-- is_connected_to_caller(...)` — ветви комнаты там нет и не задумывалось).
-- То есть строки галереи скрыты, а байты — нет: `storage.list('avatars/<uid>')`
-- проходит ту же SELECT-политику и перечисляет соседу по комнате все объекты,
-- после чего каждый можно подписать и скачать. Комната задумывалась как
-- «видите имена и лица друг друга», а не как доступ к чужому альбому.
--
-- Ровно эту же ошибку — префикс вместо объекта — 20260826190000 уже
-- исправляла у `posts/`: там политика перестала идти от пути к автору и
-- пошла от пути к ПОСТУ (`post_media_path_visible()`). У `avatars/` грубая
-- форма осталась, потому что до комнат обе ветви (своё и Connection) были
-- эквивалентны построчной проверке: Connection и так видит всю галерею по
-- политике `profile_photos`. Сосед по комнате — не видит, и именно на нём
-- префиксная форма стала шире, чем правило, которое она изображает.
--
-- Ветви «своё», «системный аккаунт» и «Connection» остаются префиксными и
-- остаются правильными: у первых двух это тавтология, у третьей — то же
-- самое, что уже разрешает `profile_photos`.

-- Один аргумент, вторая сторона всегда `auth.uid()` — то же правило, по
-- которому выданы `shares_room_with_caller()` и `owns_room()`: для чужой
-- пары функция всегда false, чужого вопроса через неё не задать.
--
-- `security definer` здесь не ради `users` (её SELECT-политика соседа по
-- комнате как раз пускает — `shares_room_with_caller(id)` в ней есть), а
-- ради того, чтобы ответ не зависел от того, какие политики стоят на `users`
-- завтра: политика storage не должна молча сузиться от правки в соседней
-- таблице. Тот же мотив, что у всего паттерна `security definer` в проекте.
CREATE OR REPLACE FUNCTION public.is_room_peer_avatar(p_path text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
      from users u
     where u.avatar_path = p_path
       and public.shares_room_with_caller(u.id)
  );
$function$;

-- `users.avatar_path` спрашивают теперь на каждый объект в листинге, а не
-- один раз в сутки из `orphaned_media_paths()`. Индекс частичный: NULL в
-- этой колонке у большинства строк, и искать по нему нечего.
create index if not exists users_avatar_path_idx
  on public.users using btree (avatar_path)
  where avatar_path is not null;

drop policy "Avatars are viewable by the user, connections and room peers" on storage.objects;

create policy "Avatars are viewable by the user, connections and room peers"
  on storage.objects
  for select
  to authenticated
  using (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'avatars'::text) AND (((storage.foldername(name))[2] = (auth.uid())::text) OR ((storage.foldername(name))[2] IN ( SELECT (s.s)::text AS s
   FROM system_account_ids() s(s))) OR (EXISTS ( SELECT 1
   FROM connections c
  WHERE (((c.user_a_id = auth.uid()) AND ((c.user_b_id)::text = (storage.foldername(objects.name))[2])) OR ((c.user_b_id = auth.uid()) AND ((c.user_a_id)::text = (storage.foldername(objects.name))[2]))))) OR public.is_room_peer_avatar(name))));

revoke execute on function public.is_room_peer_avatar(p_path text) from public, anon, authenticated;
grant execute on function public.is_room_peer_avatar(p_path text) to authenticated;


-- =====================================================================
-- 2. Мёртвый грант на set_post_media()
-- =====================================================================
-- Третья находка этого класса подряд (`is_author_visible()` в 20260826120000,
-- `is_favorited_by()` в 20260829110000), и самая дорогая из трёх.
--
-- Грант держался ради клиента build 41: «убрать можно будет, когда
-- `min(app_build)` перевалит за 42» (baseline, комментарий над функцией). Это
-- условие давно выполнено с другой стороны — 20260828100000 дропнула
-- `posts.in_general_feed` и сменила сигнатуру `create_post_with_media()`,
-- то есть выключила ленту и публикацию у всех сборок 46 и ниже; ждать
-- отдельно build 42 больше нечего. В `app/lib` вызывающих нет: `updatePost()`
-- ходит через `update_post_with_media()`, а та зовёт `set_post_media()`
-- ИЗНУТРИ `security definer`, правами владельца, где грант не нужен.
--
-- Безобидным этот грант не был. `update_post_with_media()` проверяет «пост
-- не может остаться без текста и без медиа» — а `set_post_media()`, которую
-- она оборачивает, не проверяет: это её половина работы, вторую половину
-- (текст) она не видит. Вызов `/rpc/set_post_media` с `p_items: []` по
-- собственному посту без текста оставлял пустой пост живым в ленте у всех
-- знакомых до ближайшего `purge_empty_posts()` — до часа.
--
-- Сама функция остаётся: она единственное место, где записано правило
-- «какие пути осиротели», и `update_post_with_media()` на неё опирается.
revoke execute on function public.set_post_media(p_post_id uuid, p_items jsonb) from authenticated;


-- =====================================================================
-- 3. Ретрай, сужающий аудиторию, отзывает свои пуши
-- =====================================================================
-- ВНИМАНИЕ. Тело ниже взято из `prosrc` живой схемы (её последней трогала
-- 20260829100000) и изменено ровно в одном месте — врезка в ветку ретрая,
-- сразу после `update posts`. Всё остальное построчно то же самое. После
-- наката проверять не «применилось ли», а `prosrc` на признаки старого тела
-- (см. «Грабли» в CLAUDE.md).
--
-- ЧТО БЫЛО. `enqueue_post_notifications()` — AFTER INSERT, и только INSERT.
-- Публикация с аудиторией «всем знакомым» коммитится, триггер раскладывает
-- `new_post` по тем, у кого автор в избранном. `.timeout()` при этом
-- перестаёт ждать, не отменяя запрос, так что композер показывает ошибку и
-- остаётся открытым — с живым `_submissionToken` и всё ещё редактируемым
-- переключателем аудитории. Автор переключает на «только избранным» и жмёт
-- «опубликовать» ещё раз: ретрай попадает в ветку `on conflict` и делает
-- `update posts set visibility = 'favorites'` — БЕЗ триггера. Пуш «у Пети
-- новый пост» уже лежит в очереди у того, кто держит автора в избранном, но
-- сам в избранное автора не входит, — то есть у того, кому пост не покажут.
-- Ровно та утечка, ради которой 20260829100000 завела фильтр по видимости в
-- самом триггере.
--
-- ЧТО СТАЛО. Ретрай, оставляющий пост «только избранным», убирает из очереди
-- ещё не ушедшие `new_post` про ЭТОТ пост у всех, кого в избранном автора
-- нет. Не «отменяет уведомление», а приводит очередь к тому состоянию, в
-- котором её оставил бы триггер, если бы знал финальную аудиторию.
--
-- Три границы этого фикса, названные вслух:
--   * УЖЕ ОТПРАВЛЕННОЕ (`sent_at is not null`) не трогаем — отозвать пуш
--     нельзя, и удалять журнальную строку об этом бессмысленно;
--   * `digest` не трогаем вовсе: он не называет пост, а считает их
--     («в ленте N новых постов»), так что раскрыть существование конкретного
--     поста он не может. Сузившаяся аудитория делает его число завышенным на
--     единицу — это неточность, а не утечка;
--   * обратный ход (ретрай РАСШИРЯЕТ аудиторию) уведомлений не добавляет:
--     одна публикация — один пуш, и дослать его позже значило бы, что один
--     пост уведомил дважды. Пропущенный пуш дешевле лишнего.
CREATE OR REPLACE FUNCTION public.create_post_with_media(p_client_token uuid, p_text text DEFAULT NULL::text, p_items jsonb DEFAULT '[]'::jsonb, p_visibility text DEFAULT 'connections'::text)
 RETURNS TABLE(storage_path text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- `returns table (storage_path text)` заводит OUT-параметр `storage_path`, а
-- он для plpgsql — переменная, видимая во всём теле. Ниже есть
-- `on conflict (post_id, storage_path)`, и цель конфликта обязана быть голым
-- ИМЕНЕМ КОЛОНКИ: квалифицировать её нельзя синтаксически, а неквалифицированная
-- натыкается на переменную и падает с 42702 «column reference is ambiguous».
#variable_conflict use_column
declare
  v_post_id uuid;
  v_prefix text;
  v_text text;
  v_removed text[];
  v_visibility text := coalesce(p_visibility, 'connections');
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if p_client_token is null then
    raise exception 'client_token is required' using errcode = 'PT422';
  end if;

  if v_visibility not in ('connections', 'favorites') then
    raise exception 'Unknown visibility' using errcode = 'PT422';
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

  insert into posts (author_id, text, client_token, visibility)
  values (auth.uid(), v_text, p_client_token, v_visibility)
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
       set text = v_text,
           visibility = v_visibility
     where id = v_post_id
       and (text is distinct from v_text or visibility is distinct from v_visibility);

    -- Аудиторию мог сузить ЭТОТ вызов: первая попытка закоммитилась, и
    -- AFTER INSERT-триггер уже разложил `new_post` по тем, у кого автор в
    -- избранном. Кому пост теперь не покажут — у того уведомление о нём
    -- обязано уйти из очереди, пока не отправлено. Подробности и границы —
    -- в шапке 20260905100000.
    if v_visibility = 'favorites' then
      delete from notification_outbox n
       where n.kind = 'new_post'
         and n.sent_at is null
         and n.payload ->> 'post_id' = v_post_id::text
         and not exists (
           select 1 from favorite_users g
            where g.user_id = auth.uid() and g.favorite_id = n.user_id
         );
    end if;

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
$function$;


-- =====================================================================
-- 4. Комната: «не моя» и «не существует» отвечают одинаково
-- =====================================================================
-- `rename_room()`, `add_room_member()`, `remove_room_member()` и
-- `set_room_avatar()` спрашивали существование ОТДЕЛЬНО от владения и,
-- будучи `security definer`, делали это мимо RLS:
--
--   PT404 — такой комнаты нет;
--   PT403 — комната есть, но вы не владелец.
--
-- То есть любой залогиненный мог перебирать uuid и по коду ответа отличать
-- живую комнату от выдуманной. Проект закрывает такие оракулы везде и
-- называет это правилом вслух: «„не мой“ и „не существует“ обязаны быть
-- неотличимы» (`delete_own_comment()`, `set_post_media()`,
-- `delete_own_room_message()` — у всех троих один PT404 на оба случая).
-- Четыре RPC комнаты были единственным местом, где правило не соблюдалось.
--
-- Обе проверки сворачиваются в одну: `room_owner_id()` отдаёт NULL для
-- несуществующей комнаты, а `NULL is distinct from <uuid>` — истина, так что
-- оба случая приходят в одну ветку с одним PT404.
--
-- ФОРМА ПРОВЕРКИ ВЕЗДЕ ОДНА, и это не косметика. `set_room_avatar()`
-- спрашивала владение через `if not public.owns_room(p_room_id)`, а
-- `owns_room()` — это `room_owner_id(...) = auth.uid()`, то есть NULL для
-- несуществующей комнаты; `not NULL` — тоже NULL, и ветка НЕ срабатывает.
-- Работало это только потому, что несуществующую комнату отсекала проверка
-- строкой выше. Убрать её и оставить `if not owns_room(...)` значило бы
-- пустить вызов дальше на несуществующей комнате. Поэтому все четыре
-- функции переходят на `is distinct from` — форму, у которой NULL-ловушки
-- нет вовсе.
--
-- Клиенту это ничего не ломает: PT403 от этих RPC он нигде не разбирает —
-- `_run()` в `room_details_screen.dart` показывает одну и ту же строку на
-- любую ошибку (разбор кодов есть только у инвайтов и у `request_connection`).

CREATE OR REPLACE FUNCTION public.rename_room(p_room_id uuid, p_name text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  -- Один код на «нет такой комнаты» и на «есть, но чужая» — см. заголовок
  -- раздела 4 в 20260905100000.
  if public.room_owner_id(p_room_id) is distinct from auth.uid() then
    raise exception 'Room not found' using errcode = 'PT404';
  end if;

  if exists (select 1 from rooms r where r.id = p_room_id and r.is_direct) then
    raise exception 'A one-to-one room cannot be renamed' using errcode = 'PT422';
  end if;

  update rooms
     set name = left(nullif(btrim(coalesce(p_name, '')), ''), 100)
   where id = p_room_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.add_room_member(p_room_id uuid, p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'Not authenticated';
  end if;

  if public.room_owner_id(p_room_id) is distinct from v_me then
    raise exception 'Room not found' using errcode = 'PT404';
  end if;

  if exists (select 1 from rooms r where r.id = p_room_id and r.is_direct) then
    raise exception 'A one-to-one room cannot take new members' using errcode = 'PT422';
  end if;

  if not public.are_connected(v_me, p_user_id) or public.is_blocked_pair(v_me, p_user_id) then
    raise exception 'Room members must be your connections' using errcode = 'PT422';
  end if;

  if (select count(*) from room_members m where m.room_id = p_room_id) >= 50 then
    raise exception 'room_member_limit_exceeded' using errcode = 'P0001';
  end if;

  insert into room_members (room_id, user_id)
  values (p_room_id, p_user_id)
  on conflict (room_id, user_id) do nothing;
end;
$function$;

CREATE OR REPLACE FUNCTION public.remove_room_member(p_room_id uuid, p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'Not authenticated';
  end if;

  if public.room_owner_id(p_room_id) is distinct from v_me then
    raise exception 'Room not found' using errcode = 'PT404';
  end if;

  if p_user_id = v_me then
    raise exception 'Use leave_room to leave a room' using errcode = 'PT422';
  end if;

  delete from room_members m
   where m.room_id = p_room_id and m.user_id = p_user_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_room_avatar(p_room_id uuid, p_avatar_path text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_old text;
  v_new text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  -- `is distinct from`, а не `not owns_room(...)`: у второй формы NULL от
  -- несуществующей комнаты даёт NULL, и ветка не срабатывает вовсе.
  if public.room_owner_id(p_room_id) is distinct from auth.uid() then
    raise exception 'Room not found' using errcode = 'PT404';
  end if;

  if exists (select 1 from rooms r where r.id = p_room_id and r.is_direct) then
    raise exception 'A one-to-one room has no avatar of its own' using errcode = 'PT422';
  end if;

  -- Пустая строка от клиента — это «убрать аватарку», а не путь.
  v_new := nullif(btrim(coalesce(p_avatar_path, '')), '');

  if v_new is not null and v_new not like ('rooms/' || p_room_id::text || '/%') then
    raise exception 'Avatar path outside the room prefix' using errcode = 'PT422';
  end if;

  select r.avatar_path into v_old from rooms r where r.id = p_room_id;

  update rooms set avatar_path = v_new where id = p_room_id;

  -- Ретрай с тем же путём ничего не осиротил — и сносить нечего.
  return case when v_old is distinct from v_new then v_old end;
end;
$function$;


-- =====================================================================
-- 5. Лишний поколоночный грант на posts.visibility
-- =====================================================================
-- 20260829100000 выдала `grant select (visibility) on posts to authenticated`
-- с комментарием «колоночные гранты новую колонку сами не подхватывают». Для
-- ЗАПИСИ это правда и там же используется правильно (INSERT/UPDATE у `posts`
-- выданы поколоночно, и новая колонка в них не попадает). Для ЧТЕНИЯ — нет:
-- SELECT у `posts` выдан на всю таблицу (`relacl` = `authenticated=rdm`), а
-- табличная привилегия покрывает любую колонку, включая добавленные позже.
--
-- Вреда грант не приносил, но утверждал неверное правило в комментарии рядом
-- с собой, и следующий читатель заключил бы, что SELECT у `posts`
-- поколоночный (он не поколоночный) — и завёл бы такой грант каждой будущей
-- колонке, или, наоборот, сузил бы табличный, обнаружив зависимость только
-- по факту.
--
-- Проверено симуляцией до наката: после `revoke` `attacl` колонки становится
-- NULL, а `has_column_privilege('authenticated', 'posts', 'visibility',
-- 'select')` остаётся true — читает табличный грант. Проверка ниже повторяет
-- это уже на живой схеме.
revoke select (visibility) on table public.posts from authenticated;


-- =====================================================================
-- 6. Проверки после наката
-- =====================================================================
-- Не «применилось ли», а «то ли применилось»: у пересозданных функций
-- `prosrc` проверяется на признаки И нового, И старого тела — `create or
-- replace` переписывает всё целиком, и пересоздание из более раннего текста
-- уже дважды выключало в этом проекте целую фичу (см. «Грабли» в CLAUDE.md).
do $$
declare
  v_src text;
  v_qual text;
  v_name text;
begin
  -- (1) Политика аватарок спрашивает объект, а не префикс.
  select pg_get_expr(polqual, polrelid) into v_qual
    from pg_policy
   where polrelid = 'storage.objects'::regclass
     and polname = 'Avatars are viewable by the user, connections and room peers';
  if v_qual is null then
    raise exception 'политика аватарок не пересоздалась';
  end if;
  if v_qual like '%shares_room_with_caller%' then
    raise exception 'политика аватарок всё ещё отдаёт соседу по комнате весь префикс';
  end if;
  if v_qual not like '%is_room_peer_avatar%' then
    raise exception 'политика аватарок потеряла ветвь соседа по комнате';
  end if;
  -- Три префиксные ветви обязаны остаться: без них своя же галерея, системный
  -- аккаунт и Connection перестают открываться.
  if v_qual not like '%system_account_ids%' or v_qual not like '%connections c%'
     or v_qual not like '%auth.uid())::text%' then
    raise exception 'политика аватарок пересоздана из неполного тела';
  end if;
  if not has_function_privilege('authenticated', 'public.is_room_peer_avatar(text)', 'execute') then
    raise exception 'is_room_peer_avatar() не выдана authenticated — аватарки в комнатах погаснут';
  end if;
  if has_function_privilege('anon', 'public.is_room_peer_avatar(text)', 'execute') then
    raise exception 'is_room_peer_avatar() открыта anon';
  end if;

  -- (2) Грант снят у `authenticated` — и только у него: внутренний вызов из
  -- `update_post_with_media()` идёт правами владельца и ломаться не должен.
  if has_function_privilege('authenticated', 'public.set_post_media(uuid, jsonb)', 'execute') then
    raise exception 'set_post_media() всё ещё выдана authenticated';
  end if;
  if not has_function_privilege('postgres', 'public.set_post_media(uuid, jsonb)', 'execute') then
    raise exception 'set_post_media() потеряла право исполнения у владельца';
  end if;
  if not has_function_privilege('authenticated', 'public.update_post_with_media(uuid, text, jsonb, text)', 'execute') then
    raise exception 'update_post_with_media() потеряла грант — правка поста выключена';
  end if;

  -- (3) Отзыв пушей на месте, а остальная механика функции — тоже.
  select prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'create_post_with_media';
  if v_src not ilike '%delete from notification_outbox%' then
    raise exception 'create_post_with_media() не отзывает пуши при сужении аудитории';
  end if;
  if v_src not ilike '%on conflict (author_id, client_token) do nothing%'
     or v_src not ilike '%post_media_limit_exceeded%'
     or v_src not ilike '%Media path outside your own prefix%'
     or v_src not ilike '%variable_conflict use_column%' then
    raise exception 'create_post_with_media() пересоздана из неполного тела';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'create_post_with_media') <> 1 then
    raise exception 'create_post_with_media() размножилась перегрузками';
  end if;
  if not has_function_privilege('authenticated', 'public.create_post_with_media(uuid, text, jsonb, text)', 'execute') then
    raise exception 'create_post_with_media() потеряла грант';
  end if;

  -- (4) Ни одна из четырёх RPC комнаты больше не отвечает PT403, и каждая
  -- по-прежнему спрашивает владение.
  for v_name in
    select unnest(array['rename_room', 'add_room_member',
                        'remove_room_member', 'set_room_avatar'])
  loop
    select prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_name;
    if v_src is null then
      raise exception '%() пропала из схемы', v_name;
    end if;
    if v_src like '%PT403%' then
      raise exception '%() всё ещё различает «чужая» и «несуществующая»', v_name;
    end if;
    if v_src not like '%room_owner_id(p_room_id) is distinct from%' then
      raise exception '%() потеряла проверку владения (или вернулась к NULL-ловушке not owns_room)', v_name;
    end if;
    if not has_function_privilege('authenticated', format('public.%I(uuid, %s)', v_name,
         case v_name when 'rename_room' then 'text'
                     when 'set_room_avatar' then 'text'
                     else 'uuid' end), 'execute') then
      raise exception '%() потеряла грант', v_name;
    end if;
  end loop;

  -- (5) Колоночный грант снят, а читать колонку по-прежнему можно —
  -- через табличный.
  if exists (
    select 1 from pg_attribute
     where attrelid = 'public.posts'::regclass and attname = 'visibility'
       and attacl is not null
  ) then
    raise exception 'поколоночный грант на posts.visibility не снят';
  end if;
  if not has_column_privilege('authenticated', 'public.posts', 'visibility', 'select') then
    raise exception 'posts.visibility перестала читаться — снят лишний грант вместе с нужным';
  end if;
end;
$$;
