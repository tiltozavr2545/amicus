-- =====================================================================
-- Жалобы на контент и модерация.
--
-- Закрывает пункт «Полноценная модерация и жалобы» из
-- docs/future-development.md и требование App Store 1.2 к приложениям с
-- пользовательским контентом (способ пожаловаться + разбор). Блокировка
-- знакомого, которая была до сих пор, — это личная граница между двумя
-- людьми, а не модерация: она ничего не сообщает владельцу приложения.
--
-- Три отдельные вещи, которые удобнее накатить одной миграцией, потому что
-- врозь они бессмысленны:
--   1. `hidden_at` у постов, комментариев и сообщений — обратимое скрытие.
--   2. `content_reports` — на что пожаловались и чем кончилось.
--   3. `users.write_banned_until` — запрет писать, с датой окончания.
--
-- Скрытие идёт первым не для красоты: INSERT-политика жалоб спрашивает
-- видимость объекта, в том числе у `room_message_visible()`, которую заводит
-- именно этот блок.
--
-- Разбирает жалобы локальная консоль (console/) под service_role, поэтому
-- НИ ОДНОЙ модераторской RPC здесь не заводится: каждая функция в public —
-- это эндпоинт PostgREST, а единственному потребителю, который и так ходит
-- мимо RLS, эндпоинт не нужен. Роли модератора в БД тоже нет: человек с
-- service_role-ключом и есть вся авторизация, и заводить вторую её копию в
-- виде флага на users значило бы притворяться, что бывает иначе.
-- =====================================================================


-- =====================================================================
-- 1. Обратимое скрытие
-- =====================================================================
-- Скрытое исчезает у ВСЕХ, включая автора: полумера «автор всё ещё видит
-- свой пост» означает, что у одного и того же объекта два ответа на вопрос
-- «виден ли он», и правило видимости перестаёт быть одним. Автор узнаёт о
-- скрытии уведомлением (`moderation_notice`), а не по дырке в своей стене.
alter table public.posts add column hidden_at timestamp with time zone;
alter table public.comments add column hidden_at timestamp with time zone;
alter table public.room_messages add column hidden_at timestamp with time zone;

-- Грантов на эти колонки нет и не будет: их ставит только консоль под
-- service_role. Ни выдавать, ни отбирать ничего не требуется — все гранты в
-- этой схеме поколоночные, и новая колонка не попадает ни в один список сама
-- собой. У `authenticated` на posts есть UPDATE только на `text`, а у
-- comments и room_messages UPDATE-гранта нет вовсе.

create index posts_hidden_idx on public.posts using btree (hidden_at)
  where hidden_at is not null;
create index comments_hidden_idx on public.comments using btree (hidden_at)
  where hidden_at is not null;
create index room_messages_hidden_idx on public.room_messages using btree (hidden_at)
  where hidden_at is not null;

-- Тело взято из `prosrc` живой базы, а не из миграции, которая трогала
-- функцию последней (см. «create or replace переписывает ВСЁ тело» в
-- AGENTS.md). Добавлена ровно одна строка.
create or replace function public.is_post_visible(p_post_id uuid)
 returns boolean
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
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

create or replace function public.is_comment_visible(p_comment_id uuid)
 returns boolean
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
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

-- Видно ли сообщение комнаты. Заводится сейчас, потому что жалоба на
-- сообщение обязана проверить видимость, а спросить было не у кого:
-- `room_message_in_room()` требует знать комнату заранее.
create or replace function public.room_message_visible(p_message_id uuid)
 returns boolean
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
  select coalesce((
    select m.hidden_at is null
       and m.room_id in (select public.my_room_ids())
      from room_messages m
     where m.id = p_message_id
  ), false);
$function$;

