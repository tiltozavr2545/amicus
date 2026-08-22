-- Уведомление об обновлении — только тем, кто действительно отстал.
--
-- Наконец даёт отправителя kind'у 'app_update', который с 20260820190000
-- существует без него. И даёт его в той форме, ради которой всё затевалось:
-- не «всем подряд после релиза», а «тем, у кого версия старее указанной».
--
-- КОГО СЧИТАЕМ ОТСТАВШИМ. Решение принимается по МАКСИМУМУ `app_build` среди
-- устройств пользователя, а не по каждому устройству отдельно. Причина
-- механическая: `notification_outbox` адресуется пользователю, а send-push
-- веером рассылает на все его токены — адресовать одно устройство очередь не
-- умеет. Причина смысловая важнее: если человек обновился на телефоне, а
-- планшет год лежит в ящике, он про обновление уже знает, и напоминать ему
-- нечего. Максимум и выражает «самая свежая установка этого человека».
--
-- NULL — это «старее всего». Строки, записанные до 20260822110000, и любой
-- клиент, не приславший версию, приходят с NULL, и `coalesce(max(...), 0)`
-- превращает их в отставших. Это верно по существу: приложение, не умеющее
-- сообщить свою версию, заведомо старее того, которое умеет.
--
-- Пользователи без единого device_token пропускаются: слать пуш некуда, а
-- строка в очереди для них — мусор, который дренаж всё равно пометит
-- отправленной, ничего не отправив.
--
-- ПОВТОРНЫЙ ЗАПУСК БЕЗОПАСЕН. Дедупликация идёт по `payload->>'build'`: за
-- одну и ту же целевую сборку человек получит уведомление ровно один раз,
-- сколько бы раз функцию ни позвали. Это сознательно жёстче, чем окно по
-- времени: «обновись до 38» дважды — это спам, даже если между вызовами
-- прошла неделя. Следующий релиз придёт с другим build и разбудит рассылку
-- заново сам.
--
-- Настройка `notify_system_account` (в интерфейсе — «оповещения об
-- обновлениях приложения», 20260820170000) уважается, отсутствие строки
-- читается как согласие — как и во всех остальных отправителях.
--
-- Никому не выдана: функция рассылает уведомления всем подряд и её аргумент
-- не про вызывающего. Вызывает её человек после выкладки релиза — тем же
-- Management API, которым применяются миграции:
--   select public.enqueue_app_update_notifications(38, '0.16.4');

create or replace function public.enqueue_app_update_notifications(
  p_min_build int,
  p_version text default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
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
$$;

revoke execute on function public.enqueue_app_update_notifications(int, text)
  from public, anon, authenticated;
