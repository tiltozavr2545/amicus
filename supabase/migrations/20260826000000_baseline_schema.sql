-- =====================================================================
-- BASELINE: конечное состояние схемы Amicus.
--
-- Этот файл — НЕ очередной шаг истории, а её свёртка: полное определение
-- схемы, какой она стоит в production на 2026-08-26. Он заменяет 104
-- миграции 20260707221946…20260825120000. Прежняя история никуда не
-- делась — она в git и в теге `pre-baseline-migrations`; там же лежат
-- развёрнутые обоснования каждого решения. Номера миграций в комментариях
-- ниже — адреса в этой истории:
--
--   git show pre-baseline-migrations:supabase/migrations/<версия>_*.sql
--
-- Содержимое выведено из ЖИВОЙ схемы (pg_catalog), а не из миграций:
-- миграция — журнал намерений, а не состояние, и в проекте такого возраста
-- нужная строка часто отменена более поздней (см. «Грабли» в CLAUDE.md).
-- Baseline проверен на чистой базе: применение только этого файла даёт
-- схему, побайтово совпадающую с production по колонкам, ограничениям,
-- индексам, телам функций, триггерам, RLS-политикам и грантам.
--
-- ЧЕГО ЗДЕСЬ НЕТ И ПОЧЕМУ:
--   * объекты платформы Supabase (схемы auth/storage/graphql, роли
--     anon/authenticated/service_role, событийный триггер `ensure_rls`,
--     триггеры на storage.objects) — их заводит сам проект Supabase;
--   * секреты. Значения в Vault ставятся руками один раз, см.
--     docs/operations.md. Здесь только задания pg_cron, которые их читают.
--
-- ПОРЯДОК ВАЖЕН: таблицы → функции → триггеры → RLS → гранты. Функции на
-- SQL проверяются при создании, поэтому предикаты видимости идут строго
-- снизу вверх по зависимостям.
-- =====================================================================


-- =====================================================================
-- 1. Расширения
-- =====================================================================
-- pgcrypto нужен gen_random_bytes() в invite-кодах, pg_cron и pg_net —
-- заданиям в конце файла. На живом проекте Supabase все четыре уже стоят;
-- `if not exists` оставляет их как есть (в частности, pg_cron на облаке
-- живёт в pg_catalog, а не в extensions, и переносить его не надо).

create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
create extension if not exists pg_cron with schema extensions;
create extension if not exists pg_net with schema extensions;


-- =====================================================================
-- 2. Таблицы
-- =====================================================================
-- Порядок — по внешним ключам. `users` ссылается на `auth.users`, всё
-- остальное — на `public.users`, кроме `invite_links` (см. ниже).

-- Профиль. `id` — тот же uuid, что и в `auth.users`; строку заводит триггер
-- `handle_new_user()`, INSERT-гранта у клиента нет вовсе. Из колонок клиент
-- пишет только `name`: `avatar_path` держит в синхроне триггер
-- `sync_avatar_path_from_profile_photos()`, `created_at` и
-- `dislikes_disabled` — серверные (20260820140000, 20260822210000).
create table public.users (
  id uuid not null,
  name text not null,
  avatar_path text,
  created_at timestamp with time zone default now() not null,
  dislikes_disabled boolean default false not null,
  constraint users_pkey primary key (id),
  constraint users_name_length CHECK ((char_length(name) <= 100)),
  constraint users_name_not_blank CHECK ((btrim(name) <> ''::text)),
  constraint users_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE
);

-- Двусторонняя связь, ровно одна строка на пару. `connections_ordered_pair`
-- вместе с `connections_unique_pair` не даёт завести пару дважды в
-- «зеркальном» порядке — поэтому все вставки идут через
-- least()/greatest().
create table public.connections (
  id uuid default gen_random_uuid() not null,
  user_a_id uuid not null,
  user_b_id uuid not null,
  method text not null,
  created_at timestamp with time zone default now() not null,
  constraint connections_pkey primary key (id),
  constraint connections_unique_pair unique (user_a_id, user_b_id),
  constraint connections_method_check CHECK ((method = ANY (ARRAY['invite_link'::text, 'qr_code'::text]))),
  constraint connections_ordered_pair CHECK ((user_a_id < user_b_id)),
  constraint connections_user_a_id_fkey FOREIGN KEY (user_a_id) REFERENCES public.users(id) ON DELETE CASCADE,
  constraint connections_user_b_id_fkey FOREIGN KEY (user_b_id) REFERENCES public.users(id) ON DELETE CASCADE
);

-- Предъявительский код связи. FK смотрят в `auth.users`, а не в
-- `public.users`, — так завела 20260708092302 и так и осталось.
-- Частичный уникальный индекс `invite_links_one_active_per_owner` ниже
-- держит инвариант «не больше одного живого кода на владельца»; на нём
-- стоит `rotate_invite_link()`.
create table public.invite_links (
  id uuid default gen_random_uuid() not null,
  owner_id uuid not null,
  code text not null,
  is_used boolean default false not null,
  used_by_id uuid,
  created_at timestamp with time zone default now() not null,
  constraint invite_links_pkey primary key (id),
  constraint invite_links_code_key unique (code),
  constraint invite_links_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES auth.users(id) ON DELETE CASCADE,
  constraint invite_links_used_by_id_fkey FOREIGN KEY (used_by_id) REFERENCES auth.users(id) ON DELETE SET NULL
);

-- Пост. `client_token` — идемпотентность публикации: арбитр
-- `on conflict (author_id, client_token)` в `create_post_with_media()`.
-- `text` — либо NULL, либо непустой после btrim (20260822200000).
--
-- ЕДИНСТВЕННОЕ МЕСТО, где чистая база не совпадёт с production до номера
-- колонки: в проде на attnum 4 стоит могилка от `image_path`, который
-- 20260819220000 перенесла в `post_media` и дропнула, поэтому `created_at`
-- и `client_token` там 5 и 6, а здесь 4 и 5. Воспроизводить дырку значило
-- бы завести колонку только затем, чтобы её тут же дропнуть. Наружу это не
-- видно ничем: относительный порядок колонок тот же, а PostgREST отдаёт
-- объекты, а не кортежи.
create table public.posts (
  id uuid default gen_random_uuid() not null,
  author_id uuid not null,
  text text,
  created_at timestamp with time zone default now() not null,
  client_token uuid,
  constraint posts_pkey primary key (id),
  constraint posts_text_length CHECK (((text IS NULL) OR (char_length(text) <= 5000))),
  constraint posts_text_not_blank CHECK (((text IS NULL) OR (btrim(text) <> ''::text))),
  constraint posts_author_id_fkey FOREIGN KEY (author_id) REFERENCES public.users(id) ON DELETE CASCADE
);

-- До 20 элементов на пост, одна строка на элемент. `position` — только
-- порядок в карусели, плотность не гарантируется. UPDATE-политики нет
-- намеренно: замена файла и reorder — всегда delete+insert.
-- `poster_path` — JPEG первого кадра для video, генерируется клиентом.
create table public.post_media (
  id uuid default gen_random_uuid() not null,
  post_id uuid not null,
  "position" smallint not null,
  media_type text not null,
  storage_path text not null,
  poster_path text,
  created_at timestamp with time zone default now() not null,
  constraint post_media_pkey primary key (id),
  constraint post_media_post_position_key unique (post_id, "position"),
  constraint post_media_post_storage_path_key unique (post_id, storage_path),
  constraint post_media_media_type_check CHECK ((media_type = ANY (ARRAY['image'::text, 'video'::text]))),
  constraint post_media_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.posts(id) ON DELETE CASCADE
);

-- Галерея профиля, до 80 фото. Тот же неплотный `position` и тот же
-- delete+insert-reorder, что у `post_media` (20260819240000).
create table public.profile_photos (
  id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  "position" smallint not null,
  storage_path text not null,
  created_at timestamp with time zone default now() not null,
  constraint profile_photos_pkey primary key (id),
  constraint profile_photos_user_position_key unique (user_id, "position"),
  constraint profile_photos_user_storage_path_key unique (user_id, storage_path),
  constraint profile_photos_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE
);

-- Ровно одноуровневая вложенность: `parent_comment_id` — корень ветки,
-- `reply_to_id` — адресат метки «в ответ», `deleted_at` — заглушка.
-- `comments_text_not_blank` пропускает пустой текст только у заглушки:
-- `delete_own_comment()` делает её именно пустой строкой, и там это не
-- мусор, а само значение «текста больше нет» (20260824110000).
create table public.comments (
  id uuid default gen_random_uuid() not null,
  post_id uuid not null,
  author_id uuid not null,
  text text not null,
  created_at timestamp with time zone default now() not null,
  parent_comment_id uuid,
  reply_to_id uuid,
  deleted_at timestamp with time zone,
  client_token uuid,
  constraint comments_pkey primary key (id),
  constraint comments_text_length CHECK ((char_length(text) <= 5000)),
  constraint comments_text_not_blank CHECK (((deleted_at IS NOT NULL) OR (btrim(text) <> ''::text))),
  constraint comments_author_id_fkey FOREIGN KEY (author_id) REFERENCES public.users(id) ON DELETE CASCADE,
  constraint comments_parent_comment_id_fkey FOREIGN KEY (parent_comment_id) REFERENCES public.comments(id) ON DELETE CASCADE,
  constraint comments_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.posts(id) ON DELETE CASCADE,
  constraint comments_reply_to_id_fkey FOREIGN KEY (reply_to_id) REFERENCES public.comments(id) ON DELETE SET NULL
);

