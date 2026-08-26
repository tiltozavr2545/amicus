-- =====================================================================
-- Комнаты, этап 1: сами комнаты и лента комнаты.
--
-- Ложится поверх 20260826000000_baseline_schema.sql и
-- 20260826120000_close_eleventh_audit_findings.sql. Чат комнаты — этап 2,
-- здесь его таблиц нет намеренно: правило видимости поста трогает половину
-- политик проекта, и мешать это с мессенджером в одной миграции нельзя.
--
-- Что заводится:
--   1. `rooms` / `room_members` — комната и её состав;
--   2. `post_rooms` + `posts.in_general_feed` — адресация поста
--      (общая лента и/или несколько комнат, мультипостинг);
--   3. правило видимости поста расширяется второй ветвью «пост лежит в
--      моей комнате» — и вместе с ним всё, что от видимости поста зависит:
--      медиа, комментарии, реакции, storage;
--   4. RPC управления комнатой: создать, переименовать, добавить,
--      исключить, выйти.
--
-- ГЛАВНОЕ РЕШЕНИЕ СХЕМЫ: у комнаты НЕТ колонки `creator_id`.
-- Создатель — это просто участник с наименьшим `seq` (см. `room_owner_id()`).
-- Тогда «создатель ушёл — права переходят старейшему из оставшихся»
-- выполняется само, без триггера передачи прав и без FK, который пришлось
-- бы разруливать при удалении аккаунта: удаление строки в `room_members`
-- УЖЕ и есть передача прав. Хранимое `creator_id` эту же семантику
-- обслуживало бы триггером на каждый выход и рассинхронизировалось бы
-- ровно там, где его забыли позвать.
--
-- ВТОРОЕ РЕШЕНИЕ: mute и блокировка внутри комнаты не действуют — вошли
-- в одну комнату, значит видите друг друга (осознанный выбор, см.
-- docs/data-model.md). Отсюда следствие, которое легко пропустить:
-- участники комнаты не обязаны быть Connections ДРУГ ДРУГУ (их собрал
-- владелец из СВОИХ знакомых), поэтому одной видимости поста мало —
-- профиль, аватарка и комментарии соседа по комнате тоже должны стать
-- видимыми, иначе в ленте комнаты пост будет без имени автора, а под ним
-- дыры вместо комментариев. Это `shares_room_with_caller()` ниже.
-- Предохранитель остаётся один: ДОБАВИТЬ в комнату того, с кем есть блок
-- в любую сторону, нельзя.
-- =====================================================================


-- =====================================================================
-- 1. Таблицы
-- =====================================================================

-- `name is null` — это не «без имени», а «имя собирается из участников»
-- (клиент перечисляет всех, кроме себя). Переименование пишет строку,
-- сброс имени пишет NULL и возвращает перечисление. Хранить перечисление
-- материализованно нельзя: имена участников меняются, состав тоже.
--
-- `direct_a`/`direct_b` — денормализация ради ОДНОГО инварианта: «с одним
-- человеком не больше одной парной комнаты». Через `room_members` его
-- уникальным индексом не выразить вовсе, а без него повторное нажатие
-- «написать» заводило бы вторую комнату с тем же человеком и тем же
-- именем. Пара всегда упорядочена least/greatest — тот же приём, что у
-- `connections_ordered_pair`.
create table public.rooms (
  id uuid default gen_random_uuid() not null,
  name text,
  is_direct boolean default false not null,
  direct_a uuid,
  direct_b uuid,
  created_at timestamp with time zone default now() not null,
  constraint rooms_pkey primary key (id),
  constraint rooms_name_length check ((name is null) or (char_length(name) <= 100)),
  constraint rooms_name_not_blank check ((name is null) or (btrim(name) <> ''::text)),
  -- Парная комната не переименовывается: она называется именем второго
  -- участника, у каждой стороны своим. Поэтому `name` у неё всегда NULL,
  -- и это проверка, а не соглашение.
  constraint rooms_direct_shape check (
    (is_direct and direct_a is not null and direct_b is not null and direct_a < direct_b and name is null)
    or (not is_direct and direct_a is null and direct_b is null)
  ),
  constraint rooms_direct_a_fkey foreign key (direct_a) references public.users(id) on delete cascade,
  constraint rooms_direct_b_fkey foreign key (direct_b) references public.users(id) on delete cascade
);

create unique index rooms_direct_pair_key on public.rooms using btree (direct_a, direct_b) where is_direct;

