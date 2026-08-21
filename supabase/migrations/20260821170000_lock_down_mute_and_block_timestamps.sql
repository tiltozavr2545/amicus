-- Последние две таблицы, где `authenticated` всё ещё пишет серверную колонку.
--
-- `muted_users` и `blocked_users` появились в 20260715120000 — раньше, чем
-- в проекте сложился приём с колоночными грантами, — и потому сохранили
-- табличный INSERT-грант Supabase по умолчанию. Проверено по
-- information_schema до правки: у обеих в списке insertable-колонок стоит
-- `created_at`, тогда как у `favorite_users` и `device_tokens` (20260819140000)
-- только собственные ключевые колонки.
--
-- Приём взят оттуда же дословно, и по той же причине, по которой там выбрали
-- грант, а не пин `created_at = now()` в `with check`: единственная клиентская
-- запись в обе таблицы — идемпотентный `upsert` без явного `onConflict`
-- (см. muteUser/blockUser в connections_repository.dart), то есть по
-- первичному ключу. Повторный мьют попадает в ветку ON CONFLICT DO UPDATE,
-- которая `created_at` вообще не упоминает; пин по значению сравнивал бы
-- `created_at` **исходной** строки с `now()` и валил бы операцию, которая
-- сегодня работает. Колоночный грант ограничивает ровно INSERT-ветку — то
-- единственное место, где подделанное значение может появиться.
--
-- Влияние низкое: ни один из этих `created_at` пока не участвует ни в
-- сортировке, ни в решении о доверии. Но это тот же класс подделываемой
-- серверной колонки, который в проекте закрывали уже шесть раз (posts,
-- comments, reactions, favorite_users, device_tokens, users), и оставлять
-- его открытым только потому, что таблицы старые, — ровно та же логика
-- «просто эти новые», которую отвергала 20260819140000.
--
-- Политики `for all` не трогаются: они про то, ЧЬЯ строка, а не про то, какие
-- колонки писать. DELETE-ветка (размьютить/разблокировать) от гранта на
-- INSERT не зависит.

revoke insert on public.muted_users from authenticated;
grant insert (muter_id, muted_id) on public.muted_users to authenticated;

revoke insert on public.blocked_users from authenticated;
grant insert (blocker_id, blocked_id) on public.blocked_users to authenticated;
