-- =====================================================================
-- Отдельный вид уведомления для важного обновления.
--
-- Обычный `app_update` написан нейтрально («вышла новая версия») и таким и
-- должен остаться: он уходит на каждую выкладку, которую стоит отметить, и
-- если сделать его настойчивым, настойчивость перестанет что-либо значить
-- к третьему разу.
--
-- 0.17.0 — тот случай, когда обновиться действительно надо: клиент build 43
-- и старше не знает про комнаты и не фильтрует `posts.in_general_feed`, то
-- есть показывает пост, адресованный ТОЛЬКО в комнату, ещё и в общей ленте.
-- Данные при этом не текут (RLS пускает к нему лишь участников комнаты), но
-- человек видит его не там, где автор его положил.
--
-- Поэтому не переписываем текст `app_update`, а заводим второй вид рядом.
-- Тексты живут в Edge Function, и это ВСЕГДА две правки: `kind` здесь и
-- `TEXTS` там — иначе строка в очереди молча пропускается (см. комментарий
-- над `pickText` в send-push и «Что остаётся руками» в operations.md).
-- =====================================================================

alter table public.notification_outbox drop constraint notification_outbox_kind_check;
alter table public.notification_outbox add constraint notification_outbox_kind_check
  CHECK ((kind = ANY (ARRAY['new_post'::text, 'inactive_week'::text, 'digest'::text,
                            'post_comment'::text, 'comment_reply'::text, 'app_update'::text,
                            'room_message'::text, 'room_post'::text,
                            'app_update_important'::text])));

-- Сигнатура меняется, поэтому дроп перед созданием. По PostgREST она не
-- ходит (гранта нет ни у `anon`, ни у `authenticated` — её зовёт человек
-- через Management API), так что неоднозначности перегрузок здесь не
-- случилось бы, но правило одно на все функции проекта.
drop function if exists public.enqueue_app_update_notifications(integer, text);

CREATE OR REPLACE FUNCTION public.enqueue_app_update_notifications(p_min_build integer, p_version text DEFAULT NULL::text, p_important boolean DEFAULT false)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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

revoke execute on function public.enqueue_app_update_notifications(p_min_build integer, p_version text, p_important boolean) from public, anon, authenticated;

do $$
begin
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'enqueue_app_update_notifications') <> 1 then
    raise exception 'enqueue_app_update_notifications() размножилась перегрузками';
  end if;

  if has_function_privilege('authenticated',
       'public.enqueue_app_update_notifications(integer, text, boolean)', 'execute') then
    raise exception 'enqueue_app_update_notifications() выдана клиенту';
  end if;
end;
$$;