-- `seq` — порядок вступления, и он же порядок наследования комнаты.
-- Отдельная identity-колонка, а не `joined_at`: `create_room()` вставляет
-- всех участников одной транзакцией, где `now()` у всех строк совпадает
-- до микросекунды, и «кто раньше» по времени не разрешалось бы никак.
create table public.room_members (
  room_id uuid not null,
  user_id uuid not null,
  seq bigint generated always as identity,
  joined_at timestamp with time zone default now() not null,
  constraint room_members_pkey primary key (room_id, user_id),
  constraint room_members_room_id_fkey foreign key (room_id) references public.rooms(id) on delete cascade,
  constraint room_members_user_id_fkey foreign key (user_id) references public.users(id) on delete cascade
);

create index room_members_user_id_idx on public.room_members using btree (user_id);
create unique index room_members_room_seq_idx on public.room_members using btree (room_id, seq);

-- Адресат поста. Строка на каждую комнату, куда он опубликован; общая
-- лента живёт не здесь, а флагом `posts.in_general_feed` — иначе «общая
-- лента» стала бы строкой с `room_id is null`, которую не покрыть ни
-- внешним ключом, ни уникальным индексом по паре.
create table public.post_rooms (
  post_id uuid not null,
  room_id uuid not null,
  constraint post_rooms_pkey primary key (post_id, room_id),
  constraint post_rooms_post_id_fkey foreign key (post_id) references public.posts(id) on delete cascade,
  constraint post_rooms_room_id_fkey foreign key (room_id) references public.rooms(id) on delete cascade
);

-- Лента комнаты ходит именно этим путём: room_id → посты.
create index post_rooms_room_id_idx on public.post_rooms using btree (room_id);

-- `default true` — вся история постов остаётся постами общей ленты.
-- INSERT-гранта на эту колонку нет намеренно: её заполняет сервер в
-- `create_post_with_media()`, а колоночные гранты `posts` новую колонку
-- сами не подхватывают (см. «Дефолтные гранты Supabase» в CLAUDE.md).
alter table public.posts add column in_general_feed boolean default true not null;

-- Лента комнаты сортируется по `created_at desc, id desc` тем же keyset'ом,
-- что и общая, но по подмножеству постов одной комнаты.
create index posts_general_created_at_id_idx
  on public.posts using btree (created_at desc, id desc)
  where in_general_feed;

-- Под `media_path_in_my_rooms()`: storage-политика знает только путь
-- объекта, и от него надо дойти до поста.
create index post_media_storage_path_idx on public.post_media using btree (storage_path);
create index post_media_poster_path_idx on public.post_media using btree (poster_path) where poster_path is not null;

alter table public.rooms enable row level security;
alter table public.room_members enable row level security;
alter table public.post_rooms enable row level security;


-- =====================================================================
-- 2. Предикаты комнаты
-- =====================================================================

-- Некоррелированное множество вместо построчного предиката — тот же
-- приём и та же причина, что у `visible_author_ids()`: `security definer`
-- планировщик не инлайнит (см. «Грабли» в CLAUDE.md).
CREATE OR REPLACE FUNCTION public.my_room_ids()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select m.room_id from room_members m where m.user_id = auth.uid();
$function$;

