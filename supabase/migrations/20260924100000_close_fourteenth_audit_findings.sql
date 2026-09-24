-- =====================================================================
-- Четырнадцатый полный аудит: серверная половина.
--
-- Ложится поверх 20260923100000_delivered_marks_only_when_they_move.sql.
-- Тело единственной пересоздаваемой функции взято из `prosrc` ЖИВОЙ схемы и
-- сверено с 20260913100000, которая её завела: совпало построчно, так что
-- источник здесь схема, а не память (см. «`create or replace` переписывает
-- ВСЁ тело» в AGENTS.md).
--
-- Пять пунктов:
--   1. `revoke ... from anon, authenticated` НЕ снимает грант, выданный
--      PUBLIC, — и четыре функции, которые 20260913100000 считала закрытыми,
--      всё это время отвечали анониму. Главная находка аудита;
--   2. запрет писать (`write_banned_until`) держался ТОЛЬКО на BEFORE INSERT:
--      забанённый не мог завести новый пост, но мог переписать текст любого
--      своего старого и сменить себе имя — обход модерации;
--   3. `reject_write_when_banned()` сравнивала автора с `auth.uid()` через
--      `<>`, а не `is distinct from`: при серверной записи (консоль, cron,
--      миграция) `auth.uid()` равен NULL, всё условие становится NULL, и
--      функция НЕ выходила раньше времени, а шла проверять бан того, чью
--      строку пишет сервер. Сегодня это спасает только то, что системный
--      аккаунт не забанен;
--   4. `pg_temp` не прибит последним в `search_path` — стандартная защита
--      `security definer` от подмены имён таблиц временными;
--   5. `reaction_summary()` помечена VOLATILE, хотя только читает.
--
-- ЧЕГО ЗДЕСЬ НЕТ, хотя найдено тем же аудитом:
--
--   * `room_members.notifications_muted` виден ВСЕМ участникам комнаты, а
--     doc-комментарий в `rooms_repository.dart` обещал обратное («muting a
--     room is invisible to everyone else in it»). Комментарий исправлен,
--     схема — нет: закрыть это значит снять табличный SELECT-грант и выдать
--     его поколоночно, а `room_members` лежит в публикации realtime, через
--     которую ходят галочки «доставлено/прочитано». Поведение realtime при
--     поколоночных грантах проверяется только живым клиентом, и ломать
--     работающие галочки ради того, что сосед по комнате может узнать про
--     mute, — плохая сделка. Полный план — «Комнаты» в docs/data-model.md.
--
--   * три backstop-триггера лимитов (`enforce_post_media_limit`,
--     `enforce_profile_photos_limit`, `enforce_device_token_limit`) —
--     `security invoker`, то есть их `count(*)` проходит через RLS. У
--     скрытого модерацией поста автор своих же `post_media` не видит, и
--     count читается нулём. Практических последствий нет: оба пути записи
--     в `post_media` ограничены и без триггера (RPC режет `p_items` по 20,
--     а прямой INSERT на скрытый пост отбивает сама INSERT-политика — её
--     подзапрос к `posts` тоже под RLS). Менять роль триггера ради этого
--     дороже, чем записать наблюдение.
--
--   * `public.rls_auto_enable()` держит EXECUTE у PUBLIC. Это функция
--     ПЛАТФОРМЫ (её нет ни в одной нашей миграции, включая baseline),
--     возвращает `event_trigger` — PostgREST такой тип не публикует, а
--     вызвать её вне контекста event trigger нельзя. Чужую функцию не
--     трогаем.
-- =====================================================================