-- Политики правила не вызывают, а повторяют — это решение по
-- производительности (`security definer` планировщик не инлайнит, см.
-- AGENTS.md), и здесь оно остаётся: `hidden_at is null` — литерал на
-- собственной колонке строки, а не пересказ правила видимости.
alter policy "Posts are viewable by connections, restricted ones by favorites"
  on public.posts
  using (
    hidden_at is null
    and (author_id in (select visible_author_ids() as visible_author_ids))
    and (visibility = 'connections'::text
         or author_id = auth.uid()
         or author_id in (select authors_who_favorited_me() as authors_who_favorited_me))
  );

alter policy "Comments are viewable by the viewer's unmuted connections"
  on public.comments
  using (
    hidden_at is null
    and (exists (select 1 from posts p where p.id = comments.post_id))
    and ((author_id in (select visible_author_ids() as visible_author_ids))
         or is_comment_visible_to_post_owner(id))
    and (parent_comment_id is null
         or is_author_of_comment_visible(parent_comment_id)
         or is_comment_visible_to_post_owner(parent_comment_id))
    and (reply_to_id is null
         or is_author_of_comment_visible(reply_to_id)
         or is_comment_visible_to_post_owner(reply_to_id))
  );

alter policy "Room messages are viewable by room members"
  on public.room_messages
  using (hidden_at is null and (room_id in (select my_room_ids() as my_room_ids)));

-- Политику редактирования поста трогать НЕ НАДО, и это стоит объяснить, а не
-- умолчать. Первая редакция этой миграции добавляла в её WITH CHECK условие
-- «hidden_at после правки тот же, что был» — подзапросом к `posts` внутри
-- политики самой `posts`. Это 42P17 `infinite recursion detected in policy`,
-- то есть падение ЛЮБОГО обновления поста в проде: ровно то, что уже уронило
-- отправку сообщений в 20260911100000. А нужды в проверке нет вовсе: UPDATE
-- у `posts` выдан `authenticated` поколоночно и только на `text`, так что
-- `hidden_at` этой роли недоступен ни на запись, ни (SELECT тоже
-- поколоночный) на чтение. У `comments` и `room_messages` UPDATE-гранта нет
-- вообще. Границу держит грант, а не политика, и это дешевле.

-- Медиа скрытого поста уходит из бакета вместе с ним: storage-политика
-- ходит через `post_media_path_visible()`, а та — через `is_post_visible()`,
-- в которую условие уже добавлено. Правку storage тут не требуется.
--
-- А вот у медиа СООБЩЕНИЙ ветка в storage-политике была префиксной («объект
-- лежит в папке комнаты, членом которой я являюсь») и про сами сообщения не
-- знала ничего. Скрытое сообщение исчезло бы из чата, а его фотографии
-- остались бы отдаваться по прямой ссылке — ровно тот же класс расхождения,
-- что уже случился с аватарками (см. «Префиксная ветвь в storage-политике» в
-- AGENTS.md). Поэтому ветка переписывается с префикса на объект.
create or replace function public.room_message_media_visible(p_path text)
 returns boolean
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
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

drop policy "Message media are viewable by room members" on storage.objects;
create policy "Message media are viewable by room members"
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'media'::text
    and (storage.foldername(name))[1] = 'messages'::text
    -- Дешёвая префиксная проверка остаётся первой: она отсекает чужие
    -- комнаты, не заглядывая в сообщения вовсе.
    and ((storage.foldername(name))[2])::uuid in (select my_room_ids() as my_room_ids)
    and public.room_message_media_visible(name)
  );


