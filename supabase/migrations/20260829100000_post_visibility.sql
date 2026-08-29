-- =====================================================================
-- Кому виден пост: всем знакомым или только избранным.
--
-- Взамен адресации поста в комнаты, снятой 20260828100000 вместе с их
-- лентами. Разница принципиальная, и ради неё всё и затевалось: комната —
-- это ГРУППА, отдельное место со своим составом, а видимость — свойство
-- САМОГО ПОСТА. Первое требовало второй ленты и второй ветви в правиле
-- видимости, которая жила отдельной жизнью и о которой надо было помнить;
-- второе — колонки на строке поста, которую видно там же, где и всё
-- остальное про него.
--
-- Аудитория «только избранные» — это список избранных АВТОРА
-- (`favorite_users`, где `user_id` = автор). Отдельной таблицы «близкие
-- друзья» не заводится: список уже есть, он уже про «эти люди мне важнее
-- прочих», и вторая такая же коллекция рядом с первой означала бы, что
-- человеку надо помнить, какая из них для чего.
--
-- Побочный смысл, который стоит назвать вслух: до сих пор избранное было
-- ЧИСТО ЛИЧНЫМ — «я хочу пуш о его постах», и вторая сторона о нём не знала
-- и от него не зависела. Теперь оно ещё и аудитория. Узнать, что ты у
-- кого-то в избранном, по-прежнему нельзя (строки `favorite_users` видит
-- только их владелец, и метка «только для избранных» показывается лишь
-- автору поста) — но то, ЧТО ты увидишь, теперь от чужого списка зависит.
--
-- Все существующие посты — `'connections'`: `default` на колонке отвечает и
-- за них, и за клиента, который о видимости ещё не знает.
-- =====================================================================


-- =====================================================================
-- 1. Колонка
-- =====================================================================
-- Текст с CHECK, а не boolean: «только избранным» — не отрицание «всем», и
-- третье значение («никому, кроме меня») ляжет сюда же, не переписывая ни
-- одного условия в двух местах ниже.
--
-- INSERT- и UPDATE-грантов на колонку нет намеренно: её пишут только
-- `create_post_with_media()` и `update_post_with_media()`, где значение
-- проверяется вместе с авторством. SELECT-грант нужен — композер
-- показывает текущий выбор при редактировании, а карточка рисует метку
-- автору (колоночные гранты новую колонку сами не подхватывают, см.
-- «Дефолтные гранты Supabase» в CLAUDE.md).
alter table public.posts
  add column visibility text default 'connections'::text not null;

alter table public.posts add constraint posts_visibility_check
  check (visibility = any (array['connections'::text, 'favorites'::text]));

grant select (visibility) on table public.posts to authenticated;


-- =====================================================================
-- 2. Предикаты избранного
-- =====================================================================
-- Обе функции отвечают на один вопрос — «держит ли ОН меня в избранном» — и
-- обе `security definer` по той же причине, по которой ею стала
-- `is_blocked_pair()` (0.9.0): RLS на `favorite_users` пускает к строкам
-- только их владельца (`user_id = auth.uid()`), поэтому подзапрос к ЧУЖОМУ
-- избранному внутри политики молча отфильтровался бы в ноль — и пост
-- «только для избранных» не увидел бы никто, включая самих избранных.
--
-- Их две, и это тот же дуэт, что `visible_author_ids()` / `is_author_visible()`:
-- множество для политики, скаляр для построчных вызывающих. Построчный
-- `security definer` в политике ленты — уже сделанная в этом проекте ошибка
-- (регрессия 20260726180000, 217 мс против 3.5 мс), поэтому в политике стоит
-- некоррелированный `IN (SELECT …)`, который хэшируется один раз.
CREATE OR REPLACE FUNCTION public.authors_who_favorited_me()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select f.user_id
    from favorite_users f
   where f.favorite_id = auth.uid();
$function$;

CREATE OR REPLACE FUNCTION public.is_favorited_by(p_author uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from favorite_users f
     where f.user_id = p_author and f.favorite_id = auth.uid()
  );
$function$;


-- =====================================================================
-- 3. Правило видимости: снова две ветви
-- =====================================================================
-- Записано в двух местах и только в двух — в SELECT-политике `posts`
-- (инлайном, потому что `security definer` планировщик не инлайнит) и в
-- `is_post_visible()`, которую спрашивают `is_comment_visible()`,
-- `reaction_summary()` и `post_media_path_visible()`. Менять надо оба.
-- Всё остальное — медиа, комментарии, реакции — ходит через вложенный
-- `exists (select 1 from posts …)` и получает новое правило само: RLS
-- применяется и к подзапросу внутри политики.
drop policy "Posts are viewable by author and their connections" on public.posts;