-- Одна реакция на пару (пост, пользователь). Переключение реакции — это
-- UPDATE, поэтому колоночный грант тут не годится (клиентский upsert шлёт
-- в SET все колонки); идентичность строки держит BEFORE UPDATE-триггер
-- `pin_reaction_identity()` (20260819150000).
create table public.reactions (
  id uuid default gen_random_uuid() not null,
  post_id uuid not null,
  user_id uuid not null,
  created_at timestamp with time zone default now() not null,
  type text default 'like'::text not null,
  constraint reactions_pkey primary key (id),
  constraint reactions_one_per_user_per_post unique (post_id, user_id),
  constraint reactions_type_check CHECK ((type = ANY (ARRAY['like'::text, 'neutral'::text, 'dislike'::text]))),
  constraint reactions_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.posts(id) ON DELETE CASCADE,
  constraint reactions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE
);

-- Мьют направленный, блок — нет. Обе таблицы разделяют форму и оба
-- ограничения «не на себя».
create table public.muted_users (
  muter_id uuid not null,
  muted_id uuid not null,
  created_at timestamp with time zone default now() not null,
  constraint muted_users_pkey primary key (muter_id, muted_id),
  constraint muted_users_no_self_mute CHECK ((muter_id <> muted_id)),
  constraint muted_users_muted_id_fkey FOREIGN KEY (muted_id) REFERENCES public.users(id) ON DELETE CASCADE,
  constraint muted_users_muter_id_fkey FOREIGN KEY (muter_id) REFERENCES public.users(id) ON DELETE CASCADE
);

create table public.blocked_users (
  blocker_id uuid not null,
  blocked_id uuid not null,
  created_at timestamp with time zone default now() not null,
  constraint blocked_users_pkey primary key (blocker_id, blocked_id),
  constraint blocked_users_no_self_block CHECK ((blocker_id <> blocked_id)),
  constraint blocked_users_blocked_id_fkey FOREIGN KEY (blocked_id) REFERENCES public.users(id) ON DELETE CASCADE,
  constraint blocked_users_blocker_id_fkey FOREIGN KEY (blocker_id) REFERENCES public.users(id) ON DELETE CASCADE
);

create table public.favorite_users (
  user_id uuid not null,
  favorite_id uuid not null,
  created_at timestamp with time zone default now() not null,
  constraint favorite_users_pkey primary key (user_id, favorite_id),
  constraint favorite_users_no_self_favorite CHECK ((user_id <> favorite_id)),
  constraint favorite_users_favorite_id_fkey FOREIGN KEY (favorite_id) REFERENCES public.users(id) ON DELETE CASCADE,
  constraint favorite_users_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE
);

