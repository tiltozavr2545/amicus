-- =====================================================================
-- BASELINE: конечное состояние схемы Amicus.
--
-- Этот файл — НЕ очередной шаг истории, а её свёртка: полное определение
-- схемы, какой она стоит в production на 2026-10-18. История свёрнута уже
-- второй раз, и обе её части никуда не делись:
--
--   * 104 миграции 20260707221946…20260825120000 — в теге
--     `pre-baseline-migrations`;
--   * первый baseline 20260826000000 и 27 миграций поверх него,
--     20260826120000…20261010100000, — в теге `pre-baseline-migrations-2`.
--
-- Номера миграций в комментариях ниже — адреса в этой истории; там же
-- лежат развёрнутые обоснования каждого решения:
--
--   git show pre-baseline-migrations:supabase/migrations/<версия>_*.sql
--   git show pre-baseline-migrations-2:supabase/migrations/<версия>_*.sql
--
-- (номер не больше 20260825120000 — первый тег, иначе второй).
--
-- Содержимое выведено из ЖИВОЙ схемы (pg_catalog), а не из миграций:
-- миграция — журнал намерений, а не состояние, и нужная строка часто
-- отменена более поздней (см. «Грабли» в AGENTS.md). Тела функций,
-- политики, ограничения и индексы — ровно то, что печатают
-- `pg_get_functiondef`/`pg_get_expr`/`pg_get_constraintdef`/
-- `pg_get_indexdef` в production, поэтому политики пишут
-- `( SELECT auth.uid() AS uid)` — так каталог хранит
-- `(select auth.uid())`. Применение только этого файла к чистому проекту
-- даёт схему, совпадающую с production по колонкам и их порядку,
-- ограничениям, индексам, телам функций, триггерам, RLS-политикам
-- (включая storage и realtime), грантам, дефолтным привилегиям,
-- публикации realtime, бакету и заданиям pg_cron.
--
-- ЧЕГО ЗДЕСЬ НЕТ И ПОЧЕМУ:
--   * объекты платформы Supabase (схемы auth/storage/realtime/graphql,
--     роли anon/authenticated/service_role, событийный триггер `ensure_rls`
--     и его функция `public.rls_auto_enable()`, триггеры на
--     storage.objects) — их заводит сам проект Supabase;
--   * данные. Единственная строка, без которой схема не работает, — бакет
--     `media` (раздел 8); посты, профили и прочее сюда не относятся;
--   * секреты. Значения в Vault ставятся руками один раз, см.
--     docs/operations.md. Здесь только задания pg_cron, которые их читают.
--
-- Отличия от production, которые наружу не видны ничем: в production
-- `posts` и `notification_preferences` несут могилки дропнутых колонок
-- (`posts.image_path`, 20260819220000; `posts.in_general_feed` и
-- `notification_preferences.notify_room_posts`, 20260828100000), поэтому
-- номера колонок (attnum) там другие. Относительный порядок колонок тот же,
-- а PostgREST отдаёт объекты, а не кортежи. Воспроизводить дырку значило бы
-- заводить колонку только затем, чтобы её тут же дропнуть.
--
-- ПОРЯДОК ВАЖЕН: таблицы → функции → ограничения, которые зовут функции →
-- триггеры → RLS → storage и realtime → гранты → pg_cron. Функции на SQL
-- проверяются при создании, поэтому предикаты видимости идут строго снизу
-- вверх по зависимостям.
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
--
-- `write_banned_until` — запрет писать (20260913100000). NULL — не забанен;
-- дата в прошлом — бан кончился, и чистить её незачем, она же история;
-- постоянный бан — дата далеко в будущем, отдельного «навсегда» нет. Ставит
-- только консоль под service_role, исполняет `reject_write_when_banned()`.
-- Колонку видит каждый, кому RLS показывает строку: SELECT у
-- `authenticated` выдан на таблицу целиком, а не поколоночно, как считала
-- 20260913100000. Открытая находка — закрывать отдельной миграцией.
create table public.users (
  id uuid not null,
  name text not null,
  avatar_path text,
  created_at timestamp with time zone default now() not null,
  dislikes_disabled boolean default false not null,
  write_banned_until timestamp with time zone,
  constraint users_pkey primary key (id),
  constraint users_name_length CHECK ((char_length(name) <= 100)),
  constraint users_name_not_blank CHECK ((btrim(name) <> ''::text)),
  constraint users_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE
);

