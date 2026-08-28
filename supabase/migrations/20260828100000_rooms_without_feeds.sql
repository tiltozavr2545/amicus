-- =====================================================================
-- Комната — это чат. Лента комнаты снимается целиком.
--
-- 20260826180000 завела комнату сразу двумя вещами: своей лентой и (этапом
-- позже, 20260826200000) своим чатом. Прижился чат. Лента комнаты осталась
-- вторым местом, где живут посты, — со своим экраном, своим видом
-- уведомления и своей ветвью в правиле видимости поста, — и каждая новая
-- фича про посты обязана про эту ветвь помнить. Помнят не всегда: сутки
-- спустя после наката 20260826190000 закрывала ровно такую находку —
-- фотография поста, адресованного ТОЛЬКО в комнату, открывалась знакомому
-- автора, в комнату не позванному.
--
-- Адресация поста вернётся, но не комнатой, а настройкой видимости самого
-- поста, и до тех пор второй ветви лучше не быть вовсе, чем быть спящей:
-- спящая ветвь не проверяется симуляцией и не мешает никому ошибиться.
--
-- Поэтому: посты комнат удаляются, `post_rooms` и `posts.in_general_feed`
-- дропаются, правило видимости сворачивается обратно в одну ветвь,
-- `create_post_with_media()` возвращается к трём аргументам, а вид
-- уведомления `room_post` и настройка `notify_room_posts` уходят вместе с
-- тем, о чём они уведомляли. Следом за ними — ветвь «автор комментария мой
-- сосед по комнате»: она отвечала «да» только под постом в комнате
-- (см. раздел 5).
--
-- ЭТО ЛОМАЕТ УЖЕ ВЫЛОЖЕННЫХ КЛИЕНТОВ, и осознанно. Клиент build 46 и ниже
-- шлёт `.eq('in_general_feed', true)` в запросе ленты (после дропа колонки
-- это 400) и зовёт `create_post_with_media` пятью именованными
-- параметрами (после смены сигнатуры это 404 PGRST202 — PostgREST ищет
-- функцию по именам аргументов). Порядок тот же, что у 0.17.0: сразу за
-- миграцией идёт релиз и рассылка `app_update_important` — см. «Рассылка
-- „обновитесь“» в operations.md. Отличие в том, что 0.17.0 у старого
-- клиента лишь показывала пост не там, где надо, а эта правка выключает
-- ему ленту и публикацию до обновления.
-- =====================================================================


-- =====================================================================
-- 1. Данные
-- =====================================================================
-- Пост, адресованный только в комнату, после этой миграции негде показать:
-- ветвь, по которой его видели участники, исчезает, а в общую ленту он не
-- просился. Поэтому он удаляется, а не «переезжает»: переезд показал бы
-- всем знакомым автора то, что он положил одной комнате.
--
-- Каскадом уходят его медиа, комментарии и реакции. Объекты в бакете
-- остаются без строки `post_media` — то есть сиротами, а сирот забирает
-- `reap_orphaned_media()` (ежечасный cron; порог — сутки).
delete from public.posts where not in_general_feed;

-- Иначе они не прошли бы новый CHECK ниже. Все давно отправлены: очередь
-- разгребается ежеминутным cron'ом.
delete from public.notification_outbox where kind = 'room_post';


-- =====================================================================
-- 2. Уведомление о посте в комнате
-- =====================================================================
-- Триггер снимается явно, а не каскадом от `drop table`: так порядок
-- виден в самой миграции, и её можно читать, не помня, что тянет за собой
-- дроп таблицы.
drop trigger if exists post_rooms_enqueue_notifications_after_insert on public.post_rooms;
drop function if exists public.enqueue_room_post_notifications();


