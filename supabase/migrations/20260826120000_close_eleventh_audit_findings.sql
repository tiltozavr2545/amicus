-- =====================================================================
-- Одиннадцатый полный аудит: серверная половина.
--
-- Ложится поверх 20260826000000_baseline_schema.sql. Тела всех четырёх
-- пересоздаваемых ниже функций СВЕРЕНЫ с живой схемой перед правкой и
-- совпали с baseline побайтово, так что источник для `create or replace`
-- здесь — сам baseline, а не память (см. «Грабли» в CLAUDE.md).
--
-- Шесть находок:
--   1. брошенная строка device_tokens уводила пуши прошлого владельца
--      устройства следующему аккаунту;
--   2. мёртвый грант публиковал /rpc/is_author_visible;
--   3. set_post_media() падала на дубликате пути, а парная ей
--      create_post_with_media() — нет;
--   4. reorder_profile_photos() пропускала массив с повторами;
--   5. create_invite_link() проигрывала гонку сама себе;
--   6. дайджест в enqueue_post_notifications() делал O(N) запросов внутри
--      транзакции вставки поста.
-- =====================================================================


-- =====================================================================
-- 1. Один аппарат — один аккаунт для пушей
-- =====================================================================
-- FCM-токен выдаётся УСТАНОВКЕ приложения, а не пользователю, и войти двумя
-- аккаунтами одновременно здесь нельзя. Значит строка с этим токеном под
-- другим `user_id` — всегда остаток от предыдущего владельца устройства.
--
-- Снимал её только `unregisterDevice()` на выходе, а он best-effort и
-- обёрнут в пустой catch: выход без сети (или уже провернувшаяся ротация
-- токена, из-за которой `getToken()` вернёт не ту строку, что регистрировали)
-- оставлял её навсегда. Следующий аккаунт на том же телефоне получал чужие
-- уведомления — имена комментаторов и дайджесты предыдущего пользователя.
-- Само это не чинилось ничем: send-push сносит токен только по ответу FCM
-- `UNREGISTERED`, а токен живой; повторной попытки снятия у клиента нет и
-- быть не может — после выхода сессии уже нет, а политика пускает только к
-- своим строкам.
--
-- Поэтому право на строку забирает тот, кто регистрируется последним, и
-- делает это сервер, не полагаясь на уходящего клиента.
--
-- `security definer` обязателен: строка чужая, а политика
-- «Users manage their own device tokens» пускает только к `user_id = auth.uid()`.
CREATE OR REPLACE FUNCTION public.claim_device_token()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  delete from public.device_tokens d
   where d.fcm_token = new.fcm_token
     and d.user_id <> new.user_id;
  return new;
end;
$function$;

-- Имя выбрано так, чтобы триггер срабатывал ПЕРЕД
-- `device_tokens_enforce_limit_before_insert`: BEFORE-триггеры строки
-- вызываются в алфавитном порядке имён, «claim» < «enforce». Порядок здесь
-- ни на что не влияет (лимит считает строки только этого пользователя), но
-- освободить токен до подсчёта — то, что читается правильно.
create or replace trigger device_tokens_claim_token_before_insert
  before insert on public.device_tokens
  for each row execute function public.claim_device_token();

-- Вторая половина того же инварианта. Грант на UPDATE выдан на ВСЮ таблицу
-- (клиентский апсерт шлёт в SET все колонки payload'а, поэтому поколоночный
-- грант уронил бы регистрацию пушей — 20260822130000), а политика проверяет
-- только `user_id`. Без пина ниже строку можно было перевести на чужой
-- `fcm_token` и увести пуши на чужое устройство, не нарушив ни одной
-- политики. `(user_id, fcm_token)` — первичный ключ, и UPDATE не должен его
-- двигать: ровно то же, что `pin_reaction_identity()` делает для реакций.
--
-- На легальном пути это no-op: апсерт клиента конфликтует именно по этой
-- паре, так что `excluded.user_id`/`excluded.fcm_token` равны старым.
--
-- Имя функции осталось прежним намеренно — переименование потребовало бы
-- дропнуть и пересоздать триггер ради строки в каталоге.
CREATE OR REPLACE FUNCTION public.pin_device_token_timestamps()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.user_id := old.user_id;
  new.fcm_token := old.fcm_token;
  new.created_at := old.created_at;
  new.updated_at := now();
  return new;