-- Двусторонняя связь, ровно одна строка на пару. `connections_ordered_pair`
-- вместе с `connections_unique_pair` не даёт завести пару дважды в
-- «зеркальном» порядке — поэтому все вставки идут через
-- least()/greatest().
--
-- `method` — откуда связь взялась: `invite_link` пишет
-- `activate_invite_link()`, `connection_request` — `request_connection()`
-- (встречная заявка) и `respond_to_connection_request()`, `manual` — ряды,
-- заведённые руками через Management API (20260826130000). `qr_code` —
-- задел под будущую фичу; ни один путь его не пишет.
create table public.connections (
  id uuid default gen_random_uuid() not null,
  user_a_id uuid not null,
  user_b_id uuid not null,
  method text not null,
  created_at timestamp with time zone default now() not null,
  constraint connections_pkey primary key (id),
  constraint connections_unique_pair unique (user_a_id, user_b_id),
  constraint connections_method_check CHECK ((method = ANY (ARRAY['invite_link'::text, 'qr_code'::text, 'manual'::text, 'connection_request'::text]))),
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
-- `visibility` — кому виден пост: `connections` — всем знакомым,
-- `favorites` — только тем, кого автор держит в избранном (20260829100000).
-- Текст с CHECK, а не boolean: «только избранным» — не отрицание «всем», и
-- третье значение ляжет сюда же. INSERT- и UPDATE-грантов на колонку нет:
-- её пишут только `create_post_with_media()` и `update_post_with_media()`,
-- где значение проверяется вместе с авторством.
--
-- `hidden_at` — скрытие модерацией (20260913100000). Скрытое исчезает у
-- ВСЕХ, включая автора: иначе у одного объекта два ответа на вопрос «виден
-- ли он», и правило видимости перестаёт быть одним. Автор узнаёт о скрытии
-- уведомлением `moderation_notice`. Ставит только консоль.
create table public.posts (
  id uuid default gen_random_uuid() not null,
  author_id uuid not null,
  text text,
  created_at timestamp with time zone default now() not null,
  client_token uuid,
  visibility text default 'connections'::text not null,
  hidden_at timestamp with time zone,
  constraint posts_pkey primary key (id),
  constraint posts_text_length CHECK (((text IS NULL) OR (char_length(text) <= 5000))),
  constraint posts_text_not_blank CHECK (((text IS NULL) OR (btrim(text) <> ''::text))),
  constraint posts_visibility_check CHECK ((visibility = ANY (ARRAY['connections'::text, 'favorites'::text]))),
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
-- `hidden_at` — скрытие модерацией, как у постов (20260913100000).
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
  hidden_at timestamp with time zone,
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
-- триггером, а не отбиваются ошибкой (20260821180000). Строка с тем же
-- токеном под другим пользователем забирается при регистрации — см.
-- `claim_device_token()`.
--
-- `platform`/`os_version` — на чём стоит установка (20260912100000). Обе
-- nullable, и CHECK их пропускает: выложенные клиенты эти колонки не шлют,
-- а жёсткая проверка на фоновом апсерте уронила бы регистрацию пуш-токена
-- целиком и молча. `platform` — перечисление, а не свободный текст: это
-- ключ, по которому собираются аудитории. `os_version` — только цифры и
-- точки, не больше трёх частей; приводит клиент (`shared/device_os.dart`).
create table public.device_tokens (
  user_id uuid not null,
  fcm_token text not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  locale text default 'ru'::text not null,
  app_version text,
  app_build integer,
  platform text,
  os_version text,
  constraint device_tokens_pkey primary key (user_id, fcm_token),
  constraint device_tokens_app_build_positive CHECK (((app_build IS NULL) OR (app_build > 0))),
  constraint device_tokens_app_version_format CHECK (((app_version IS NULL) OR (app_version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'::text))),
  constraint device_tokens_fcm_token_length CHECK (((char_length(fcm_token) >= 64) AND (char_length(fcm_token) <= 4096))),
  constraint device_tokens_locale_check CHECK ((locale = ANY (ARRAY['en'::text, 'ru'::text]))),
  constraint device_tokens_os_version_format CHECK (((os_version IS NULL) OR (os_version ~ '^[0-9]+(\.[0-9]+){0,2}$'::text))),
  constraint device_tokens_platform_check CHECK (((platform IS NULL) OR (platform = ANY (ARRAY['android'::text, 'ios'::text, 'macos'::text, 'windows'::text, 'linux'::text, 'fuchsia'::text, 'web'::text])))),
  constraint device_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE
);

-- Очередь пушей. Политик нет вовсе — при включённой RLS это значит, что
-- `authenticated` не видит и не пишет ни строки; работает с ней только
-- `service_role` из Edge Function и `security definer`-функции.
--
-- Новый `kind` — это ВСЕГДА две правки: CHECK здесь и тексты в `TEXTS`
-- send-push (см. «Релиз» в docs/operations.md). Без второй строка не
-- откладывается, а поглощается: drain её забирает, текста не находит и всё
-- равно ставит `sent_at`, иначе перевыбирал бы вечно (20260913110000).
--
-- Выключатель в `notification_preferences` есть не у каждого вида.
-- Заявка на знакомство, ответ на неё и решения модерации адресованы лично
-- и приходят редко: выключатель к ним значил бы «я больше никогда не
-- узнаю, что меня позвали» (20260828140000).
create table public.notification_outbox (
  id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  kind text not null,
  payload jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null,
  sent_at timestamp with time zone,
  claimed_at timestamp with time zone,
  constraint notification_outbox_pkey primary key (id),
  constraint notification_outbox_kind_check CHECK ((kind = ANY (ARRAY['new_post'::text, 'inactive_week'::text, 'digest'::text, 'post_comment'::text, 'comment_reply'::text, 'app_update'::text, 'app_update_important'::text, 'room_message'::text, 'connection_request'::text, 'connection_accepted'::text, 'moderation_notice'::text, 'report_resolved'::text, 'report_rejected'::text]))),
  constraint notification_outbox_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE
);

-- Отсутствие строки = все уведомления включены; поэтому весь сервер
-- читает эти флаги через coalesce(..., true), а не через join.
-- `notify_room_messages` — общий выключатель пушей из чатов; заглушить
-- одну комнату — `room_members.notifications_muted` (20260828110000).
create table public.notification_preferences (
  user_id uuid not null,
  notify_system_account boolean default true not null,
  notify_favorites boolean default true not null,
  notify_comments boolean default true not null,
  notify_digest boolean default true not null,
  notify_inactive_week boolean default true not null,
  notify_room_messages boolean default true not null,
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

-- Комната — это чат (20260826180000, 20260826200000). Своя лента у комнаты
-- была и снята целиком (20260828100000): вторая ветвь в правиле видимости
-- поста жила отдельной жизнью, и о ней забывали.
--
-- У комнаты НЕТ колонки `creator_id`. Владелец — участник с наименьшим
-- `seq` (`room_owner_id()`), поэтому «владелец ушёл — права у старейшего
-- из оставшихся» выполняется само: удаление строки в `room_members` и есть
-- передача прав.
--
-- `name is null` — это не «без имени», а «имя собирается из участников»
-- (клиент перечисляет всех, кроме себя). Хранить перечисление
-- материализованно нельзя: имена участников меняются, состав тоже.
--
-- `direct_a`/`direct_b` — денормализация ради ОДНОГО инварианта: «с одним
-- человеком не больше одной парной комнаты». Через `room_members` его
-- уникальным индексом не выразить, а без него повторное «написать»
-- заводило бы вторую комнату. Пара упорядочена least/greatest, как у
-- `connections_ordered_pair`.
--
-- `avatar_path` — своя аватарка групповой комнаты (20260826210000).
-- `rooms_avatar_shape` держит оба инварианта: у парной комнаты аватарки нет
-- вовсе (это второй участник, и аватарка — его), а путь всегда лежит под
-- префиксом СВОЕЙ комнаты — иначе владелец одной комнаты мог бы записать в
-- свою строку путь к файлу чужой.
create table public.rooms (
  id uuid default gen_random_uuid() not null,
  name text,
  is_direct boolean default false not null,
  direct_a uuid,
  direct_b uuid,
  created_at timestamp with time zone default now() not null,
  avatar_path text,
  constraint rooms_pkey primary key (id),
  constraint rooms_avatar_shape CHECK (((avatar_path IS NULL) OR ((NOT is_direct) AND (avatar_path ~~ (('rooms/'::text || (id)::text) || '/%'::text))))),
  constraint rooms_direct_shape CHECK (((is_direct AND (direct_a IS NOT NULL) AND (direct_b IS NOT NULL) AND (direct_a < direct_b) AND (name IS NULL)) OR ((NOT is_direct) AND (direct_a IS NULL) AND (direct_b IS NULL)))),
  constraint rooms_name_length CHECK (((name IS NULL) OR (char_length(name) <= 100))),
  constraint rooms_name_not_blank CHECK (((name IS NULL) OR (btrim(name) <> ''::text))),
  constraint rooms_direct_a_fkey FOREIGN KEY (direct_a) REFERENCES public.users(id) ON DELETE CASCADE,
  constraint rooms_direct_b_fkey FOREIGN KEY (direct_b) REFERENCES public.users(id) ON DELETE CASCADE
);

-- Состав комнаты — и всё, что относится к паре «человек ↔ комната»:
-- отдельная таблица на каждую метку повторяла бы ключ (room_id, user_id)
-- один в один.
--
-- `seq` — порядок вступления, он же порядок наследования комнаты.
-- Отдельная identity-колонка, а не `joined_at`: `create_room()` вставляет
-- всех участников одной транзакцией, где `now()` у всех строк совпадает.
--
-- `last_read_at` — докуда дочитал (20260826200000), `last_delivered_at` —
-- докуда доставлено, то есть «клиент синхронизировал список комнат»
-- (20260827100000); галочки и непрочитанные — сравнение этих меток с
-- `created_at` сообщения на клиенте. `default now()` у обеих: новый
-- участник не получает историю непрочитанной и недоставленной.
--
-- `notifications_muted` — mute одной комнаты, и только про пуши:
-- непрочитанные считаются как прежде (20260828110000). Флаг виден всем
-- участникам комнаты: закрыть его — значит выдать SELECT поколоночно на
-- таблице из публикации realtime, через которую ходят галочки; это
-- осознанно отложено (20260924100000, «Комнаты» в docs/data-model.md).
--
-- Таблица в публикации realtime — ради галочек, которые переворачиваются,
-- пока отправитель смотрит на экран. Пишут её только RPC: политики на
-- запись нет, грантов на запись тоже.
create table public.room_members (
  room_id uuid not null,
  user_id uuid not null,
  seq bigint generated always as identity not null,
  joined_at timestamp with time zone default now() not null,
  last_read_at timestamp with time zone default now() not null,
  last_delivered_at timestamp with time zone default now() not null,
  notifications_muted boolean default false not null,
  constraint room_members_pkey primary key (room_id, user_id),
  constraint room_members_room_id_fkey FOREIGN KEY (room_id) REFERENCES public.rooms(id) ON DELETE CASCADE,
  constraint room_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE
);

-- Сообщения комнаты. Видимость отдельного правила НЕ заводит: сообщение
-- видно тому, кто в комнате, — ни mute, ни блок её не сужают
-- (20260826200000).
--
-- `client_token` — та же идемпотентность отправки, что у постов и
-- комментариев. `deleted_at` — заглушка вместо реального delete, и по своей
-- причине: подписка realtime отдаёт DELETE без содержимого строки (replica
-- identity default — только ключ), проверить по нему RLS нечем, а UPDATE
-- приезжает целой строкой и фильтруется политикой как обычный SELECT.
-- Удаляет только `delete_own_room_message()`; UPDATE- и DELETE-политик нет.
--
-- `media` — до 10 вложений колонкой, а не строками отдельной таблицы, и это
-- единственное такое место в проекте (20260828120000): realtime отдаёт
-- подписчику СТРОКУ, и вложения должны приехать вместе с сообщением. Форму
-- и потолки держит `room_messages_media_shape` (раздел 5). Пустым сообщение
-- быть не может, но «непусто» значит «текст или вложения»; заглушка
-- удалённого — третий законный случай пустоты.
--
-- `reply_to_id` — ответ на сообщение (20260911100000). `on delete set null`,
-- а не cascade: строки физически не удаляются, но если это изменится, ответ
-- должен пережить оригинал. `hidden_at` — скрытие модерацией
-- (20260913100000).
create table public.room_messages (
  id uuid default gen_random_uuid() not null,
  room_id uuid not null,
  author_id uuid not null,
  text text not null,
  created_at timestamp with time zone default now() not null,
  client_token uuid,
  deleted_at timestamp with time zone,
  media jsonb default '[]'::jsonb not null,
  reply_to_id uuid,
  hidden_at timestamp with time zone,
  constraint room_messages_pkey primary key (id),
  constraint room_messages_text_length CHECK ((char_length(text) <= 5000)),
  constraint room_messages_text_not_blank CHECK (((deleted_at IS NOT NULL) OR (btrim(text) <> ''::text) OR (jsonb_array_length(media) > 0))),
  constraint room_messages_author_id_fkey FOREIGN KEY (author_id) REFERENCES public.users(id) ON DELETE CASCADE,
  constraint room_messages_reply_to_id_fkey FOREIGN KEY (reply_to_id) REFERENCES public.room_messages(id) ON DELETE SET NULL,
  constraint room_messages_room_id_fkey FOREIGN KEY (room_id) REFERENCES public.rooms(id) ON DELETE CASCADE
);

-- Заявка на знакомство — второй способ завести Connection рядом с
-- инвайт-кодом (20260828140000). Отправить её можно ТОЛЬКО тому, с кем есть
-- общая комната: ни каталога людей, ни возможности написать незнакомцу это
-- не открывает. Проверяет сервер (`request_connection()`).
--
-- Пара здесь НЕ упорядочена (в отличие от `connections_ordered_pair`): у
-- заявки есть направление. Одна заявка на НАПРАВЛЕНИЕ за всё время, в любом
-- статусе (`connection_requests_pair_key`): отказ окончателен, иначе он
-- превращается в переговоры. Передумавший отправляет СВОЮ заявку в обратную
-- сторону, и она законна — поэтому симметричного индекса нет и быть не
-- должно.
create table public.connection_requests (
  id uuid default gen_random_uuid() not null,
  requester_id uuid not null,
  recipient_id uuid not null,
  status text default 'pending'::text not null,
  created_at timestamp with time zone default now() not null,
  responded_at timestamp with time zone,
  constraint connection_requests_pkey primary key (id),
  constraint connection_requests_not_self CHECK ((requester_id <> recipient_id)),
  constraint connection_requests_responded_shape CHECK (((status = 'pending'::text) = (responded_at IS NULL))),
  constraint connection_requests_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'accepted'::text, 'declined'::text]))),
  constraint connection_requests_recipient_id_fkey FOREIGN KEY (recipient_id) REFERENCES public.users(id) ON DELETE CASCADE,
  constraint connection_requests_requester_id_fkey FOREIGN KEY (requester_id) REFERENCES public.users(id) ON DELETE CASCADE
);

-- Жалобы на контент (20260913100000). Разбирает их локальная консоль под
-- service_role, поэтому ни одной модераторской RPC и ни одной роли
-- модератора в базе нет: человек с service_role-ключом и есть вся
-- авторизация.
--
-- `target_id` намеренно без внешнего ключа: он указывает в одну из четырёх
-- таблиц в зависимости от `target_kind`. Цена — висячая ссылка после
-- удаления контента, поэтому `target_author_id` и `target_snapshot`
-- заполняет триггер `fill_content_report_target()`: жалоба остаётся
-- разбираемой, даже когда автор сам снёс написанное. Снимок обрезан до 500
-- символов — опора для решения, а не архив чужих текстов.
create table public.content_reports (
  id uuid default gen_random_uuid() not null,
  reporter_id uuid not null,
  target_kind text not null,
  target_id uuid not null,
  reason text not null,
  note text,
  target_author_id uuid,
  target_snapshot text,
  created_at timestamp with time zone default now() not null,
  status text default 'open'::text not null,
  resolution text,
  resolved_at timestamp with time zone,
  constraint content_reports_pkey primary key (id),
  constraint content_reports_kind_check CHECK ((target_kind = ANY (ARRAY['post'::text, 'comment'::text, 'room_message'::text, 'user'::text]))),
  constraint content_reports_note_length CHECK (((note IS NULL) OR (char_length(note) <= 1000))),
  constraint content_reports_reason_check CHECK ((reason = ANY (ARRAY['spam'::text, 'harassment'::text, 'hate'::text, 'violence'::text, 'sexual'::text, 'illegal'::text, 'other'::text]))),
  constraint content_reports_resolved_shape CHECK ((((status = 'open'::text) AND (resolved_at IS NULL)) OR ((status <> 'open'::text) AND (resolved_at IS NOT NULL)))),
  constraint content_reports_snapshot_length CHECK (((target_snapshot IS NULL) OR (char_length(target_snapshot) <= 500))),
  constraint content_reports_status_check CHECK ((status = ANY (ARRAY['open'::text, 'resolved'::text, 'rejected'::text]))),
  constraint content_reports_reporter_id_fkey FOREIGN KEY (reporter_id) REFERENCES public.users(id) ON DELETE CASCADE,
  constraint content_reports_target_author_id_fkey FOREIGN KEY (target_author_id) REFERENCES public.users(id) ON DELETE SET NULL
);

-- Чем кончилась последняя попытка зарегистрировать пуш-токен
-- (20260913120000). У `registerDevice()` три выхода без строки в
-- `device_tokens` — отказ в разрешении, отсутствие токена, исключение
-- апсерта, — и снаружи все три выглядели одинаково.
--
-- Строка одна на человека, а не на устройство: при неудаче идентификатора
-- установки нет (токен им и был). `app_version`/`app_build`/`platform`/
-- `os_version` дублируют `device_tokens` намеренно — там они есть только у
-- тех, у кого всё получилось. Ограничения повторены дословно, иначе форматы
-- разъедутся.
create table public.push_registration_status (
  user_id uuid not null,
  status text not null,
  platform text,
  os_version text,
  app_version text,
  app_build integer,
  detail text,
  updated_at timestamp with time zone default now() not null,
  constraint push_registration_status_pkey primary key (user_id),
  constraint push_registration_status_app_build_positive CHECK (((app_build IS NULL) OR (app_build > 0))),
  constraint push_registration_status_app_version_format CHECK (((app_version IS NULL) OR (app_version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'::text))),
  constraint push_registration_status_detail_length CHECK (((detail IS NULL) OR (char_length(detail) <= 300))),
  constraint push_registration_status_os_version_format CHECK (((os_version IS NULL) OR (os_version ~ '^[0-9]+(\.[0-9]+){0,2}$'::text))),
  constraint push_registration_status_platform_check CHECK (((platform IS NULL) OR (platform = ANY (ARRAY['android'::text, 'ios'::text, 'macos'::text, 'windows'::text, 'linux'::text, 'fuchsia'::text, 'web'::text])))),
  constraint push_registration_status_status_check CHECK ((status = ANY (ARRAY['granted'::text, 'denied'::text, 'no_token'::text, 'error'::text]))),
  constraint push_registration_status_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE
);

comment on column public.users.write_banned_until is 'Запрет писать до этого момента. NULL — не забанен. Ставит только консоль под service_role.';
comment on column public.device_tokens.platform is 'ОС установки: android/ios/… NULL = клиент старее этой колонки.';
comment on column public.device_tokens.os_version is 'Версия ОС цифрами: 18.1, 15. Нормализуется клиентом (shared/device_os.dart).';
comment on column public.content_reports.target_snapshot is 'Копия текста на момент жалобы, до 500 символов: автор может снести написанное раньше разбора.';


-- =====================================================================
-- 3. Индексы
-- =====================================================================
-- Только те, которых не заводят PRIMARY KEY/UNIQUE выше. Индексы на
-- ведущей колонке составного ключа тоже не дублируются: `favorite_users`
-- и `connections` индексируют ВТОРУЮ колонку пары, потому что правило
-- видимости спрашивает связь в обе стороны (20260821140000).


-- `users.avatar_path` спрашивают на каждый объект в листинге `avatars/`
-- (`is_room_peer_avatar()`, 20260905100000). Частичный: у большинства
-- строк NULL.
create index users_avatar_path_idx on public.users using btree (avatar_path) where (avatar_path IS NOT NULL);
create index users_write_banned_idx on public.users using btree (write_banned_until) where (write_banned_until IS NOT NULL);
create index connections_user_b_id_idx on public.connections using btree (user_b_id);
create unique index invite_links_one_active_per_owner on public.invite_links using btree (owner_id) where (NOT is_used);
create unique index posts_author_id_client_token_key on public.posts using btree (author_id, client_token);
create index posts_author_id_created_at_idx on public.posts using btree (author_id, created_at);
create index posts_created_at_id_idx on public.posts using btree (created_at desc, id desc);

-- Частичные индексы по `hidden_at` у постов, комментариев и сообщений:
-- скрытого единицы, у остальных строк NULL.
create index posts_hidden_idx on public.posts using btree (hidden_at) where (hidden_at IS NOT NULL);
create index post_media_poster_path_idx on public.post_media using btree (poster_path) where (poster_path IS NOT NULL);

-- Под `post_media_path_visible()`: storage-политика знает только путь
-- объекта, и от него надо дойти до поста — по файлу или по постеру видео.
create index post_media_storage_path_idx on public.post_media using btree (storage_path);
create unique index comments_author_id_client_token_key on public.comments using btree (author_id, client_token);
create index comments_hidden_idx on public.comments using btree (hidden_at) where (hidden_at IS NOT NULL);
create index comments_parent_comment_id_idx on public.comments using btree (parent_comment_id);
create index comments_post_id_idx on public.comments using btree (post_id);
create index favorite_users_favorite_id_idx on public.favorite_users using btree (favorite_id);
create index notification_outbox_unsent_idx on public.notification_outbox using btree (created_at) where (sent_at IS NULL);
create index notification_outbox_user_kind_created_idx on public.notification_outbox using btree (user_id, kind, created_at desc);
create unique index rooms_direct_pair_key on public.rooms using btree (direct_a, direct_b) where is_direct;

-- Владелец — минимальный `seq` в комнате (`room_owner_id()`); участник по
-- пользователю — `my_room_ids()`.
create unique index room_members_room_seq_idx on public.room_members using btree (room_id, seq);
create index room_members_user_id_idx on public.room_members using btree (user_id);

-- Отправка идемпотентна по (автор, токен), как у постов; ретрай клиент
-- читает по 23505.
create unique index room_messages_author_client_token_key on public.room_messages using btree (author_id, client_token) where (client_token IS NOT NULL);
create index room_messages_hidden_idx on public.room_messages using btree (hidden_at) where (hidden_at IS NOT NULL);

-- Лента чата, последнее сообщение в `my_rooms()` и `exists` в
-- `mark_rooms_delivered()`.
create index room_messages_room_created_idx on public.room_messages using btree (room_id, created_at desc, id desc);

-- Одна заявка на направление — см. `connection_requests`. Два индекса ниже —
-- обычные lookup'ы под входящие и исходящие.
create unique index connection_requests_pair_key on public.connection_requests using btree (requester_id, recipient_id);
create index connection_requests_recipient_idx on public.connection_requests using btree (recipient_id, status);
create index connection_requests_requester_idx on public.connection_requests using btree (requester_id, status);

-- Один человек — одна жалоба на один объект. Повторное нажатие приходит как
-- 23505, и клиент читает его как «уже отправлено». Индекс НЕчастичный и по
-- этой причине тоже (см. «upsert из PostgREST» в AGENTS.md).
create unique index content_reports_once_per_reporter on public.content_reports using btree (reporter_id, target_kind, target_id);

-- Очередь консоли: сначала неразобранные, новые сверху. И сколько раз
-- пожаловались на один объект — главный сигнал в очереди.
create index content_reports_open_idx on public.content_reports using btree (created_at desc) where (status = 'open'::text);
create index content_reports_target_idx on public.content_reports using btree (target_kind, target_id);

-- Частичный: интересны те, у кого не получилось.
create index push_registration_status_status_idx on public.push_registration_status using btree (status) where (status <> 'granted'::text);


-- =====================================================================
-- 4. Функции
-- =====================================================================
-- Порядок строгий: функции на SQL проверяются при создании, поэтому
-- предикаты видимости идут снизу вверх по зависимостям.
--
-- Каждая функция в `public` — эндпоинт PostgREST. Гранты на исполнение
-- собраны отдельным блоком (раздел 9) и выданы `authenticated` только там,
-- где каждый аргумент про самого вызывающего, — или там, где функцию зовёт
-- политика: выражение политики исполняется от ВЫЗЫВАЮЩЕЙ роли, и без
-- EXECUTE она отбивается 42501 (20260924100000).
--
-- У каждой функции `search_path` прибит, и `pg_temp` в нём стоит последним
-- (20260924100000): у `security definer` без этого имя таблицы можно было бы
-- подменить временной таблицей вызывающего. Исключения — две SQL-функции,
-- которые к таблицам не ходят и должны инлайниться (`system_account_ids()`,
-- `room_message_media_ok()`): `SET` на функции инлайн выключает.

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
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1 from public.system_account_ids() as s where s = p_id
  );
$function$;

-- Три маленьких предиката, из которых собрано правило видимости. Все
-- `security definer` — иначе подзапрос к `blocked_users` внутри политики
-- сам фильтровался бы политикой `blocked_users`, и ветка «меня
-- заблокировали» молча отваливалась бы (см. «Грабли» в AGENTS.md).
-- Ни один НЕ выдан `authenticated`: оба аргумента произвольные, и прямой
-- грант отвечал бы на чужой вопрос «а эти двое знакомы/замьючены/
-- заблокированы» (20260726140000).
CREATE OR REPLACE FUNCTION public.are_connected(p_user_a uuid, p_user_b uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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
 SET search_path TO 'public', 'pg_temp'
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
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1 from blocked_users b
    where (b.blocker_id = user_a and b.blocked_id = user_b)
       or (b.blocker_id = user_b and b.blocked_id = user_a)
  );
$function$;

-- ОДНО правило видимости на весь проект: я сам, системный аккаунт, либо
-- Connection, с которым нет блока ни в одну сторону. Раньше правило было
-- размножено на четыре копии, две отстали от mute/block и стали дырами;
-- 20260726120000 свела их сюда. МЕНЯТЬ ТОЛЬКО ЗДЕСЬ.
--
-- Mute в правиле НЕ участвует (20260829130000): он фильтр ЛЕНТЫ, а не
-- стена — замьюченного нет в общей ленте и нет его пушей, а профиль, посты
-- в нём и всё остальное видно как у обычного Connection. RLS не знает
-- экрана, и «в ленте скрыть, в профиле показать» политикой не выразить,
-- поэтому лента фильтрует mute своим запросом. Следствие: mute — не граница
-- приватности, и любой правленый клиент может его не применять; граница —
-- блокировка, и она целиком на сервере.
CREATE OR REPLACE FUNCTION public.is_author_visible(p_author uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select p_author = auth.uid()
      or public.is_system_account(p_author)
      or (
        public.are_connected(auth.uid(), p_author)
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
 SET search_path TO 'public', 'pg_temp'
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
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select public.are_connected(auth.uid(), p_other);
$function$;

-- Автору поста видны комментарии под ним, даже если сам комментатор ему
-- не Connection (20260818170000). Блок это сужает; mute — нет, по той же
-- причине, что в `is_author_visible()` (20260829130000): иначе комментарий
-- замьюченного был бы виден, а строка `users` с его именем — нет, и под
-- постом появилась бы подпись без автора.
CREATE OR REPLACE FUNCTION public.is_comment_visible_to_post_owner(p_comment_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1
    from comments c
    join posts p on p.id = c.post_id
    where c.id = p_comment_id
      and p.author_id = auth.uid()
      and not public.is_blocked_pair(auth.uid(), c.author_id)
  );
$function$;

-- Пара к ней для строки `users`: автору поста виден профиль того, кто
-- комментировал его посты. Блок сужает, mute — нет (20260829130000).
CREATE OR REPLACE FUNCTION public.is_commenter_visible_to_post_owner(p_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1
    from comments c
    join posts p on p.id = c.post_id
    where c.author_id = p_user_id
      and p.author_id = auth.uid()
  )
  and not public.is_blocked_pair(auth.uid(), p_user_id);
$function$;

CREATE OR REPLACE FUNCTION public.is_author_of_comment_visible(p_comment_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce(
    public.is_author_visible(
      (select author_id from comments where id = p_comment_id)
    ),
    false
  );
$function$;

-- Считает комментарии для ленты. `security invoker` осознанно: RLS на
-- `comments` применяется, поэтому чужие скрытые комментарии в счётчик не
-- попадают сами собой (20260817120000).
CREATE OR REPLACE FUNCTION public.comment_summary(p_post_ids uuid[])
 RETURNS TABLE(post_id uuid, comment_count bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select comments.post_id, count(*)
  from comments
  where comments.post_id = any (p_post_ids)
    and comments.deleted_at is null
  group by comments.post_id;
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
--
-- Гонку с самой собой функция не проигрывает (20260826120000): два
-- одновременных вызова одного владельца — а это ровно ретрай после
-- таймаута — оба доходят до INSERT, и `on conflict (owner_id) where not
-- is_used` (вывод по частичному индексу, предикат обязателен) гасит
-- второй. `row_count` отличает «вставил я» от «успел кто-то другой»; во
-- втором случае ответ — ЕГО код, тот же приём, что в
-- `activate_invite_link()`.
CREATE OR REPLACE FUNCTION public.create_invite_link()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_code text;
  v_existing text;
  v_inserted int;
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
  values (auth.uid(), v_code)
  on conflict (owner_id) where not is_used do nothing;

  get diagnostics v_inserted = row_count;

  if v_inserted > 0 then
    return v_code;
  end if;

  -- Наша строка отброшена: параллельный вызов успел раньше. Отдаём его код.
  select code into v_existing
  from invite_links
  where owner_id = auth.uid() and not is_used
  limit 1;

  -- Живого кода нет и после конфликта — значит между арбитражем и этим
  -- чтением тот же владелец успел его отозвать (`rotate_invite_link()`) или
  -- предъявить. Вернуть NULL нельзя: клиент читает результат как `String` и
  -- получил бы TypeError вместо сообщения.
  if v_existing is null then
    raise exception 'Invite code could not be issued, try again'
      using errcode = 'P0001';
  end if;

  return v_existing;
end;
$function$;

CREATE OR REPLACE FUNCTION public.rotate_invite_link()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
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
 SET search_path TO 'public', 'extensions', 'pg_temp'
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
--
-- `p_visibility` — аудитория поста (20260829100000), проверяется здесь
-- вместе с авторством. Параметры добавлялись drop+create, а не
-- `create or replace`: PostgREST ищет функцию по ИМЕНАМ аргументов.
--
-- Ретрай — это UPDATE, а `enqueue_post_notifications()` — AFTER INSERT и
-- на него не срабатывает. Поэтому ретрай, оставляющий пост «только
-- избранным», сам убирает из очереди ещё не ушедшие `new_post` про этот
-- пост у всех, кого в избранном автора нет (20260905100000): иначе пуш
-- лежал бы у того, кому пост не покажут. Уже отправленное не трогается
-- (отозвать пуш нельзя), `digest` не трогается (он считает посты, а не
-- называет их), а РАСШИРЕНИЕ аудитории уведомлений не добавляет: одна
-- публикация — один пуш.
CREATE OR REPLACE FUNCTION public.create_post_with_media(p_client_token uuid, p_text text DEFAULT NULL::text, p_items jsonb DEFAULT '[]'::jsonb, p_visibility text DEFAULT 'connections'::text)
 RETURNS TABLE(storage_path text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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

-- Путь РЕДАКТИРОВАНИЯ медиа, изнутри `update_post_with_media()`. Наружу
-- не выдана (20260905100000): прямой вызов был последним путём записи мимо
-- инварианта «текст или медиа».
--
-- Финальный INSERT гасит повтор пути `on conflict do nothing`, как и
-- парная ей `create_post_with_media()` (20260826120000): один и тот же
-- `storage_path`, пришедший в `p_items` дважды, — повтор, а не повод для
-- сырого 23505. `#variable_conflict use_column` при этом обязателен:
-- `returns table (storage_path text)` заводит OUT-параметр с этим именем, а
-- цель конфликта — голое имя колонки, и без директивы она натыкается на
-- переменную (42702).
CREATE OR REPLACE FUNCTION public.set_post_media(p_post_id uuid, p_items jsonb)
 RETURNS TABLE(storage_path text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
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
  from jsonb_array_elements(p_items) with ordinality as item(value, idx)
  on conflict (post_id, storage_path) do nothing;

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
-- своего. `p_visibility` NULL — аудитория не меняется (20260829100000).
CREATE OR REPLACE FUNCTION public.update_post_with_media(p_post_id uuid, p_text text DEFAULT NULL::text, p_items jsonb DEFAULT '[]'::jsonb, p_visibility text DEFAULT NULL::text)
 RETURNS TABLE(storage_path text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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

-- `position` раздаёт сервер, из той же транзакции, в которую строки и
-- лягут (20260824130000). Считать его на клиенте было нельзя: экран
-- считал от закэшированного списка, а тот отстаёт ровно тогда, когда
-- предыдущая попытка закоммитилась уже после «не удалось добавить фото».
CREATE OR REPLACE FUNCTION public.append_profile_photos(p_items jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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
--
-- Повторы в массиве отсекаются отдельной проверкой ДО чтения таблицы
-- (20260826120000): сравнение длин их не ловит — для галереи {a, b} массив
-- [a, a] даёт на join'е две строки, длины сходятся, а дальше `delete`
-- сносил обе фотографии и INSERT падал сырым 23505. NULL-элементы
-- отваливаются там же — `count(distinct)` их не считает.
CREATE OR REPLACE FUNCTION public.reorder_profile_photos(p_photo_ids uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_paths text[];
  v_total int;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  -- Один и тот же id дважды — это не перестановка, а потеря фотографии.
  if (select count(distinct id) from unnest(p_photo_ids) as id)
     <> coalesce(array_length(p_photo_ids, 1), 0) then
    raise exception 'Photo set does not match your gallery' using errcode = 'PT422';
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
 SET search_path TO 'public', 'pg_temp'
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
 SET search_path TO 'public', 'pg_temp'
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
 SET search_path TO 'public', 'pg_temp'
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
 SET search_path TO 'public', 'pg_temp'
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

CREATE OR REPLACE FUNCTION public.enqueue_comment_notifications()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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
-- а `prosrc` на признаки старого тела (см. «Грабли» в AGENTS.md).
--
-- Ветка избранного — пуш `new_post` тем, кто держит автора в избранном.
-- Пост «только избранным» уведомляет лишь тех, кто в избранном У АВТОРА:
-- списки разные — левый про то, кто хочет пуш, правый про то, кто увидит
-- пост (20260829100000). Mute здесь проверяется отдельно от правила
-- видимости и остаётся: замьютить и получать пуши было бы бессмыслицей
-- (20260829130000).
--
-- Дайджест — один `insert ... select` вместо цикла с `count(*)` на каждого
-- знакомого внутри транзакции вставки поста (20260826120000).
-- `materialized` на CTE закрепляет порядок: без него планировщик волен
-- посчитать дорогой lateral и для отсеянных. Подсчёт непрочитанного видит
-- только те посты, которые зрителю покажут, — звать в ленту числом постов,
-- которых он там не найдёт, хуже, чем не звать.
CREATE OR REPLACE FUNCTION public.enqueue_post_notifications()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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

-- Backstop-лимиты. BEFORE INSERT-триггер срабатывает до арбитража
-- `ON CONFLICT`, поэтому строка, которую `DO NOTHING` в итоге отбросит,
-- всё равно проходит через триггер: без ветки «это дубликат по тому же
-- ключу» лимит ловил не 21-й элемент, а ретрай уже опубликованного поста
-- (20260820120000).
--
-- Все три — `security invoker`, то есть их `count(*)` идёт через RLS. У
-- скрытого модерацией поста автор своих `post_media` не видит, и count
-- читается нулём; последствий нет — RPC режет `p_items` по 20, а прямой
-- INSERT на скрытый пост отбивает сама INSERT-политика (20260924100000).
CREATE OR REPLACE FUNCTION public.enforce_post_media_limit()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
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
 SET search_path TO 'public', 'pg_temp'
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
 SET search_path TO 'public', 'pg_temp'
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
-- (20260822130000). Пинятся и время (до этого `updated_at` не обновлялся
-- вообще и врал о том, когда устройство выходило на связь), и ключ
-- `(user_id, fcm_token)` (20260826120000): политика проверяет только
-- `user_id`, и без пина строку можно было перевести на чужой `fcm_token`,
-- уведя пуши на чужое устройство. То же, что `pin_reaction_identity()`
-- делает для реакций. На легальном пути это no-op: апсерт конфликтует
-- именно по этой паре. Имя функции осталось прежним — переименование
-- потребовало бы пересоздать триггер ради строки в каталоге.
CREATE OR REPLACE FUNCTION public.pin_device_token_timestamps()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  new.user_id := old.user_id;
  new.fcm_token := old.fcm_token;
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
 SET search_path TO 'public', 'pg_temp'
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
 SET search_path TO 'public', 'pg_temp'
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
 SET search_path TO 'public', 'pg_temp'
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
 SET search_path TO 'public', 'pg_temp'
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

-- Рассылка «вышло обновление» тем, у кого НИ ОДНО устройство не дотягивает
-- до `p_min_build`. Зовётся руками (см. «Рассылка „обновитесь“» в
-- docs/operations.md), наружу не выдана. `p_important` выбирает вид:
-- обычный `app_update` написан нейтрально и уходит на каждую заметную
-- выкладку, `app_update_important` — для случая, когда обновиться
-- действительно надо (20260826220000). Защита от повтора смотрит на оба
-- вида сразу: про одну сборку не приходит двух уведомлений.
CREATE OR REPLACE FUNCTION public.enqueue_app_update_notifications(p_min_build integer, p_version text DEFAULT NULL::text, p_important boolean DEFAULT false)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_queued integer;
  v_kind text := case when coalesce(p_important, false)
                   then 'app_update_important' else 'app_update' end;
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
    select o.user_id, v_kind,
           jsonb_build_object('build', p_min_build, 'version', p_version)
      from outdated o
     where coalesce(
             (select notify_system_account from notification_preferences
               where user_id = o.user_id),
             true
           )
       -- Защита от повтора смотрит на ОБА вида сразу: про одну и ту же сборку
       -- человеку не должно прийти двух уведомлений — ни одинаковых, ни
       -- «обычное, а следом настойчивое».
       and not exists (
         select 1 from notification_outbox n
          where n.user_id = o.user_id
            and n.kind in ('app_update', 'app_update_important')
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
 SET search_path TO 'public', 'pg_temp'
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

-- Крон остаётся нужным, пока у `authenticated` есть прямой INSERT в `posts`
-- (`author_id, client_token, created_at, text`): пост без текста и без
-- медиа всё ещё может приехать мимо RPC (20260905100000).
CREATE OR REPLACE FUNCTION public.purge_empty_posts()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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
 SET search_path TO 'public', 'pg_temp'
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
--
-- Ветвь на каждый префикс, потому что у каждого свой вопрос «на этот файл
-- ещё кто-нибудь ссылается»: у `posts/` — строки `post_media`, у
-- `avatars/` — `profile_photos`, у `messages/` — jsonb внутри
-- `room_messages` (20260828120000), у `rooms/` — `rooms.avatar_path`
-- (20260829110000). Аватарка удалённой комнаты без последней ветви не
-- просто не собиралась, а становилась недостижимой: обе storage-политики
-- префикса спрашивают `owns_room()`, а у несуществующей комнаты владельца
-- нет ни у кого. Порог в сутки общий: свежая заливка почти всегда ещё не
-- успела обзавестись строкой.
CREATE OR REPLACE FUNCTION public.orphaned_media_paths()
 RETURNS SETOF text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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

CREATE OR REPLACE FUNCTION public.reap_orphaned_media()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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

-- FCM-токен выдаётся УСТАНОВКЕ приложения, а не пользователю, и войти двумя
-- аккаунтами одновременно здесь нельзя. Значит строка с этим токеном под
-- другим `user_id` — всегда остаток от предыдущего владельца устройства
-- (20260826120000).
--
-- Снимал её только `unregisterDevice()` на выходе, а он best-effort:
-- выход без сети оставлял её навсегда, и следующий аккаунт на том же
-- телефоне получал чужие уведомления. Поэтому право на строку забирает
-- тот, кто регистрируется последним, и делает это сервер, не полагаясь на
-- уходящего клиента. `security definer` обязателен: строка чужая, а
-- политика «Users manage their own device tokens» пускает только к
-- `user_id = auth.uid()`.
CREATE OR REPLACE FUNCTION public.claim_device_token()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  delete from public.device_tokens d
   where d.fcm_token = new.fcm_token
     and d.user_id <> new.user_id;
  return new;
end;
$function$;

-- Комнаты вызывающего — некоррелированным множеством вместо построчного
-- предиката, тот же приём, что у `visible_author_ids()`: `security definer`
-- планировщик не инлайнит (см. «Грабли» в AGENTS.md). Он же разрывает
-- рекурсию: политики `room_members` спрашивают состав комнаты, и подзапрос
-- к той же таблице внутри её политики зациклился бы.
CREATE OR REPLACE FUNCTION public.my_room_ids()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select m.room_id from room_members m where m.user_id = auth.uid();
$function$;

-- Владелец комнаты = участник с наименьшим `seq`. Единственное место, где
-- это правило записано. Отвечает про ЛЮБУЮ комнату, поэтому наружу не
-- выдана; для вызывающего есть `owns_room()`.
CREATE OR REPLACE FUNCTION public.room_owner_id(p_room_id uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select m.user_id from room_members m where m.room_id = p_room_id order by m.seq limit 1;
$function$;

-- «Этот человек в одной комнате со мной». Один аргумент, вторая сторона
-- всегда `auth.uid()` — поэтому её и безопасно выдать `authenticated`
-- (ровно та же логика, что у `is_connected_to_caller()`): чужой вопрос
-- «а эти двое в одной комнате» через неё не задать.
--
-- Mute и блок внутри комнаты не действуют — вошли в одну комнату, значит
-- видите друг друга (20260826180000). Участники не обязаны быть
-- Connections ДРУГ ДРУГУ, поэтому профиль соседа по комнате виден через
-- эту функцию. Предохранитель один: ДОБАВИТЬ в комнату того, с кем есть
-- блок, нельзя.
CREATE OR REPLACE FUNCTION public.shares_room_with_caller(p_other uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1
      from room_members mine
      join room_members theirs on theirs.room_id = mine.room_id
     where mine.user_id = auth.uid()
       and theirs.user_id = p_other
  );
$function$;

-- Комната пустеет — комната исчезает: последний вышедший уносит её с
-- собой, каскадом уходят сообщения (20260826180000). Парная комната
-- умирает от ухода ЛЮБОЙ из сторон: она и есть пара, и «комната на одного»
-- с чужой перепиской внутри — не то, что должно остаться. Групповая
-- переживает уход кого угодно, включая владельца: владелец — это просто
-- минимальный `seq`, и он пересчитывается сам. Файлы аватарки и вложений
-- подбирает `reap_orphaned_media()`.
CREATE OR REPLACE FUNCTION public.cleanup_orphaned_room()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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

-- RPC комнат — `security definer`: они пишут в `rooms`/`room_members`, на
-- которые у `authenticated` нет ни одного гранта на запись. Это осознанно:
-- правила («я владелец», «он мой Connection», «блока нет», «в парную
-- комнату не добавляют») политикой не выражаются, а отказ должен быть
-- объяснимым, а не «0 строк».
--
-- Создать комнату. Идемпотентна ТОЛЬКО для парной: там уникальный индекс
-- по паре, и повторный вызов возвращает существующую комнату. Групповая
-- идемпотентности не имеет — двойное нажатие заведёт две комнаты, и это
-- сознательный размен: ключа, по которому две группы «одинаковы», не
-- существует.
CREATE OR REPLACE FUNCTION public.create_room(p_member_ids uuid[], p_name text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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
--
-- Здесь и в `add_room_member()`, `remove_room_member()`, `set_room_avatar()`
-- «нет такой комнаты» и «комната есть, но вы не владелец» отвечают ОДНИМ
-- PT404 (20260905100000): различать их значит дать любому залогиненному
-- перебирать uuid и отличать живую комнату от выдуманной. Проверка одна —
-- `room_owner_id(...) is distinct from auth.uid()`, — и форма важна: у
-- `not owns_room(...)` для несуществующей комнаты NULL, и ветка не
-- срабатывает (см. «Грабли» в AGENTS.md).
CREATE OR REPLACE FUNCTION public.rename_room(p_room_id uuid, p_name text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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

-- Добавить участника. Только владелец, только в групповую, только своего
-- Connection и только без блока в любую сторону.
CREATE OR REPLACE FUNCTION public.add_room_member(p_room_id uuid, p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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

-- Исключить участника. Только владелец и только не себя: уход владельца —
-- это `leave_room()`, где комната переходит к следующему по `seq`.
CREATE OR REPLACE FUNCTION public.remove_room_member(p_room_id uuid, p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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

-- Выйти. Комнату это может и уничтожить — см. `cleanup_orphaned_room()`.
CREATE OR REPLACE FUNCTION public.leave_room(p_room_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  delete from room_members m
   where m.room_id = p_room_id and m.user_id = auth.uid();
end;
$function$;

-- Список комнат для экрана — он же список чатов. Одним запросом вместо
-- N+1: имя, аватарка, состав, последнее сообщение, непрочитанные и mute.
-- Имя парной комнаты клиент собирает сам из второго участника.
--
-- `security definer` здесь не ради обхода политик `rooms`/`room_members`
-- (они пустили бы ровно те же строки), а ради `users`: имена и аватарки
-- соседей читаются одним join'ом. Выборка ограничена строкой участника
-- вызывающего — чужую комнату через неё не увидеть. Свои сообщения
-- непрочитанными не считаются никогда; mute на счёт не влияет.
CREATE OR REPLACE FUNCTION public.my_rooms()
 RETURNS TABLE(id uuid, name text, avatar_path text, is_direct boolean, owner_id uuid, created_at timestamp with time zone, last_message_at timestamp with time zone, last_message_text text, last_message_author_id uuid, last_message_has_media boolean, unread_count integer, notifications_muted boolean, members jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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
         msg.has_media,
         unread.n,
         me.notifications_muted,
         mem.members
    from rooms r
    join room_members me on me.room_id = r.id and me.user_id = auth.uid()
    left join lateral (
      select m.created_at, m.text, m.author_id, jsonb_array_length(m.media) > 0 as has_media
        from room_messages m
       where m.room_id = r.id and m.deleted_at is null
       order by m.created_at desc, m.id desc
       limit 1
    ) msg on true
    cross join lateral (
      -- Свои сообщения непрочитанными не считаются никогда: отправка их же
      -- и порождает, и счётчик на собственной кнопке был бы шумом. Mute на
      -- этот счёт не влияет — он про пуши, а не про чтение.
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

-- Прочитано до «сейчас». Прочитанное сообщение не может быть
-- недоставленным, поэтому чтение продвигает обе метки (20260827100000).
CREATE OR REPLACE FUNCTION public.mark_room_read(p_room_id uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  update room_members m
     set last_read_at = now(),
         last_delivered_at = now()
   where m.room_id = p_room_id
     and m.user_id = auth.uid();
$function$;

-- Пуш о сообщении — всем участникам, кроме автора, у кого не выключены
-- пуши из чатов, не заглушена эта комната (20260828110000) и кто не читал
-- её последнюю минуту, то есть не сидит в ней прямо сейчас. Пока
-- предыдущий пуш из этой комнаты не ушёл, второй человеку не заводится:
-- оживший чат не превращается в сорок одинаковых уведомлений.
--
-- Имя комнаты в пуш НЕ кладётся намеренно. Оно у каждого своё (у комнаты
-- без названия — перечисление остальных участников), считает его клиент, и
-- вторая копия этого правила на сервере разошлась бы с первой при первом же
-- переименовании. В payload едет `room_id`, а текст обходится именем
-- автора.
CREATE OR REPLACE FUNCTION public.enqueue_room_message_notifications()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_author_name text;
begin
  select name into v_author_name from users where id = new.author_id;

  insert into notification_outbox (user_id, kind, payload)
  select m.user_id, 'room_message',
    jsonb_build_object(
      'author_name', v_author_name,
      'room_id', new.room_id,
      'message_id', new.id
    )
  from room_members m
  where m.room_id = new.room_id
    and m.user_id <> new.author_id
    and coalesce(
      (select np.notify_room_messages from notification_preferences np where np.user_id = m.user_id),
      true
    )
    -- Эта комната заглушена лично этим человеком (20260828110000). Общая
    -- настройка выше отвечает на вопрос «хочу ли я пуши из чатов вообще»,
    -- а флаг — «хочу ли я их из ЭТОГО чата»; непрочитанные при этом
    -- считаются по-прежнему.
    and not m.notifications_muted
    -- Человек сейчас в этом чате: экран отмечает прочитанным каждое
    -- входящее сообщение, так что свежая `last_read_at` — это и есть
    -- «читает прямо сейчас». Пуш о сообщении, которое уже на экране,
    -- бесполезен.
    and m.last_read_at < now() - interval '1 minute'
    -- Очередь схлопывается: пока предыдущий пуш из этой комнаты не ушёл,
    -- второй не заводится. Иначе оживший чат превращается в очередь из
    -- сорока одинаковых уведомлений, которые все придут разом.
    and not exists (
      select 1 from notification_outbox n
       where n.user_id = m.user_id
         and n.kind = 'room_message'
         and n.sent_at is null
         and n.payload ->> 'room_id' = new.room_id::text
    );

  return new;
end;
$function$;

-- Своё сообщение, и только своё. «Нет такого» и «есть, но чужое» отвечают
-- одним PT404 — различать их значит отвечать на вопрос «жива ли строка» про
-- то, что RLS обязана скрывать целиком (тот же принцип, что в
-- `delete_own_comment()`). Членства не требует: погасить своё сообщение
-- можно и из покинутой комнаты. Возвращает пути вложений — объекты клиент
-- сносит сам, после строки (20260828120000).
CREATE OR REPLACE FUNCTION public.delete_own_room_message(p_message_id uuid)
 RETURNS TABLE(storage_path text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_media jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select m.media into v_media
    from room_messages m
   where m.id = p_message_id
     and m.author_id = auth.uid()
     and m.deleted_at is null
   for update;

  -- Повторное удаление уже удалённого — не ошибка: ретрай должен быть тихим,
  -- и сносить в этот раз уже нечего. А вот «строки нет» и «строка чужая» —
  -- один PT404 на оба случая: различать их значит отвечать на вопрос «жива
  -- ли строка» про то, что RLS обязана скрывать целиком.
  if not found then
    if not exists (
      select 1 from room_messages
       where id = p_message_id and author_id = auth.uid()
    ) then
      raise exception 'Message not found' using errcode = 'PT404';
    end if;
    return;
  end if;

  update room_messages
     set deleted_at = now(),
         text = '',
         media = '[]'::jsonb
   where id = p_message_id;

  return query
    select path
      from (
        select item.value ->> 'storage_path' as path
          from jsonb_array_elements(v_media) item
        union all
        select nullif(item.value ->> 'poster_path', '')
          from jsonb_array_elements(v_media) item
      ) gone
     where path is not null;
end;
$function$;

-- Однонаправленная обёртка над `room_owner_id()`, ровно по той же причине,
-- по которой у `are_connected()` есть `is_connected_to_caller()`: эта —
-- про вызывающего, её выдать безопасно, а без гранта её нельзя было бы
-- позвать из storage-политики.
CREATE OR REPLACE FUNCTION public.owns_room(p_room_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select public.room_owner_id(p_room_id) = auth.uid();
$function$;

-- UPDATE-гранта на `rooms` нет и не будет: политика на UPDATE не умеет
-- ограничить, КАКИЕ колонки меняются, и вместе с аватаркой открыла бы
-- `is_direct` и пару `direct_a`/`direct_b`, на которых стоит уникальность
-- парной комнаты. Поэтому путь пишет RPC (20260826210000).
--
-- Возвращает путь, который перестал быть нужен, — как это делает
-- `create_post_with_media()`. Клиент сносит объект ПОСЛЕ того, как строка
-- записана: строка, указывающая на удалённый файл, — это дырка в
-- интерфейсе у всех участников, а файл, на который никто не указывает, —
-- просто байты, и их подберёт `reap_orphaned_media()`.
CREATE OR REPLACE FUNCTION public.set_room_avatar(p_room_id uuid, p_avatar_path text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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

-- Продвигает «доставлено» во всех комнатах вызывающего разом
-- (20260827100000). Аргументов нет — фильтр `auth.uid()` встроен, так что
-- грант `authenticated` не отвечает ни на чей вопрос, кроме вопроса о самом
-- вызывающем.
--
-- Пишет только строки, где есть что доставлять: живое чужое сообщение
-- новее отметки (20260923100000). `room_members` лежит в публикации
-- realtime, и каждая переписанная строка — событие для всех участников
-- комнаты; переписывать её, когда галочка от этого не меняется, значило
-- будить всю комнату на каждый перезапрос списка. Свои сообщения не в
-- счёт: галочки на них рисуются по ЧУЖИМ отметкам.
CREATE OR REPLACE FUNCTION public.mark_rooms_delivered()
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  update room_members m
     set last_delivered_at = now()
   where m.user_id = auth.uid()
     and exists (
       select 1
         from room_messages msg
        where msg.room_id = m.room_id
          and msg.author_id <> m.user_id
          and msg.deleted_at is null
          and msg.created_at > m.last_delivered_at
     );
$function$;

-- RPC, а не UPDATE-политика, по той же причине, что и у `mark_room_read()`:
-- политика не умеет ограничить, КАКИЕ колонки меняются, и вместе с этим
-- флагом открыла бы `last_read_at`/`last_delivered_at` — а по ним считаются
-- непрочитанные и рисуются галочки (20260828110000).
--
-- Своя строка и только своя: `user_id = auth.uid()` в `where`. Чужая
-- комната не задевает ничего, и ответ «ничего не изменилось» неотличим от
-- «такой комнаты не существует», что и требуется.
CREATE OR REPLACE FUNCTION public.set_room_muted(p_room_id uuid, p_muted boolean)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  update room_members m
     set notifications_muted = coalesce(p_muted, false)
   where m.room_id = p_room_id
     and m.user_id = auth.uid();
$function$;

-- Форма `room_messages.media` (20260828120000). Проверять её приходится
-- функцией: в CHECK нельзя ни подзапрос, ни set-returning вызов вроде
-- `jsonb_array_elements`, а внутри `language sql` immutable-функции — можно.
-- Immutable она честно: смотрит только на свои аргументы.
--
-- Путь проверяется ЗДЕСЬ, а не в INSERT-политике: политика ограничивает
-- вызывающего, CHECK — саму строку, то есть правило переживёт и будущую
-- `security definer`-функцию, которая начнёт писать сообщения в обход
-- политики. Форма пути — `messages/<room_id>/<author_id>/…`, та же, что
-- проверяют storage-политики.
--
-- Потолки — 10 элементов, 400 символов на путь, 8000 на всю колонку
-- (20260829110000): это единственная клиентская колонка, которая
-- рассылается всем участникам через realtime, и без потолка правленый
-- клиент рассылал бы мегабайты набивки. Самый длинный законный путь —
-- 168 символов, десять полных элементов — около 3970 байт: запас ровно
-- вдвое.
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

-- Тема приватного канала Realtime — `room:<room_id>` — это комната, в
-- которой я состою (20260828130000). Регулярка перед приведением типа — не
-- украшение: тема приезжает строкой от клиента, и `'room:мусор'::uuid` был
-- бы не «false», а ошибкой прямо внутри политики. `case` даёт порядок
-- вычисления, на который можно положиться, — в отличие от `and`.
CREATE OR REPLACE FUNCTION public.is_my_room_topic(p_topic text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case
    when p_topic ~ '^room:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then substring(p_topic from 6)::uuid in (select public.my_room_ids())
    else false
  end;
$function$;

-- Заявка на знакомство. Только тому, с кем есть общая комната, без блока
-- и без уже готового Connection.
--
-- Возвращает 'requested' или 'connected' — второе, когда встречная заявка
-- уже лежала: два человека, попросившие друг друга, согласны оба, и
-- заставлять кого-то из них ещё и нажать «принять» было бы церемонией ради
-- церемонии.
--
-- Блок и отсутствие общей комнаты отвечают ОДНИМ PT403. Различать их значит
-- отвечать на вопрос «а он меня заблокировал?», который блок обязан скрывать.
CREATE OR REPLACE FUNCTION public.request_connection(p_user_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me uuid := auth.uid();
  v_incoming connection_requests%rowtype;
  v_inserted int;
  v_my_name text;
begin
  if v_me is null then
    raise exception 'Not authenticated';
  end if;

  if p_user_id is null or p_user_id = v_me then
    raise exception 'Cannot request yourself' using errcode = 'PT422';
  end if;

  if not public.shares_room_with_caller(p_user_id)
     or public.is_blocked_pair(v_me, p_user_id) then
    raise exception 'Not available' using errcode = 'PT403';
  end if;

  if public.are_connected(v_me, p_user_id) then
    raise exception 'Already connected' using errcode = 'PT409';
  end if;

  select name into v_my_name from users where id = v_me;

  -- Встречная заявка: принимаем её вместо того, чтобы заводить вторую.
  select * into v_incoming
    from connection_requests
   where requester_id = p_user_id
     and recipient_id = v_me
     and status = 'pending'
   for update;

  if found then
    insert into connections (user_a_id, user_b_id, method)
    values (least(v_me, p_user_id), greatest(v_me, p_user_id), 'connection_request')
    on conflict (user_a_id, user_b_id) do nothing;

    update connection_requests
       set status = 'accepted', responded_at = now()
     where id = v_incoming.id;

    insert into notification_outbox (user_id, kind, payload)
    values (p_user_id, 'connection_accepted',
            jsonb_build_object('user_id', v_me, 'user_name', v_my_name));

    return 'connected';
  end if;

  insert into connection_requests (requester_id, recipient_id)
  values (v_me, p_user_id)
  on conflict (requester_id, recipient_id) do nothing;

  get diagnostics v_inserted = row_count;

  -- Уже просили — неважно, ждёт эта заявка ответа или получила отказ.
  -- Отказ окончателен, и «попросить ещё раз» отличается от «уговаривать»
  -- только словом.
  if v_inserted = 0 then
    raise exception 'Already requested' using errcode = 'PT409';
  end if;

  insert into notification_outbox (user_id, kind, payload)
  values (p_user_id, 'connection_request',
          jsonb_build_object('user_id', v_me, 'user_name', v_my_name));

  return 'requested';
end;
$function$;

-- Только получатель и только по ждущей ответа заявке. «Нет такой» и «чужая»
-- отвечают одним PT404 — тот же принцип, что у `delete_own_comment()`.
--
-- Отказ уведомления НЕ порождает: сообщать «вам отказали» значит превращать
-- тихий отказ в событие. Отправитель увидит это сам — кнопка «позвать» к
-- нему не вернётся.
CREATE OR REPLACE FUNCTION public.respond_to_connection_request(p_request_id uuid, p_accept boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me uuid := auth.uid();
  v_request connection_requests%rowtype;
  v_my_name text;
begin
  if v_me is null then
    raise exception 'Not authenticated';
  end if;

  select * into v_request
    from connection_requests
   where id = p_request_id
     and recipient_id = v_me
     and status = 'pending'
   for update;

  if not found then
    raise exception 'Request not found' using errcode = 'PT404';
  end if;

  if not coalesce(p_accept, false) then
    update connection_requests
       set status = 'declined', responded_at = now()
     where id = v_request.id;
    return;
  end if;

  -- Блок мог появиться после отправки заявки — согласиться с ним нельзя.
  if public.is_blocked_pair(v_me, v_request.requester_id) then
    raise exception 'Not available' using errcode = 'PT403';
  end if;

  insert into connections (user_a_id, user_b_id, method)
  values (least(v_me, v_request.requester_id), greatest(v_me, v_request.requester_id),
          'connection_request')
  on conflict (user_a_id, user_b_id) do nothing;

  update connection_requests
     set status = 'accepted', responded_at = now()
   where id = v_request.id;

  select name into v_my_name from users where id = v_me;

  insert into notification_outbox (user_id, kind, payload)
  values (v_request.requester_id, 'connection_accepted',
          jsonb_build_object('user_id', v_me, 'user_name', v_my_name));
end;
$function$;

-- «Держит ли ОН меня в избранном» — множеством для политики `posts`
-- (20260829100000). `security definer` по той же причине, по которой ею
-- стала `is_blocked_pair()`: RLS на `favorite_users` пускает к строкам
-- только их владельца, и подзапрос к ЧУЖОМУ избранному внутри политики
-- молча отфильтровался бы в ноль — пост «только для избранных» не увидел
-- бы никто. Пара к ней — скаляр `is_favorited_by()`, тот же дуэт, что
-- `visible_author_ids()` / `is_author_visible()`.
--
-- Избранное этим стало ещё и аудиторией, но узнать, что ты у кого-то в
-- избранном, по-прежнему нельзя: строки `favorite_users` видит только
-- владелец, а метку «только для избранных» — только автор поста.
CREATE OR REPLACE FUNCTION public.authors_who_favorited_me()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select f.user_id
    from favorite_users f
   where f.favorite_id = auth.uid();
$function$;

-- Скалярный двойник для построчных вызывающих — сегодня это одна
-- `is_post_visible()`. Наружу НЕ выдана (20260829110000): ручка отвечала бы
-- про ЛЮБОГО `p_author` на вопрос, ради сокрытия которого `favorite_users`
-- закрыта RLS до строк одного владельца.
CREATE OR REPLACE FUNCTION public.is_favorited_by(p_author uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1 from favorite_users f
     where f.user_id = p_author and f.favorite_id = auth.uid()
  );
$function$;

-- Правило видимости ПОСТА целиком: виден автор, пост не скрыт модерацией,
-- и аудитория пускает — всем знакомым, либо я автор, либо я у автора в
-- избранном (20260829100000, 20260913100000). Живёт здесь один раз;
-- SELECT-политика `posts` повторяет его дословно по той же причине, по
-- которой это делает `is_comment_visible()` (построчный
-- `security definer` на ленте — регрессия 20260726180000). Менять надо оба
-- места. Спрашивают её `is_comment_visible()`, `reaction_summary()`,
-- `post_media_path_visible()` и `can_report()`; наружу не выдана — это
-- оракул по произвольному id.
CREATE OR REPLACE FUNCTION public.is_post_visible(p_post_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce((
    select p.hidden_at is null
       and public.is_author_visible(p.author_id)
       and (p.visibility = 'connections'
            or p.author_id = auth.uid()
            or public.is_favorited_by(p.author_id))
      from posts p
     where p.id = p_post_id
  ), false);
$function$;

-- Дословная копия условия SELECT-политики `comments` — единственное место
-- в проекте, где правило продублировано НАМЕРЕННО. Подставить функцию в
-- саму политику нельзя: `security definer` не инлайнится, и построчный
-- вызов на ленте — регрессия из 20260726180000. Менять надо обе
-- (20260822140000). Видимость поста спрашивается у `is_post_visible()`,
-- скрытое модерацией не видно никому (20260913100000).
CREATE OR REPLACE FUNCTION public.is_comment_visible(p_comment_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce((
    select
      c.hidden_at is null
      -- Пост виден. Внутри `security definer` политика posts не применяется,
      -- поэтому спрашиваем правило у `is_post_visible()` — единственного
      -- места, где оно записано вне самой политики.
      and public.is_post_visible(c.post_id)
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

-- Счётчики реакций — `security definer`, поэтому видимость проверяет сама,
-- и спрашивает её у поста, а не у автора (20260826180000). Помечена
-- STABLE: она только читает (20260924100000).
CREATE OR REPLACE FUNCTION public.reaction_summary(p_post_ids uuid[])
 RETURNS TABLE(post_id uuid, like_count bigint, neutral_count bigint, dislike_count bigint, my_reaction text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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

-- Структурные правила ответов. BEFORE INSERT-триггер срабатывает ДО
-- WITH CHECK политики, поэтому он молчит про всё, чего вызывающему видеть
-- нельзя: не видно — `return new`, и отказывает уже политика, одинаковым
-- 42501 на «нет строки», «строка чужая» и «строка-заглушка»
-- (20260822140000).
CREATE OR REPLACE FUNCTION public.enforce_comment_reply_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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

-- Виден ли файл поста: путь объекта идёт к строке `post_media` — по файлу
-- или по постеру — и дальше к самому посту, у которого спрашивается
-- `is_post_visible()` (20260826190000). Путь
-- `posts/<author_id>/<токены>/<файл>` знает только автора, а у одного
-- автора бывают посты, которые часть его знакомых видеть не должна.
-- Выдана `authenticated`, потому что её зовёт storage-политика.
CREATE OR REPLACE FUNCTION public.post_media_path_visible(p_path text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1
      from post_media pm
     where (pm.storage_path = p_path or pm.poster_path = p_path)
       and public.is_post_visible(pm.post_id)
  );
$function$;

-- Аватарка соседа по комнате — это ОДИН объект, текущий
-- `users.avatar_path`, а не весь префикс `avatars/<uid>/`
-- (20260905100000). Под префиксом лежит вся галерея профиля, до 80
-- фотографий, а RLS на `profile_photos` соседа по комнате не пускает
-- вовсе: префиксная ветвь отдавала бы ему байты, строки которых он не
-- видит. Ровно эту ошибку — префикс вместо объекта — у `posts/` исправила
-- `post_media_path_visible()` (см. «Префиксная ветвь в storage-политике» в
-- AGENTS.md).
--
-- Один аргумент, вторая сторона всегда `auth.uid()`: чужого вопроса через
-- неё не задать. `security definer` — чтобы ответ не зависел от того,
-- какие политики стоят на `users` завтра.
CREATE OR REPLACE FUNCTION public.is_room_peer_avatar(p_path text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1
      from users u
     where u.avatar_path = p_path
       and public.shares_room_with_caller(u.id)
  );
$function$;

-- «`reply_to_id`, если задан, указывает на сообщение ИЗ ТОЙ ЖЕ комнаты» —
-- через `security definer`, а не голым EXISTS в политике
-- (20260911100000). EXISTS к `room_messages` внутри INSERT-политики самой
-- `room_messages` — это 42P17 «infinite recursion detected in policy» на
-- ЛЮБОЙ отправке, даже без ответа: первая накатка именно так и уронила чат
-- (см. «Подзапрос к СВОЕЙ ЖЕ таблице» в AGENTS.md).
CREATE OR REPLACE FUNCTION public.room_message_in_room(p_message_id uuid, p_room_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1 from room_messages rm where rm.id = p_message_id and rm.room_id = p_room_id
  );
$function$;

-- Видно ли сообщение комнаты: я в ней, и оно не скрыто (20260913100000).
-- Зовётся только из `can_report()`, то есть изнутри `security definer`;
-- наружу закрыта (20260924100000).
CREATE OR REPLACE FUNCTION public.room_message_visible(p_message_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce((
    select m.hidden_at is null
       and m.room_id in (select public.my_room_ids())
      from room_messages m
     where m.id = p_message_id
  ), false);
$function$;

-- Виден ли файл вложения: путь должен лежать в `media` не скрытого
-- сообщения той комнаты, что названа в самом пути (20260913100000). У
-- удалённого сообщения медиа снято вместе с текстом, так что его пути не
-- находятся и так. Префиксная ветвь «папка моей комнаты» про сами
-- сообщения не знала ничего — скрытое сообщение исчезло бы из чата, а его
-- фотографии остались бы отдаваться по прямой ссылке.
--
-- Сама она членство не проверяет — это делает ветвь storage-политики рядом.
-- Как отдельная ручка она — оракул существования пути, поэтому закрыта от
-- анонима; `authenticated` выдана, потому что её зовёт политика
-- (20260924100000). Путь из трёх uuid не угадывается, и так же устроена
-- `post_media_path_visible()`.
CREATE OR REPLACE FUNCTION public.room_message_media_visible(p_path text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1
      from room_messages m,
           lateral jsonb_array_elements(m.media) item
     -- Комната берётся из самого пути (`messages/<room_id>/<author_id>/…`),
     -- чтобы отбор шёл по индексу, а не разворачивал jsonb у всех сообщений
     -- всех комнат.
     where m.room_id = nullif(split_part(p_path, '/', 2), '')::uuid
       and m.hidden_at is null
       and (item.value ->> 'storage_path' = p_path
            or item.value ->> 'poster_path' = p_path)
  );
$function$;

-- Кто автор объекта жалобы и что там было написано. `security definer`:
-- жалобщик по большей части не видит эти таблицы целиком, и подзапросы
-- фильтровались бы их политиками от его лица (20260913100000).
CREATE OR REPLACE FUNCTION public.fill_content_report_target()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if new.target_kind = 'post' then
    select p.author_id, left(coalesce(p.text, ''), 500)
      into new.target_author_id, new.target_snapshot
      from posts p where p.id = new.target_id;
  elsif new.target_kind = 'comment' then
    select c.author_id, left(coalesce(c.text, ''), 500)
      into new.target_author_id, new.target_snapshot
      from comments c where c.id = new.target_id;
  elsif new.target_kind = 'room_message' then
    select m.author_id, left(coalesce(m.text, ''), 500)
      into new.target_author_id, new.target_snapshot
      from room_messages m where m.id = new.target_id;
  elsif new.target_kind = 'user' then
    new.target_author_id := new.target_id;
    new.target_snapshot := null;
  end if;

  -- Жалоба на себя — не жалоба. Проверка здесь, а не в политике: автора
  -- объекта политика не знает, а сюда он уже разрешён.
  if new.target_author_id = new.reporter_id then
    raise exception 'Cannot report your own content'
      using errcode = 'AMR02';
  end if;

  -- Приходят только те значения, что перечислены в INSERT-гранте; остальное
  -- расставляет сервер, и переписать его клиенту нечем.
  new.status := 'open';
  new.resolution := null;
  new.resolved_at := null;
  new.created_at := now();
  return new;
end;
$function$;

-- Жаловаться можно только на то, что видно (20260913100000). Иначе форма
-- жалобы становится оракулом: «существует ли пост с таким id». Правило не
-- переписывается, а спрашивается у тех же функций, что держат видимость
-- везде.
--
-- Звать их прямо из политики нельзя: выражение политики исполняется от
-- вызывающей роли, а у `is_post_visible()` и `is_author_visible()` гранта
-- для `authenticated` нет намеренно. Поэтому диспетчер один, внутри него
-- проверки идут от владельца, и выдан наружу только он; его вопрос честно
-- про вызывающего — «можно ли МНЕ пожаловаться на это».
CREATE OR REPLACE FUNCTION public.can_report(p_target_kind text, p_target_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case p_target_kind
    when 'post' then public.is_post_visible(p_target_id)
    when 'comment' then public.is_comment_visible(p_target_id)
    when 'room_message' then public.room_message_visible(p_target_id)
    when 'user' then public.is_author_visible(p_target_id)
    else false
  end;
$function$;

-- Под запретом ли писать — про ЛЮБОЙ аккаунт по uuid. Живых вызовов нет;
-- закрыта для всех, включая PUBLIC (20260924100000): решение модерации
-- наружу не отдаётся.
CREATE OR REPLACE FUNCTION public.is_write_banned(p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1 from users u
     where u.id = p_user and u.write_banned_until > now()
  );
$function$;

-- Запрет писать проверяется ТРИГГЕРОМ, а не INSERT-политиками
-- (20260913100000): все пишущие RPC проекта — `security definer`, внутри
-- них RLS не применяется вовсе, и условие в политике `posts` забанённого не
-- остановило бы — посты создаются RPC. Триггер привязан к таблице и
-- срабатывает одинаково на прямой записи через PostgREST и внутри
-- definer-функции. Одно тело на все таблицы — вместо копий условия,
-- которые разошлись бы к третьей правке.
--
-- Висит на восьми таблицах: на семи — BEFORE INSERT, на `users` — BEFORE
-- UPDATE, а на `posts` — оба: правка текста старого поста и смена имени —
-- тоже запись (20260924100000). Автор строки находится по имени колонки, у
-- `users` — по первичному ключу.
--
-- «Шапка пункта 3» в теле — это 20260924100000: сравнение с `auth.uid()`
-- идёт через `is distinct from`, а не `<>`. При серверной записи
-- `auth.uid()` — NULL, `<>` дал бы NULL, и функция пошла бы судить бан
-- автора строки, которую пишет сервер. BEFORE INSERT срабатывает до
-- арбитража `ON CONFLICT`, так что идемпотентный ретрай забанённого
-- получает отказ вместо тихого успеха — здесь это и нужно.
CREATE OR REPLACE FUNCTION public.reject_write_when_banned()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_until timestamp with time zone;
  v_author uuid;
begin
  -- У всех восьми таблиц колонка автора называется по-разному, а тело одно.
  -- Берётся из NEW через to_jsonb, чтобы не плодить восемь функций.
  v_author := coalesce(
    (to_jsonb(new) ->> 'author_id')::uuid,
    (to_jsonb(new) ->> 'user_id')::uuid,
    (to_jsonb(new) ->> 'owner_id')::uuid,
    (to_jsonb(new) ->> 'requester_id')::uuid,
    -- `public.users` — единственная таблица, где автор строки это её
    -- первичный ключ. Поэтому ветка условная по имени таблицы, а не просто
    -- `id` пятым элементом цепочки: `id` есть и у `posts`, и у `comments`, и
    -- у `rooms`, и там это НЕ человек — безусловный `id` превратил бы функцию
    -- в проверку бана «пользователя с id поста». Без этой ветки триггер на
    -- `users` срабатывал, не находил автора и выходил как «пишет сервер» —
    -- то есть смена имени забанённому оставалась разрешённой (поймано пробой,
    -- а не рассуждением).
    case
      when tg_table_schema = 'public' and tg_table_name = 'users'
        then (to_jsonb(new) ->> 'id')::uuid
    end
  );
  -- `is distinct from`, а не `<>`: см. шапку пункта 3.
  if v_author is distinct from auth.uid() then
    -- Не наше дело: строку пишет не сам пользователь (сервер, миграция,
    -- консоль) либо автор в ней не назван. Чужие вставки этот триггер не
    -- судит — за них отвечают политики и гранты.
    return new;
  end if;

  select u.write_banned_until into v_until
    from users u where u.id = v_author;

  if v_until is not null and v_until > now() then
    -- Свой SQLSTATE, чтобы клиент отличил бан от отказа политики (42501) и
    -- от сетевой ошибки. Дата уезжает в DETAIL: текст клиент рисует свой,
    -- локализованный, а из ответа ему нужна только она.
    raise exception 'Writing is restricted for this account'
      using errcode = 'AMB01',
            detail = to_char(v_until at time zone 'UTC',
                             'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  end if;

  return new;
end;
$function$;

-- Время ставит сервер, как и у `device_tokens`: поле отвечает на вопрос
-- «когда мы это видели», и ответ не должен зависеть от часов телефона
-- (20260913120000).
CREATE OR REPLACE FUNCTION public.pin_push_registration_timestamp()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  new.updated_at := now();
  return new;
end;
$function$;


-- =====================================================================
-- 5. Ограничения, которые зовут функции
-- =====================================================================
-- CHECK, который вызывает нашу функцию, не может стоять в `create table`:
-- функции ещё нет. Поэтому он навешивается здесь, сразу после неё.

-- Форма вложений сообщения — см. `room_message_media_ok()` выше и
-- `room_messages` в разделе 2.
alter table public.room_messages
  add constraint room_messages_media_shape CHECK (room_message_media_ok(room_id, author_id, media));


-- =====================================================================
-- 6. Триггеры
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

-- Имя выбрано так, чтобы триггер срабатывал ПЕРЕД
-- `device_tokens_enforce_limit_before_insert`: BEFORE-триггеры строки
-- вызываются в алфавитном порядке имён, «claim» < «enforce». Порядок здесь
-- ни на что не влияет (лимит считает строки только этого пользователя), но
-- освободить токен до подсчёта — то, что читается правильно.
create trigger device_tokens_claim_token_before_insert
  before insert on public.device_tokens
  for each row execute function public.claim_device_token();

-- Последний вышедший уносит комнату, из парной хватает любого.
create trigger room_members_cleanup_after_delete
  after delete on public.room_members
  for each row execute function public.cleanup_orphaned_room();

create trigger room_messages_enqueue_notifications_after_insert
  after insert on public.room_messages
  for each row execute function public.enqueue_room_message_notifications();

create trigger fill_content_report_target
  before insert on public.content_reports
  for each row execute function public.fill_content_report_target();

-- Запрет писать — см. `reject_write_when_banned()`. Одно тело, восемь
-- таблиц; на `posts` и `users` ещё и UPDATE.
create trigger reject_write_when_banned
  before insert on public.posts
  for each row execute function public.reject_write_when_banned();

create trigger reject_write_when_banned
  before insert on public.comments
  for each row execute function public.reject_write_when_banned();

create trigger reject_write_when_banned
  before insert on public.room_messages
  for each row execute function public.reject_write_when_banned();

create trigger reject_write_when_banned
  before insert on public.reactions
  for each row execute function public.reject_write_when_banned();

create trigger reject_write_when_banned
  before insert on public.profile_photos
  for each row execute function public.reject_write_when_banned();

create trigger reject_write_when_banned
  before insert on public.invite_links
  for each row execute function public.reject_write_when_banned();

create trigger reject_write_when_banned
  before insert on public.connection_requests
  for each row execute function public.reject_write_when_banned();

create trigger pin_push_registration_timestamp
  before insert or update on public.push_registration_status
  for each row execute function public.pin_push_registration_timestamp();

-- `update of text` у постов и `update of name` у профиля — ровно те
-- колонки, которые `authenticated` вообще может менять (20260924100000).
create trigger reject_write_when_banned_on_update
  before update of text on public.posts
  for each row execute function public.reject_write_when_banned();

create trigger reject_write_when_banned_on_update
  before update of name on public.users
  for each row execute function public.reject_write_when_banned();


-- =====================================================================
-- 7. RLS и политики
-- =====================================================================
-- RLS включена на каждой таблице `public` без исключений. У
-- `notification_outbox` и `user_activity` политик нет вовсе — это и есть
-- их правило доступа: `authenticated` не видит и не пишет там ничего.
--
-- Имена политик даны ровно так, как они лежат в каталоге: PostgreSQL
-- обрезает идентификатор по 63 байтам, и длинные имена приехали сюда
-- уже обрезанными. Переписывать их «красиво» нельзя — получится вторая
-- политика рядом со старой.
--
-- Условия — дословно из каталога, поэтому `auth.uid()` в них записан как
-- `( SELECT auth.uid() AS uid)`: обёрнутый в скалярный подзапрос, он
-- считается один раз на запрос, а не на каждую строку (20261010100000).
-- В новых политиках писать сразу `(select auth.uid())`.

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
alter table public.rooms enable row level security;
alter table public.room_members enable row level security;
alter table public.room_messages enable row level security;
alter table public.connection_requests enable row level security;
alter table public.content_reports enable row level security;
alter table public.push_registration_status enable row level security;

create policy "Users can update their own profile"
  on public.users
  for update
  to authenticated
  using ((( SELECT auth.uid() AS uid) = id))
  with check ((( SELECT auth.uid() AS uid) = id));

-- Кто видит профиль: сам владелец; все — профиль системного аккаунта;
-- Connections; соседи по комнате (`shares_room_with_caller()`,
-- 20260826180000); автор поста, под которым человек комментировал. Mute сюда
-- не входит никогда, блок сужает внутри функций.
create policy "Profiles are viewable by connections, room peers, commenters"
  on public.users
  for select
  to authenticated
  using (((id = ( SELECT auth.uid() AS uid)) OR is_system_account(id) OR is_connected_to_caller(id) OR shares_room_with_caller(id) OR is_commenter_visible_to_post_owner(id)));

create policy "Users can view their own connections"
  on public.connections
  for select
  to authenticated
  using (((( SELECT auth.uid() AS uid) = user_a_id) OR (( SELECT auth.uid() AS uid) = user_b_id)));

create policy "Owners can view their own invite links"
  on public.invite_links
  for select
  to authenticated
  using ((owner_id = ( SELECT auth.uid() AS uid)));

create policy "Users can create their own posts"
  on public.posts
  for insert
  to authenticated
  with check (((author_id = ( SELECT auth.uid() AS uid)) AND (created_at = now())));

create policy "Users can edit their own posts"
  on public.posts
  for update
  to authenticated
  using ((author_id = ( SELECT auth.uid() AS uid)))
  with check ((author_id = ( SELECT auth.uid() AS uid)));

create policy "Users can delete their own posts"
  on public.posts
  for delete
  to authenticated
  using ((author_id = ( SELECT auth.uid() AS uid)));

-- Дословный повтор `is_post_visible()`: не скрыт, автор виден, и аудитория
-- пускает — всем знакомым, либо я автор, либо я у автора в избранном
-- (20260829100000, 20260913100000). Политика правило не вызывает, а
-- повторяет — построчный `security definer` на ленте не инлайнится и стоил
-- 217 мс против 3.5 (20260726180000). Менять надо оба места.
create policy "Posts are viewable by connections, restricted ones by favorites"
  on public.posts
  for select
  to authenticated
  using (((hidden_at IS NULL) AND (author_id IN ( SELECT visible_author_ids() AS visible_author_ids)) AND ((visibility = 'connections'::text) OR (author_id = ( SELECT auth.uid() AS uid)) OR (author_id IN ( SELECT authors_who_favorited_me() AS authors_who_favorited_me)))));

create policy "Users can attach media to their own posts"
  on public.post_media
  for insert
  to authenticated
  with check (((created_at = now()) AND (EXISTS ( SELECT 1
   FROM posts p
  WHERE ((p.id = post_media.post_id) AND (p.author_id = ( SELECT auth.uid() AS uid))))) AND (storage_path ~~ (('posts/'::text || (( SELECT auth.uid() AS uid))::text) || '/%'::text)) AND ((poster_path IS NULL) OR (poster_path ~~ (('posts/'::text || (( SELECT auth.uid() AS uid))::text) || '/%'::text)))));

create policy "Users can delete media from their own posts"
  on public.post_media
  for delete
  to authenticated
  using ((EXISTS ( SELECT 1
   FROM posts p
  WHERE ((p.id = post_media.post_id) AND (p.author_id = ( SELECT auth.uid() AS uid))))));

-- Медиа видно тогда и только тогда, когда виден пост: подзапрос к `posts`
-- сам идёт через её SELECT-политику (20260826180000).
create policy "Post media follow their post's visibility"
  on public.post_media
  for select
  to authenticated
  using ((EXISTS ( SELECT 1
   FROM posts p
  WHERE (p.id = post_media.post_id))));

create policy "Profile photos are viewable by the user, their connections, and"
  on public.profile_photos
  for select
  to authenticated
  using (((user_id = ( SELECT auth.uid() AS uid)) OR is_system_account(user_id) OR is_connected_to_caller(user_id)));

create policy "Users can add their own profile photos"
  on public.profile_photos
  for insert
  to authenticated
  with check (((user_id = ( SELECT auth.uid() AS uid)) AND (created_at = now()) AND (storage_path ~~ (('avatars/'::text || (( SELECT auth.uid() AS uid))::text) || '/%'::text))));

create policy "Users can delete their own profile photos"
  on public.profile_photos
  for delete
  to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)));

-- Дословный двойник `is_comment_visible()` — единственный намеренный
-- дубликат правила в проекте; менять обе вместе. Пост проверяется
-- подзапросом к `posts` под её политикой, скрытое модерацией не видно
-- никому (20260913100000). Имя политики старше правила: mute в видимости
-- не участвует с 20260829130000, а переименование политики — это вторая
-- политика рядом.
create policy "Comments are viewable by the viewer's unmuted connections"
  on public.comments
  for select
  to authenticated
  using (((hidden_at IS NULL) AND (EXISTS ( SELECT 1
   FROM posts p
  WHERE (p.id = comments.post_id))) AND ((author_id IN ( SELECT visible_author_ids() AS visible_author_ids)) OR is_comment_visible_to_post_owner(id)) AND ((parent_comment_id IS NULL) OR is_author_of_comment_visible(parent_comment_id) OR is_comment_visible_to_post_owner(parent_comment_id)) AND ((reply_to_id IS NULL) OR is_author_of_comment_visible(reply_to_id) OR is_comment_visible_to_post_owner(reply_to_id))));

create policy "Users can comment on posts and comments they can see"
  on public.comments
  for insert
  to authenticated
  with check (((author_id = ( SELECT auth.uid() AS uid)) AND (created_at = now()) AND (deleted_at IS NULL) AND (EXISTS ( SELECT 1
   FROM posts p
  WHERE (p.id = comments.post_id))) AND ((parent_comment_id IS NULL) OR is_comment_visible(parent_comment_id)) AND ((reply_to_id IS NULL) OR is_comment_visible(reply_to_id))));

create policy "Users can view their own reactions"
  on public.reactions
  for select
  to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)));

create policy "Users can like posts they can see"
  on public.reactions
  for insert
  to authenticated
  with check (((user_id = ( SELECT auth.uid() AS uid)) AND (created_at = now()) AND (EXISTS ( SELECT 1
   FROM posts p
  WHERE (p.id = reactions.post_id))) AND (NOT ((type = 'dislike'::text) AND (EXISTS ( SELECT 1
   FROM (posts p
     JOIN users u ON ((u.id = p.author_id)))
  WHERE ((p.id = reactions.post_id) AND u.dislikes_disabled)))))));

create policy "Users can change their own reaction"
  on public.reactions
  for update
  to authenticated
  using (((user_id = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM posts p
  WHERE (p.id = reactions.post_id)))))
  with check (((user_id = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM posts p
  WHERE (p.id = reactions.post_id))) AND (NOT ((type = 'dislike'::text) AND (EXISTS ( SELECT 1
   FROM (posts p
     JOIN users u ON ((u.id = p.author_id)))
  WHERE ((p.id = reactions.post_id) AND u.dislikes_disabled)))))));

create policy "Users can remove their own like"
  on public.reactions
  for delete
  to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)));

create policy "Users manage their own mutes"
  on public.muted_users
  for all
  to authenticated
  using ((muter_id = ( SELECT auth.uid() AS uid)))
  with check ((muter_id = ( SELECT auth.uid() AS uid)));

create policy "Users manage their own blocks"
  on public.blocked_users
  for all
  to authenticated
  using ((blocker_id = ( SELECT auth.uid() AS uid)))
  with check ((blocker_id = ( SELECT auth.uid() AS uid)));

create policy "Users manage their own favorites"
  on public.favorite_users
  for all
  to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)))
  with check ((user_id = ( SELECT auth.uid() AS uid)));

create policy "Users manage their own device tokens"
  on public.device_tokens
  for all
  to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)))
  with check ((user_id = ( SELECT auth.uid() AS uid)));

-- notification_outbox: политик нет намеренно (см. выше).
create policy "Users manage their own notification preferences"
  on public.notification_preferences
  for all
  to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)))
  with check ((user_id = ( SELECT auth.uid() AS uid)));

-- user_activity: политик нет намеренно (см. выше).

-- Ни INSERT, ни UPDATE, ни DELETE: состав и имя комнаты меняются только
-- через RPC, где проверяется «я владелец», «он мой Connection» и «блока
-- нет». Политика для этого не годится — она умеет разрешить запись, но не
-- умеет объяснить отказ и не проверит соседние строки.
create policy "Rooms are viewable by their members"
  on public.rooms
  for select
  to authenticated
  using ((id IN ( SELECT my_room_ids() AS my_room_ids)));

create policy "Room members are viewable by fellow members"
  on public.room_members
  for select
  to authenticated
  using ((room_id IN ( SELECT my_room_ids() AS my_room_ids)));

-- Видит тот, кто в комнате; скрытое модерацией — никто.
create policy "Room messages are viewable by room members"
  on public.room_messages
  for select
  to authenticated
  using (((hidden_at IS NULL) AND (room_id IN ( SELECT my_room_ids() AS my_room_ids))));

-- Писать может только участник и только от своего имени. `created_at = now()`
-- — тот же приём, что у постов и комментариев: клиент не назначает время
-- сам. Ответ — только на сообщение той же комнаты, через
-- `room_message_in_room()` (20260911100000).
create policy "Room members can write in their rooms"
  on public.room_messages
  for insert
  to authenticated
  with check (((author_id = ( SELECT auth.uid() AS uid)) AND (created_at = now()) AND (deleted_at IS NULL) AND (room_id IN ( SELECT my_room_ids() AS my_room_ids)) AND ((reply_to_id IS NULL) OR room_message_in_room(reply_to_id, room_id))));

-- Видит только та пара, которой заявка касается. Ни INSERT, ни UPDATE, ни
-- DELETE: весь путь записи — через `request_connection()` и
-- `respond_to_connection_request()`.
create policy "Connection requests are visible to both sides"
  on public.connection_requests
  for select
  to authenticated
  using (((requester_id = ( SELECT auth.uid() AS uid)) OR (recipient_id = ( SELECT auth.uid() AS uid))));

-- Жалоба — от своего имени и только на то, что видно (`can_report()`).
-- Читать жалобы не может никто, кроме консоли: SELECT-политики нет.
create policy "Users report what they can see"
  on public.content_reports
  for insert
  to authenticated
  with check (((reporter_id = ( SELECT auth.uid() AS uid)) AND can_report(target_kind, target_id)));

create policy "Users manage their own push registration status"
  on public.push_registration_status
  for all
  to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)))
  with check ((user_id = ( SELECT auth.uid() AS uid)));


-- =====================================================================
-- 8. Storage и Realtime
-- =====================================================================
-- Бакет заводится здесь, а не руками в дашборде: до 20260822260000 его
-- настраивали через `update … where id = 'media'`, и на чистом проекте
-- такой update молча не находил ничего. `public = false` — инвариант, на
-- нём стоят все SELECT-политики ниже; публичный бакет отменяет их разом.
-- Списки mime — ровно под imageExtensions/videoExtensions в
-- app/lib/shared/media_extensions.dart: storage_client берёт content-type
-- из расширения в имени объекта, а не из содержимого (20260820130000).
--
-- Префиксы: `avatars/<uid>/`, `posts/<author_id>/`, `rooms/<room_id>/`,
-- `messages/<room_id>/<author_id>/`. Первая папка — что это, вторая —
-- чьё. UPDATE-политики нет ни у одного префикса (20260822210000): замена
-- файла — всегда новый объект под свежим client-minted путём плюс delete
-- старого, поэтому uploadTolerant намеренно не ставит upsert.
--
-- Префиксная ветвь в политике равна построчному правилу только пока всё
-- под префиксом видно одинаково. Где это не так, политика идёт от пути к
-- ОБЪЕКТУ — `post_media_path_visible()`, `is_room_peer_avatar()`,
-- `room_message_media_visible()` (см. «Префиксная ветвь в
-- storage-политике» в AGENTS.md).

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

-- Файл поста видно тогда, когда виден сам пост, а не его автор
-- (20260826190000): путь знает только автора. Своя ветвь у автора первая
-- и строки `post_media` не требует — клиент заливает файлы ДО того, как
-- появляется пост.
create policy "Post photos follow their post's visibility"
  on storage.objects
  for select
  to authenticated
  using (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'posts'::text) AND (((storage.foldername(name))[2] = (auth.uid())::text) OR post_media_path_visible(name))));

-- Аватарка комнаты: читают участники, пишет и сносит владелец
-- (20260826210000).
create policy "Room avatars are viewable by room members"
  on storage.objects
  for select
  to authenticated
  using (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'rooms'::text) AND (((storage.foldername(name))[2])::uuid IN ( SELECT my_room_ids() AS my_room_ids))));

create policy "Room owners can upload a room avatar"
  on storage.objects
  for insert
  to authenticated
  with check (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'rooms'::text) AND owns_room(((storage.foldername(name))[2])::uuid)));

create policy "Room owners can delete a room avatar"
  on storage.objects
  for delete
  to authenticated
  using (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'rooms'::text) AND owns_room(((storage.foldername(name))[2])::uuid)));

-- Вложения сообщений: `messages/<room_id>/<author_id>/<токен отправки>/
-- <токен файла>.<ext>` (20260828120000). Заливает только участник комнаты
-- и только под своим именем — без второго условия участник мог бы
-- положить файл в чужую папку общей комнаты.
create policy "Room members can upload message media"
  on storage.objects
  for insert
  to authenticated
  with check (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'messages'::text) AND (((storage.foldername(name))[2])::uuid IN ( SELECT my_room_ids() AS my_room_ids)) AND ((storage.foldername(name))[3] = (auth.uid())::text)));

-- Сносит автор — и после того, как вышел из комнаты (20260829120000):
-- членство с DELETE снято, право — третий сегмент пути. Иначе
-- `delete_own_account()`, унося `room_members` каскадом раньше уборки
-- объектов, оставлял бы вложения сиротами, а погасить своё сообщение в
-- покинутой комнате можно, но файл — нет.
create policy "Authors can delete their own message media"
  on storage.objects
  for delete
  to authenticated
  using (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'messages'::text) AND ((storage.foldername(name))[3] = (auth.uid())::text)));

-- `avatars/<uid>/…` видно себе, Connections и системному аккаунту — всем
-- префиксом, — и соседу по комнате — ОДНИМ объектом, текущей аватаркой
-- (`is_room_peer_avatar()`, 20260905100000). Блок префикс НЕ сужает:
-- заблокированный остаётся на экране «Заблокированные», где блок и
-- снимают, а тот рисует аватарку (20260823130000).
create policy "Avatars are viewable by the user, connections and room peers"
  on storage.objects
  for select
  to authenticated
  using (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'avatars'::text) AND (((storage.foldername(name))[2] = (auth.uid())::text) OR ((storage.foldername(name))[2] IN ( SELECT (s.s)::text AS s
   FROM system_account_ids() s(s))) OR (EXISTS ( SELECT 1
   FROM connections c
  WHERE (((c.user_a_id = auth.uid()) AND ((c.user_b_id)::text = (storage.foldername(objects.name))[2])) OR ((c.user_b_id = auth.uid()) AND ((c.user_a_id)::text = (storage.foldername(objects.name))[2]))))) OR is_room_peer_avatar(name))));