-- =====================================================================
-- 1. PUBLIC — это третий грантополучатель, и его никто не отзывал
-- =====================================================================
-- `create function` в PostgreSQL по умолчанию выдаёт EXECUTE роли **PUBLIC**,
-- а PUBLIC включает и `anon`, и `authenticated`. Поэтому:
--
--   revoke execute on function f() from anon, authenticated;   -- НЕ закрывает
--   revoke execute on function f() from public;                --    закрывает
--
-- 20260913100000 (тринадцатый аудит) закрывала шесть своих функций первой
-- формой. Baseline пишет правильную (`from public, anon, authenticated`) —
-- значит это не незнание, а пропущенное слово в одной миграции, и заметить
-- его нечем: `revoke` от роли, у которой права и не было, проходит молча и
-- без единого NOTICE.
--
-- Та же ошибка на уровень выше, и она объясняет, почему это не поймали:
-- baseline снимает у `anon` ДЕФОЛТНЫЕ привилегии
-- (`alter default privileges ... revoke all on functions from anon`) и
-- комментарием заявляет, что «дефолтный EXECUTE делал бы каждую новую функцию
-- анонимно вызываемой PostgREST-ручкой» — закрыто. Но дефолт на функции
-- выдаётся не `anon`, а PUBLIC, и эта строка его не касается. То есть КАЖДАЯ
-- функция, созданная после baseline, публиковалась анониму, если её явно не
-- закрыли словом `public`.
--
-- Что было открыто в живой базе на момент аудита (проверено запросом
-- публичным ключом приложения, без сессии, — HTTP 200 на оба):
--
--   is_write_banned(uuid)             — security definer, мимо RLS. Отвечает
--                                       про ЛЮБОЙ аккаунт по его uuid:
--                                       «ограничена ли этому человеку
--                                        запись». Решение модерации, которое
--                                       наружу не должно уходить вообще, а
--                                       уходило кому угодно в интернете.
--   room_message_media_visible(text)  — security definer, и в её теле НЕТ ни
--                                       одной проверки вызывающего: она
--                                       отвечает «существует ли такой путь
--                                       живым вложением в этой комнате».
--                                       Внутри storage-политики это верно
--                                       (членство проверено ветвью выше), как
--                                       отдельная ручка — оракул
--                                       существования по чужому чату.
--                                       Угадать путь из трёх uuid нельзя,
--                                       поэтому это не утечка переписки, но
--                                       анониму она не нужна.
--   room_message_visible(uuid)        — про вызывающего, и анониму честно
--                                       отвечает false. Открытой быть всё
--                                       равно не должна.
--   can_report(text, uuid)            — задумана для `authenticated`
--                                       (`revoke ... from anon` + `grant ...
--                                       to authenticated`). Первая половина
--                                       не сработала; анониму бесполезна
--                                       (всё через auth.uid()), но список
--                                       ручек должен совпадать с замыслом.
--
-- Триггерные функции здесь же, за компанию: PostgREST тип `trigger` не
-- публикует и Postgres запрещает звать их напрямую, так что грант на них
-- ничего не открывает. Но пока он есть, инвентарь «что опубликовано» нельзя
-- прочитать глазами — а именно это и подвело выше.
-- ВАЖНО, и это чуть не стало регрессией: выражение политики исполняется от
-- ВЫЗЫВАЮЩЕЙ роли, а не от владельца, поэтому каждая функция, названная прямо
-- в политике, обязана иметь EXECUTE у `authenticated` — иначе политика
-- отбивается 42501 и фича встаёт целиком. Вложенные вызовы внутри
-- `security definer`-функции это правило не затрагивает: они уже идут от
-- владельца.
--
-- `room_message_media_visible(text)` стоит в SELECT-политике
-- `storage.objects` на `messages/` и до сих пор работала ИМЕННО за счёт
-- гранта PUBLIC. Снять его совсем — значит выключить все вложения в чатах у
-- всех. Поэтому она закрывается от анонима и переоткрывается
-- `authenticated`, ровно как `post_media_path_visible()` рядом с ней. Оракул
-- существования при этом остаётся у залогиненного — цена того, что политика
-- зовёт функцию напрямую; путь из трёх uuid не угадывается, и точно так же
-- устроен уже существующий `post_media_path_visible()`.
--
-- `can_report(text, uuid)` — по той же причине: она в CHECK-политике
-- `content_reports`.
--
-- `room_message_visible(uuid)` и `is_write_banned(uuid)` в политиках не
-- участвуют (проверено по `pg_policies`, см. блок проверок ниже), поэтому
-- закрываются насовсем. Первая зовётся только из `can_report()` — то есть
-- изнутри `security definer`, где грант не нужен; у второй живых вызовов нет
-- вообще.
revoke execute on function public.is_write_banned(uuid) from public, anon, authenticated;
revoke execute on function public.room_message_visible(uuid) from public, anon, authenticated;

revoke execute on function public.room_message_media_visible(text) from public, anon, authenticated;
grant execute on function public.room_message_media_visible(text) to authenticated;

revoke execute on function public.can_report(text, uuid) from public, anon, authenticated;
grant execute on function public.can_report(text, uuid) to authenticated;