end;
$function$;

-- Триггерные функции PostgREST не публикует, поэтому грант на них ничего не
-- открывает — но у `anon` он снимается и здесь, чтобы дефолт из baseline и
-- живая схема не разъезжались.
revoke execute on function public.claim_device_token() from anon;


-- =====================================================================
-- 2. Мёртвый грант на is_author_visible()
-- =====================================================================
-- Каждая функция в `public` — эндпоинт PostgREST, и грант выдаётся только
-- тому, что кому-то нужно. Этому — не нужно никому: все четыре вызова
-- `is_author_visible()` (в `visible_author_ids()`,
-- `is_author_of_comment_visible()`, `is_comment_visible()` и
-- `reaction_summary()`) лежат внутри `security definer`-функций, то есть
-- исполняются от владельца, а ни в одной RLS-политике её нет — проверено
-- запросом к pg_policy на живой схеме, 0 совпадений.
--
-- Дырой грант не был: единственный аргумент — про самого вызывающего
-- («виден ли мне этот автор»), то же, что у выданной намеренно
-- `is_connected_to_caller()`. Но публиковать наружу ручку, которой никто не
-- пользуется, незачем.
revoke execute on function public.is_author_visible(p_author uuid) from authenticated;


-- =====================================================================
-- 3. set_post_media(): дубликат пути ронял правку поста
-- =====================================================================
-- Финальный INSERT шёл без `on conflict`, хотя парная ей
-- `create_post_with_media()` этот же уникальный ключ гасит `do nothing`. Две
-- функции, пишущие в одну таблицу по одному ключу, вели себя по-разному:
-- один и тот же `storage_path`, пришедший в `p_items` дважды, на публикации
-- отбрасывался молча, а на редактировании падал сырым 23505 по
-- `post_media_post_storage_path_key`. Клиент такой код не разбирает и
-- показывает общее «не удалось сохранить изменения», хотя достаточно было
-- отбросить повтор.
--
-- Вместе с `on conflict` приезжает `#variable_conflict use_column`, и это не
-- украшение: `returns table (storage_path text)` заводит OUT-параметр с этим
-- именем, а цель конфликта обязана быть голым ИМЕНЕМ КОЛОНКИ —
-- квалифицировать её нельзя синтаксически, а неквалифицированная натыкается
-- на переменную и падает с 42702 «column reference is ambiguous». Ровно то,
-- о чём предупреждал комментарий в `create_post_with_media()`: эта функция
-- жила без директивы только потому, что нигде не писала `storage_path` без
-- префикса таблицы. Теперь пишет.
CREATE OR REPLACE FUNCTION public.set_post_media(p_post_id uuid, p_items jsonb)
 RETURNS TABLE(storage_path text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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


-- =====================================================================
-- 4. reorder_profile_photos(): массив с повторами проходил проверку
-- =====================================================================
-- Проверка целостности набора сравнивала только ДЛИНЫ, а комментарий над
-- ней утверждал, что расхождение длин ловит любой некорректный набор. Не
-- ловило: для галереи {a, b} массив [a, a] даёт на join'е две строки (обе —
-- путь a), длины сходятся 2 = 2 = 2, PT422 не срабатывает. Дальше `delete`
-- сносил ОБЕ фотографии, а INSERT падал на
-- `profile_photos_user_storage_path_key` сырым 23505. Транзакция
-- откатывалась, данные оставались целы, но вместо внятного «набор не
-- совпадает с вашей галереей» человек получал общую ошибку, по которой
-- причину понять невозможно.
--
-- Повторы отсекаются отдельной проверкой ДО чтения таблицы: считать их
-- через тот же `array_length` нельзя, длина как раз и совпадает.
-- NULL-элементы отваливаются здесь же — `count(distinct)` их не считает.
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