-- =====================================================================
-- 3. Уведомления об обычном посте
-- =====================================================================
-- ВНИМАНИЕ. Это та самая функция, которую дважды пересоздавали из
-- дореформенного текста, и оба раза публиковать не мог никто, у кого есть
-- Connection без mute/block/избранного. Тело ниже взято из `prosrc` ЖИВОЙ
-- схемы (сверено с 20260826180000 — они совпадают построчно), а не из
-- baseline и не по памяти. После наката проверять не «применилось ли», а
-- `prosrc` на признаки старого тела (см. «Грабли» в CLAUDE.md).
--
-- Меняются ровно две вещи, обе — снятие фильтра, заведённого 20260826180000:
--   1. ранний выход по `not new.in_general_feed`;
--   2. `and p.in_general_feed` в подсчёте непрочитанного для дайджеста.
-- Всё остальное построчно то же самое.
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
-- 4. Видимость поста: обратно в одну ветвь
-- =====================================================================
-- Политика возвращается к своему прежнему имени и тексту — тому, что
-- лежит в baseline. Дропнуть колонку, пока политика на неё ссылается,
-- нельзя: у политики есть зависимость от колонки, у `security definer`
-- функции с телом-строкой — нет, поэтому порядок здесь важен именно для
-- политики и индекса.
drop policy "Posts are viewable by connections or by room members" on public.posts;

create policy "Posts are viewable by author and their connections"
  on public.posts
  for select
  to authenticated
  using ((author_id IN ( SELECT visible_author_ids() AS visible_author_ids)));