-- Владелец комнаты = участник с наименьшим `seq`. Единственное место, где
-- это правило записано.
CREATE OR REPLACE FUNCTION public.room_owner_id(p_room_id uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select m.user_id from room_members m where m.room_id = p_room_id order by m.seq limit 1;
$function$;

-- «Этот человек в одной комнате со мной». Один аргумент, вторая сторона
-- всегда `auth.uid()` — поэтому её и безопасно выдать `authenticated`
-- (ровно та же логика, что у `is_connected_to_caller()`): чужой вопрос
-- «а эти двое в одной комнате» через неё не задать.
CREATE OR REPLACE FUNCTION public.shares_room_with_caller(p_other uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
      from room_members mine
      join room_members theirs on theirs.room_id = mine.room_id
     where mine.user_id = auth.uid()
       and theirs.user_id = p_other
  );
$function$;

-- «Этот пост лежит хотя бы в одной моей комнате». Тоже про вызывающего,
-- поэтому выдаётся `authenticated` — без этого её нельзя было бы позвать
-- из политики `posts`.
CREATE OR REPLACE FUNCTION public.post_in_my_rooms(p_post_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
      from post_rooms pr
      join room_members m on m.room_id = pr.room_id
     where pr.post_id = p_post_id
       and m.user_id = auth.uid()
  );
$function$;

-- Правило видимости ПОСТА целиком, как множество не выражаемое: две ветви,
-- общая лента и комната. Живёт здесь один раз; политика `posts` повторяет
-- его дословно по той же причине, по которой это делает `is_comment_visible()`
-- (построчный `security definer` на ленте — регрессия 20260726180000).
-- Менять надо оба места.
CREATE OR REPLACE FUNCTION public.is_post_visible(p_post_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((
    select (p.in_general_feed and public.is_author_visible(p.author_id))
        or public.post_in_my_rooms(p.id)
      from posts p
     where p.id = p_post_id
  ), false);
$function$;

-- Storage-политике доступно только имя объекта, поэтому путь → пост →
-- комната. Проверяются оба поля: постер видео лежит отдельной строкой
-- пути внутри той же строки `post_media`.
CREATE OR REPLACE FUNCTION public.media_path_in_my_rooms(p_path text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
      from post_media pm
      join post_rooms pr on pr.post_id = pm.post_id
     where (pm.storage_path = p_path or pm.poster_path = p_path)
       and pr.room_id in (select public.my_room_ids())
  );
$function$;


-- =====================================================================
-- 3. Политики комнат
-- =====================================================================
-- Ни INSERT, ни UPDATE, ни DELETE: состав и имя комнаты меняются только
-- через RPC ниже, где проверяется «я владелец», «он мой Connection» и
-- «блока нет». Политика для этого не годится — она умеет разрешить
-- запись, но не умеет объяснить отказ и не проверит соседние строки.

create policy "Rooms are viewable by their members"
  on public.rooms
  for select
  to authenticated
  using ((id in ( SELECT my_room_ids() AS my_room_ids)));

create policy "Room members are viewable by fellow members"
  on public.room_members
  for select
  to authenticated
  using ((room_id in ( SELECT my_room_ids() AS my_room_ids)));

-- Клиент читает её, чтобы показать «опубликовано в: …» и подставить
-- галочки при редактировании. Чужие адресаты через неё не видны: строка
-- отдаётся только участнику комнаты.
create policy "Post targets are viewable by room members"
  on public.post_rooms
  for select
  to authenticated
  using ((room_id in ( SELECT my_room_ids() AS my_room_ids)));


-- =====================================================================
-- 4. Видимость поста: вторая ветвь
-- =====================================================================

-- Было: `author_id in (select visible_author_ids())`.
-- Стало: то же самое, но только для постов общей ленты, плюс ветвь
-- комнаты. Пост, адресованный ТОЛЬКО в комнату, не виден нигде, кроме её
-- ленты, — включая стену профиля автора (клиент фильтрует по
-- `in_general_feed`, а здесь это гарантируется тем, что первая ветвь для
-- такого поста ложна для всех, включая самого автора: он проходит второй
-- ветвью, как участник).
drop policy "Posts are viewable by author and their connections" on public.posts;

create policy "Posts are viewable by connections or by room members"
  on public.posts
  for select
  to authenticated
  using (
    ((in_general_feed AND (author_id IN ( SELECT visible_author_ids() AS visible_author_ids))))
    OR post_in_my_rooms(id)
  );

-- Медиа больше не повторяет правило видимости, а спрашивает его у самого
-- поста: RLS применяется и к подзапросу внутри политики (см. «Грабли» в
-- CLAUDE.md), поэтому `exists (select 1 from posts …)` — это ровно
-- «пост видно». Тем же способом уже живут обе политики `comments` и все
-- политики `reactions`; лишняя копия правила здесь была четвёртой.
drop policy "Post media are viewable by author and their connections" on public.post_media;

create policy "Post media follow their post's visibility"
  on public.post_media
  for select
  to authenticated
  using ((EXISTS ( SELECT 1
   FROM posts p
  WHERE (p.id = post_media.post_id))));

-- Сосед по комнате — не обязательно Connection: комнату собрал владелец
-- из своих знакомых, и участники могут не знать друг друга. Без этой
-- ветви пост в ленте комнаты остался бы без имени автора (строка `users`
-- не видна), а его комментарии — невидимыми.
drop policy "Profiles are viewable by the user, their connections, the syste" on public.users;

create policy "Profiles are viewable by connections, room peers, commenters"
  on public.users
  for select
  to authenticated
  using (
    ((id = auth.uid()) OR is_system_account(id) OR is_connected_to_caller(id)
     OR shares_room_with_caller(id) OR is_commenter_visible_to_post_owner(id))
  );


-- Та же ветвь для комментариев. Прочитать автора родительского
-- комментария подзапросом ПРЯМО В ПОЛИТИКЕ нельзя: политика `comments`,
-- обращающаяся к `comments`, — это «infinite recursion detected in policy»,
-- поэтому все три ветви ходят через `security definer`-обёртку, как и
-- существующая `is_author_of_comment_visible()`.
--
-- Выдаётся `authenticated` (иначе её не позвать из политики) и это
-- безопасно: обе половины условия — про вызывающего, для чужой комнаты
-- функция всегда false.
CREATE OR REPLACE FUNCTION public.is_comment_author_room_peer(p_comment_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((
    select public.post_in_my_rooms(c.post_id)
       and public.shares_room_with_caller(c.author_id)
      from comments c
     where c.id = p_comment_id
  ), false);
$function$;

drop policy "Comments are viewable by the viewer's unmuted connections" on public.comments;

create policy "Comments are viewable by connections or by room peers"
  on public.comments
  for select
  to authenticated
  using (((EXISTS ( SELECT 1
   FROM posts p
  WHERE (p.id = comments.post_id)))
  AND ((author_id IN ( SELECT visible_author_ids() AS visible_author_ids)) OR is_comment_visible_to_post_owner(id) OR is_comment_author_room_peer(id))
  AND ((parent_comment_id IS NULL) OR is_author_of_comment_visible(parent_comment_id) OR is_comment_visible_to_post_owner(parent_comment_id) OR is_comment_author_room_peer(parent_comment_id))
  AND ((reply_to_id IS NULL) OR is_author_of_comment_visible(reply_to_id) OR is_comment_visible_to_post_owner(reply_to_id) OR is_comment_author_room_peer(reply_to_id))));


-- =====================================================================
-- 5. Функции, несущие копию правила видимости
-- =====================================================================

-- Дословный двойник SELECT-политики `comments` (единственный намеренный
-- дубликат в проекте — см. комментарий над ней в baseline). Меняются
-- обе, всегда вместе. Здесь добавились: ветвь комнаты в проверке поста и
-- `is_comment_author_room_peer()` в трёх ветвях автора.
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
        or public.is_comment_author_room_peer(c.id)
      )
      and (
        c.parent_comment_id is null
        or public.is_author_of_comment_visible(c.parent_comment_id)
        or public.is_comment_visible_to_post_owner(c.parent_comment_id)
        or public.is_comment_author_room_peer(c.parent_comment_id)
      )
      and (
        c.reply_to_id is null
        or public.is_author_of_comment_visible(c.reply_to_id)
        or public.is_comment_visible_to_post_owner(c.reply_to_id)
        or public.is_comment_author_room_peer(c.reply_to_id)
      )
    from comments c
    where c.id = p_comment_id
  ), false);