-- Видно участнику комнаты — и только вложение не скрытого сообщения
-- (`room_message_media_visible()`, 20260913100000): скрытое сообщение не
-- должно продолжать отдавать свои фотографии по прямой ссылке.
create policy "Message media are viewable by room members"
  on storage.objects
  for select
  to authenticated
  using (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'messages'::text) AND (((storage.foldername(name))[2])::uuid IN ( SELECT my_room_ids() AS my_room_ids)) AND room_message_media_visible(name)));

-- Realtime. В публикации `supabase_realtime` две таблицы: `room_messages`
-- (чат, 20260826200000) и `room_members` (галочки, 20260827100000).
-- Подписчик Postgres Changes получает строку, только если её пускает
-- SELECT-политика таблицы. Добавление обёрнуто в проверку: `alter
-- publication … add table` на уже добавленной таблице — ошибка.
do $pub$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime'
                    and schemaname = 'public' and tablename = 'room_members') then
    alter publication supabase_realtime add table public.room_members;
  end if;
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime'
                    and schemaname = 'public' and tablename = 'room_messages') then
    alter publication supabase_realtime add table public.room_messages;
  end if;
end
$pub$;

-- Приватный канал Realtime `room:<room_id>` — «печатает…» и «в сети»
-- (20260828130000). Presence и broadcast, в отличие от Postgres Changes,
-- RLS не проверяют ни на что, если канал публичный; приватный идёт через
-- `realtime.messages`. SELECT — «подписаться и слышать», INSERT —
-- «сказать»; оба только участнику комнаты.
create policy "Room presence is readable by room members"
  on realtime.messages
  for select
  to authenticated
  using (is_my_room_topic(( SELECT realtime.topic() AS topic)));