-- =====================================================================
-- 2. Жалобы
-- =====================================================================
-- `target_id` намеренно без внешнего ключа: он указывает в одну из четырёх
-- таблиц в зависимости от `target_kind`, и FK на все сразу не бывает. Цена
-- решения — висячая ссылка после удаления контента, и именно поэтому ниже
-- заводятся `target_author_id` и `target_snapshot`: жалоба должна оставаться
-- разбираемой после того, как автор сам снёс написанное. Снимок обрезан до
-- 500 символов — это опора для решения, а не архив чужих текстов.
create table public.content_reports (
  id uuid default gen_random_uuid() not null,
  reporter_id uuid not null,
  target_kind text not null,
  target_id uuid not null,
  reason text not null,
  note text,
  -- Заполняет сервер (триггер ниже), клиент их не шлёт и не может: грант на
  -- INSERT выдан поколоночно.
  target_author_id uuid,
  target_snapshot text,
  created_at timestamp with time zone default now() not null,
  status text default 'open' not null,
  resolution text,
  resolved_at timestamp with time zone,
  constraint content_reports_pkey primary key (id),
  constraint content_reports_kind_check
    check (target_kind = any (array['post'::text, 'comment'::text,
                                    'room_message'::text, 'user'::text])),
  -- Список причин закрытый: это то, по чему консоль группирует и сортирует
  -- очередь. Свободный текст для деталей — в `note`.
  constraint content_reports_reason_check
    check (reason = any (array['spam'::text, 'harassment'::text, 'hate'::text,
                               'violence'::text, 'sexual'::text,
                               'illegal'::text, 'other'::text])),
  constraint content_reports_status_check
    check (status = any (array['open'::text, 'resolved'::text, 'rejected'::text])),
  constraint content_reports_note_length
    check (note is null or char_length(note) <= 1000),
  constraint content_reports_snapshot_length
    check (target_snapshot is null or char_length(target_snapshot) <= 500),
  -- Разобранная жалоба обязана нести дату разбора, неразобранная — не нести.
  constraint content_reports_resolved_shape
    check ((status = 'open' and resolved_at is null)
           or (status <> 'open' and resolved_at is not null)),
  constraint content_reports_reporter_id_fkey
    foreign key (reporter_id) references public.users(id) on delete cascade,
  constraint content_reports_target_author_id_fkey
    foreign key (target_author_id) references public.users(id) on delete set null
);

-- Один человек — одна жалоба на один объект. Повторное нажатие приходит как
-- 23505, и клиент читает его как «уже отправлено», а не как ошибку: тот же
-- приём, что у отправки сообщений (см. «upsert из PostgREST» в AGENTS.md).
-- Индекс НЕчастичный и по этой причине тоже.
create unique index content_reports_once_per_reporter
  on public.content_reports using btree (reporter_id, target_kind, target_id);

-- Очередь консоли: сначала неразобранные, новые сверху.
create index content_reports_open_idx
  on public.content_reports using btree (created_at desc)
  where status = 'open';

-- Сколько раз пожаловались на один объект — главный сигнал в очереди.
create index content_reports_target_idx
  on public.content_reports using btree (target_kind, target_id);

alter table public.content_reports enable row level security;

-- Кто автор объекта и что там было написано — вопрос к таблицам, которых
-- жалобщик по большей части не видит целиком, поэтому `security definer`.
-- Без него подзапросы фильтровались бы политиками тех таблиц от лица
-- жалобщика (та же механика, что с `blocked_users`, см. AGENTS.md).
create or replace function public.fill_content_report_target()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
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

create trigger fill_content_report_target
  before insert on public.content_reports
  for each row execute function public.fill_content_report_target();

-- Жаловаться можно только на то, что видно. Иначе форма жалобы становится
-- оракулом: «существует ли пост с таким id» — вопрос, на который посторонний
-- отвечать не должен. Правило не переписывается, а спрашивается у тех же
-- функций, что держат видимость везде.
--
-- Вызывать их ПРЯМО ИЗ ПОЛИТИКИ нельзя, и это не стиль, а отказ: выражение
-- политики выполняется от лица вызывающей роли, и `execute` проверяется по
-- ней же. У `is_post_visible()` и `is_author_visible()` гранта для
-- `authenticated` нет намеренно (первая — оракул по произвольному id, вторую
-- закрыли в 20260826120000), так что первая же жалоба отлетела бы на
-- 42501 `permission denied for function`. Внутри `security definer` таких
-- проверок нет — тело исполняется от владельца, — поэтому диспетчер здесь
-- один и выдан наружу только он. Заодно это единственная функция всей
-- миграции, которую вообще видит PostgREST, и её вопрос честно про
-- вызывающего: «можно ли МНЕ пожаловаться на это».
create or replace function public.can_report(p_target_kind text, p_target_id uuid)
 returns boolean
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
  select case p_target_kind
    when 'post' then public.is_post_visible(p_target_id)
    when 'comment' then public.is_comment_visible(p_target_id)
    when 'room_message' then public.room_message_visible(p_target_id)
    when 'user' then public.is_author_visible(p_target_id)
    else false
  end;
