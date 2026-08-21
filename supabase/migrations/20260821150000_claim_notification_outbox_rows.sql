-- Дренаж очереди уведомлений начинает ЗАБИРАТЬ строки, а не просто читать их.
--
-- Как было. send-push выбирал `where sent_at is null … limit 200`, слал пуши
-- последовательно и проставлял `sent_at` одним апдейтом ПОСЛЕ всего цикла.
-- Ничего строки не помечало на время работы. Cron при этом ходит раз в минуту
-- (20260818200000), а `net.http_post` — fire-and-forget, то есть pg_cron не
-- ждёт завершения предыдущего вызова.
--
-- Арифметика, из-за которой это не теория: 200 строк × ~2 устройства × ~400 мс
-- на последовательный запрос в FCM ≈ 160 секунд. На 60-й секунде стартует
-- второй прогон, видит те же 200 строк с пустым `sent_at` и шлёт всё заново;
-- на 120-й подключается третий. Каждый получатель получает один и тот же пуш
-- 2–3 раза, и чем сильнее наложение, тем медленнее батчи — окно расширяется,
-- а не схлопывается. Комментарий в самой функции при этом прямо говорит, что
-- дубликат хуже потери («One duplicate push is worse than one dropped one»).
--
-- Починка — одна колонка и одна функция. `claimed_at` помечает строки взятыми
-- в работу, `for update skip locked` разводит одновременные прогоны по разным
-- строкам без ожидания на блокировках, а окно в 5 минут возвращает в оборот
-- строки прогона, который упал или был убит по таймауту, не дойдя до
-- проставления `sent_at`.
--
-- Семантику «best-effort, без очереди ретраев» это не меняет: строка,
-- по которой попытка была, по-прежнему помечается отправленной независимо от
-- результата доставки. Claim нужен ровно для того, чтобы попытка была одна.
--
-- Функция вызывается только Edge Function'ом под service_role. Ни `anon`, ни
-- `authenticated` её не получают: очередь целиком внутренняя (см. комментарий
-- к таблице в 20260818190000), а аргумент здесь вообще не про вызывающего.

alter table public.notification_outbox
  add column claimed_at timestamptz;

-- Частичный индекс из 20260818190000 покрывает `sent_at is null` и порядок по
-- created_at — то, что нужно подзапросу ниже. Отдельный индекс под claimed_at
-- не заводится: строк в окне мало, и предикат уже сужен тем же частичным
-- индексом.

create or replace function public.claim_notification_outbox(p_limit int)
returns table (id uuid, user_id uuid, kind text, payload jsonb)
language sql
security definer
set search_path = public
as $$
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
$$;

revoke execute on function public.claim_notification_outbox(int) from public, anon, authenticated;
grant execute on function public.claim_notification_outbox(int) to service_role;