create policy "Room members can announce their presence"
  on realtime.messages
  for insert
  to authenticated
  with check (is_my_room_topic(( SELECT realtime.topic() AS topic)));


-- =====================================================================
-- 9. Гранты
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
-- SELECT выдан на таблицы целиком — поколоночно выдаются только INSERT и
-- UPDATE. Значит новая колонка читается всеми, кому RLS показывает строку;
-- так `users.write_banned_until` и стал виден (см. `users`).
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

-- UPDATE — на таблицу целиком: апсерт токена шлёт в SET все колонки, а
-- ключ и время пинает триггер (`pin_device_token_timestamps()`).
revoke all on table public.device_tokens from anon, authenticated;
grant delete, maintain, select, update on table public.device_tokens to authenticated;
grant insert (app_build, app_version, fcm_token, locale, os_version, platform, user_id) on table public.device_tokens to authenticated;

revoke all on table public.notification_outbox from anon, authenticated;

revoke all on table public.notification_preferences from anon, authenticated;
grant delete, insert, maintain, select, update on table public.notification_preferences to authenticated;

revoke all on table public.user_activity from anon, authenticated;

revoke all on table public.rooms from anon, authenticated;
grant maintain, select on table public.rooms to authenticated;

revoke all on table public.room_members from anon, authenticated;
grant maintain, select on table public.room_members to authenticated;