-- Токен FCM на устройство. `app_version`/`app_build` — версия УСТАНОВКИ,
-- пишутся при каждом апсерте токена. NULL значит «старее всего
-- известного». Не больше 20 строк на пользователя, лишние вытесняются
-- триггером, а не отбиваются ошибкой (20260821180000).
create table public.device_tokens (
  user_id uuid not null,
  fcm_token text not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  locale text default 'ru'::text not null,
  app_version text,
  app_build integer,
  constraint device_tokens_pkey primary key (user_id, fcm_token),
  constraint device_tokens_app_build_positive CHECK (((app_build IS NULL) OR (app_build > 0))),
  constraint device_tokens_app_version_format CHECK (((app_version IS NULL) OR (app_version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'::text))),
  constraint device_tokens_fcm_token_length CHECK (((char_length(fcm_token) >= 64) AND (char_length(fcm_token) <= 4096))),
  constraint device_tokens_locale_check CHECK ((locale = ANY (ARRAY['en'::text, 'ru'::text]))),
  constraint device_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE
);

-- Очередь пушей. Политик нет вовсе — при включённой RLS это значит, что
-- `authenticated` не видит и не пишет ни строки; работает с ней только
-- `service_role` из Edge Function и `security definer`-функции.
create table public.notification_outbox (
  id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  kind text not null,
  payload jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null,
  sent_at timestamp with time zone,
  claimed_at timestamp with time zone,
  constraint notification_outbox_pkey primary key (id),
  constraint notification_outbox_kind_check CHECK ((kind = ANY (ARRAY['new_post'::text, 'inactive_week'::text, 'digest'::text, 'post_comment'::text, 'comment_reply'::text, 'app_update'::text]))),
  constraint notification_outbox_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE
);

-- Отсутствие строки = все уведомления включены; поэтому весь сервер
-- читает эти флаги через coalesce(..., true), а не через join.
create table public.notification_preferences (
  user_id uuid not null,
  notify_system_account boolean default true not null,
  notify_favorites boolean default true not null,
  notify_comments boolean default true not null,
  notify_digest boolean default true not null,
  notify_inactive_week boolean default true not null,
  constraint notification_preferences_pkey primary key (user_id),
  constraint notification_preferences_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE
);

-- Когда пользователь последний раз открывал приложение. Нужна дайджесту:
-- окно «что я не видел» отсчитывается от неё. Пишется только через
-- `touch_user_activity()`, политик нет.
create table public.user_activity (
  user_id uuid not null,
  last_active_at timestamp with time zone default now() not null,
  constraint user_activity_pkey primary key (user_id),
  constraint user_activity_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE
);


-- =====================================================================
-- 3. Индексы
-- =====================================================================
-- Только те, которых не заводят PRIMARY KEY/UNIQUE выше. Индексы на
-- ведущей колонке составного ключа тоже не дублируются: `favorite_users`
-- и `connections` индексируют ВТОРУЮ колонку пары, потому что правило
-- видимости спрашивает связь в обе стороны (20260821140000).

create index connections_user_b_id_idx on public.connections using btree (user_b_id);
create unique index invite_links_one_active_per_owner on public.invite_links using btree (owner_id) where (NOT is_used);
create unique index posts_author_id_client_token_key on public.posts using btree (author_id, client_token);
create index posts_author_id_created_at_idx on public.posts using btree (author_id, created_at);
create index posts_created_at_id_idx on public.posts using btree (created_at desc, id desc);
create unique index comments_author_id_client_token_key on public.comments using btree (author_id, client_token);
create index comments_parent_comment_id_idx on public.comments using btree (parent_comment_id);
create index comments_post_id_idx on public.comments using btree (post_id);
create index favorite_users_favorite_id_idx on public.favorite_users using btree (favorite_id);
create index notification_outbox_unsent_idx on public.notification_outbox using btree (created_at) where (sent_at IS NULL);
create index notification_outbox_user_kind_created_idx on public.notification_outbox using btree (user_id, kind, created_at desc);

-- =====================================================================
-- 4. Функции
-- =====================================================================
-- Порядок строгий: функции на SQL проверяются при создании, поэтому
-- предикаты видимости идут снизу вверх по зависимостям.
--
-- Каждая функция в `public` — эндпоинт PostgREST. Гранты на исполнение
-- собраны отдельным блоком (раздел 8) и выданы `authenticated` только там,
-- где каждый аргумент про самого вызывающего.


-- Единственное место, где живёт id системного аккаунта Amicus. Заведена
-- 20260821160000 для клиента (чтобы лента не носила копию id в APK) и
-- 20260822220000 сделана единственным источником и на сервере.
CREATE OR REPLACE FUNCTION public.system_account_ids()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE
AS $function$
  -- Тот же набор, что проверяет is_system_account(p_id).
  select 'e5110c16-91e7-44ca-8075-348bca3efedd'::uuid;
$function$;

-- Единственное хардкоженное исключение из правила видимости: системный
-- аккаунт виден всем (20260818150000).
CREATE OR REPLACE FUNCTION public.is_system_account(p_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from public.system_account_ids() as s where s = p_id
  );
$function$;

-- Три маленьких предиката, из которых собрано правило видимости. Все
-- `security definer` — иначе подзапрос к `blocked_users` внутри политики
-- сам фильтровался бы политикой `blocked_users`, и ветка «меня
-- заблокировали» молча отваливалась бы (см. «Грабли» в CLAUDE.md).
-- Ни один НЕ выдан `authenticated`: оба аргумента произвольные, и прямой
-- грант отвечал бы на чужой вопрос «а эти двое знакомы/замьючены/
-- заблокированы» (20260726140000).
CREATE OR REPLACE FUNCTION public.are_connected(p_user_a uuid, p_user_b uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from connections c
    where (c.user_a_id = p_user_a and c.user_b_id = p_user_b)
       or (c.user_b_id = p_user_a and c.user_a_id = p_user_b)
  );
$function$;
CREATE OR REPLACE FUNCTION public.has_muted(p_muter uuid, p_muted uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from muted_users m
    where m.muter_id = p_muter and m.muted_id = p_muted
  );
$function$;
CREATE OR REPLACE FUNCTION public.is_blocked_pair(user_a uuid, user_b uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from blocked_users b
    where (b.blocker_id = user_a and b.blocked_id = user_b)
       or (b.blocker_id = user_b and b.blocked_id = user_a)
  );
$function$;

-- ОДНО правило видимости на весь проект: я сам, системный аккаунт, либо
-- Connection, которого я не замьютил и с которым нет блока ни в одну
-- сторону. Раньше правило было размножено на четыре копии, две отстали от
-- mute/block и стали дырами; 20260726120000 свела их сюда.
-- МЕНЯТЬ ТОЛЬКО ЗДЕСЬ.
CREATE OR REPLACE FUNCTION public.is_author_visible(p_author uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select p_author = auth.uid()
      or public.is_system_account(p_author)
      or (
        public.are_connected(auth.uid(), p_author)
        and not public.has_muted(auth.uid(), p_author)
        and not public.is_blocked_pair(auth.uid(), p_author)
      );
$function$;

-- Та же проверка, но как множество, а не построчный предикат. В политиках
-- используется как `author_id in (select visible_author_ids())`:
-- `security definer`-функцию планировщик не инлайнит, и построчным
-- фильтром она стоила 217 мс на ленте против 3.5 мс здесь
-- (20260726180000). Системный аккаунт берётся прямым вызовом, а не
-- перебором `users` с предикатом на каждой строке (20260822250000).
CREATE OR REPLACE FUNCTION public.visible_author_ids()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select auth.uid()
  union
  select s from public.system_account_ids() s
  union
  select other.id
    from (
      select case when c.user_a_id = auth.uid() then c.user_b_id else c.user_a_id end as id
        from connections c
       where c.user_a_id = auth.uid() or c.user_b_id = auth.uid()
    ) other
   where public.is_author_visible(other.id);
$function$;

-- Однонаправленная обёртка над are_connected(): один аргумент, второй
-- всегда auth.uid(). Только её и безопасно выдать `authenticated` —
-- нужна в сырой политике `users`.
CREATE OR REPLACE FUNCTION public.is_connected_to_caller(p_other uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public.are_connected(auth.uid(), p_other);
$function$;

-- Автору поста видны комментарии под ним, даже если сам комментатор ему
-- не Connection (20260818170000). Mute и блок это всё равно сужают.
CREATE OR REPLACE FUNCTION public.is_comment_visible_to_post_owner(p_comment_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
    from comments c
    join posts p on p.id = c.post_id
    where c.id = p_comment_id
      and p.author_id = auth.uid()
      and not public.has_muted(auth.uid(), c.author_id)
      and not public.is_blocked_pair(auth.uid(), c.author_id)
  );
$function$;
CREATE OR REPLACE FUNCTION public.is_commenter_visible_to_post_owner(p_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
    from comments c
    join posts p on p.id = c.post_id
    where c.author_id = p_user_id
      and p.author_id = auth.uid()
  )
  and not public.has_muted(auth.uid(), p_user_id)
  and not public.is_blocked_pair(auth.uid(), p_user_id);
$function$;
CREATE OR REPLACE FUNCTION public.is_author_of_comment_visible(p_comment_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(
    public.is_author_visible(
      (select author_id from comments where id = p_comment_id)
    ),
    false
  );
$function$;

-- Дословная копия условия SELECT-политики `comments` — единственное место
-- в проекте, где правило продублировано НАМЕРЕННО. Подставить функцию в
-- саму политику нельзя: `security definer` не инлайнится, и построчный
-- вызов на ленте — регрессия из 20260726180000. Менять надо обе
-- (20260822140000).
CREATE OR REPLACE FUNCTION public.is_comment_visible(p_comment_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((
    select
      -- Пост виден. Внутри `security definer` политика posts не применяется,
      -- поэтому проверка выписана явно тем же некоррелированным множеством,
      -- что и в самой политике.
      exists (
        select 1 from posts p
         where p.id = c.post_id
           and p.author_id in (select public.visible_author_ids())
      )
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

-- Считает комментарии для ленты. `security invoker` осознанно: RLS на
-- `comments` применяется, поэтому чужие скрытые комментарии в счётчик не
-- попадают сами собой (20260817120000).
CREATE OR REPLACE FUNCTION public.comment_summary(p_post_ids uuid[])
 RETURNS TABLE(post_id uuid, comment_count bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select comments.post_id, count(*)
  from comments
  where comments.post_id = any (p_post_ids)
    and comments.deleted_at is null
  group by comments.post_id;
$function$;

-- А эта — `security definer`, поэтому видимость поста проверяет сама.
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
    and public.is_author_visible(p.author_id)
  group by p.id;
$function$;

-- Выпуск кода — две разные функции, и это не дубликат.
-- `create_invite_link()` идемпотентна: есть неиспользованный код — вернёт
-- ЕГО, что и нужно ретраю. `rotate_invite_link()` (20260822150000)
-- удаляет неиспользованные строки владельца и чеканит новую — единственный
-- способ отозвать код, отправленный не тому. Именно удаление, а не
-- `is_used = true`: отозванный код должен читаться как PT404 («нет
-- такого»), а не PT409 («уже использован») — второе неправда.
-- 16 байт энтропии (20260823140000): код предъявительский, не протухает и
-- открывает ленту, профиль и галерею; прежних 5 байт для этого мало.
CREATE OR REPLACE FUNCTION public.create_invite_link()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_code text;
  v_existing text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  -- Already have an unused invite? Hand back the same code instead of
  -- minting a new one (idempotent, and the client just displays whatever
  -- code comes back, so no app-side change needed).
  select code into v_existing
  from invite_links
  where owner_id = auth.uid() and not is_used
  limit 1;

  if v_existing is not null then
    return v_existing;
  end if;

  v_code := encode(gen_random_bytes(16), 'hex');

  insert into invite_links (owner_id, code)
  values (auth.uid(), v_code);

  return v_code;
end;
$function$;
CREATE OR REPLACE FUNCTION public.rotate_invite_link()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_code text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  delete from invite_links
   where owner_id = auth.uid()
     and not is_used;

  v_code := encode(gen_random_bytes(16), 'hex');

  insert into invite_links (owner_id, code)
  values (auth.uid(), v_code);

  return v_code;
end;
$function$;

-- Стабильные SQLSTATE наружу — PT404/PT409/PT422 (20260726170000); клиент
-- мапит их в строки из ARB и никогда не показывает e.message.
-- Код сгорает только если он ДЕЙСТВИТЕЛЬНО завёл связь: `is_used = true`
-- стоит под `row_count` вставки, иначе предъявление кода тем, кто с
-- владельцем и так на связи, гасило код впустую (20260825120000).
CREATE OR REPLACE FUNCTION public.activate_invite_link(p_code text)
 RETURNS TABLE(owner_id uuid, owner_name text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_invite invite_links%rowtype;
  v_connected int;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select * into v_invite
  from invite_links
  where code = p_code
  for update;

  if not found then
    raise exception 'Invite code not found' using errcode = 'PT404';
  end if;

  if v_invite.is_used then
    raise exception 'Invite code already used' using errcode = 'PT409';
  end if;

  if v_invite.owner_id = auth.uid() then
    raise exception 'Cannot activate your own invite link' using errcode = 'PT422';
  end if;

  insert into connections (user_a_id, user_b_id, method)
  values (least(v_invite.owner_id, auth.uid()), greatest(v_invite.owner_id, auth.uid()), 'invite_link')
  on conflict (user_a_id, user_b_id) do nothing;

  get diagnostics v_connected = row_count;

  if v_connected > 0 then
    update invite_links
    set is_used = true, used_by_id = auth.uid()
    where id = v_invite.id;
  end if;

  return query
  select u.id, u.name from users u where u.id = v_invite.owner_id;
end;
$function$;

-- Публикация поста вместе с медиа — ОДНОЙ транзакцией (20260823120000).
-- Раньше это были три запроса PostgREST подряд, то есть три транзакции:
-- обрыв после первой публиковал пост с текстом и без фотографий — живой в
-- ленте у всех знакомых, с уже ушедшим пушем, — пока композер показывал
-- «не удалось опубликовать».
-- Ветка конфликта по `client_token` не `do nothing`, а «привести пост к
-- присланному состоянию» (20260824100000): один токен — одна публикация,
-- содержимое которой определяет ПОСЛЕДНИЙ вызов с этим токеном. Раз
-- повтор может убрать медиа, функция возвращает осиротевшие пути, чтобы
-- клиент снёс объекты уже после переписывания строк (20260825110000).
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
$function$;

-- Путь РЕДАКТИРОВАНИЯ медиа. Клиент build 42+ зовёт её не напрямую, а
-- через update_post_with_media(); НЕ УДАЛЯТЬ и не снимать грант: по ней
-- ходит build 41, который сейчас стоит у всех
-- (`select min(app_build) from device_tokens`). Убрать можно будет, когда
-- это число перевалит за 42.
CREATE OR REPLACE FUNCTION public.set_post_media(p_post_id uuid, p_items jsonb)
 RETURNS TABLE(storage_path text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$;

-- То же, что create_post_with_media() для публикации: обе половины правки
-- приезжают вместе, поэтому инвариант «текст или медиа» наконец
-- проверяем (20260824120000). Внутри зовётся set_post_media(), а не её
-- переписанная копия: правило «какие пути осиротели» и проверка префикса
-- должны остаться в одном месте. Владение проверяется здесь и ДО неё —
-- `security definer` проносит UPDATE мимо политики «Users can edit their
-- own posts», так что это единственное, что отделяет чужой пост от
-- своего.
CREATE OR REPLACE FUNCTION public.update_post_with_media(p_post_id uuid, p_text text DEFAULT NULL::text, p_items jsonb DEFAULT '[]'::jsonb)
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

  update posts set text = v_text where id = p_post_id;

  -- Остальное — включая проверку префикса путей, лимит в 20 элементов и расчёт
  -- осиротевших объектов — принадлежит set_post_media() и остаётся там.
  return query select s.storage_path from public.set_post_media(p_post_id, p_items) s;
end;
$function$;

-- `position` раздаёт сервер, из той же транзакции, в которую строки и
-- лягут (20260824130000). Считать его на клиенте было нельзя: экран
-- считал от закэшированного списка, а тот отстаёт ровно тогда, когда
-- предыдущая попытка закоммитилась уже после «не удалось добавить фото».
CREATE OR REPLACE FUNCTION public.append_profile_photos(p_items jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_next int;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if jsonb_typeof(p_items) <> 'array' then
    raise exception 'Photo list must be an array' using errcode = 'PT422';
  end if;

  if jsonb_array_length(p_items) = 0 then
    return;
  end if;

  if exists (
    select 1
      from jsonb_array_elements(p_items) item
     where coalesce(item.value ->> 'storage_path', '')
           not like 'avatars/' || auth.uid()::text || '/%'
  ) then
    raise exception 'Photo path outside your own prefix' using errcode = 'PT422';
  end if;

  select coalesce(max(pp.position) + 1, 0) into v_next
    from profile_photos pp
   where pp.user_id = auth.uid();

  insert into profile_photos (user_id, position, storage_path)
  select
    auth.uid(),
    (v_next + row_number() over (order by fresh.idx) - 1)::smallint,
    fresh.storage_path
  from (
    select item.idx as idx, item.value ->> 'storage_path' as storage_path
      from jsonb_array_elements(p_items) with ordinality as item(value, idx)
     where not exists (
       select 1 from profile_photos pp
        where pp.user_id = auth.uid()
          and pp.storage_path = item.value ->> 'storage_path'
     )
  ) fresh
  on conflict (user_id, storage_path) do nothing;
end;
$function$;

-- Передавать надо ВСЮ галерею: позиции переписываются в плотные 0..N-1, и
-- частичная перестановка налезла бы на нетронутые строки (PT422).
-- Delete+insert — потому что UPDATE-политики у profile_photos нет; обе
-- половины в одной транзакции, иначе обрыв между ними стирал галерею
-- целиком вместе с users.avatar_path.
CREATE OR REPLACE FUNCTION public.reorder_profile_photos(p_photo_ids uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$;

-- Удаление комментария решает сервер: есть ответы — заглушка, нет —
-- реальный delete (20260725180000). DELETE-политики на `comments` нет
-- намеренно: прямой DELETE унёс бы по каскаду ответы ДРУГИХ людей.
-- «Нет такого комментария» и «есть, но чужой» отвечают одним PT404 —
-- различать их значит отвечать на вопрос «жива ли строка» про то, что
-- RLS обязана скрывать целиком (20260822140000).
CREATE OR REPLACE FUNCTION public.delete_own_comment(p_comment_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_author uuid;
  v_parent uuid;
  v_has_replies boolean;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  -- FOR UPDATE: см. 20260726150000, пункт (2). Обязан быть взят до проверки
  -- на наличие ответов.
  select author_id, parent_comment_id
    into v_author, v_parent
    from comments
   where id = p_comment_id
     for update;

  -- Один код на «нет такого комментария» и на «есть, но чужой». Различать их
  -- значит отвечать на вопрос «жива ли ещё та строка» про комментарий, который
  -- RLS обязана скрывать целиком.
  if not found or v_author is distinct from auth.uid() then
    raise exception 'Comment not found' using errcode = 'PT404';
  end if;

  select exists (
    select 1 from comments where parent_comment_id = p_comment_id
  ) into v_has_replies;

  -- Есть ответы: заглушка, чтобы ветка осталась читаемой.
  if v_has_replies then
    update comments
       set deleted_at = now(),
           text = ''
     where id = p_comment_id;
    return;
  end if;

  delete from comments where id = p_comment_id;

  -- Это был последний ответ под заглушкой? Тогда заглушке больше нечего
  -- держать вместе.
  if v_parent is not null then
    delete from comments
     where id = v_parent
       and deleted_at is not null
       and not exists (
         select 1 from comments r where r.parent_comment_id = v_parent
       );
  end if;
end;
$function$;

-- Удаляет строку в auth.users; всё остальное уносит `on delete cascade`.
CREATE OR REPLACE FUNCTION public.delete_own_account()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  delete from auth.users where id = auth.uid();
end;
$function$;

-- Единственный путь записи в user_activity: политик у таблицы нет.
CREATE OR REPLACE FUNCTION public.touch_user_activity()
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  insert into user_activity (user_id, last_active_at)
  values (auth.uid(), now())
  on conflict (user_id) do update set last_active_at = now();
$function$;

-- Профиль заводит сервер, не клиент: INSERT-гранта на `users` нет вовсе.
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  insert into public.users (id, name)
  values (
    new.id,
    left(
      coalesce(nullif(trim(new.raw_user_meta_data ->> 'name'), ''), 'Без имени'),
      100
    )
  );
  return new;
end;
$function$;

-- Структурные правила ответов. BEFORE INSERT-триггер срабатывает ДО
-- WITH CHECK политики, поэтому он молчит про всё, чего вызывающему видеть
-- нельзя: не видно — `return new`, и отказывает уже политика, одинаковым
-- 42501 на «нет строки», «строка чужая» и «строка-заглушка»
-- (20260822140000).
CREATE OR REPLACE FUNCTION public.enforce_comment_reply_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  parent record;
  addressee record;
begin
  if new.parent_comment_id is null then
    if new.reply_to_id is not null then
      raise exception 'Only a reply can address another comment';
    end if;
    return new;
  end if;

  -- Не рассказывать ничего про строку, которой вызывающему видеть нельзя:
  -- отдать вердикт INSERT-политике выше. Она отказывает одинаковым 42501 и
  -- когда строки нет, и когда она чужая, и когда это заглушка.
  if not public.is_comment_visible(new.parent_comment_id) then
    return new;
  end if;

  select post_id, parent_comment_id, deleted_at
    into parent
    from comments
   where id = new.parent_comment_id;

  -- Видимость уже проверена, так что сюда доходит только существующая строка.
  -- Ветка остаётся на случай удаления между двумя запросами: политика
  -- перепроверит то же самое и откажет.
  if not found then
    return new;
  end if;

  if parent.post_id <> new.post_id then
    raise exception 'Parent comment belongs to a different post';
  end if;
  if parent.parent_comment_id is not null then
    raise exception 'Replies cannot be nested more than one level deep';
  end if;
  if parent.deleted_at is not null then
    raise exception 'Cannot reply to a deleted comment';
  end if;

  -- Адресат обязан быть внутри этой же ветки: либо корень, либо один из его
  -- ответов. Иначе метка «в ответ» указывала бы на посторонний (возможно,
  -- невидимый) комментарий.
  if new.reply_to_id is not null then
    if not public.is_comment_visible(new.reply_to_id) then
      return new;
    end if;

    select parent_comment_id, deleted_at
      into addressee
      from comments
     where id = new.reply_to_id;

    if not found then
      return new;
    end if;

    if new.reply_to_id <> new.parent_comment_id
       and addressee.parent_comment_id is distinct from new.parent_comment_id then
      raise exception 'Addressed comment belongs to a different thread';
    end if;
    if addressee.deleted_at is not null then
      raise exception 'Cannot reply to a deleted comment';
    end if;
  end if;

  return new;
end;
$function$;
CREATE OR REPLACE FUNCTION public.enqueue_comment_notifications()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_commenter_name text;
  v_post_owner uuid;
  v_reply_target_author uuid;
begin
  select name into v_commenter_name from users where id = new.author_id;
  select author_id into v_post_owner from posts where id = new.post_id;

  if new.reply_to_id is not null then
    select author_id into v_reply_target_author from comments where id = new.reply_to_id;

    if v_reply_target_author is not null
       and v_reply_target_author <> new.author_id
       and not public.is_system_account(v_reply_target_author)
       and not public.has_muted(v_reply_target_author, new.author_id)
       and not public.is_blocked_pair(v_reply_target_author, new.author_id)
       and coalesce(
         (select notify_comments from notification_preferences where user_id = v_reply_target_author),
         true
       )
    then
      insert into notification_outbox (user_id, kind, payload)
      values (
        v_reply_target_author,
        'comment_reply',
        jsonb_build_object(
          'author_name', v_commenter_name,
          'post_id', new.post_id,
          'comment_id', new.id
        )
      );
    end if;

    if v_reply_target_author = v_post_owner then
      return new;
    end if;
  end if;

  if v_post_owner is not null
     and v_post_owner <> new.author_id
     and not public.is_system_account(v_post_owner)
     and not public.has_muted(v_post_owner, new.author_id)
     and not public.is_blocked_pair(v_post_owner, new.author_id)
     and coalesce(
       (select notify_comments from notification_preferences where user_id = v_post_owner),
       true
     )
  then
    insert into notification_outbox (user_id, kind, payload)
    values (
      v_post_owner,
      'post_comment',
      jsonb_build_object(
        'author_name', v_commenter_name,
        'post_id', new.post_id,
        'comment_id', new.id
      )
    );
  end if;

  return new;
end;
$function$;

-- Двойник и дайджест. Осторожно: `create or replace` переписывает ВСЁ
-- тело. Эту функцию дважды пересоздавали из дореформенного текста ради
-- правки одной ветки — и публиковать не мог никто, у кого есть Connection
-- без mute/block/избранного. После наката проверять не «применилось ли»,
-- а `prosrc` на признаки старого тела (см. «Грабли» в CLAUDE.md).
CREATE OR REPLACE FUNCTION public.enqueue_post_notifications()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_author_name text;
  v_viewer_id uuid;
  v_window_start timestamptz;
  v_unseen_count int;
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

  for v_viewer_id in
    select case when c.user_a_id = new.author_id then c.user_b_id else c.user_a_id end as viewer_id
      from connections c
     where c.user_a_id = new.author_id or c.user_b_id = new.author_id
     order by viewer_id
  loop
    continue when public.has_muted(v_viewer_id, new.author_id);
    continue when public.is_blocked_pair(v_viewer_id, new.author_id);
    continue when exists (
      select 1 from favorite_users f
      where f.user_id = v_viewer_id and f.favorite_id = new.author_id
    );
    continue when not coalesce(
      (select notify_digest from notification_preferences where user_id = v_viewer_id),
      true
    );

    -- Never having opened the (updated) app yet reads as "just became
    -- active" — nothing counts as unseen until we actually know otherwise.
    select coalesce(
      (select last_active_at from user_activity where user_id = v_viewer_id),
      now()
    ) into v_window_start;

    -- Already sent a digest since they were last active — the count can only
    -- have grown since, so nothing new to decide until they open the app
    -- again and this window moves forward.
    continue when exists (
      select 1 from notification_outbox n
      where n.user_id = v_viewer_id
        and n.kind = 'digest'
        and n.created_at > v_window_start
    );

    -- Direct joins against the base tables rather than has_muted()/
    -- is_blocked_pair() per row — those are fine called once per viewer
    -- (above), but calling a SECURITY DEFINER function per candidate post
    -- here is exactly the row-filter cost CLAUDE.md's "Грабли" warns about.
    select count(*) into v_unseen_count
    from posts p
    join connections c
      on (c.user_a_id = v_viewer_id and c.user_b_id = p.author_id)
      or (c.user_b_id = v_viewer_id and c.user_a_id = p.author_id)
    where p.created_at > v_window_start
      and not exists (
        select 1 from muted_users m
        where m.muter_id = v_viewer_id and m.muted_id = p.author_id
      )
      and not exists (
        select 1 from blocked_users b
        where (b.blocker_id = v_viewer_id and b.blocked_id = p.author_id)
           or (b.blocker_id = p.author_id and b.blocked_id = v_viewer_id)
      )
      and not exists (
        select 1 from favorite_users f
        where f.user_id = v_viewer_id and f.favorite_id = p.author_id
      );

    if v_unseen_count >= 7 then
      insert into notification_outbox (user_id, kind, payload)
      values (v_viewer_id, 'digest', jsonb_build_object('count', v_unseen_count));
    end if;
  end loop;

  return new;
end;
$function$;

-- Backstop-лимиты. BEFORE INSERT-триггер срабатывает до арбитража
-- `ON CONFLICT`, поэтому строка, которую `DO NOTHING` в итоге отбросит,
-- всё равно проходит через триггер: без ветки «это дубликат по тому же
-- ключу» лимит ловил не 21-й элемент, а ретрай уже опубликованного поста
-- (20260820120000).
CREATE OR REPLACE FUNCTION public.enforce_post_media_limit()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  -- Повтор уже существующего элемента: `ON CONFLICT (post_id, storage_path)`
  -- отбросит эту строку сам, а в лимит она уже посчитана.
  if exists (
    select 1 from public.post_media
    where post_id = new.post_id
      and storage_path = new.storage_path
  ) then
    return new;
  end if;

  if (select count(*) from public.post_media where post_id = new.post_id) >= 20 then
    raise exception 'post_media_limit_exceeded' using errcode = 'P0001';
  end if;
  return new;
end;
$function$;
CREATE OR REPLACE FUNCTION public.enforce_profile_photos_limit()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  -- То же самое по `(user_id, storage_path)`.
  if exists (
    select 1 from public.profile_photos
    where user_id = new.user_id
      and storage_path = new.storage_path
  ) then
    return new;
  end if;

  if (select count(*) from public.profile_photos where user_id = new.user_id) >= 80 then
    raise exception 'profile_photos_limit_exceeded' using errcode = 'P0001';
  end if;
  return new;
end;
$function$;
CREATE OR REPLACE FUNCTION public.enforce_device_token_limit()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  -- Повторная регистрация того же устройства: строку разрешит `ON CONFLICT`,
  -- в лимит она уже посчитана, вытеснять ради неё нечего.
  if exists (
    select 1 from public.device_tokens
    where user_id = new.user_id and fcm_token = new.fcm_token
  ) then
    return new;
  end if;

  -- Оставить место ровно под эту строку: держим 19 последних выходивших на
  -- связь, остальные уходят.
  delete from public.device_tokens d
   where d.user_id = new.user_id
     and (d.user_id, d.fcm_token) in (
       select d2.user_id, d2.fcm_token
         from public.device_tokens d2
        where d2.user_id = new.user_id
        order by d2.updated_at desc, d2.fcm_token desc
        offset 19
     );

  return new;
end;
$function$;

-- Апсерт токена шлёт в SET все колонки payload, поэтому колоночный грант
-- на UPDATE уронил бы регистрацию пушей — вместо гранта пин триггером
-- (20260822130000). Вторая строка важнее первой: до неё `updated_at` не
-- обновлялся вообще и врал о том, когда устройство выходило на связь.
CREATE OR REPLACE FUNCTION public.pin_device_token_timestamps()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.created_at := old.created_at;
  new.updated_at := now();
  return new;
end;
$function$;

-- То же и по той же причине для реакций (20260819150000): молча
-- возвращает идентичность строки к старым значениям, `type` не трогает.
CREATE OR REPLACE FUNCTION public.pin_reaction_identity()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.id := old.id;
  new.post_id := old.post_id;
  new.user_id := old.user_id;
  new.created_at := old.created_at;
  return new;
end;
$function$;

-- `users.avatar_path` — единственное поле, которое читает весь остальной
-- клиент; триггер держит его равным фото с наименьшей `position`.
-- `security definer` не ради чужих строк, а потому что после
-- 20260822210000 у `authenticated` нет права писать эту колонку вовсе.
CREATE OR REPLACE FUNCTION public.sync_avatar_path_from_profile_photos()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update public.users
  set avatar_path = (
    select storage_path from public.profile_photos
    where user_id = coalesce(new.user_id, old.user_id)
    order by position asc
    limit 1
  )
  where id = coalesce(new.user_id, old.user_id);
  return coalesce(new, old);
end;
$function$;

-- Обслуживание. Ничего из этого блока не выдано `authenticated`:
-- зовёт либо pg_cron, либо Edge Function под service_role.
CREATE OR REPLACE FUNCTION public.claim_notification_outbox(p_limit integer)
 RETURNS TABLE(id uuid, user_id uuid, kind text, payload jsonb)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update notification_outbox o
     set claimed_at = now()
   where o.id in (
     select n.id
       from notification_outbox n
      where n.sent_at is null
        and (n.claimed_at is null or n.claimed_at < now() - interval '5 minutes')
      order by n.created_at
      limit p_limit
      for update skip locked
   )
  returning o.id, o.user_id, o.kind, o.payload;
$function$;
CREATE OR REPLACE FUNCTION public.enqueue_inactive_week_notifications()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  insert into notification_outbox (user_id, kind, payload)
  select u.id, 'inactive_week', '{}'::jsonb
  from users u
  where not public.is_system_account(u.id)
    and u.created_at < now() - interval '7 days'
    and not exists (
      select 1 from posts p
      where p.author_id = u.id and p.created_at > now() - interval '7 days'
    )
    and not exists (
      select 1 from notification_outbox n
      where n.user_id = u.id
        and n.kind = 'inactive_week'
        and n.created_at > now() - interval '7 days'
    )
    and coalesce(
      (select notify_inactive_week from notification_preferences where user_id = u.id),
      true
    );
end;
$function$;
CREATE OR REPLACE FUNCTION public.enqueue_app_update_notifications(p_min_build integer, p_version text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_queued integer;
begin
  if p_min_build is null or p_min_build <= 0 then
    raise exception 'p_min_build must be a positive versionCode'
      using errcode = 'P0001';
  end if;

  with outdated as (
    select d.user_id
      from device_tokens d
     group by d.user_id
    having coalesce(max(d.app_build), 0) < p_min_build
  ),
  queued as (
    insert into notification_outbox (user_id, kind, payload)
    select o.user_id, 'app_update',
           jsonb_build_object('build', p_min_build, 'version', p_version)
      from outdated o
     where coalesce(
             (select notify_system_account from notification_preferences
               where user_id = o.user_id),
             true
           )
       and not exists (
         select 1 from notification_outbox n
          where n.user_id = o.user_id
            and n.kind = 'app_update'
            and n.payload->>'build' = p_min_build::text
       )
    returning 1
  )
  select count(*) into v_queued from queued;

  return v_queued;
end;
$function$;
CREATE OR REPLACE FUNCTION public.purge_notification_outbox()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_deleted integer;
begin
  with gone as (
    delete from notification_outbox
     where created_at < now() - interval '90 days'
    returning 1
  )
  select count(*) into v_deleted from gone;

  return v_deleted;
end;
$function$;

-- Крон остаётся нужным, пока не сняты гранты на прямой INSERT в
-- posts/post_media и на set_post_media(): ими пользуются установленные
-- сборки из Play, и пустой пост всё ещё может приехать оттуда.
CREATE OR REPLACE FUNCTION public.purge_empty_posts()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_deleted integer;
begin
  with doomed as (
    select p.id
      from posts p
     where p.text is null
       and p.created_at < now() - interval '1 hour'
       and not exists (select 1 from post_media m where m.post_id = p.id)
  ),
  gone as (
    delete from posts
     where id in (select id from doomed)
    returning 1
  )
  select count(*) into v_deleted from gone;

  return v_deleted;
end;
$function$;
CREATE OR REPLACE FUNCTION public.purge_abandoned_signups()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_deleted integer;
begin
  with doomed as (
    select au.id
      from auth.users au
     where au.email_confirmed_at is null
       and au.created_at < now() - interval '30 days'
       and not public.is_system_account(au.id)
       and not exists (select 1 from posts p where p.author_id = au.id)
       and not exists (select 1 from comments c where c.author_id = au.id)
       and not exists (select 1 from reactions r where r.user_id = au.id)
       and not exists (select 1 from connections cn
                        where cn.user_a_id = au.id or cn.user_b_id = au.id)
       and not exists (select 1 from invite_links il
                        where il.owner_id = au.id or il.used_by_id = au.id)
       and not exists (select 1 from profile_photos pp where pp.user_id = au.id)
       and not exists (select 1 from device_tokens dt where dt.user_id = au.id)
  ),
  gone as (
    delete from auth.users au
     where au.id in (select id from doomed)
    returning au.id
  )
  select count(*) into v_deleted from gone;

  return v_deleted;
end;
$function$;

-- Уборка бакета. Заливка идёт ДО вставки строк, поэтому каждый брошенный
-- черновик оставляет за собой то, что успел залить (20260823110000).
-- Строки storage.objects тут не трогаются намеренно: объект сносит
-- Storage API, а он сам приберёт за собой и строку.
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
     and (storage.foldername(o.name))[1] in ('posts', 'avatars')
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
   order by o.name
   limit 100;
$function$;
CREATE OR REPLACE FUNCTION public.reap_orphaned_media()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_paths text[];
begin
  select array_agg(p) into v_paths from public.orphaned_media_paths() p;

  if v_paths is null then
    return 0;
  end if;

  -- Batch-эндпоинт: один запрос на запуск, а не один на объект.
  perform net.http_delete(
    url := (select decrypted_secret from vault.decrypted_secrets
             where name = 'storage_object_url'),
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets
                                      where name = 'send_push_service_role_key'),
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object('prefixes', to_jsonb(v_paths))
  );

  -- Строки storage.objects тут не трогаются намеренно — см. заголовок.
  return array_length(v_paths, 1);
end;
$function$;

-- =====================================================================
-- 5. Триггеры
-- =====================================================================

-- Профиль заводится вместе с аккаунтом.
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create trigger comments_enforce_reply_rules
  before insert on public.comments
  for each row execute function public.enforce_comment_reply_rules();

create trigger on_comment_created_enqueue_notifications
  after insert on public.comments
  for each row execute function public.enqueue_comment_notifications();

create trigger on_post_created_enqueue_notifications
  after insert on public.posts
  for each row execute function public.enqueue_post_notifications();

create trigger post_media_enforce_limit_before_insert
  before insert on public.post_media
  for each row execute function public.enforce_post_media_limit();

create trigger profile_photos_enforce_limit_before_insert
  before insert on public.profile_photos
  for each row execute function public.enforce_profile_photos_limit();

create trigger profile_photos_sync_avatar_path
  after insert or delete or update on public.profile_photos
  for each row execute function public.sync_avatar_path_from_profile_photos();

create trigger device_tokens_enforce_limit_before_insert
  before insert on public.device_tokens
  for each row execute function public.enforce_device_token_limit();

create trigger device_tokens_pin_timestamps_before_update
  before update on public.device_tokens
  for each row execute function public.pin_device_token_timestamps();

create trigger reactions_pin_identity_before_update
  before update on public.reactions
  for each row execute function public.pin_reaction_identity();


-- =====================================================================
-- 6. RLS и политики
-- =====================================================================
-- RLS включена на каждой таблице `public` без исключений. У
-- `notification_outbox` и `user_activity` политик нет вовсе — это и есть
-- их правило доступа: `authenticated` не видит и не пишет там ничего.
--
-- Имена политик даны ровно так, как они лежат в каталоге: PostgreSQL
-- обрезает идентификатор по 63 байтам, и три длинных имени приехали сюда
-- уже обрезанными. Переписывать их «красиво» нельзя — получится вторая
-- политика рядом со старой.

alter table public.users enable row level security;
alter table public.connections enable row level security;
alter table public.invite_links enable row level security;
alter table public.posts enable row level security;
alter table public.post_media enable row level security;
alter table public.profile_photos enable row level security;
alter table public.comments enable row level security;
alter table public.reactions enable row level security;
alter table public.muted_users enable row level security;
alter table public.blocked_users enable row level security;
alter table public.favorite_users enable row level security;
alter table public.device_tokens enable row level security;
alter table public.notification_outbox enable row level security;
alter table public.notification_preferences enable row level security;
alter table public.user_activity enable row level security;

create policy "Profiles are viewable by the user, their connections, the syste"
  on public.users
  for select
  to authenticated
  using (((id = auth.uid()) OR is_system_account(id) OR is_connected_to_caller(id) OR is_commenter_visible_to_post_owner(id)));

create policy "Users can update their own profile"
  on public.users
  for update
  to authenticated
  using ((auth.uid() = id))
  with check ((auth.uid() = id));

create policy "Users can view their own connections"
  on public.connections
  for select
  to authenticated
  using (((auth.uid() = user_a_id) OR (auth.uid() = user_b_id)));

create policy "Owners can view their own invite links"
  on public.invite_links
  for select
  to authenticated
  using ((owner_id = auth.uid()));

create policy "Posts are viewable by author and their connections"
  on public.posts
  for select
  to authenticated
  using ((author_id IN ( SELECT visible_author_ids() AS visible_author_ids)));

create policy "Users can create their own posts"
  on public.posts
  for insert
  to authenticated
  with check (((author_id = auth.uid()) AND (created_at = now())));

create policy "Users can edit their own posts"
  on public.posts
  for update
  to authenticated
  using ((author_id = auth.uid()))
  with check ((author_id = auth.uid()));

create policy "Users can delete their own posts"
  on public.posts
  for delete
  to authenticated
  using ((author_id = auth.uid()));

create policy "Post media are viewable by author and their connections"
  on public.post_media
  for select
  to authenticated
  using ((EXISTS ( SELECT 1
   FROM posts p
  WHERE ((p.id = post_media.post_id) AND (p.author_id IN ( SELECT visible_author_ids() AS visible_author_ids))))));

create policy "Users can attach media to their own posts"
  on public.post_media
  for insert
  to authenticated
  with check (((created_at = now()) AND (EXISTS ( SELECT 1
   FROM posts p
  WHERE ((p.id = post_media.post_id) AND (p.author_id = auth.uid())))) AND (storage_path ~~ (('posts/'::text || (auth.uid())::text) || '/%'::text)) AND ((poster_path IS NULL) OR (poster_path ~~ (('posts/'::text || (auth.uid())::text) || '/%'::text)))));

create policy "Users can delete media from their own posts"
  on public.post_media
  for delete
  to authenticated
  using ((EXISTS ( SELECT 1
   FROM posts p
  WHERE ((p.id = post_media.post_id) AND (p.author_id = auth.uid())))));

create policy "Profile photos are viewable by the user, their connections, and"
  on public.profile_photos
  for select
  to authenticated
  using (((user_id = auth.uid()) OR is_system_account(user_id) OR is_connected_to_caller(user_id)));

create policy "Users can add their own profile photos"
  on public.profile_photos
  for insert
  to authenticated
  with check (((user_id = auth.uid()) AND (created_at = now()) AND (storage_path ~~ (('avatars/'::text || (auth.uid())::text) || '/%'::text))));

create policy "Users can delete their own profile photos"
  on public.profile_photos
  for delete
  to authenticated
  using ((user_id = auth.uid()));

create policy "Comments are viewable by the viewer's unmuted connections"
  on public.comments
  for select
  to authenticated
  using (((EXISTS ( SELECT 1
   FROM posts p
  WHERE (p.id = comments.post_id))) AND ((author_id IN ( SELECT visible_author_ids() AS visible_author_ids)) OR is_comment_visible_to_post_owner(id)) AND ((parent_comment_id IS NULL) OR is_author_of_comment_visible(parent_comment_id) OR is_comment_visible_to_post_owner(parent_comment_id)) AND ((reply_to_id IS NULL) OR is_author_of_comment_visible(reply_to_id) OR is_comment_visible_to_post_owner(reply_to_id))));

create policy "Users can comment on posts and comments they can see"
  on public.comments
  for insert
  to authenticated
  with check (((author_id = auth.uid()) AND (created_at = now()) AND (deleted_at IS NULL) AND (EXISTS ( SELECT 1
   FROM posts p
  WHERE (p.id = comments.post_id))) AND ((parent_comment_id IS NULL) OR is_comment_visible(parent_comment_id)) AND ((reply_to_id IS NULL) OR is_comment_visible(reply_to_id))));

create policy "Users can view their own reactions"
  on public.reactions
  for select
  to authenticated
  using ((user_id = auth.uid()));

create policy "Users can like posts they can see"
  on public.reactions
  for insert
  to authenticated
  with check (((user_id = auth.uid()) AND (created_at = now()) AND (EXISTS ( SELECT 1
   FROM posts p
  WHERE (p.id = reactions.post_id))) AND (NOT ((type = 'dislike'::text) AND (EXISTS ( SELECT 1
   FROM (posts p
     JOIN users u ON ((u.id = p.author_id)))
  WHERE ((p.id = reactions.post_id) AND u.dislikes_disabled)))))));

create policy "Users can change their own reaction"
  on public.reactions
  for update
  to authenticated
  using (((user_id = auth.uid()) AND (EXISTS ( SELECT 1
   FROM posts p
  WHERE (p.id = reactions.post_id)))))
  with check (((user_id = auth.uid()) AND (EXISTS ( SELECT 1
   FROM posts p
  WHERE (p.id = reactions.post_id))) AND (NOT ((type = 'dislike'::text) AND (EXISTS ( SELECT 1
   FROM (posts p
     JOIN users u ON ((u.id = p.author_id)))
  WHERE ((p.id = reactions.post_id) AND u.dislikes_disabled)))))));

create policy "Users can remove their own like"
  on public.reactions
  for delete
  to authenticated
  using ((user_id = auth.uid()));

create policy "Users manage their own mutes"
  on public.muted_users
  for all
  to authenticated
  using ((muter_id = auth.uid()))
  with check ((muter_id = auth.uid()));

create policy "Users manage their own blocks"
  on public.blocked_users
  for all
  to authenticated
  using ((blocker_id = auth.uid()))
  with check ((blocker_id = auth.uid()));

create policy "Users manage their own favorites"
  on public.favorite_users
  for all
  to authenticated
  using ((user_id = auth.uid()))
  with check ((user_id = auth.uid()));

create policy "Users manage their own device tokens"
  on public.device_tokens
  for all
  to authenticated
  using ((user_id = auth.uid()))
  with check ((user_id = auth.uid()));

-- notification_outbox: политик нет намеренно (см. выше).

create policy "Users manage their own notification preferences"
  on public.notification_preferences
  for all
  to authenticated
  using ((user_id = auth.uid()))
  with check ((user_id = auth.uid()));

-- user_activity: политик нет намеренно (см. выше).


-- =====================================================================
-- 7. Storage
-- =====================================================================
-- Бакет заводится здесь, а не руками в дашборде: до 20260822260000 его
-- настраивали через `update … where id = 'media'`, и на чистом проекте
-- такой update молча не находил ничего. `public = false` — инвариант, на
-- нём стоят обе SELECT-политики ниже; публичный бакет отменяет их разом.
-- Списки mime — ровно под imageExtensions/videoExtensions в
-- app/lib/shared/media_extensions.dart: storage_client берёт content-type
-- из расширения в имени объекта, а не из содержимого (20260820130000).

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'media', 'media', false, 104857600,
  array[
    'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif',
    'video/mp4', 'video/quicktime', 'video/x-m4v', 'video/3gpp',
    'video/webm', 'video/x-matroska'
  ]
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- UPDATE-политики нет ни у одного префикса (20260822210000): замена файла
-- тут всегда новый объект под свежим client-minted путём плюс delete
-- старого, поэтому uploadTolerant намеренно не ставит upsert.
-- `avatars/<uid>/…` видно себе, Connections и системному аккаунту, и блок
-- их НЕ сужает: заблокированный остаётся на экране «Заблокированные», где
-- блок и снимают, а тот рисует аватарку (20260823130000).

create policy "Avatars are viewable by the user, their connections, and the sy"
  on storage.objects
  for select
  to authenticated
  using (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'avatars'::text) AND (((storage.foldername(name))[2] = (auth.uid())::text) OR ((storage.foldername(name))[2] IN ( SELECT (s.s)::text AS s
   FROM system_account_ids() s(s))) OR (EXISTS ( SELECT 1
   FROM connections c
  WHERE (((c.user_a_id = auth.uid()) AND ((c.user_b_id)::text = (storage.foldername(objects.name))[2])) OR ((c.user_b_id = auth.uid()) AND ((c.user_a_id)::text = (storage.foldername(objects.name))[2]))))))));

create policy "Post photos are viewable by author and their connections"
  on storage.objects
  for select
  to authenticated
  using (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'posts'::text) AND (((storage.foldername(name))[2])::uuid IN ( SELECT visible_author_ids() AS visible_author_ids))));

create policy "Users can upload their own avatar"
  on storage.objects
  for insert
  to authenticated
  with check (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'avatars'::text) AND ((storage.foldername(name))[2] = (auth.uid())::text)));

create policy "Users can upload their own post photos"
  on storage.objects
  for insert
  to authenticated
  with check (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'posts'::text) AND ((storage.foldername(name))[2] = (auth.uid())::text)));

create policy "Users can delete their own avatar"
  on storage.objects
  for delete
  to authenticated
  using (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'avatars'::text) AND ((storage.foldername(name))[2] = (auth.uid())::text)));

create policy "Users can delete their own post photos"
  on storage.objects
  for delete
  to authenticated
  using (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'posts'::text) AND ((storage.foldername(name))[2] = (auth.uid())::text)));


-- =====================================================================
-- 8. Гранты
-- =====================================================================
-- У `anon` не оставлено ничего (20260818140000, 20260821120000): в
-- приложении нет ни одного анонимного чтения.
--
-- У `authenticated` каждая таблица сначала обнуляется, потом ей выдаётся
-- ровно то, что нужно, и по колонкам там, где запись частичная. `revoke
-- all` в начале — не украшение: дефолтные привилегии Supabase выдают
-- новой таблице в `public` полный набор прав обеим ролям, так что без
-- этого блока baseline на чистом проекте открыл бы больше, чем стоит в
-- production.
--
-- TRUNCATE (D) снят отдельно и это главное из трёх: на него RLS не
-- распространяется В ПРИНЦИПЕ — политики фильтруют строки, а он не
-- строчная операция. До 20260822240000 пользователь, которому политики
-- показывали 3 строки `reactions`, сносил все 56. TRIGGER (t) и
-- REFERENCES (x) сняты за компанию. MAINTAIN (m) оставлен сознательно: он
-- не даёт ни прочитать, ни изменить ни одной строки.
--
-- Инвариант «грант ↔ политика» проверяет блок в самом конце файла.

revoke all on table public.users from anon, authenticated;
grant maintain, select on table public.users to authenticated;
grant update (name) on table public.users to authenticated;

revoke all on table public.connections from anon, authenticated;
grant maintain, select on table public.connections to authenticated;

revoke all on table public.invite_links from anon, authenticated;
grant maintain, select on table public.invite_links to authenticated;

revoke all on table public.posts from anon, authenticated;
grant delete, maintain, select on table public.posts to authenticated;
grant insert (author_id, client_token, created_at, text) on table public.posts to authenticated;
grant update (text) on table public.posts to authenticated;

revoke all on table public.post_media from anon, authenticated;
grant delete, maintain, select on table public.post_media to authenticated;
grant insert (created_at, media_type, "position", post_id, poster_path, storage_path) on table public.post_media to authenticated;

revoke all on table public.profile_photos from anon, authenticated;
grant delete, maintain, select on table public.profile_photos to authenticated;
grant insert (created_at, "position", storage_path, user_id) on table public.profile_photos to authenticated;

revoke all on table public.comments from anon, authenticated;
grant maintain, select on table public.comments to authenticated;
grant insert (author_id, client_token, created_at, deleted_at, parent_comment_id, post_id, reply_to_id, text) on table public.comments to authenticated;

revoke all on table public.reactions from anon, authenticated;
grant delete, maintain, select, update on table public.reactions to authenticated;
grant insert (created_at, post_id, type, user_id) on table public.reactions to authenticated;

revoke all on table public.muted_users from anon, authenticated;
grant delete, maintain, select, update on table public.muted_users to authenticated;
grant insert (muted_id, muter_id) on table public.muted_users to authenticated;

revoke all on table public.blocked_users from anon, authenticated;
grant delete, maintain, select, update on table public.blocked_users to authenticated;
grant insert (blocked_id, blocker_id) on table public.blocked_users to authenticated;

revoke all on table public.favorite_users from anon, authenticated;
grant delete, maintain, select, update on table public.favorite_users to authenticated;
grant insert (favorite_id, user_id) on table public.favorite_users to authenticated;

revoke all on table public.device_tokens from anon, authenticated;
grant delete, maintain, select, update on table public.device_tokens to authenticated;
grant insert (app_build, app_version, fcm_token, locale, user_id) on table public.device_tokens to authenticated;

revoke all on table public.notification_outbox from anon, authenticated;

revoke all on table public.notification_preferences from anon, authenticated;
grant delete, insert, maintain, select, update on table public.notification_preferences to authenticated;

revoke all on table public.user_activity from anon, authenticated;

-- То же и на будущее: без этих строк следующая созданная таблица получит
-- права обратно из дефолтных привилегий — ровно так это и произошло между
-- 20260818140000 и 20260821120000. Миграции накатываются от имени
-- `postgres`, то есть именно от той роли, чьи дефолты здесь и правятся.
--
-- У `anon` дефолт снимается ЦЕЛИКОМ и по всем трём видам объектов. Роль в
-- этом приложении не используется вообще: анонимный вход выключен
-- (`enable_anonymous_sign_ins = false`), ни одного чтения до логина нет.
-- Дефолтный TRUNCATE отдавал бы каждую новую таблицу анониму мимо RLS, а
-- дефолтный EXECUTE делал бы каждую новую функцию анонимно вызываемой
-- PostgREST-ручкой. Последовательностей в схеме нет (ключи всюду uuid) —
-- строка про них стоит за компанию, чтобы дефолт не пришлось чинить
-- третий раз.
--
-- У `authenticated` снимаются только TRUNCATE/TRIGGER/REFERENCES, а не всё:
-- SELECT/INSERT/UPDATE/DELETE роли нужны, они и так сужены до конкретных
-- колонок в блоке выше. MAINTAIN оставлен сознательно — он не даёт ни
-- прочитать, ни изменить ни одной строки.
alter default privileges in schema public
  revoke truncate, trigger, references on tables from authenticated;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on functions from anon;
alter default privileges in schema public revoke all on sequences from anon;

-- Функции. Каждая в `public` — эндпоинт PostgREST, поэтому по умолчанию
-- закрыты все, а `authenticated` открыты только те, у которых каждый
-- аргумент про самого вызывающего. Предикаты видимости с двумя
-- произвольными uuid (are_connected/has_muted/is_blocked_pair) остаются
-- закрытыми: прямой грант отвечал бы на чужой вопрос (20260726140000).
-- Триггерные функции PostgREST не публикует, поэтому грант на них ничего не
-- открывает — но у `anon` он снимается и там: иначе дефолт выше и живая
-- схема разъезжаются, а прошлые миграции перечисляли функции поимённо и
-- триггерные пропускали.
revoke execute on function public.enforce_comment_reply_rules() from anon;
revoke execute on function public.enforce_device_token_limit() from anon;
revoke execute on function public.enforce_post_media_limit() from anon;
revoke execute on function public.enforce_profile_photos_limit() from anon;
revoke execute on function public.enqueue_comment_notifications() from anon;
revoke execute on function public.enqueue_post_notifications() from anon;
revoke execute on function public.handle_new_user() from anon;
revoke execute on function public.pin_device_token_timestamps() from anon;
revoke execute on function public.pin_reaction_identity() from anon;
revoke execute on function public.sync_avatar_path_from_profile_photos() from anon;

revoke execute on function public.activate_invite_link(p_code text) from public, anon, authenticated;
grant execute on function public.activate_invite_link(p_code text) to authenticated;
revoke execute on function public.append_profile_photos(p_items jsonb) from public, anon, authenticated;
grant execute on function public.append_profile_photos(p_items jsonb) to authenticated;
revoke execute on function public.are_connected(p_user_a uuid, p_user_b uuid) from public, anon, authenticated;
revoke execute on function public.claim_notification_outbox(p_limit integer) from public, anon, authenticated;
revoke execute on function public.comment_summary(p_post_ids uuid[]) from public, anon, authenticated;
grant execute on function public.comment_summary(p_post_ids uuid[]) to authenticated;
revoke execute on function public.create_invite_link() from public, anon, authenticated;
grant execute on function public.create_invite_link() to authenticated;
revoke execute on function public.create_post_with_media(p_client_token uuid, p_text text, p_items jsonb) from public, anon, authenticated;
grant execute on function public.create_post_with_media(p_client_token uuid, p_text text, p_items jsonb) to authenticated;
revoke execute on function public.delete_own_account() from public, anon, authenticated;
grant execute on function public.delete_own_account() to authenticated;
revoke execute on function public.delete_own_comment(p_comment_id uuid) from public, anon, authenticated;
grant execute on function public.delete_own_comment(p_comment_id uuid) to authenticated;
revoke execute on function public.enqueue_app_update_notifications(p_min_build integer, p_version text) from public, anon, authenticated;
revoke execute on function public.enqueue_inactive_week_notifications() from public, anon, authenticated;
revoke execute on function public.has_muted(p_muter uuid, p_muted uuid) from public, anon, authenticated;
revoke execute on function public.is_author_of_comment_visible(p_comment_id uuid) from public, anon, authenticated;
grant execute on function public.is_author_of_comment_visible(p_comment_id uuid) to authenticated;
revoke execute on function public.is_author_visible(p_author uuid) from public, anon, authenticated;
grant execute on function public.is_author_visible(p_author uuid) to authenticated;
revoke execute on function public.is_blocked_pair(user_a uuid, user_b uuid) from public, anon, authenticated;
revoke execute on function public.is_comment_visible(p_comment_id uuid) from public, anon, authenticated;
grant execute on function public.is_comment_visible(p_comment_id uuid) to authenticated;
revoke execute on function public.is_comment_visible_to_post_owner(p_comment_id uuid) from public, anon, authenticated;
grant execute on function public.is_comment_visible_to_post_owner(p_comment_id uuid) to authenticated;
revoke execute on function public.is_commenter_visible_to_post_owner(p_user_id uuid) from public, anon, authenticated;
grant execute on function public.is_commenter_visible_to_post_owner(p_user_id uuid) to authenticated;
revoke execute on function public.is_connected_to_caller(p_other uuid) from public, anon, authenticated;
grant execute on function public.is_connected_to_caller(p_other uuid) to authenticated;
revoke execute on function public.is_system_account(p_id uuid) from public, anon, authenticated;
grant execute on function public.is_system_account(p_id uuid) to authenticated;
revoke execute on function public.orphaned_media_paths() from public, anon, authenticated;
revoke execute on function public.purge_abandoned_signups() from public, anon, authenticated;
revoke execute on function public.purge_empty_posts() from public, anon, authenticated;
revoke execute on function public.purge_notification_outbox() from public, anon, authenticated;
revoke execute on function public.reaction_summary(p_post_ids uuid[]) from public, anon, authenticated;
grant execute on function public.reaction_summary(p_post_ids uuid[]) to authenticated;
revoke execute on function public.reap_orphaned_media() from public, anon, authenticated;
revoke execute on function public.reorder_profile_photos(p_photo_ids uuid[]) from public, anon, authenticated;
grant execute on function public.reorder_profile_photos(p_photo_ids uuid[]) to authenticated;
revoke execute on function public.rotate_invite_link() from public, anon, authenticated;
grant execute on function public.rotate_invite_link() to authenticated;
revoke execute on function public.set_post_media(p_post_id uuid, p_items jsonb) from public, anon, authenticated;
grant execute on function public.set_post_media(p_post_id uuid, p_items jsonb) to authenticated;
revoke execute on function public.system_account_ids() from public, anon, authenticated;
grant execute on function public.system_account_ids() to authenticated;
revoke execute on function public.touch_user_activity() from public, anon, authenticated;
grant execute on function public.touch_user_activity() to authenticated;
revoke execute on function public.update_post_with_media(p_post_id uuid, p_text text, p_items jsonb) from public, anon, authenticated;
grant execute on function public.update_post_with_media(p_post_id uuid, p_text text, p_items jsonb) to authenticated;
revoke execute on function public.visible_author_ids() from public, anon, authenticated;
grant execute on function public.visible_author_ids() to authenticated;

-- =====================================================================
-- 9. Задания pg_cron
-- =====================================================================
-- `cron.schedule` идемпотентна по имени задания: повторный накат baseline
-- перепишет расписание, а не заведёт второе.
--
-- Секреты сюда не попадают и не должны: значения ставятся руками один раз
-- на проект, см. docs/operations.md.
--   select vault.create_secret('<url>',               'send_push_function_url');
--   select vault.create_secret('<service_role_key>',  'send_push_service_role_key');
--   select vault.create_secret('<random>',            'send_push_shared_secret');
--   select vault.create_secret('<storage_batch_url>', 'storage_object_url');

-- Раз в минуту будит Edge Function, которая разгребает notification_outbox.
-- До минуты задержки вместо real-time — приложению этого размера хватает, а
-- polling избавляет от Vault/pg_net-обвязки, которую потребовал бы триггер
-- на каждую вставку.
--
-- `x-send-push-secret` — отдельный заголовок и отдельный секрет НЕ от
-- лишней осторожности: `Authorization` занят `verify_jwt`-гейтом, а
-- переменная SUPABASE_SERVICE_ROLE_KEY, которую платформа инжектит в
-- функцию, — не тот ключ, что лежит в Vault (у проекта одновременно живут
-- два поколения ключей). Сравнение bearer с этой переменной выглядит
-- очевидным и выключает пуши целиком (20260820160000).
select cron.schedule(
  'drain-notification-outbox',
  '* * * * *',
  $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'send_push_function_url'),
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'send_push_service_role_key'),
      'x-send-push-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'send_push_shared_secret'),
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb
  );
  $$
);

