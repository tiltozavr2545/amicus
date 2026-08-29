-- =====================================================================
-- Mute — это фильтр ЛЕНТЫ, а не стена. Блокировка остаётся стеной.
--
-- Ложится поверх 20260829120000. Тела всех трёх пересоздаваемых ниже функций
-- взяты из `prosrc` живой схемы и совпадают с baseline построчно; меняется в
-- каждой ровно один конъюнкт (см. «`create or replace` переписывает ВСЁ
-- тело» в CLAUDE.md).
--
-- ЧТО БЫЛО. `is_author_visible()` — единственное правило видимости проекта —
-- считало замьюченного невидимым НАСОВСЕМ: «Connection, которого я не
-- замьютил и с которым нет блока». Поэтому mute убирал человека не только из
-- ленты, но и из его собственного профиля: тапаешь по аватарке знакомого,
-- открывается его страница — и она пустая, хотя он сам ничего не сделал, не
-- мутил и не блокировал. Пустой профиль читается как «у него нет постов» или
-- «он меня заблокировал», то есть врёт про другого человека из-за моей же
-- личной настройки.
--
-- ЧТО СТАЛО. Mute перестаёт участвовать в видимости и означает ровно две
-- вещи: **нет в общей ленте и нет пушей**. Всё остальное — профиль, посты в
-- нём, их медиа, комментарии, реакции — видно как у обычного Connection.
-- Блокировка не меняется ни в одном месте: она взаимна и она и есть стена.
--
-- ПОЧЕМУ MUTE УХОДИТ ИЗ RLS ЦЕЛИКОМ, А НЕ «ТОЛЬКО ДЛЯ ПРОФИЛЯ». RLS не знает
-- экрана: и лента, и профиль — это один и тот же `select from posts`,
-- отличается лишь клиентский `.eq('author_id', …)`. Выразить «в ленте скрыть,
-- в профиле показать» политикой нельзя в принципе, а завести для профиля
-- вторую копию правила видимости — ровно та ошибка, которую проект уже
-- совершал (четыре копии, две отстали от mute/block и стали дырами) и
-- которую CLAUDE.md запрещает отдельным пунктом. Поэтому правило остаётся
-- ОДНО и становится честнее, а «чего нет в ленте» переезжает туда, где
-- лента и живёт, — в её запрос.
--
-- Отсюда важное следствие, которое надо назвать вслух: **mute больше не
-- является границей приватности и не должен ею считаться.** Он и не был ею
-- по смыслу — это моя настройка про мою ленту, односторонняя, второй стороне
-- невидимая, — но раз теперь его исполняет клиентский фильтр, любой правленый
-- клиент может его не применять. Ничего чужого этим не открывается: замьюченный
-- и так остаётся Connection, чей профиль и аватарка были видны всегда
-- (`is_connected_to_caller()` в политике `users` про mute не спрашивает
-- никогда). Границей была и остаётся блокировка, и она целиком на сервере.
--
-- ЧТО НЕ МЕНЯЕТСЯ. `has_muted()` никуда не девается и остаётся в обеих
-- функциях уведомлений — `enqueue_post_notifications()` (ветвь избранного и
-- подсчёт дайджеста) и `enqueue_comment_notifications()`. Замьютить и
-- продолжать получать пуши было бы бессмыслицей, а эти проверки написаны
-- отдельно от правила видимости и всегда были независимы от него. Таблица
-- `muted_users`, её RLS и клиентские mute/unmute — без изменений.
-- =====================================================================


-- =====================================================================
-- 1. Правило видимости
-- =====================================================================
-- МЕНЯТЬ ТОЛЬКО ЗДЕСЬ (см. заголовок baseline над этой же функцией).
-- Уходит один конъюнкт — `not has_muted(...)`. Проверка блока остаётся на
-- месте и остаётся симметричной: `is_blocked_pair()` смотрит обе стороны, и
-- именно она не даёт заблокированному увидеть профиль заблокировавшего.
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
        and not public.is_blocked_pair(auth.uid(), p_author)
      );
$function$;

-- `visible_author_ids()` не трогаем: она спрашивает правило у
-- `is_author_visible()` и получает новое сама. Это и есть смысл «одного
-- места».


-- =====================================================================
-- 2. Две ветви «автору поста видно, кто под ним написал»
-- =====================================================================
-- Тот же конъюнкт и та же причина. Без этой правки вышло бы хуже, чем было:
-- комментарий замьюченного стал бы видимым (он проходит первой ветвью
-- политики `comments` через `visible_author_ids()`), а строка `users` с его
-- именем — нет, и под постом появилась бы подпись без автора.
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
  and not public.is_blocked_pair(auth.uid(), p_user_id);
$function$;


-- =====================================================================
-- 3. Проверки после наката
-- =====================================================================
do $$
declare
  v_src text;
  v_name text;
begin
  -- Ни одна из трёх больше не спрашивает про mute...
  for v_name in
    select unnest(array['is_author_visible',
                        'is_comment_visible_to_post_owner',
                        'is_commenter_visible_to_post_owner'])
  loop
    select prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_name;

    if v_src ilike '%has_muted%' then
      raise exception '%() всё ещё считает mute границей видимости', v_name;
    end if;
    -- ...и каждая по-прежнему спрашивает про блок. Это главная проверка
    -- миграции: потерять здесь блок значит открыть профиль автора тому, кого
    -- он заблокировал, — то есть повторить дыру 0.9.0 с другой стороны.
    if v_src not ilike '%is_blocked_pair%' then
      raise exception '%() потеряла проверку блокировки', v_name;
    end if;
  end loop;

  -- Правило видимости не пересоздано из огрызка: обе оставшиеся ветви на
  -- месте.
  select prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'is_author_visible';
  if v_src not ilike '%is_system_account%' or v_src not ilike '%are_connected%'
     or v_src not ilike '%auth.uid()%' then
    raise exception 'is_author_visible() пересоздана из неполного тела';
  end if;

  -- Mute не умер: обе функции уведомлений обязаны о нём знать, иначе
  -- замьюченный продолжит слать пуши.
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.prosrc ilike '%has_muted%') <> 2 then
    raise exception 'has_muted() ожидается ровно у двух функций уведомлений';
  end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'enqueue_post_notifications'
       and p.prosrc ilike '%has_muted%'
  ) then
    raise exception 'enqueue_post_notifications() перестала глушить пуши замьюченного';
  end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'enqueue_comment_notifications'
       and p.prosrc ilike '%has_muted%'
  ) then
    raise exception 'enqueue_comment_notifications() перестала глушить пуши замьюченного';
  end if;

  -- Таблица и её политика на месте: клиентский фильтр ленты читает именно её.
  if not exists (
    select 1 from pg_policy pol join pg_class c on c.oid = pol.polrelid
     where c.relname = 'muted_users'
  ) then
    raise exception 'политика muted_users пропала — клиент не прочитает свои мьюты';
  end if;
end;
$$;