-- UPDATE- и DELETE-грантов нет: удаление — только `delete_own_room_message()`.
revoke all on table public.room_messages from anon, authenticated;
grant maintain, select on table public.room_messages to authenticated;
grant insert (author_id, client_token, created_at, media, reply_to_id, room_id, text) on table public.room_messages to authenticated;

revoke all on table public.connection_requests from anon, authenticated;
grant maintain, select on table public.connection_requests to authenticated;

-- Только INSERT и только тех колонок, что заполняет жалобщик; остальное
-- ставит триггер и консоль. SELECT нет вовсе.
revoke all on table public.content_reports from anon, authenticated;
grant insert (note, reason, reporter_id, target_id, target_kind) on table public.content_reports to authenticated;

-- UPDATE включает `user_id` (20260913130000): PostgREST разворачивает
-- upsert в `ON CONFLICT DO UPDATE SET` по ВСЕМ присланным колонкам, включая
-- ключ конфликта, и без права на него апсерт отбивается 42501. Дыры это не
-- открывает — `with check (user_id = auth.uid())` на месте.
revoke all on table public.push_registration_status from anon, authenticated;
grant select on table public.push_registration_status to authenticated;
grant insert (app_build, app_version, detail, os_version, platform, status, user_id) on table public.push_registration_status to authenticated;
grant update (app_build, app_version, detail, os_version, platform, status, user_id) on table public.push_registration_status to authenticated;