revoke execute on function public.claim_device_token() from public, anon, authenticated;
revoke execute on function public.enforce_comment_reply_rules() from public, anon, authenticated;
revoke execute on function public.enforce_device_token_limit() from public, anon, authenticated;
revoke execute on function public.enforce_post_media_limit() from public, anon, authenticated;
revoke execute on function public.enforce_profile_photos_limit() from public, anon, authenticated;
revoke execute on function public.enqueue_comment_notifications() from public, anon, authenticated;
revoke execute on function public.enqueue_post_notifications() from public, anon, authenticated;
revoke execute on function public.enqueue_room_message_notifications() from public, anon, authenticated;
revoke execute on function public.fill_content_report_target() from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.pin_device_token_timestamps() from public, anon, authenticated;
revoke execute on function public.pin_push_registration_timestamp() from public, anon, authenticated;
revoke execute on function public.pin_reaction_identity() from public, anon, authenticated;
revoke execute on function public.reject_write_when_banned() from public, anon, authenticated;
revoke execute on function public.sync_avatar_path_from_profile_photos() from public, anon, authenticated;

-- И то же на будущее, иначе следующая созданная функция снова окажется
-- опубликованной — ровно так этот пункт и появился.
--
-- Дефолт снимается у PUBLIC (то, чего не хватало) и у `authenticated`.
-- Второе — не перестраховка, а запись политики проекта в самой базе: «каждая
-- функция в `public` закрыта, `authenticated` открывается та, у которой
-- каждый аргумент про самого вызывающего». Раньше это держалось на том, что
-- автор миграции не забудет `revoke`; теперь забытый `grant` ломает фичу
-- громко (42501 на первом же вызове), а забытый `revoke` больше ничего не
-- открывает. Громкий отказ дешевле тихой публикации.
--
-- `service_role` не затрагивается: у него свой грант из дефолтных привилегий
-- Supabase, и консоль с cron ходят именно им.
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from authenticated;


-- =====================================================================
-- 2. Запрет писать распространяется на правку, а не только на создание
-- =====================================================================
-- 20260913100000 навесила `reject_write_when_banned` семью триггерами, и все
-- семь — BEFORE INSERT. Рассуждение тогда было «писать» = «создавать строку»,
-- и для шести таблиц из семи оно верное: комментарий и сообщение в комнате
-- редактировать нельзя вовсе (UPDATE-гранта нет), реакция переписывается
-- только в `type` (`pin_reaction_identity`), фото профиля и invite-ссылка
-- правок не знают.
--
-- Мимо прошли два UPDATE, и оба доступны прямым PATCH через PostgREST:
--
--   posts: грант `update (text)` + политика `author_id = auth.uid()`;
--   users: грант `update (name)` + политика `auth.uid() = id`.
--
-- То есть забанённый за текст поста мог этот же текст переписать на любой
-- другой, а заодно назваться как угодно — имя видно всем его Connections и
-- во всех его комнатах. Запрет писать, который не мешает переписывать, — это
-- не запрет, а задержка.
--
-- Триггеры поколоночные (`update of ...`) намеренно, и это не оптимизация:
--
--   * `posts`: консоль скрывает и возвращает пост через `update (hidden_at)`,
--     а `hidden_at` в список не входит — то есть модерация не начинает
--     спорить сама с собой на авторе, которого сама же и забанила. Правка
--     новостного поста консолью (`update (text)` от service_role) проходит
--     по пункту 3 ниже: `auth.uid()` там NULL, и функция выходит сразу;
--   * `users`: `sync_avatar_path_from_profile_photos()` пишет `avatar_path`
--     на каждое добавление и УДАЛЕНИЕ фотографии. Полный BEFORE UPDATE
--     отбивал бы это, то есть забанённый не смог бы удалить собственную
--     фотографию. Удаление своего — не запись, и запрещать его не за что.
--     Консольные `update (write_banned_until)` не проходят по той же
--     причине.
--
-- `visibility` поста отдельно не упомянут: сменить её можно только через
-- `update_post_with_media()`, а он всегда пишет и `text`, то есть попадает
-- под `update of text`. Прямого гранта на колонку нет.
--
-- Чего этот пункт НЕ закрывает и почему: `rename_room()` и
-- `set_room_avatar()` — тоже UPDATE, и забанённый владелец комнаты ими
-- по-прежнему пользуется. Триггер тут не помогает: у `rooms` нет колонки
-- автора вовсе (владелец — это наименьший `seq` в `room_members`), то есть
-- общее тело функции его не найдёт, а отдельная копия правила — это ровно
-- тот путь, которым «правило видимости жило в четырёх копиях». Название
-- комнаты видно только её участникам, то есть кругу, который забанённый уже
-- собрал сам; вложение этого не стоит.
--
-- Имя триггера другое (`..._on_update`), потому что на `posts` уже висит
-- `reject_write_when_banned` — имена триггеров уникальны в пределах таблицы.