create policy "Posts are viewable by connections, restricted ones by favorites"
  on public.posts
  for select
  to authenticated
  using (
    (author_id IN ( SELECT visible_author_ids() AS visible_author_ids))
    AND ((visibility = 'connections'::text)
         -- Автор всегда видит свой пост. Первая ветвь это уже говорит
         -- (`visible_author_ids()` начинается с `auth.uid()`), а вторая — нет:
         -- чтобы пройти её, автору пришлось бы держать в избранном самого
         -- себя. Нашла симуляция сразу после наката — из пяти своих постов
         -- автор видел четыре.
         OR (author_id = auth.uid())
         OR (author_id IN ( SELECT authors_who_favorited_me() AS authors_who_favorited_me)))
  );

CREATE OR REPLACE FUNCTION public.is_post_visible(p_post_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((
    select public.is_author_visible(p.author_id)
       and (p.visibility = 'connections'
            or p.author_id = auth.uid()
            or public.is_favorited_by(p.author_id))
      from posts p
     where p.id = p_post_id
  ), false);
$function$;


-- =====================================================================
-- 4. Публикация и правка
-- =====================================================================
-- Новый параметр со значением по умолчанию: клиент, который о видимости не
-- знает, продолжает публиковать «всем знакомым», ничего не меняя. Дроп перед
-- созданием обязателен — `create or replace` с другим списком аргументов
-- завёл бы ВТОРУЮ перегрузку, и вызов с тремя именованными параметрами стал
-- бы для PostgREST неоднозначным (300 Multiple Choices).
drop function if exists public.create_post_with_media(uuid, text, jsonb);

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

-- У правки значение по умолчанию — NULL, а не 'connections', и разница тут
-- существенная: NULL значит «не трогать». Клиент build 47, который о
-- видимости не знает, правит подпись у поста «только для избранных» — и не
-- должен этой правкой раскрыть его всем знакомым.
drop function if exists public.update_post_with_media(uuid, text, jsonb);

CREATE OR REPLACE FUNCTION public.update_post_with_media(p_post_id uuid, p_text text DEFAULT NULL::text, p_items jsonb DEFAULT '[]'::jsonb, p_visibility text DEFAULT NULL::text)
 RETURNS TABLE(storage_path text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_text text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not exists (
    select 1 from posts p where p.id = p_post_id and p.author_id = auth.uid()
  ) then
    raise exception 'Post not found' using errcode = 'PT404';
  end if;

  if p_visibility is not null and p_visibility not in ('connections', 'favorites') then
    raise exception 'Unknown visibility' using errcode = 'PT422';
  end if;

  if jsonb_typeof(p_items) <> 'array' then
    raise exception 'Media list must be an array' using errcode = 'PT422';
  end if;

  -- Тот же nullif(btrim(...)), что в create_post_with_media() и в
  -- posts_text_not_blank (20260822200000): пустая строка от клиента — это
  -- отсутствие текста, а не текст.
  v_text := nullif(btrim(coalesce(p_text, '')), '');

  if v_text is null and jsonb_array_length(p_items) = 0 then
    raise exception 'A post needs text or media' using errcode = 'PT422';
  end if;

  update posts
     set text = v_text,
         visibility = coalesce(p_visibility, visibility)
   where id = p_post_id;

  -- Остальное — включая проверку префикса путей, лимит в 20 элементов и расчёт
  -- осиротевших объектов — принадлежит set_post_media() и остаётся там.
  return query select s.storage_path from public.set_post_media(p_post_id, p_items) s;
end;
$function$;


-- =====================================================================
-- 5. Уведомления
-- =====================================================================
-- ВНИМАНИЕ. Та самая функция, которую дважды пересоздавали из
-- дореформенного текста, и оба раза публиковать не мог никто. Тело ниже
-- взято из `prosrc` ЖИВОЙ схемы (её последней трогала 20260828100000) и
-- изменено ровно в двух местах — оба про то, что пост «только избранным» не
-- должен порождать ни уведомления, ни строчки в дайджесте у того, кому его
-- не покажут. После наката проверять не «применилось ли», а `prosrc` на
-- признаки старого тела (см. «Грабли» в CLAUDE.md).
CREATE OR REPLACE FUNCTION public.enqueue_post_notifications()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_author_name text;
begin
  -- 20260820190000: пост системного аккаунта сам по себе не уведомляет
  -- никого. Kind 'app_update' и notify_system_account остаются для того, кто
  -- будет слать это уведомление отдельно.
  if public.is_system_account(new.author_id) then
    return new;
  end if;

  select name into v_author_name from users where id = new.author_id;

  insert into notification_outbox (user_id, kind, payload)
  select f.user_id, 'new_post',
    jsonb_build_object(
      'author_id', new.author_id,
      'author_name', v_author_name,
      'post_id', new.id
    )
  from favorite_users f
  where f.favorite_id = new.author_id
    and public.are_connected(f.user_id, new.author_id)
    -- Пост «только избранным» уведомляет лишь тех, кто в избранном У АВТОРА.
    -- Списки тут РАЗНЫЕ: слева те, кто добавил автора к себе (они и хотят
    -- пуш), справа те, кого автор добавил к себе (они и увидят пост). Без
    -- этой строки пуш «у Пети новый пост» уходил бы тому, кому пост не
    -- покажут, — то же самое, чем был ранний выход по `in_general_feed` до
    -- 20260828100000.
    and (new.visibility = 'connections'
         or exists (select 1 from favorite_users g
                     where g.user_id = new.author_id and g.favorite_id = f.user_id))
    and not public.has_muted(f.user_id, new.author_id)
    and not public.is_blocked_pair(f.user_id, new.author_id)
    and coalesce(
      (select notify_favorites from notification_preferences where user_id = f.user_id),
      true
    );

  with candidate as materialized (
    select distinct
           case when c.user_a_id = new.author_id then c.user_b_id else c.user_a_id end as viewer_id
      from connections c
     where c.user_a_id = new.author_id or c.user_b_id = new.author_id
  ),
  eligible as materialized (
    select cd.viewer_id,
           -- Never having opened the (updated) app yet reads as "just became
           -- active" — nothing counts as unseen until we actually know otherwise.
           coalesce(
             (select ua.last_active_at from user_activity ua where ua.user_id = cd.viewer_id),
             now()
           ) as window_start
      from candidate cd
     where not public.has_muted(cd.viewer_id, new.author_id)
       and not public.is_blocked_pair(cd.viewer_id, new.author_id)
       and not exists (
         select 1 from favorite_users f
          where f.user_id = cd.viewer_id and f.favorite_id = new.author_id
       )
       and coalesce(
         (select np.notify_digest from notification_preferences np
           where np.user_id = cd.viewer_id),
         true
       )
  ),
  -- Already sent a digest since they were last active — the count can only
  -- have grown since, so nothing new to decide until they open the app
  -- again and this window moves forward.
  fresh as materialized (
    select e.viewer_id, e.window_start
      from eligible e
     where not exists (
       select 1 from notification_outbox n
        where n.user_id = e.viewer_id
          and n.kind = 'digest'
          and n.created_at > e.window_start
     )
  )
  insert into notification_outbox (user_id, kind, payload)
  select fr.viewer_id, 'digest', jsonb_build_object('count', u.unseen_count)
    from fresh fr
    cross join lateral (
      -- Direct joins against the base tables rather than has_muted()/
      -- is_blocked_pair() per row — those are fine called once per viewer
      -- (above), but calling a SECURITY DEFINER function per candidate post
      -- here is exactly the row-filter cost CLAUDE.md's "Грабли" warns about.
      select count(*) as unseen_count
        from posts p
        join connections c
          on (c.user_a_id = fr.viewer_id and c.user_b_id = p.author_id)
          or (c.user_b_id = fr.viewer_id and c.user_a_id = p.author_id)
       where p.created_at > fr.window_start
         -- Та же проверка, что и выше, но со стороны зрителя: звать в ленту
         -- числом постов, которых он там не найдёт, — хуже, чем не звать.
         and (p.visibility = 'connections'
              or exists (select 1 from favorite_users g
                          where g.user_id = p.author_id and g.favorite_id = fr.viewer_id))
         and not exists (
           select 1 from muted_users m
            where m.muter_id = fr.viewer_id and m.muted_id = p.author_id
         )
         and not exists (
           select 1 from blocked_users b
            where (b.blocker_id = fr.viewer_id and b.blocked_id = p.author_id)
               or (b.blocker_id = p.author_id and b.blocked_id = fr.viewer_id)
         )
         and not exists (
           select 1 from favorite_users f
            where f.user_id = fr.viewer_id and f.favorite_id = p.author_id
         )
    ) u
   where u.unseen_count >= 7
   order by fr.viewer_id;

  return new;
end;
$function$;


-- =====================================================================
-- 6. Гранты
-- =====================================================================
-- Обе пересозданные функции получают грант заново — он уходит вместе с
-- функцией. Предикаты избранного выдаются `authenticated` по тому же
-- правилу, что и `shares_room_with_caller()`: каждый их аргумент про самого
-- вызывающего, для чужой пары ответ всегда false. Грант на них нужен и
-- потому, что политика выше вычисляется правами читающего.
revoke execute on function public.create_post_with_media(p_client_token uuid, p_text text, p_items jsonb, p_visibility text) from public, anon, authenticated;
grant execute on function public.create_post_with_media(p_client_token uuid, p_text text, p_items jsonb, p_visibility text) to authenticated;

revoke execute on function public.update_post_with_media(p_post_id uuid, p_text text, p_items jsonb, p_visibility text) from public, anon, authenticated;
grant execute on function public.update_post_with_media(p_post_id uuid, p_text text, p_items jsonb, p_visibility text) to authenticated;

revoke execute on function public.authors_who_favorited_me() from public, anon;
grant execute on function public.authors_who_favorited_me() to authenticated;

revoke execute on function public.is_favorited_by(p_author uuid) from public, anon;
grant execute on function public.is_favorited_by(p_author uuid) to authenticated;

-- `is_post_visible()` по-прежнему без гранта: её зовут только изнутри
-- других `security definer`-функций.
revoke execute on function public.is_post_visible(p_post_id uuid) from public, anon, authenticated;


-- =====================================================================
-- 7. Проверки после наката
-- =====================================================================
do $$
declare
  v_src text;
  v_bad text;
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'posts' and column_name = 'visibility'
  ) then
    raise exception 'posts.visibility не завелась';
  end if;

  -- Все старые посты остаются видимыми всем знакомым: иначе миграция тихо
  -- спрятала бы чужую переписку с миром.
  if exists (select 1 from posts where visibility <> 'connections') then
    raise exception 'у существующих постов видимость не connections';
  end if;

  -- Писать колонку может только сервер.
  select string_agg(format('%s:%s', grantee, privilege_type), ', ')
    into v_bad
    from information_schema.column_privileges
   where table_schema = 'public' and table_name = 'posts' and column_name = 'visibility'
     and (grantee = 'anon' or (grantee = 'authenticated' and privilege_type <> 'SELECT'));
  if v_bad is not null then
    raise exception 'Лишние гранты на posts.visibility: %', v_bad;
  end if;

  if not exists (
    select 1 from information_schema.column_privileges
     where table_schema = 'public' and table_name = 'posts' and column_name = 'visibility'
       and grantee = 'authenticated' and privilege_type = 'SELECT'
  ) then
    raise exception 'SELECT-грант на posts.visibility не выдан';
  end if;

  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.proname in ('create_post_with_media', 'update_post_with_media')) <> 2 then
    raise exception 'функции публикации размножились перегрузками';
  end if;

  if not has_function_privilege('authenticated', 'public.create_post_with_media(uuid, text, jsonb, text)', 'execute')
     or not has_function_privilege('authenticated', 'public.update_post_with_media(uuid, text, jsonb, text)', 'execute') then
    raise exception 'функция публикации потеряла грант после пересоздания';
  end if;

  -- Не «применилось ли», а `prosrc` на признаки старого тела.
  select prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'enqueue_post_notifications';
  if v_src not ilike '%visibility%' then
    raise exception 'enqueue_post_notifications() не знает про видимость';
  end if;
  if v_src not ilike '%unseen_count >= 7%' or v_src not ilike '%notify_favorites%' then
    raise exception 'enqueue_post_notifications() пересоздана из неполного тела';
  end if;

  if exists (
    select 1 from pg_policy
     where polrelid = 'public.posts'::regclass
       and polname = 'Posts are viewable by author and their connections'
  ) then
    raise exception 'старая политика posts осталась';
  end if;

  -- Обе копии правила знают, что автор видит свой пост всегда.
  if (select pg_get_expr(polqual, polrelid) from pg_policy
       where polrelid = 'public.posts'::regclass
         and polname = 'Posts are viewable by connections, restricted ones by favorites')
     not like '%author_id = auth.uid()%' then
    raise exception 'политика posts не пускает автора к своему посту';
  end if;
  if (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'is_post_visible')
     not like '%auth.uid()%' then
    raise exception 'is_post_visible() не пускает автора к своему посту';
  end if;
end;
$$;