$function$;

create policy "Users report what they can see"
  on public.content_reports
  for insert
  to authenticated
  with check (
    reporter_id = auth.uid()
    and public.can_report(target_kind, target_id)
  );

-- Дефолтные привилегии схемы дают `authenticated` на КАЖДУЮ новую таблицу
-- полный набор (a/r/w/d) — baseline снял их у `anon` совсем, а у
-- `authenticated` оставил, сузив потом поколоночно у каждой таблицы по
-- отдельности. Поэтому здесь тот же порядок: сначала снять всё, потом выдать
-- ровно нужное. Без `revoke` поколоночный грант ниже был бы просто добавкой
-- к уже выданному на всю таблицу, и клиент писал бы `status` с
-- `target_author_id` сам.
revoke all on table public.content_reports from anon, authenticated;

-- SELECT-политики нет намеренно — как у `notification_outbox`. Жалобщику
-- нечего читать обратно: подтверждение ему показывает сам клиент, а список
-- чужих жалоб на один объект — это счётчик, по которому легко понять, кого
-- ещё не любят, и наружу он не нужен. Политик на UPDATE/DELETE нет по той же
-- причине: разбор идёт из консоли под service_role.
grant insert (reporter_id, target_kind, target_id, reason, note)
  on table public.content_reports to authenticated;


-- =====================================================================
-- 3. Запрет писать
-- =====================================================================
-- NULL — не забанен. Дата в прошлом — бан кончился; чистить её незачем, она
-- же и история. Постоянный бан — дата далеко в будущем, отдельного «навсегда»
-- не заводится: одно поле с одним смыслом сравнивается одним оператором.
alter table public.users add column write_banned_until timestamp with time zone;

-- Колонку не видит никто, кроме сервера: `grant select` у users выдан
-- поколоночно (id, name, avatar_path, created_at, dislikes_disabled), новая
-- колонка в этот список не входит и наружу не отдаётся.
create index users_write_banned_idx on public.users using btree (write_banned_until)
  where write_banned_until is not null;

create or replace function public.is_write_banned(p_user uuid)
 returns boolean
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
  select exists (
    select 1 from users u
     where u.id = p_user and u.write_banned_until > now()
  );
$function$;

-- ГЛАВНОЕ решение всей миграции. Проверка живёт в триггере, а НЕ в
-- INSERT-политиках, потому что в политиках она не сработала бы почти нигде:
-- все девятнадцать пишущих RPC этого проекта — `security definer` и выданы
-- `authenticated` (`create_post_with_media`, `request_connection`,
-- `create_room`, …), а внутри definer-функции RLS не применяется вовсе, и
-- `force row level security` не включён ни на одной таблице. Условие в
-- политике `posts` забанённого не остановило бы: посты создаются RPC.
--
-- Триггер привязан к таблице, а не к роли, и срабатывает одинаково на прямой
-- вставке через PostgREST и внутри definer-функции. Одно тело на восемь
-- таблиц — вместо восьми копий условия, которые разошлись бы к третьей
-- правке (см. «правило видимости жило в четырёх копиях» в AGENTS.md).
--
-- Про `ON CONFLICT`: BEFORE INSERT срабатывает до арбитража конфликта, то
-- есть идемпотентный ретрай забанённого получит отказ вместо тихого успеха.
-- Здесь это верное поведение, а не грабля: забанённому отказ и полагается.
create or replace function public.reject_write_when_banned()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
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
    (to_jsonb(new) ->> 'requester_id')::uuid
  );
  if v_author is null or v_author <> auth.uid() then
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