-- =====================================================================
-- 3. `auth.uid()` бывает NULL, и `<>` с ним даёт NULL, а не true
-- =====================================================================
-- Ветка «не наше дело, строку пишет сервер» была написана как
-- `v_author is null or v_author <> auth.uid()`. При серверной записи
-- `auth.uid()` — NULL, второе сравнение даёт NULL, всё условие — NULL, IF не
-- срабатывает, и функция идёт проверять `write_banned_until` автора чужой
-- строки. Единственное, что держит это сегодня, — что так пишет только
-- системный аккаунт (новостные посты из консоли), а он не забанен.
--
-- Без этой правки пункт 2 стал бы поломкой: `update of text` на `posts`
-- ловит и правку новостного поста консолью, и она бы пошла спрашивать бан
-- системного аккаунта.
--
-- `is distinct from` верно в обе стороны сразу: NULL слева (автор не назван),
-- NULL справа (пишет сервер), и обычное сравнение, когда оба известны.
--
-- Сигнатура та же, поэтому `create or replace`, а не drop+create.
create or replace function public.reject_write_when_banned()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
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

revoke execute on function public.reject_write_when_banned() from public, anon, authenticated;

drop trigger if exists reject_write_when_banned_on_update on public.posts;
create trigger reject_write_when_banned_on_update
  before update of text on public.posts
  for each row execute function public.reject_write_when_banned();

drop trigger if exists reject_write_when_banned_on_update on public.users;
create trigger reject_write_when_banned_on_update
  before update of name on public.users
  for each row execute function public.reject_write_when_banned();


-- =====================================================================
-- 4. `pg_temp` последним в search_path
-- =====================================================================
-- Временная схема ищется ПЕРВОЙ, даже раньше `pg_catalog`, если её не
-- назвать в `search_path` явно, — и ищется она для имён таблиц и вьюх.
-- Значит внутри `security definer`-функции ссылка на `users` может быть
-- уведена на `pg_temp.users`, а тело в этот момент исполняется с правами
-- владельца.
--
-- Дыры сегодня нет, и это важно не преувеличить: чтобы завести временную
-- таблицу, нужно послать `create temp table`, а `authenticated` ходит только
-- через PostgREST, который произвольный SQL не принимает. Поэтому это
-- эшелонирование, а не закрытая дыра: цена — одна строчка метаданных на
-- функцию, а выигрыш появляется в тот день, когда кто-нибудь заведёт функцию
-- с динамическим SQL.
--
-- Что НЕ трогается и почему: `room_message_media_ok()` и
-- `system_account_ids()` — единственные функции без `search_path` вообще,
-- которые написаны на SQL и потому ИНЛАЙНЯТСЯ планировщиком. Любой `SET` в
-- определении инлайн отключает, а первая стоит в CHECK-ограничении
-- `room_messages` (каждая отправка сообщения), вторая — внутри
-- `is_system_account()`, то есть внутри политик. Ни одна из них не читает
-- таблиц, так что `pg_temp` им и не нужен. Шесть plpgsql-триггеров без
-- `search_path` инлайну не подлежат в принципе, поэтому им он дописывается.
do $$
declare
  fn record;
  v_path text;
  v_touched int := 0;
begin
  for fn in
    select p.oid::regprocedure::text as sig,
           coalesce(
             (select c from unnest(p.proconfig) c where c like 'search\_path=%'),
             ''
           ) as cfg
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       -- Платформенная функция, не наша (см. шапку).
       and p.proname <> 'rls_auto_enable'
       -- Инлайнящиеся SQL-функции без search_path — см. абзац выше.
       and not (
         p.proconfig is null
         and p.prolang = (select oid from pg_language where lanname = 'sql')
       )
  loop
    v_path := nullif(split_part(fn.cfg, '=', 2), '');

    if v_path is null then
      execute format(
        'alter function %s set search_path to %L, %L', fn.sig, 'public', 'pg_temp');
      v_touched := v_touched + 1;
    elsif v_path not like '%pg_temp%' then
      -- Существующий список сохраняется слово в слово и pg_temp дописывается
      -- в КОНЕЦ: порядок здесь и есть вся защита.
      execute format(
        'alter function %s set search_path to %s, %L', fn.sig, v_path, 'pg_temp');
      v_touched := v_touched + 1;
    end if;
  end loop;

  raise notice 'search_path: pg_temp прибит у % функций', v_touched;
