-- Два инварианта, которые до сих пор держались только клиентом.
--
-- 1. users.name. 20260820140000 ограничил имя сверху (`users_name_length`,
--    100 символов) и не ограничил снизу. Пустое имя отбивает только
--    `_saveName` в profile_screen.dart; PATCH с `{"name":""}` проходит и
--    политику, и CHECK. После этого автор исчезает отовсюду, где имя берётся с
--    сервера: шапка поста, список знакомых, строка автора комментария и слот
--    {author_name} в тексте пуша. Фолбэк 'Без имени' есть только в
--    handle_new_user(), то есть на регистрации, а на UPDATE его нет.
--
-- 2. posts. `posts_has_content` сняли в 20260819220000 вместе с колонкой
--    image_path и не заменили, поэтому БД принимает пост без текста и без
--    медиа. Такой пост — пустая карточка в ленте у всех Connection'ов, и он ещё
--    и дёргает enqueue_post_notifications(), то есть за него уходит пуш.
--
--    Синхронным CHECK'ом это не выражается, и не по недосмотру: createPost
--    вставляет строку поста и строки post_media ДВУМЯ запросами PostgREST, то
--    есть двумя транзакциями. Любая проверка «есть текст или есть медиа» в
--    момент вставки поста отвергла бы легальный пост из одних фотографий —
--    их строк на тот момент ещё нет. Отложенный constraint не спасает по той же
--    причине: он сработает на коммите ПЕРВОЙ транзакции.
--
--    Поэтому здесь два разных инструмента. CHECK ловит то, что проверяемо
--    сразу, — текст из одних пробелов (клиент всегда шлёт уже обрезанный
--    непустой текст либо null, так что живой путь он не задевает). А пост,
--    оставшийся без всякого содержимого, подчищает крон.
--
--    Час — с огромным запасом. Медиа заливаются ДО вставки строки поста (см.
--    createPost), так что легальный разрыв между постом и его post_media —
--    один round trip. Ретрай с тем же client_token остаётся идемпотентным и
--    после уборки: строки нет, upsert вставит её заново, а 409-терпимые
--    загрузки не полезут в бакет второй раз.
--
--    Объекты в storage от подчищенного поста остаются сиротами — ровно как и
--    сейчас, когда createPost падает между двумя запросами. Строка, которая
--    ссылается на удалённый объект, хуже байтов, на которые никто не
--    ссылается: правило целиком — в app/lib/shared/delete_order.dart.

alter table public.users
  add constraint users_name_not_blank check (btrim(name) <> '');

alter table public.posts
  add constraint posts_text_not_blank check (text is null or btrim(text) <> '');

create or replace function public.purge_empty_posts()
returns integer
language plpgsql
security definer
set search_path = public
as $$
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
$$;

revoke execute on function public.purge_empty_posts() from public, anon, authenticated;

select cron.schedule(
  'purge-empty-posts',
  '20 * * * *',
  $$ select public.purge_empty_posts(); $$
);
