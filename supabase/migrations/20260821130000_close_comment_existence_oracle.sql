-- is_author_of_comment_visible() отвечал тремя значениями вместо двух и этим
-- работал оракулом существования строки.
--
-- Внутренний `select author_id from comments where id = p_comment_id` идёт под
-- `security definer`, то есть без фильтрации политикой comments. Дальше:
--   * комментарий есть, автор скрыт  -> is_author_visible(<uuid>) = false
--   * комментария нет вовсе          -> is_author_visible(null)   = null
-- PostgREST отдаёт это как `false` и `null` — различимо. Функция выдана
-- `authenticated` (20260726140000:46), значит это обычный HTTP-эндпоинт.
--
-- Воспроизведено симуляцией до правки: для зрителя, которому автор
-- комментария не виден, вызов на живой id вернул false, на
-- '00000000-0000-0000-0000-000000000000' — null. То есть заблокированный,
-- сохранивший id чужого комментария, мог опросом отличать «строка ещё жива» от
-- «строку удалили», хотя RLS обязана скрывать её целиком. Ровно тот же класс
-- оракула уже закрывался трижды — для posts.id (20260818130000),
-- comments.id и reactions.id/post_id (20260819130000, 20260819150000).
--
-- Починка — свести ответ к строгому boolean. Для политик это ничего не меняет:
-- функция стоит только в цепочках `or` (20260726180000:73,77 и далее), а там
-- `null or X` и `false or X` дают одинаковый итоговый вердикт — RLS трактует
-- null как отказ. Меняется лишь то, что видит вызывающий напрямую.
--
-- Сигнатура и грант не трогаются, поэтому пересоздавать политики не нужно.

create or replace function public.is_author_of_comment_visible(p_comment_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    public.is_author_visible(
      (select author_id from comments where id = p_comment_id)
    ),
    false
  );
$$;
