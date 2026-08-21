-- Три индекса, которых не хватало под уже существующие горячие запросы.
--
-- 1. connections (user_b_id).
--    У таблицы есть только `connections_unique_pair unique (user_a_id,
--    user_b_id)` (20260708092302:29), и он обслуживает исключительно половину
--    user_a_id. При этом каждое решение о видимости в схеме спрашивает обе:
--      * visible_author_ids()  — `where c.user_a_id = auth.uid() or
--        c.user_b_id = auth.uid()` (20260726180000:48); на нём стоят SELECT-
--        политики posts, comments, post_media и storage-политика фото постов;
--      * are_connected() / is_connected_to_caller() (20260819160000) — под
--        политиками users и profile_photos;
--      * цикл зрителей в enqueue_post_notifications() — на каждой вставке
--        поста.
--    `a = X or b = X` планировщик закрывает bitmap-OR только когда
--    проиндексированы обе колонки; с одной он вырождается в seq scan всей
--    таблицы, то есть стоимость растёт от общего числа связей в продукте, а не
--    от числа знакомых вызывающего. 20260726180000 выиграла на ленте 217 мс ->
--    3.5 мс, вынеся функцию из построчного фильтра, но сам скан под ней так и
--    остался.
--
-- 2. favorite_users (favorite_id).
--    PK — (user_id, favorite_id) (20260818180000:15), а запрос в
--    enqueue_post_notifications() идёт `where f.favorite_id = new.author_id`,
--    то есть по второй колонке: полный скан favorite_users внутри триггера на
--    каждой публикации.
--
-- 3. posts (created_at desc, id desc).
--    Лента сортирует ровно так (feed_repository.dart, `.order('created_at',
--    ascending: false).order('id', ascending: false)`), а единственный индекс
--    на posts кроме PK — posts_author_id_created_at_idx (20260819190000:46),
--    у которого ведущая колонка author_id хэшируется против множества из
--    `in (select visible_author_ids())` и который не содержит id. В итоге
--    каждая страница сортирует все видимые посты целиком, прежде чем применить
--    LIMIT.
--
-- Таблицы сейчас маленькие, поэтому без `concurrently` — обычный create index
-- отрабатывает мгновенно и не требует отдельной транзакции.

create index connections_user_b_id_idx on public.connections (user_b_id);

create index favorite_users_favorite_id_idx on public.favorite_users (favorite_id);

create index posts_created_at_id_idx on public.posts (created_at desc, id desc);