select cron.schedule('inactive-week-nudge',      '0 12 * * *', $$select public.enqueue_inactive_week_notifications();$$);
select cron.schedule('purge-empty-posts',        '20 * * * *', $$ select public.purge_empty_posts(); $$);
select cron.schedule('purge-abandoned-signups',  '40 3 * * *', $$ select public.purge_abandoned_signups(); $$);
select cron.schedule('reap-orphaned-media',      '45 4 * * *', $$ select public.reap_orphaned_media(); $$);
select cron.schedule('purge-notification-outbox','10 5 * * *', $$ select public.purge_notification_outbox(); $$);


-- =====================================================================
-- 10. Контрольный блок
-- =====================================================================
-- Накат падает, если baseline оставил базу в состоянии, которого в
-- production нет. Проверяется то, что уже дважды ломалось молча:
--
--   (1) таблица в `public` без RLS;
--   (2) любое право у `anon`;
--   (3) право на запись у `authenticated`, под которым нет ни одной
--       политики. Смотреть надо в ДВА места: `column_privileges` —
--       правильный источник для INSERT и UPDATE, которые бывают
--       поколоночными, и слепой на DELETE (это привилегия уровня таблицы,
--       там она не появляется никогда). Ровно на этом четыре мёртвых
--       DELETE-гранта прошли мимо проверки, написанной против такого
--       (20260824140000 → 20260825100000).