-- Последовательность identity-колонки `room_members.seq`. Права на неё у
-- `authenticated` — из дефолта Supabase для последовательностей: строку
-- `room_members` эта роль вставить не может, а сами функции
-- последовательностей PostgREST не публикует.
revoke all on sequence public.room_members_seq_seq from anon;

-- То же и на будущее: без этих строк следующая созданная таблица получит
-- права обратно из дефолтных привилегий — ровно так это и произошло между
-- 20260818140000 и 20260821120000. Миграции накатываются от имени
-- `postgres`, то есть именно от той роли, чьи дефолты здесь и правятся.
--
-- У `anon` дефолт снимается ЦЕЛИКОМ и по всем трём видам объектов: роль в
-- приложении не используется вообще (`enable_anonymous_sign_ins = false`),
-- а дефолтный TRUNCATE отдавал бы ей каждую новую таблицу мимо RLS.
-- У `authenticated` с таблиц снимаются только TRUNCATE/TRIGGER/REFERENCES:
-- SELECT/INSERT/UPDATE/DELETE роли нужны, и они сужаются поколоночно.
--
-- Дефолтный EXECUTE на функции выдаётся не `anon`, а PUBLIC — а PUBLIC
-- включает и `anon`, и `authenticated` (20260924100000). Поэтому снимается
-- и он, и дефолт `authenticated`: новая функция по умолчанию не
-- вызывается никем, кроме владельца и `service_role`, и каждый грант
-- `authenticated` ниже — явный. И по той же причине функции закрываются
-- словами `from public, anon, authenticated`: `revoke … from anon,
-- authenticated` грант PUBLIC не снимает и проходит молча.
alter default privileges in schema public
  revoke truncate, trigger, references on tables from authenticated;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on functions from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from authenticated;