-- =====================================================================
-- 5. create_invite_link(): гонка на частичном уникальном индексе
-- =====================================================================
-- Функция делала read-then-insert без блокировки, опираясь на
-- `invite_links_one_active_per_owner`, но конфликт по нему не обрабатывала.
-- Два одновременных вызова одного владельца — а это ровно тот ретрай после
-- таймаута, ради которого функция и сделана идемпотентной, потому что
-- `.timeout()` перестаёт ждать, не отменяя запрос, — оба не находили живого
-- кода, оба доходили до INSERT, и второй падал с 23505. Клиент этот код не
-- разбирает и показывает «непредвиденная ошибка», хотя код на самом деле
-- выпущен: идемпотентность не работала именно там, где нужна.
--
-- `on conflict (owner_id) where not is_used` — вывод по частичному индексу,
-- предикат обязателен. `row_count` под ним отличает «вставил я» от «успел
-- кто-то другой»: во втором случае идемпотентный ответ — ЕГО код, тот же
-- приём, что в `activate_invite_link()`.
CREATE OR REPLACE FUNCTION public.create_invite_link()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
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


-- =====================================================================
-- 6. Дайджест: O(N) запросов внутри транзакции вставки поста
-- =====================================================================
-- ВНИМАНИЕ. Это та самая функция, которую дважды пересоздавали из
-- дореформенного текста, и оба раза публиковать не мог никто, у кого есть
-- Connection без mute/block/избранного. Тело ниже взято из baseline, а
-- baseline перед этим сверен с живой схемой посимвольно. После наката
-- проверять не «применилось ли», а `prosrc` — и опубликовать пост.
--
-- Менялась ровно одна вещь: ветка дайджеста была циклом по всем Connection
-- автора, и на каждого выполнялся отдельный `count(*)` по posts × connections.
-- То есть O(N) агрегирующих запросов ВНУТРИ транзакции вставки поста, где
-- любая ошибка откатывает сам пост, а задержка публикации растёт линейно с
-- числом знакомых. Теперь это один `insert ... select`.
--
-- Смысл сохранён построчно, шаг в шаг с прежним циклом:
--   `continue when` из начала тела  → WHERE в CTE `eligible`;
--   окно и проверка «дайджест уже уходил» → CTE `eligible`/`fresh`;
--   подсчёт непрочитанного           → lateral;
--   `if v_unseen_count >= 7`         → WHERE финального SELECT.
--
-- `materialized` на CTE — не украшение, а закрепление порядка вычислений:
-- без него планировщик волен заинлайнить CTE и посчитать дорогой lateral
-- для КАЖДОГО знакомого, включая отсеянных, то есть ровно то, от чего эта
-- правка избавляется. `order by` сохраняет детерминированный порядок
-- вставок, который в цикле давал `order by viewer_id`.
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
-- 7. Пропускная способность уборщика бакета
-- =====================================================================
-- `orphaned_media_paths()` жёстко ограничена `limit 100`, а джоб ходил раз в
-- сутки — потолок 100 объектов в день. Композер при этом принимает 20 медиа
-- на пост, каждое видео до 100 МиБ, и заливка идёт ДО вставки строк, так что
-- один брошенный черновик оставляет за собой до 40 объектов; туда же
-- попадает всё, что не добил `create_post_with_media()` на ретрае, и вся
-- медиатека аккаунта, если чистка при удалении не прошла. Мусор мог
-- копиться быстрее, чем уборщик его выносит, и заметно это было бы только
-- по счёту за Storage.
--
-- Раз в час вместо раза в сутки: 2400 объектов в день тем же батчем в 100
-- штук, без роста размера HTTP-запроса к Storage. Сама функция не тронута —
-- `limit 100` заодно держит размер тела запроса предсказуемым, а
-- operations.md описывает её как способ посмотреть, что джоб собирается
-- снести.
--
-- `cron.schedule` идемпотентна по имени: это перезапись расписания, а не
-- второй джоб.
select cron.schedule('reap-orphaned-media', '45 * * * *', $$ select public.reap_orphaned_media(); $$);