$function$;

-- Счётчики реакций: `security definer`, поэтому видимость проверяет сама —
-- и теперь спрашивает её у поста, а не у автора. Пост, адресованный только
-- в комнату, чужому по комнате счётчиков не отдаёт.
CREATE OR REPLACE FUNCTION public.reaction_summary(p_post_ids uuid[])
 RETURNS TABLE(post_id uuid, like_count bigint, neutral_count bigint, dislike_count bigint, my_reaction text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select
    p.id,
    count(*) filter (where r.type = 'like'),
    count(*) filter (where r.type = 'neutral'),
    count(*) filter (where r.type = 'dislike'),
    max(r.type) filter (where r.user_id = auth.uid())
  from posts p
  left join reactions r on r.post_id = p.id
  where p.id = any (p_post_ids)
    and public.is_post_visible(p.id)
  group by p.id;
$function$;


-- =====================================================================
-- 6. Storage
-- =====================================================================
-- Путь файла — `posts/<author_id>/…`, то есть политика знает только автора.
-- Для поста в комнате этого мало: сосед по комнате может быть не
-- Connection (или быть замьюченным — в комнате mute не действует), и тогда
-- пост в ленте открывался бы, а его фотографии — нет.

drop policy "Post photos are viewable by author and their connections" on storage.objects;

create policy "Post photos are viewable by connections or by room members"
  on storage.objects
  for select
  to authenticated
  using (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'posts'::text)
    AND ((((storage.foldername(name))[2])::uuid IN ( SELECT visible_author_ids() AS visible_author_ids))
         OR public.media_path_in_my_rooms(name))));

-- Аватарка соседа по комнате — по той же причине: без неё в ленте и в
-- списке участников у половины людей пустой кружок.
drop policy "Avatars are viewable by the user, their connections, and the sy" on storage.objects;

create policy "Avatars are viewable by the user, connections and room peers"
  on storage.objects
  for select
  to authenticated
  using (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'avatars'::text) AND (((storage.foldername(name))[2] = (auth.uid())::text) OR ((storage.foldername(name))[2] IN ( SELECT (s.s)::text AS s
   FROM system_account_ids() s(s))) OR public.shares_room_with_caller(((storage.foldername(name))[2])::uuid) OR (EXISTS ( SELECT 1
   FROM connections c
  WHERE (((c.user_a_id = auth.uid()) AND ((c.user_b_id)::text = (storage.foldername(objects.name))[2])) OR ((c.user_b_id = auth.uid()) AND ((c.user_a_id)::text = (storage.foldername(objects.name))[2]))))))));