-- Функции. Каждая в `public` — эндпоинт PostgREST, поэтому закрыты все, а
-- `authenticated` открыты только те, у которых каждый аргумент про самого
-- вызывающего, — и те, которые зовёт политика: выражение политики
-- исполняется от ВЫЗЫВАЮЩЕЙ роли (`post_media_path_visible()`,
-- `room_message_media_visible()`, `is_room_peer_avatar()`, `owns_room()`,
-- `my_room_ids()`, `can_report()`, …). Предикаты с двумя произвольными
-- uuid (`are_connected()`/`has_muted()`/`is_blocked_pair()`) и все, что
-- отвечают про чужой объект по id (`is_post_visible()`, `room_owner_id()`,
-- `is_favorited_by()`), закрыты: прямой грант отвечал бы на чужой вопрос
-- (20260726140000, 20260826120000, 20260829110000). Триггерные функции
-- закрыты тоже: PostgREST их не публикует, но пока грант есть, инвентарь
-- «что опубликовано» нельзя прочитать глазами (20260924100000).
revoke execute on function public.activate_invite_link(p_code text) from public, anon, authenticated;
grant execute on function public.activate_invite_link(p_code text) to authenticated;
revoke execute on function public.add_room_member(p_room_id uuid, p_user_id uuid) from public, anon, authenticated;
grant execute on function public.add_room_member(p_room_id uuid, p_user_id uuid) to authenticated;
revoke execute on function public.append_profile_photos(p_items jsonb) from public, anon, authenticated;
grant execute on function public.append_profile_photos(p_items jsonb) to authenticated;
revoke execute on function public.are_connected(p_user_a uuid, p_user_b uuid) from public, anon, authenticated;
revoke execute on function public.authors_who_favorited_me() from public, anon, authenticated;
grant execute on function public.authors_who_favorited_me() to authenticated;
revoke execute on function public.can_report(p_target_kind text, p_target_id uuid) from public, anon, authenticated;
grant execute on function public.can_report(p_target_kind text, p_target_id uuid) to authenticated;
revoke execute on function public.claim_device_token() from public, anon, authenticated;
revoke execute on function public.claim_notification_outbox(p_limit integer) from public, anon, authenticated;
revoke execute on function public.cleanup_orphaned_room() from public, anon, authenticated;
revoke execute on function public.comment_summary(p_post_ids uuid[]) from public, anon, authenticated;
grant execute on function public.comment_summary(p_post_ids uuid[]) to authenticated;
revoke execute on function public.create_invite_link() from public, anon, authenticated;
grant execute on function public.create_invite_link() to authenticated;
revoke execute on function public.create_post_with_media(p_client_token uuid, p_text text, p_items jsonb, p_visibility text) from public, anon, authenticated;
grant execute on function public.create_post_with_media(p_client_token uuid, p_text text, p_items jsonb, p_visibility text) to authenticated;
revoke execute on function public.create_room(p_member_ids uuid[], p_name text) from public, anon, authenticated;
grant execute on function public.create_room(p_member_ids uuid[], p_name text) to authenticated;
revoke execute on function public.delete_own_account() from public, anon, authenticated;
grant execute on function public.delete_own_account() to authenticated;
revoke execute on function public.delete_own_comment(p_comment_id uuid) from public, anon, authenticated;
grant execute on function public.delete_own_comment(p_comment_id uuid) to authenticated;
revoke execute on function public.delete_own_room_message(p_message_id uuid) from public, anon, authenticated;
grant execute on function public.delete_own_room_message(p_message_id uuid) to authenticated;
revoke execute on function public.enforce_comment_reply_rules() from public, anon, authenticated;
revoke execute on function public.enforce_device_token_limit() from public, anon, authenticated;
revoke execute on function public.enforce_post_media_limit() from public, anon, authenticated;
revoke execute on function public.enforce_profile_photos_limit() from public, anon, authenticated;
revoke execute on function public.enqueue_app_update_notifications(p_min_build integer, p_version text, p_important boolean) from public, anon, authenticated;
revoke execute on function public.enqueue_comment_notifications() from public, anon, authenticated;
revoke execute on function public.enqueue_inactive_week_notifications() from public, anon, authenticated;
revoke execute on function public.enqueue_post_notifications() from public, anon, authenticated;
revoke execute on function public.enqueue_room_message_notifications() from public, anon, authenticated;
revoke execute on function public.fill_content_report_target() from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.has_muted(p_muter uuid, p_muted uuid) from public, anon, authenticated;
revoke execute on function public.is_author_of_comment_visible(p_comment_id uuid) from public, anon, authenticated;
grant execute on function public.is_author_of_comment_visible(p_comment_id uuid) to authenticated;
revoke execute on function public.is_author_visible(p_author uuid) from public, anon, authenticated;
revoke execute on function public.is_blocked_pair(user_a uuid, user_b uuid) from public, anon, authenticated;
revoke execute on function public.is_comment_visible(p_comment_id uuid) from public, anon, authenticated;
grant execute on function public.is_comment_visible(p_comment_id uuid) to authenticated;
revoke execute on function public.is_comment_visible_to_post_owner(p_comment_id uuid) from public, anon, authenticated;
grant execute on function public.is_comment_visible_to_post_owner(p_comment_id uuid) to authenticated;
revoke execute on function public.is_commenter_visible_to_post_owner(p_user_id uuid) from public, anon, authenticated;
grant execute on function public.is_commenter_visible_to_post_owner(p_user_id uuid) to authenticated;
revoke execute on function public.is_connected_to_caller(p_other uuid) from public, anon, authenticated;
grant execute on function public.is_connected_to_caller(p_other uuid) to authenticated;
revoke execute on function public.is_favorited_by(p_author uuid) from public, anon, authenticated;
revoke execute on function public.is_my_room_topic(p_topic text) from public, anon, authenticated;
grant execute on function public.is_my_room_topic(p_topic text) to authenticated;
revoke execute on function public.is_post_visible(p_post_id uuid) from public, anon, authenticated;
revoke execute on function public.is_room_peer_avatar(p_path text) from public, anon, authenticated;
grant execute on function public.is_room_peer_avatar(p_path text) to authenticated;
revoke execute on function public.is_system_account(p_id uuid) from public, anon, authenticated;
grant execute on function public.is_system_account(p_id uuid) to authenticated;
revoke execute on function public.is_write_banned(p_user uuid) from public, anon, authenticated;
revoke execute on function public.leave_room(p_room_id uuid) from public, anon, authenticated;
grant execute on function public.leave_room(p_room_id uuid) to authenticated;
revoke execute on function public.mark_room_read(p_room_id uuid) from public, anon, authenticated;
grant execute on function public.mark_room_read(p_room_id uuid) to authenticated;
revoke execute on function public.mark_rooms_delivered() from public, anon, authenticated;
grant execute on function public.mark_rooms_delivered() to authenticated;
revoke execute on function public.my_room_ids() from public, anon, authenticated;
grant execute on function public.my_room_ids() to authenticated;
revoke execute on function public.my_rooms() from public, anon, authenticated;
grant execute on function public.my_rooms() to authenticated;
revoke execute on function public.orphaned_media_paths() from public, anon, authenticated;
revoke execute on function public.owns_room(p_room_id uuid) from public, anon, authenticated;
grant execute on function public.owns_room(p_room_id uuid) to authenticated;
revoke execute on function public.pin_device_token_timestamps() from public, anon, authenticated;
revoke execute on function public.pin_push_registration_timestamp() from public, anon, authenticated;
revoke execute on function public.pin_reaction_identity() from public, anon, authenticated;
revoke execute on function public.post_media_path_visible(p_path text) from public, anon, authenticated;
grant execute on function public.post_media_path_visible(p_path text) to authenticated;
revoke execute on function public.purge_abandoned_signups() from public, anon, authenticated;
revoke execute on function public.purge_empty_posts() from public, anon, authenticated;
revoke execute on function public.purge_notification_outbox() from public, anon, authenticated;
revoke execute on function public.reaction_summary(p_post_ids uuid[]) from public, anon, authenticated;
grant execute on function public.reaction_summary(p_post_ids uuid[]) to authenticated;
revoke execute on function public.reap_orphaned_media() from public, anon, authenticated;
revoke execute on function public.reject_write_when_banned() from public, anon, authenticated;
revoke execute on function public.remove_room_member(p_room_id uuid, p_user_id uuid) from public, anon, authenticated;
grant execute on function public.remove_room_member(p_room_id uuid, p_user_id uuid) to authenticated;
revoke execute on function public.rename_room(p_room_id uuid, p_name text) from public, anon, authenticated;
grant execute on function public.rename_room(p_room_id uuid, p_name text) to authenticated;
revoke execute on function public.reorder_profile_photos(p_photo_ids uuid[]) from public, anon, authenticated;
grant execute on function public.reorder_profile_photos(p_photo_ids uuid[]) to authenticated;
revoke execute on function public.request_connection(p_user_id uuid) from public, anon, authenticated;
grant execute on function public.request_connection(p_user_id uuid) to authenticated;
revoke execute on function public.respond_to_connection_request(p_request_id uuid, p_accept boolean) from public, anon, authenticated;
grant execute on function public.respond_to_connection_request(p_request_id uuid, p_accept boolean) to authenticated;
revoke execute on function public.room_message_in_room(p_message_id uuid, p_room_id uuid) from public, anon, authenticated;
grant execute on function public.room_message_in_room(p_message_id uuid, p_room_id uuid) to authenticated;
revoke execute on function public.room_message_media_ok(p_room_id uuid, p_author_id uuid, p_media jsonb) from public, anon, authenticated;
grant execute on function public.room_message_media_ok(p_room_id uuid, p_author_id uuid, p_media jsonb) to authenticated;
revoke execute on function public.room_message_media_visible(p_path text) from public, anon, authenticated;
grant execute on function public.room_message_media_visible(p_path text) to authenticated;
revoke execute on function public.room_message_visible(p_message_id uuid) from public, anon, authenticated;
revoke execute on function public.room_owner_id(p_room_id uuid) from public, anon, authenticated;
revoke execute on function public.rotate_invite_link() from public, anon, authenticated;
grant execute on function public.rotate_invite_link() to authenticated;
revoke execute on function public.set_post_media(p_post_id uuid, p_items jsonb) from public, anon, authenticated;
revoke execute on function public.set_room_avatar(p_room_id uuid, p_avatar_path text) from public, anon, authenticated;
grant execute on function public.set_room_avatar(p_room_id uuid, p_avatar_path text) to authenticated;
revoke execute on function public.set_room_muted(p_room_id uuid, p_muted boolean) from public, anon, authenticated;
grant execute on function public.set_room_muted(p_room_id uuid, p_muted boolean) to authenticated;
revoke execute on function public.shares_room_with_caller(p_other uuid) from public, anon, authenticated;
grant execute on function public.shares_room_with_caller(p_other uuid) to authenticated;
revoke execute on function public.sync_avatar_path_from_profile_photos() from public, anon, authenticated;
revoke execute on function public.system_account_ids() from public, anon, authenticated;
grant execute on function public.system_account_ids() to authenticated;
revoke execute on function public.touch_user_activity() from public, anon, authenticated;
grant execute on function public.touch_user_activity() to authenticated;
revoke execute on function public.update_post_with_media(p_post_id uuid, p_text text, p_items jsonb, p_visibility text) from public, anon, authenticated;
grant execute on function public.update_post_with_media(p_post_id uuid, p_text text, p_items jsonb, p_visibility text) to authenticated;
revoke execute on function public.visible_author_ids() from public, anon, authenticated;
grant execute on function public.visible_author_ids() to authenticated;


