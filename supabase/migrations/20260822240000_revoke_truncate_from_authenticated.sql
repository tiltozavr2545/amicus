-- Снять с роли `authenticated` право очищать таблицы целиком.
--
-- 20260818140000 забрала дефолтные гранты Supabase у `anon` и назвала там
-- единственный довод, который был не про аккуратность, а про безопасность: на
-- **TRUNCATE row-level security не распространяется в принципе** — политики
-- фильтруют строки, а TRUNCATE не строчная операция. То есть у этого права нет
-- второго рубежа обороны вовсе, и держит его ровно одно обстоятельство:
-- PostgREST не отображает TRUNCATE ни на один HTTP-глагол.
--
-- 20260821120000 повторила ту же уборку для `post_media`/`profile_photos`,
-- потому что обе таблицы появились позже и получили дефолт заново.
--
-- Обе миграции трогали только `anon`. У `authenticated` — роли, которую носит
-- КАЖДЫЙ вошедший пользователь, — то же самое право осталось на всех
-- тринадцати таблицах. Довод «PostgREST такого запроса не умеет» для неё ровно
-- тот же и ровно так же был признан недостаточным.
--
-- Воспроизведено симуляцией на живой схеме до правки (роль `authenticated`,
-- `request.jwt.claims`, транзакция с rollback):
--
--   reactions_before           = 56       -- строк в таблице
--   rows_visible_to_this_user  = 3        -- сколько ему показывает RLS
--   truncate_result            = ПРОШЁЛ
--   reactions_after            = 0        -- снесены все 56
--
-- Три строки видимости против пятидесяти шести стёртых — это и есть «политики
-- тут не при чём».
--
-- Забираются три права, ни одно из которых не нужно ни одному пути записи:
--
--   TRUNCATE    см. выше;
--   TRIGGER     право повесить свой триггер на таблицу;
--   REFERENCES  право сослаться на неё внешним ключом.
--
-- Последние два сегодня недостижимы по другой причине (нужно ещё право
-- создавать объекты в схеме, которого у роли нет), но это опять защита
-- поверхностью, а не привилегией — а `revoke all`, каким закрывали `anon`,
-- здесь не годится: SELECT/INSERT/UPDATE/DELETE роли нужны, они и так сужены
-- до конкретных колонок предыдущими миграциями.
--
-- MAINTAIN (появился в PostgreSQL 17) сознательно оставлен: он не даёт ни
-- прочитать, ни изменить, ни удалить ни одной строки — только запустить
-- обслуживание вроде VACUUM/ANALYZE, — так что в один класс с TRUNCATE не
-- попадает, а забирать его значило бы писать миграцию, которая молча меняет
-- смысл на более старом сервере.
--
-- Вторая половина правки — про будущее. Дефолтные привилегии Supabase
-- (`pg_default_acl` для роли `postgres` в схеме `public`) выдают новым таблицам
-- `arwdDxtm` для `authenticated`, поэтому таблица, созданная следующей
-- миграцией, получит TRUNCATE обратно — ровно так это и произошло между
-- 20260818140000 и 20260821120000. `alter default privileges` снимает три этих
-- права на будущее, так что уборку не придётся повторять третий раз. Миграции
-- накатываются от имени `postgres`, то есть именно от той роли, чьи дефолты
-- здесь и правятся.

revoke truncate, trigger, references on public.users from authenticated;
revoke truncate, trigger, references on public.posts from authenticated;
revoke truncate, trigger, references on public.comments from authenticated;
revoke truncate, trigger, references on public.reactions from authenticated;
revoke truncate, trigger, references on public.connections from authenticated;
revoke truncate, trigger, references on public.invite_links from authenticated;
revoke truncate, trigger, references on public.muted_users from authenticated;
revoke truncate, trigger, references on public.blocked_users from authenticated;
revoke truncate, trigger, references on public.favorite_users from authenticated;
revoke truncate, trigger, references on public.device_tokens from authenticated;
revoke truncate, trigger, references on public.notification_preferences from authenticated;
revoke truncate, trigger, references on public.post_media from authenticated;
revoke truncate, trigger, references on public.profile_photos from authenticated;

alter default privileges in schema public
  revoke truncate, trigger, references on tables from authenticated;