-- =====================================================================
-- 7. Управление комнатой
-- =====================================================================
-- Все пять RPC — `security definer`: они пишут в `rooms`/`room_members`, на
-- которые у `authenticated` нет ни INSERT-, ни UPDATE-, ни DELETE-гранта.
-- Это осознанно: правила («я владелец», «он мой Connection», «блока нет»,
-- «в парную комнату не добавляют») политикой не выражаются, а отказ должен
-- быть объяснимым, а не «0 строк».

-- Комната пустеет — комната исчезает: последний вышедший уносит её с собой
-- вместе с лентой (посты падают каскадом через `post_rooms`... точнее, сами
-- посты остаются, каскадом уходит только адресация — пост, у которого не
-- осталось ни одного адресата и который не в общей ленте, недостижим ни для
-- кого, и его подберёт `reap_orphaned_media()`/`purge_empty_posts()` по
-- общим правилам).
--
-- Парная комната умирает от ухода ЛЮБОЙ из сторон: она и есть пара, и
-- «комната на одного» с чужой перепиской внутри — не то, что должно
-- остаться. Групповая переживает уход кого угодно, включая владельца:
-- владелец — это просто минимальный `seq`, и он пересчитывается сам.
CREATE OR REPLACE FUNCTION public.cleanup_orphaned_room()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if exists (select 1 from rooms r where r.id = old.room_id and r.is_direct)
     or not exists (select 1 from room_members m where m.room_id = old.room_id)
  then
    delete from rooms where id = old.room_id;
  end if;
  return old;
end;
$function$;

create trigger room_members_cleanup_after_delete
  after delete on public.room_members
  for each row execute function public.cleanup_orphaned_room();