create trigger reject_write_when_banned before insert on public.posts
  for each row execute function public.reject_write_when_banned();
create trigger reject_write_when_banned before insert on public.comments
  for each row execute function public.reject_write_when_banned();
create trigger reject_write_when_banned before insert on public.room_messages
  for each row execute function public.reject_write_when_banned();
create trigger reject_write_when_banned before insert on public.reactions
  for each row execute function public.reject_write_when_banned();
create trigger reject_write_when_banned before insert on public.profile_photos
  for each row execute function public.reject_write_when_banned();
create trigger reject_write_when_banned before insert on public.invite_links
  for each row execute function public.reject_write_when_banned();
create trigger reject_write_when_banned before insert on public.connection_requests
  for each row execute function public.reject_write_when_banned();
-- post_media отдельно: у неё нет колонки автора вовсе, автор — у поста.
-- Но и вставляется она только вместе с постом, внутри
-- `create_post_with_media()`, который уже отобьётся на самом посте. Триггер
-- здесь был бы третьим запросом на ту же проверку — не ставится намеренно.


-- =====================================================================
-- 4. Виды уведомлений
-- =====================================================================
-- Новый вид — это ВСЕГДА две правки: CHECK здесь и тексты в TEXTS
-- Edge Function (см. «Релиз» в docs/operations.md). Без второй строка в
-- очереди молча пропускается, и пуш не приходит.
alter table public.notification_outbox drop constraint notification_outbox_kind_check;
alter table public.notification_outbox add constraint notification_outbox_kind_check
  CHECK ((kind = ANY (ARRAY['new_post'::text, 'inactive_week'::text, 'digest'::text,
    'post_comment'::text, 'comment_reply'::text, 'app_update'::text,
    'app_update_important'::text, 'room_message'::text, 'connection_request'::text,
    'connection_accepted'::text,
    -- Список целиком взят из `pg_constraint` живой базы. Пересобирать его по
    -- памяти или по глазами прочитанной миграции нельзя: этот CHECK
    -- пересоздаётся `drop`+`add`, то есть любой невыписанный вид исчезает
    -- молча, а заметно это станет только тем, что какой-то пуш перестал
    -- приходить. При написании этой миграции ровно так и потерялся
    -- `connection_accepted` (он живёт в 20260828140000) — вернулся только
    -- после сверки с базой.
    'moderation_notice'::text, 'report_resolved'::text])));

comment on column public.content_reports.target_snapshot is
  'Копия текста на момент жалобы, до 500 символов: автор может снести написанное раньше разбора.';
comment on column public.users.write_banned_until is
  'Запрет писать до этого момента. NULL — не забанен. Ставит только консоль под service_role.';


-- =====================================================================
-- 5. Гранты на функции
-- =====================================================================
-- Дефолтные привилегии схемы выдают `authenticated` EXECUTE на КАЖДУЮ новую
-- функцию (у `anon` baseline снял это насовсем, у `authenticated` — нет).
-- А каждая функция в `public` — эндпоинт PostgREST, поэтому всё, что здесь
-- заведено, закрывается явно, и открывается ровно одна: диспетчер жалоб.
-- `create or replace` существующих функций их ACL не трогает, так что
-- `is_post_visible()` остаётся закрытой, какой и была.
revoke execute on function public.room_message_visible(uuid) from anon, authenticated;
revoke execute on function public.room_message_media_visible(text) from anon, authenticated;
revoke execute on function public.is_write_banned(uuid) from anon, authenticated;
revoke execute on function public.fill_content_report_target() from anon, authenticated;
revoke execute on function public.reject_write_when_banned() from anon, authenticated;
revoke execute on function public.can_report(text, uuid) from anon;
grant execute on function public.can_report(text, uuid) to authenticated;