end;
$$;


-- =====================================================================
-- 5. `reaction_summary()` — STABLE, а не VOLATILE
-- =====================================================================
-- Функция только читает (`posts`, `reactions`, `is_post_visible()`), но
-- помечена VOLATILE, то есть планировщик обязан считать, что она меняет базу:
-- её нельзя вычислить один раз на запрос и нельзя выполнить в read-only
-- транзакции. Зовётся она на каждую страницу ленты сразу после самой
-- страницы (`fetchPage`), так что метка просто неверна.
--
-- `alter function`, а не `create or replace`: менять надо флаг, а тело
-- переписывать незачем — и каждое лишнее переписывание тела это шанс
-- накатить устаревший текст (те же «Грабли»).
alter function public.reaction_summary(uuid[]) stable;


-- =====================================================================
-- Проверки после наката
-- =====================================================================
-- Проверяется `prosrc` и сам каталог, а не «применилось ли»: накат из
-- устаревшего текста проходит молча (см. «Грабли» в AGENTS.md).
do $$
declare
  v_src text;
  v_bad text;
  v_sig text;
begin
  -- 1. Ни одной не-триггерной функции, достижимой анонимом. Проверяется
  --    через has_function_privilege, а не через чтение proacl: именно
  --    чтение proacl глазами и пропустило `=X/` (это и есть PUBLIC).
  select string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ', ')
    into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname <> 'rls_auto_enable'
     and has_function_privilege('anon', p.oid, 'execute');
  if v_bad is not null then
    raise exception 'anon всё ещё может звать: %', v_bad;
  end if;

  -- И ни одной триггерной, достижимой authenticated.
  select string_agg(p.proname, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and pg_get_function_result(p.oid) = 'trigger'
     and has_function_privilege('authenticated', p.oid, 'execute');
  if v_bad is not null then
    raise exception 'триггерные функции всё ещё открыты authenticated: %', v_bad;
  end if;

  -- Каждая функция, названная ПРЯМО в выражении политики, обязана сохранить
  -- EXECUTE у `authenticated`: политика исполняется от вызывающей роли.
  -- Проверка общая, а не списком поимённо, потому что именно эта связь и
  -- чуть не сломала вложения в чатах: `room_message_media_visible()` стоит в
  -- storage-политике, а грант держался на PUBLIC. Список берётся из
  -- `pg_policies`, так что следующая политика попадёт под проверку сама.
  select string_agg(distinct f.proname, ', ') into v_bad
    from pg_proc f
    join pg_namespace fn on fn.oid = f.pronamespace
    join (
      select coalesce(qual, '') || ' ' || coalesce(with_check, '') as expr
        from pg_policies where schemaname in ('public', 'storage')
    ) pol on pol.expr ~ ('(^|[^a-z_])' || f.proname || '\s*\(')
   where fn.nspname = 'public'
     and not has_function_privilege('authenticated', f.oid, 'execute');
  if v_bad is not null then
    raise exception 'функции из выражений политик остались без гранта: %', v_bad;
  end if;

  -- Дефолт на будущее снят у обоих.
  if exists (
    select 1 from pg_default_acl d
     where d.defaclnamespace = 'public'::regnamespace
       and d.defaclobjtype = 'f'
       and d.defaclacl::text ~ '[{,]=X/'
  ) then
    raise exception 'дефолтный EXECUTE для PUBLIC на функции всё ещё выдаётся';
  end if;

  -- 2 и 3. Функция бана.
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'reject_write_when_banned') <> 1 then
    raise exception 'reject_write_when_banned() размножилась перегрузками';
  end if;

  select prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'reject_write_when_banned';

  if v_src not ilike '%is distinct from auth.uid()%' then
    raise exception 'reject_write_when_banned() всё ещё сравнивает автора через <>';
  end if;
  if v_src not ilike '%AMB01%' then
    raise exception 'reject_write_when_banned() потеряла свой SQLSTATE';
  end if;
  if v_src not ilike '%tg_table_name = ''users''%' then
    raise exception 'reject_write_when_banned() снова не находит автора в users';
  end if;

  -- Семь триггеров на вставку из 20260913100000 должны остаться на месте:
  -- `create or replace` их не трогает, но проверить дешевле, чем узнать от
  -- модератора, что бан перестал действовать на новые посты.
  if (select count(*) from pg_trigger t
       where t.tgname = 'reject_write_when_banned' and not t.tgisinternal) <> 7 then
    raise exception 'триггеров бана на вставку стало не 7';
  end if;

  -- Триггеры на правку: и что они есть, и что они поколоночные. Без второй
  -- половины проверка пропустит полный BEFORE UPDATE, который запретил бы
  -- забанённому удалять свои же фотографии. Читается через
  -- `pg_get_triggerdef`, а не разбором `tgattr`: тот int2vector, и сравнение
  -- с ним — лишний способ ошибиться в самой проверке.
  select pg_get_triggerdef(t.oid) into v_src
    from pg_trigger t
   where t.tgrelid = 'public.posts'::regclass
     and t.tgname = 'reject_write_when_banned_on_update';
  if v_src is null then
    raise exception 'на posts нет триггера бана на правку';
  end if;
  if v_src !~* 'before update of text on' then
    raise exception 'триггер бана на posts не поколоночный по text: %', v_src;
  end if;

  select pg_get_triggerdef(t.oid) into v_src
    from pg_trigger t
   where t.tgrelid = 'public.users'::regclass
     and t.tgname = 'reject_write_when_banned_on_update';
  if v_src is null then
    raise exception 'на users нет триггера бана на правку';
  end if;
  -- `avatar_path` в списке колонок (или отсутствие списка вовсе) означал бы,
  -- что удаление своей фотографии у забанённого больше не проходит:
  -- `sync_avatar_path_from_profile_photos()` пишет именно эту колонку.
  if v_src !~* 'before update of name on' or v_src ~* 'avatar_path' then
    raise exception 'триггер бана на users ловит не только name: %', v_src;
  end if;

  -- 4. pg_temp.
  select string_agg(p.proname, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname not in ('rls_auto_enable', 'room_message_media_ok', 'system_account_ids')
     and coalesce(array_to_string(p.proconfig, ' '), '') not like '%pg_temp%';
  if v_bad is not null then
    raise exception 'без pg_temp в search_path остались: %', v_bad;
  end if;

  -- Порядок, а не только наличие: pg_temp обязан быть ПОСЛЕДНИМ.
  select string_agg(p.proname, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and coalesce(array_to_string(p.proconfig, ' '), '') like '%pg_temp%'
     and array_to_string(p.proconfig, ' ') !~ 'pg_temp\s*$';
  if v_bad is not null then
    raise exception 'pg_temp стоит не последним у: %', v_bad;
  end if;

  -- 5. Волатильность.
  if (select provolatile from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'reaction_summary') <> 's' then
    raise exception 'reaction_summary() не стала STABLE';
  end if;

  -- Контрольные числа: всё, что клиент зовёт на каждом экране. Пункт 1
  -- снимает дефолтный грант, поэтому проверка «не потеряли ли лишнего»
  -- важнее обычного — без неё приложение встанет целиком.
  foreach v_sig in array array[
    'public.my_rooms()',
    'public.my_room_ids()',
    'public.visible_author_ids()',
    'public.authors_who_favorited_me()',
    'public.comment_summary(uuid[])',
    'public.reaction_summary(uuid[])',
    'public.system_account_ids()',
    'public.create_post_with_media(uuid, text, jsonb, text)',
    'public.update_post_with_media(uuid, text, jsonb, text)',
    'public.mark_room_read(uuid)',
    'public.mark_rooms_delivered()',
    'public.set_room_muted(uuid, boolean)',
    'public.activate_invite_link(text)',
    'public.create_invite_link()',
    'public.rotate_invite_link()',
    'public.request_connection(uuid)',
    'public.respond_to_connection_request(uuid, boolean)',
    'public.can_report(text, uuid)',
    'public.delete_own_account()',
    'public.delete_own_comment(uuid)',
    'public.delete_own_room_message(uuid)',
    'public.touch_user_activity()',
    'public.append_profile_photos(jsonb)',
    'public.reorder_profile_photos(uuid[])',
    'public.add_room_member(uuid, uuid)',
    'public.remove_room_member(uuid, uuid)',
    'public.rename_room(uuid, text)',
    'public.set_room_avatar(uuid, text)',
    'public.leave_room(uuid)',
    'public.create_room(uuid[], text)'
  ] loop
    -- has_function_privilege() бросает 42883 на несуществующую сигнатуру, то
    -- есть опечатка в списке выше не пройдёт молча, а уронит накат.
    if not has_function_privilege('authenticated', v_sig, 'execute') then
      raise exception '% потеряла грант', v_sig;
    end if;
  end loop;
end;
$$;