do $check$
declare
  v_bad text;
begin
  select string_agg(c.relname, ', ' order by c.relname) into v_bad
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
  if v_bad is not null then
    raise exception 'RLS выключена: %', v_bad;
  end if;

  select string_agg(format('%s:%s', table_name, privilege_type), ', ')
    into v_bad
    from information_schema.role_table_grants
   where table_schema = 'public' and grantee = 'anon';
  if v_bad is not null then
    raise exception 'у anon остались права: %', v_bad;
  end if;

  with granted as (
    select table_name, privilege_type
      from information_schema.role_table_grants
     where table_schema = 'public' and grantee = 'authenticated'
       and privilege_type in ('INSERT', 'UPDATE', 'DELETE')
    union
    select table_name, privilege_type
      from information_schema.column_privileges
     where table_schema = 'public' and grantee = 'authenticated'
       and privilege_type in ('INSERT', 'UPDATE', 'DELETE')
  )
  select string_agg(format('%s:%s', g.table_name, g.privilege_type), ', ')
    into v_bad
    from granted g
   where not exists (
     select 1
       from pg_policy p
       join pg_class c on c.oid = p.polrelid
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and c.relname = g.table_name
        and 'authenticated'::regrole = any (p.polroles)
        and p.polcmd = any (array['*'::"char", case g.privilege_type
                                                 when 'INSERT' then 'a'
                                                 when 'UPDATE' then 'w'
                                                 else 'd' end::"char"])
   );
  if v_bad is not null then
    raise exception 'грант на запись без политики: %', v_bad;
  end if;
end
$check$;
