-- =====================================================================
-- Отдельный вид уведомления для отклонённой жалобы.
--
-- Правка по следам 20260913100000. Там завелись два статуса разбора,
-- `resolved` и `rejected`, но уведомление жалобщику уходило ОДНО на оба:
-- «Ваша жалоба рассмотрена». То есть человек, чью жалобу признали
-- беспочвенной, и человек, по чьей жалобе убрали пост, получали ровно один
-- текст и не могли отличить один исход от другого. Два статуса, у которых
-- нет разных последствий, — это не два статуса, а лишняя кнопка в консоли;
-- различать их стоит там, где различие кому-то видно.
--
-- Список видов взят из `pg_constraint` живой базы (двенадцать на момент
-- правки), а не собран по миграциям: ограничение пересоздаётся `drop`+`add`,
-- и любой невыписанный вид исчезает молча — в прошлый раз так едва не
-- потерялся `connection_accepted`.
--
-- Вторая половина правки — тексты в `supabase/functions/send-push/index.ts`.
-- Без неё строка этого вида не откладывается, а ПОГЛОЩАЕТСЯ: drain забирает
-- её, не находит текста, пропускает — и всё равно ставит `sent_at`, иначе
-- перевыбирал бы вечно. В очереди она будет выглядеть отправленной.
-- Выкладывать функцию руками: `supabase functions deploy send-push`.
-- =====================================================================

alter table public.notification_outbox drop constraint notification_outbox_kind_check;
alter table public.notification_outbox add constraint notification_outbox_kind_check
  CHECK ((kind = ANY (ARRAY['new_post'::text, 'inactive_week'::text, 'digest'::text,
    'post_comment'::text, 'comment_reply'::text, 'app_update'::text,
    'app_update_important'::text, 'room_message'::text, 'connection_request'::text,
    'connection_accepted'::text, 'moderation_notice'::text, 'report_resolved'::text,
    'report_rejected'::text])));