-- Создать комнату. Идемпотентна ТОЛЬКО для парной: там уникальный индекс
-- по паре, и повторный вызов (второе нажатие, ретрай после таймаута)
-- возвращает существующую комнату, а не заводит вторую. Групповая
-- идемпотентности не имеет — двойное нажатие заведёт две комнаты, и это
-- сознательный размен: ключа, по которому две группы «одинаковы», не
-- существует (тот же состав — законный повод завести вторую комнату).
CREATE OR REPLACE FUNCTION public.create_room(p_member_ids uuid[], p_name text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me uuid := auth.uid();
  v_ids uuid[];
  v_other uuid;
  v_room uuid;
begin
  if v_me is null then
    raise exception 'Not authenticated';
  end if;

  -- Себя из списка вычёркиваем молча: клиенту незачем знать, включать ли
  -- себя, а дубликат в `room_members` был бы ошибкой первичного ключа.
  select coalesce(array_agg(distinct x), '{}'::uuid[]) into v_ids
    from unnest(coalesce(p_member_ids, '{}'::uuid[])) x
   where x <> v_me;

  if coalesce(array_length(v_ids, 1), 0) = 0 then
    raise exception 'A room needs at least one other member' using errcode = 'PT422';
  end if;

  if array_length(v_ids, 1) > 49 then
    raise exception 'room_member_limit_exceeded' using errcode = 'P0001';
  end if;

  -- Единственное, что блок в комнате всё-таки делает: не даёт СОБРАТЬ
  -- комнату с тем, с кем блок в любую сторону. Уже существующую комнату
  -- блок не трогает — см. заголовок миграции.
  if exists (
    select 1 from unnest(v_ids) x
     where not public.are_connected(v_me, x)
        or public.is_blocked_pair(v_me, x)
  ) then
    raise exception 'Room members must be your connections' using errcode = 'PT422';
  end if;

  if array_length(v_ids, 1) = 1 then
    v_other := v_ids[1];

    select r.id into v_room
      from rooms r
     where r.is_direct
       and r.direct_a = least(v_me, v_other)
       and r.direct_b = greatest(v_me, v_other);

    if v_room is not null then
      return v_room;
    end if;

    -- Обе стороны могут нажать «написать» одновременно; проигравший гонку
    -- получает комнату победителя, а не ошибку уникального индекса.
    begin
      insert into rooms (is_direct, direct_a, direct_b)
      values (true, least(v_me, v_other), greatest(v_me, v_other))
      returning id into v_room;
    exception when unique_violation then
      select r.id into v_room
        from rooms r
       where r.is_direct
         and r.direct_a = least(v_me, v_other)
         and r.direct_b = greatest(v_me, v_other);
      return v_room;
    end;
  else
    insert into rooms (name)
    values (left(nullif(btrim(coalesce(p_name, '')), ''), 100))
    returning id into v_room;
  end if;

  -- Создатель вставляется ПЕРВЫМ, и это не косметика: наименьший `seq` —
  -- это и есть право владельца (см. `room_owner_id()`).
  insert into room_members (room_id, user_id) values (v_room, v_me);

  insert into room_members (room_id, user_id)
  select v_room, t.x
    from unnest(v_ids) with ordinality t(x, ord)
   order by t.ord;

  return v_room;
end;
$function$;

-- Переименовать. NULL/пусто — сброс к перечислению имён участников.
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

  if not exists (select 1 from rooms r where r.id = p_room_id) then
    raise exception 'Room not found' using errcode = 'PT404';
  end if;

  if public.room_owner_id(p_room_id) is distinct from auth.uid() then
    raise exception 'Only the room owner can do that' using errcode = 'PT403';
  end if;

  if exists (select 1 from rooms r where r.id = p_room_id and r.is_direct) then
    raise exception 'A one-to-one room cannot be renamed' using errcode = 'PT422';
  end if;

  update rooms
     set name = left(nullif(btrim(coalesce(p_name, '')), ''), 100)
   where id = p_room_id;
end;
$function$;

-- Добавить участника. Только владелец, только в групповую, только своего
-- Connection.
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

  if not exists (select 1 from rooms r where r.id = p_room_id) then
    raise exception 'Room not found' using errcode = 'PT404';
  end if;

  if public.room_owner_id(p_room_id) is distinct from v_me then
    raise exception 'Only the room owner can do that' using errcode = 'PT403';
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

-- Исключить участника. Только владелец и только не себя: уход владельца —
-- это `leave_room()`, где он заодно передаёт комнату.
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

  if not exists (select 1 from rooms r where r.id = p_room_id) then
    raise exception 'Room not found' using errcode = 'PT404';
  end if;

  if public.room_owner_id(p_room_id) is distinct from v_me then
    raise exception 'Only the room owner can do that' using errcode = 'PT403';
  end if;

  if p_user_id = v_me then
    raise exception 'Use leave_room to leave a room' using errcode = 'PT422';
  end if;

  delete from room_members m
   where m.room_id = p_room_id and m.user_id = p_user_id;
end;
$function$;

-- Выйти. Комнату это может и уничтожить — см. `cleanup_orphaned_room()`.
CREATE OR REPLACE FUNCTION public.leave_room(p_room_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  delete from room_members m
   where m.room_id = p_room_id and m.user_id = auth.uid();
end;
$function$;

-- Список комнат для экрана. Одним запросом вместо N+1: клиенту нужны имя,
-- состав (аватарки в списке) и время последней активности, а имя парной
-- комнаты он вообще собирает сам из второго участника.
--
-- `security definer` здесь не ради обхода политик `rooms`/`room_members`
-- (они пустили бы ровно те же строки), а ради `users`: имена и аватарки
-- соседей по комнате читаются одним join'ом вместо отдельного запроса.
-- Выборка ограничена `my_room_ids()` — чужую комнату через неё не увидеть.
CREATE OR REPLACE FUNCTION public.my_rooms()
 RETURNS TABLE(id uuid, name text, is_direct boolean, owner_id uuid, created_at timestamp with time zone, last_post_at timestamp with time zone, members jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select r.id,
         r.name,
         r.is_direct,
         public.room_owner_id(r.id),
         r.created_at,
         a.last_post_at,
         mem.members
    from rooms r
    cross join lateral (
      select max(p.created_at) as last_post_at
        from post_rooms pr
        join posts p on p.id = pr.post_id
       where pr.room_id = r.id
    ) a
    cross join lateral (
      select jsonb_agg(
               jsonb_build_object('id', u.id, 'name', u.name, 'avatar_path', u.avatar_path)
               order by m.seq
             ) as members
        from room_members m
        join users u on u.id = m.user_id
       where m.room_id = r.id
    ) mem
   where r.id in (select public.my_room_ids())
   order by coalesce(a.last_post_at, r.created_at) desc, r.id desc;
$function$;


-- =====================================================================
-- 8. Публикация: адресаты поста
-- =====================================================================
-- Тело взято из baseline (20260826000000), который перед этим сверен с
-- живой схемой; правки — только про адресатов, всё остальное построчно то
-- же самое (см. «`create or replace` переписывает ВСЁ тело» в CLAUDE.md).
--
-- Сигнатура меняется, поэтому старая функция СНАЧАЛА дропается: иначе
-- `create or replace` с новым списком аргументов завёл бы вторую
-- перегрузку, и вызов с тремя именованными параметрами (а именно так
-- ходят уже выложенные клиенты) стал бы для PostgREST неоднозначным и
-- падал бы 300 Multiple Choices — то есть публикация сломалась бы у всех
-- сразу. Новые параметры со значениями по умолчанию: клиент, который о
-- комнатах не знает, продолжает публиковать в общую ленту, ничего не
-- меняя. Грант после дропа выдаётся заново — он уходит вместе с функцией.
drop function if exists public.create_post_with_media(uuid, text, jsonb);

CREATE OR REPLACE FUNCTION public.create_post_with_media(p_client_token uuid, p_text text DEFAULT NULL::text, p_items jsonb DEFAULT '[]'::jsonb, p_room_ids uuid[] DEFAULT '{}'::uuid[], p_in_general_feed boolean DEFAULT true)
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
-- `return query`. `set_post_media()` с той же сигнатурой живёт без директивы
-- только потому, что не пишет `storage_path` без префикса таблицы ни в одном
-- месте; полагаться на это в функции, которую ещё будут править, не стоит.
#variable_conflict use_column
declare
  v_post_id uuid;
  v_prefix text;
  v_text text;
  v_removed text[];
  v_rooms uuid[];
  v_general boolean := coalesce(p_in_general_feed, true);
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

  select coalesce(array_agg(distinct x), '{}'::uuid[]) into v_rooms
    from unnest(coalesce(p_room_ids, '{}'::uuid[])) x;

  -- Пост без адресата некуда положить, и он не то же самое, что пост в
  -- общую ленту: молча дописать «ну пусть будет общая» значило бы
  -- опубликовать всем то, что человек собирался показать одной комнате.
  if not v_general and coalesce(array_length(v_rooms, 1), 0) = 0 then
    raise exception 'A post needs a destination' using errcode = 'PT422';
  end if;

  -- Членство проверяется здесь, а не политикой: `post_rooms` наполняется
  -- изнутри `security definer`, где RLS не применяется вовсе.
  if exists (
    select 1 from unnest(v_rooms) x
     where not exists (
       select 1 from room_members m
        where m.room_id = x and m.user_id = auth.uid()
     )
  ) then
    raise exception 'You are not a member of that room' using errcode = 'PT403';
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

  insert into posts (author_id, text, client_token, in_general_feed)
  values (auth.uid(), v_text, p_client_token, v_general)
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
           in_general_feed = v_general
     where id = v_post_id
       and (text is distinct from v_text or in_general_feed is distinct from v_general);

    -- Адресаты переписываются тем же правилом, что и медиа: состояние
    -- задаёт последний вызов с этим токеном. Выбывшая комната теряет пост
    -- из своей ленты — вместе с ним уходят и его комментарии там.
    delete from post_rooms pr
     where pr.post_id = v_post_id
       and not (pr.room_id = any (v_rooms));

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

  insert into post_rooms (post_id, room_id)
  select v_post_id, x from unnest(v_rooms) x
  on conflict (post_id, room_id) do nothing;

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
-- 9. Уведомления
-- =====================================================================
-- ВНИМАНИЕ. Это та самая функция, которую дважды пересоздавали из
-- дореформенного текста, и оба раза публиковать не мог никто, у кого есть
-- Connection без mute/block/избранного. Тело ниже взято из
-- 20260826120000 — миграции, которая трогала её последней, — а не из
-- baseline и не по памяти. После наката проверять не «применилось ли», а
-- `prosrc` на признаки старого тела (см. «Грабли» в CLAUDE.md).
--
-- Меняются ровно две вещи, обе про одно и то же: пост, не адресованный в
-- общую ленту, не должен порождать ни одного уведомления НЕ участнику
-- комнаты — иначе пуш «у Пети новый пост» рассказывает о существовании
-- поста тому, кому его не покажут.
--   1. ранний выход по `new.in_general_feed`;
--   2. тот же фильтр внутри подсчёта непрочитанного — иначе дайджест
--      считал бы посты, которых зритель не увидит, и звал бы его в пустую
--      ленту.
-- Уведомления УЧАСТНИКАМ комнаты о посте в ней — этап 2, вместе с
-- чатом: у них общая настройка и общий kind в send-push.
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

  -- Пост только в комнату: о нём знают её участники и никто больше.
  if not new.in_general_feed then
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
         and p.in_general_feed
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
-- 10. Гранты
-- =====================================================================
-- Правило прежнее: `authenticated` получает ровно то, чем пользуется, и
-- ничего сверх. Никаких INSERT/UPDATE/DELETE на комнаты — весь путь записи
-- идёт через RPC выше. Каждая функция в `public` — эндпоинт PostgREST,
-- поэтому `grant execute` тут только у тех, чей КАЖДЫЙ аргумент про самого
-- вызывающего (см. «Грабли» в CLAUDE.md):
--   my_room_ids / my_rooms                 — вообще без аргументов;
--   shares_room_with_caller(other)         — вторая сторона всегда auth.uid();
--   post_in_my_rooms / media_path_in_my_rooms / is_comment_author_room_peer
--                                          — «моё ли это», для чужой комнаты
--                                            всегда false.
-- Без гранта остаются `room_owner_id()`, `is_post_visible()` и
-- `cleanup_orphaned_room()`: первые две зовутся только изнутри
-- `security definer`-функций, третья — триггер.

revoke all on table public.rooms from anon, authenticated;
grant maintain, select on table public.rooms to authenticated;

revoke all on table public.room_members from anon, authenticated;
grant maintain, select on table public.room_members to authenticated;

revoke all on table public.post_rooms from anon, authenticated;
grant maintain, select on table public.post_rooms to authenticated;

revoke execute on function public.cleanup_orphaned_room() from public, anon, authenticated;

revoke execute on function public.room_owner_id(p_room_id uuid) from public, anon, authenticated;
revoke execute on function public.is_post_visible(p_post_id uuid) from public, anon, authenticated;

revoke execute on function public.my_room_ids() from public, anon, authenticated;
grant execute on function public.my_room_ids() to authenticated;

revoke execute on function public.my_rooms() from public, anon, authenticated;
grant execute on function public.my_rooms() to authenticated;

revoke execute on function public.shares_room_with_caller(p_other uuid) from public, anon, authenticated;
grant execute on function public.shares_room_with_caller(p_other uuid) to authenticated;

revoke execute on function public.post_in_my_rooms(p_post_id uuid) from public, anon, authenticated;
grant execute on function public.post_in_my_rooms(p_post_id uuid) to authenticated;

revoke execute on function public.media_path_in_my_rooms(p_path text) from public, anon, authenticated;
grant execute on function public.media_path_in_my_rooms(p_path text) to authenticated;

revoke execute on function public.is_comment_author_room_peer(p_comment_id uuid) from public, anon, authenticated;
grant execute on function public.is_comment_author_room_peer(p_comment_id uuid) to authenticated;

revoke execute on function public.create_room(p_member_ids uuid[], p_name text) from public, anon, authenticated;
grant execute on function public.create_room(p_member_ids uuid[], p_name text) to authenticated;

revoke execute on function public.rename_room(p_room_id uuid, p_name text) from public, anon, authenticated;
grant execute on function public.rename_room(p_room_id uuid, p_name text) to authenticated;

revoke execute on function public.add_room_member(p_room_id uuid, p_user_id uuid) from public, anon, authenticated;
grant execute on function public.add_room_member(p_room_id uuid, p_user_id uuid) to authenticated;

revoke execute on function public.remove_room_member(p_room_id uuid, p_user_id uuid) from public, anon, authenticated;
grant execute on function public.remove_room_member(p_room_id uuid, p_user_id uuid) to authenticated;

revoke execute on function public.leave_room(p_room_id uuid) from public, anon, authenticated;
grant execute on function public.leave_room(p_room_id uuid) to authenticated;

-- Грант ушёл вместе с дропнутой перегрузкой (см. раздел 8) — выдаётся заново.
revoke execute on function public.create_post_with_media(p_client_token uuid, p_text text, p_items jsonb, p_room_ids uuid[], p_in_general_feed boolean) from public, anon, authenticated;
grant execute on function public.create_post_with_media(p_client_token uuid, p_text text, p_items jsonb, p_room_ids uuid[], p_in_general_feed boolean) to authenticated;


-- =====================================================================
-- 11. Проверки после наката
-- =====================================================================
-- Не «применилось ли», а «то ли применилось»: у трёх новых таблиц не
-- должно быть ни одного гранта для `anon`, ни одной команды записи для
-- `authenticated`, а у `enqueue_post_notifications()` в теле обязана быть
-- ветвь про `in_general_feed` — именно её потеря дважды ломала публикацию.
do $$
declare
  v_bad text;
begin
  select string_agg(format('%s:%s:%s', table_name, grantee, privilege_type), ', ')
    into v_bad
    from information_schema.role_table_grants
   where table_schema = 'public'
     and table_name in ('rooms', 'room_members', 'post_rooms')
     and (grantee = 'anon'
          or (grantee = 'authenticated' and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')));
  if v_bad is not null then
    raise exception 'Неожиданные гранты на таблицах комнат: %', v_bad;
  end if;

  if not exists (
    select 1 from pg_proc
     where proname = 'enqueue_post_notifications'
       and prosrc like '%in_general_feed%'
  ) then
    raise exception 'enqueue_post_notifications() накатилась старым телом';
  end if;

  if not exists (
    select 1 from pg_policy
     where polrelid = 'public.posts'::regclass
       and polname = 'Posts are viewable by connections or by room members'
  ) then
    raise exception 'Политика видимости постов не заменилась';
  end if;
end;
$$;