-- =====================================================================
-- 10. Задания pg_cron
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

-- Раз в час, а не раз в сутки (20260826120000): `orphaned_media_paths()`
-- ограничена `limit 100`, а один брошенный черновик оставляет до 40
-- объектов. Раз в сутки мусор мог копиться быстрее, чем уборщик его
-- выносит. `limit 100` держит размер HTTP-запроса к Storage
-- предсказуемым.
select cron.schedule('reap-orphaned-media', '45 * * * *', $$ select public.reap_orphaned_media(); $$);

select cron.schedule('purge-notification-outbox','10 5 * * *', $$ select public.purge_notification_outbox(); $$);


-- =====================================================================
-- 11. Контрольный блок
-- =====================================================================
-- Накат падает, если baseline оставил базу в состоянии, которого в
-- production нет. Проверяется то, что уже ломалось молча:
--
--   (1) таблица в `public` без RLS;
--   (2) любое право у `anon` на таблицы;
--   (3) право на запись у `authenticated`, под которым нет ни одной
--       политики. Смотреть надо в ДВА места: `column_privileges` —
--       правильный источник для INSERT и UPDATE, которые бывают
--       поколоночными, и слепой на DELETE (это привилегия уровня таблицы,
--       там она не появляется никогда). Ровно на этом четыре мёртвых
--       DELETE-гранта прошли мимо проверки, написанной против такого
--       (20260824140000 → 20260825100000);
--   (4) функция, которую может вызвать `anon`. Через
--       `has_function_privilege`, а не чтением `proacl`: именно чтение
--       глазами пропустило `=X/` — грант PUBLIC (20260924100000).
--       `rls_auto_enable()` — функция платформы, не наша;
--   (5) триггерная функция, открытая `authenticated`;
--   (6) функция, названная прямо в выражении политики, без EXECUTE у
--       `authenticated`: политика исполняется от вызывающей роли и без
--       гранта отбивается 42501. Список берётся из `pg_policies`, так что
--       следующая политика попадёт под проверку сама;
--   (7) дефолтный EXECUTE для PUBLIC на будущие функции.

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

  select string_agg(p.oid::regprocedure::text, ', ') into v_bad
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname <> 'rls_auto_enable'
     and has_function_privilege('anon', p.oid, 'execute');
  if v_bad is not null then
    raise exception 'anon может звать: %', v_bad;
  end if;

  select string_agg(p.oid::regprocedure::text, ', ') into v_bad
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prorettype = 'trigger'::regtype
     and has_function_privilege('authenticated', p.oid, 'execute');
  if v_bad is not null then
    raise exception 'триггерные функции открыты authenticated: %', v_bad;
  end if;

  select string_agg(distinct f.proname, ', ') into v_bad
    from pg_proc f
    join (
      select coalesce(qual, '') || ' ' || coalesce(with_check, '') as expr
        from pg_policies where schemaname in ('public', 'storage', 'realtime')
    ) pol on pol.expr ~ ('(^|[^a-z_])' || f.proname || '\s*\(')
   where f.pronamespace = 'public'::regnamespace
     and not has_function_privilege('authenticated', f.oid, 'execute');
  if v_bad is not null then
    raise exception 'функции из выражений политик без гранта: %', v_bad;
  end if;

  if exists (
    select 1 from pg_default_acl d
     where d.defaclnamespace = 'public'::regnamespace
       and d.defaclobjtype = 'f'
       and d.defaclacl::text ~ '[{,]=X/'
  ) then
    raise exception 'дефолтный EXECUTE для PUBLIC на функции всё ещё выдаётся';
  end if;
end
$check$;