-- `is_post_visible()` завела та же 20260826180000, и она остаётся: её
-- спрашивают `is_comment_visible()`, `reaction_summary()` и
-- `post_media_path_visible()`. Уходит из неё только вторая ветвь.
CREATE OR REPLACE FUNCTION public.is_post_visible(p_post_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((
    select public.is_author_visible(p.author_id)
      from posts p
     where p.id = p_post_id
  ), false);
$function$;

drop function if exists public.post_in_my_rooms(uuid);


-- =====================================================================
-- 5. Видимость комментария
-- =====================================================================
-- Ветвь «автор комментария — мой сосед по комнате» держалась на
-- `post_in_my_rooms()` первым же конъюнктом: она отвечала «да» только под
-- постом, лежащим в моей комнате. Постов в комнатах больше нет, значит
-- ветвь всегда ложна — и, что важнее, она бы не просто молчала: дроп
-- `post_in_my_rooms()` выше оставил `is_comment_author_room_peer()`
-- ссылаться на несуществующую функцию, а тело `security definer`-функции
-- разрешается в рантайме, поэтому ЧТЕНИЕ КОММЕНТАРИЕВ падало бы 42883 у
-- всех, кому не хватило первой ветви. Нашла симуляция сразу после наката,
-- и это ровно тот случай, о котором предупреждает «Что сейчас разрешено —
-- спрашивать у живой схемы» в CLAUDE.md: зависимость от дропнутой функции
-- не видна ни планировщику, ни `drop`.
--
-- Политика и `is_comment_visible()` возвращаются к дороомнатному тексту
-- (baseline), и их по-прежнему ровно две копии одного правила — менять
-- надо обе.
drop policy "Comments are viewable by connections or by room peers" on public.comments;

create policy "Comments are viewable by the viewer's unmuted connections"
  on public.comments
  for select
  to authenticated
  using (((EXISTS ( SELECT 1
   FROM posts p
  WHERE (p.id = comments.post_id))) AND ((author_id IN ( SELECT visible_author_ids() AS visible_author_ids)) OR is_comment_visible_to_post_owner(id)) AND ((parent_comment_id IS NULL) OR is_author_of_comment_visible(parent_comment_id) OR is_comment_visible_to_post_owner(parent_comment_id)) AND ((reply_to_id IS NULL) OR is_author_of_comment_visible(reply_to_id) OR is_comment_visible_to_post_owner(reply_to_id))));

CREATE OR REPLACE FUNCTION public.is_comment_visible(p_comment_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((
    select
      -- Пост виден. Внутри `security definer` политика posts не применяется,
      -- поэтому спрашиваем правило у `is_post_visible()` — единственного
      -- места, где оно записано вне самой политики.
      public.is_post_visible(c.post_id)
      and (
        public.is_author_visible(c.author_id)
        or public.is_comment_visible_to_post_owner(c.id)
      )
      and (
        c.parent_comment_id is null
        or public.is_author_of_comment_visible(c.parent_comment_id)
        or public.is_comment_visible_to_post_owner(c.parent_comment_id)
      )
      and (
        c.reply_to_id is null
        or public.is_author_of_comment_visible(c.reply_to_id)
        or public.is_comment_visible_to_post_owner(c.reply_to_id)
      )
    from comments c
    where c.id = p_comment_id
  ), false);
$function$;

drop function if exists public.is_comment_author_room_peer(uuid);


-- =====================================================================
-- 6. Список комнат
-- =====================================================================
-- Четвёртое пересоздание `my_rooms()` и по той же причине, что и первые
-- три: меняется набор OUT-колонок, а `create or replace` его менять не
-- умеет («cannot change return type of existing function»). Уходит
-- `last_post_at` — единственное, что связывало список комнат с постами.
-- Сортировка остаётся той же по смыслу: последняя активность, то есть
-- теперь просто последнее сообщение. Грант выдаётся заново — он уходит
-- вместе с функцией.
drop function if exists public.my_rooms();

CREATE OR REPLACE FUNCTION public.my_rooms()
 RETURNS TABLE(id uuid, name text, avatar_path text, is_direct boolean, owner_id uuid, created_at timestamp with time zone, last_message_at timestamp with time zone, last_message_text text, last_message_author_id uuid, unread_count integer, members jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select r.id,
         r.name,
         r.avatar_path,
         r.is_direct,
         public.room_owner_id(r.id),
         r.created_at,
         msg.created_at,
         msg.text,
         msg.author_id,
         unread.n,
         mem.members
    from rooms r
    join room_members me on me.room_id = r.id and me.user_id = auth.uid()
    left join lateral (
      select m.created_at, m.text, m.author_id
        from room_messages m
       where m.room_id = r.id and m.deleted_at is null
       order by m.created_at desc, m.id desc
       limit 1
    ) msg on true
    cross join lateral (
      -- Свои сообщения непрочитанными не считаются никогда: отправка их же
      -- и порождает, и счётчик на собственной кнопке был бы шумом.
      select count(*)::int as n
        from room_messages m
       where m.room_id = r.id
         and m.deleted_at is null
         and m.author_id <> auth.uid()
         and m.created_at > me.last_read_at
    ) unread
    cross join lateral (
      select jsonb_agg(
               jsonb_build_object('id', u.id, 'name', u.name, 'avatar_path', u.avatar_path)
               order by m2.seq
             ) as members
        from room_members m2
        join users u on u.id = m2.user_id
       where m2.room_id = r.id
    ) mem
   order by coalesce(msg.created_at, r.created_at) desc, r.id desc;
$function$;


-- =====================================================================
-- 7. Публикация: снова три аргумента
-- =====================================================================
-- Дроп перед созданием — то же правило, что и всегда: `create or replace`
-- с другим списком аргументов завёл бы ВТОРУЮ перегрузку, и вызов с тремя
-- именованными параметрами стал бы для PostgREST неоднозначным (300
-- Multiple Choices), то есть публикация сломалась бы и у нового клиента
-- тоже. Тело — живое минус всё про комнаты; вся остальная механика
-- (идемпотентность по `client_token`, переписывание медиа, возврат
-- осиротевших путей) не меняется ни строкой.
drop function if exists public.create_post_with_media(uuid, text, jsonb, uuid[], boolean);

CREATE OR REPLACE FUNCTION public.create_post_with_media(p_client_token uuid, p_text text DEFAULT NULL::text, p_items jsonb DEFAULT '[]'::jsonb)
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
-- Директива разрешает такие столкновения в пользу колонки — то, что здесь нужно
-- везде: сама переменная не читается ни разу, наружу список уходит через
-- `return query`.
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
$function$;


-- =====================================================================
-- 8. Схема: адресаты и флаг
-- =====================================================================
drop table if exists public.post_rooms;

-- Частичный индекс держался на колонке и уходит вместе с ней; сносится
-- явно по той же причине, что и триггер выше. Общая лента остаётся на
-- `posts_created_at_id_idx` — том же (created_at desc, id desc), но без
-- предиката, который 20260826180000 добавила рядом.
drop index if exists public.posts_general_created_at_id_idx;

alter table public.posts drop column in_general_feed;

-- Настройка глушила уведомления о постах в комнате. Уведомлений больше
-- нет, а настройка, которая ничего не выключает, — худший вид настройки:
-- её видно, и она врёт.
alter table public.notification_preferences drop column notify_room_posts;

-- `room_message` в списке остаётся: чат никуда не делся. `room_post`
-- уходит — вместе с текстами в send-push (это ВСЕГДА две правки, см.
-- комментарий над `pickText` там же).
alter table public.notification_outbox drop constraint notification_outbox_kind_check;
alter table public.notification_outbox add constraint notification_outbox_kind_check
  CHECK ((kind = ANY (ARRAY['new_post'::text, 'inactive_week'::text, 'digest'::text,
                            'post_comment'::text, 'comment_reply'::text, 'app_update'::text,
                            'room_message'::text, 'app_update_important'::text])));


-- =====================================================================
-- 9. Гранты
-- =====================================================================
-- Обе функции пересозданы, а грант уходит вместе с функцией.
revoke execute on function public.my_rooms() from public, anon, authenticated;
grant execute on function public.my_rooms() to authenticated;

revoke execute on function public.create_post_with_media(p_client_token uuid, p_text text, p_items jsonb) from public, anon, authenticated;
grant execute on function public.create_post_with_media(p_client_token uuid, p_text text, p_items jsonb) to authenticated;

revoke execute on function public.is_post_visible(p_post_id uuid) from public, anon, authenticated;


-- =====================================================================
-- 10. Проверки после наката
-- =====================================================================
do $$
declare
  v_src text;
begin
  if exists (select 1 from pg_class where relname = 'post_rooms' and relnamespace = 'public'::regnamespace) then
    raise exception 'post_rooms осталась в схеме';
  end if;

  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'posts' and column_name = 'in_general_feed'
  ) then
    raise exception 'posts.in_general_feed осталась в схеме';
  end if;

  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'notification_preferences'
       and column_name = 'notify_room_posts'
  ) then
    raise exception 'notification_preferences.notify_room_posts осталась в схеме';
  end if;

  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('post_in_my_rooms', 'enqueue_room_post_notifications',
                         'is_comment_author_room_peer')
  ) then
    raise exception 'функции ленты комнат остались в схеме';
  end if;

  -- Тела `security definer`-функций разрешаются в рантайме, поэтому ссылка
  -- на дропнутую функцию видна не при накате, а первому же читателю.
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prosrc ilike '%post_in_my_rooms%'
  ) then
    raise exception 'кто-то ещё зовёт post_in_my_rooms()';
  end if;

  -- Не «применилось ли», а именно `prosrc` на признаки старого тела:
  -- `create or replace` переписывает всё тело, и пересоздание из
  -- дореформенного текста уже дважды выключало публикацию всем подряд.
  select prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'enqueue_post_notifications';
  if v_src ilike '%in_general_feed%' then
    raise exception 'enqueue_post_notifications() ещё помнит in_general_feed';
  end if;
  if v_src not ilike '%unseen_count >= 7%' or v_src not ilike '%notify_favorites%' then
    raise exception 'enqueue_post_notifications() пересоздана из неполного тела';
  end if;

  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'create_post_with_media') <> 1 then
    raise exception 'create_post_with_media() размножилась перегрузками';
  end if;

  if not has_function_privilege('authenticated', 'public.create_post_with_media(uuid, text, jsonb)', 'execute') then
    raise exception 'create_post_with_media() потеряла грант после пересоздания';
  end if;

  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'my_rooms') <> 1 then
    raise exception 'my_rooms() размножилась перегрузками';
  end if;

  if not has_function_privilege('authenticated', 'public.my_rooms()', 'execute') then
    raise exception 'my_rooms() потеряла грант после пересоздания';
  end if;

  if exists (
    select 1 from pg_policy
     where polrelid = 'public.posts'::regclass
       and polname = 'Posts are viewable by connections or by room members'
  ) then
    raise exception 'старая политика posts осталась';
  end if;
end;
$$;
