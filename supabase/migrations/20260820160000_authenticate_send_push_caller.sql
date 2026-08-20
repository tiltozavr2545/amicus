-- Cron начинает предъявлять send-push общий секрет, а не только bearer.
--
-- 20260818200000 завела дренаж очереди как «раз в минуту дёрнуть Edge Function
-- с service-role-ключом в `Authorization`». Проблема была не в ключе, а в том,
-- что сама функция вызывающего не проверяла никак, а платформенный `verify_jwt`
-- перед ней устраивает ЛЮБОЙ JWT проекта — включая anon-ключ, который лежит
-- внутри APK (`--dart-define=SUPABASE_ANON_KEY`) и публичен by design. То есть
-- дренаж очереди мог запустить кто угодно, распаковавший приложение: каждый
-- вызов — обмен токена у Google плюс запрос в FCM на каждое устройство, и
-- `sent_at` проставляется независимо от успеха доставки, так что
-- недоставленные уведомления просто терялись.
--
-- Секрет отдельный и едет в СВОЁМ заголовке, а не в `Authorization`, по двум
-- причинам, вторая из которых обошлась в живой инцидент.
--
--   1. `Authorization` обязан остаться валидным JWT — его проверяет тот самый
--      `verify_jwt`-гейт перед функцией. Этот заголовок не наш, чтобы его
--      переиспользовать.
--   2. Сравнивать bearer с `SUPABASE_SERVICE_ROLE_KEY` внутри функции выглядит
--      очевидным решением и не работает. У проекта одновременно живут два
--      поколения ключей (legacy JWT и новые `sb_secret_…`): cron шлёт legacy
--      JWT из Vault, а платформа инжектит в функцию значение другого формата и
--      другой длины. Первый же выкат такой проверки дал 401 на КАЖДЫЙ
--      легитимный вызов — то есть тихо выключил все пуш-уведомления. Секрет,
--      существующий только ради этого рукопожатия, разъехаться так не может.
--
-- Значение живёт в двух местах и нигде больше: в Vault (его читает вот этот
-- cron) и в секретах функции под именем `SEND_PUSH_SECRET`. В миграцию оно не
-- попадает — она коммитится, — поэтому задаётся один раз снаружи:
--   select vault.create_secret('<secret>', 'send_push_shared_secret');
--   supabase secrets set SEND_PUSH_SECRET='<secret>'
--
-- Расписание, URL и bearer не меняются — только добавляется заголовок.
select cron.unschedule('drain-notification-outbox');

select cron.schedule(
  'drain-notification-outbox',
  '* * * * *',
  $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'send_push_function_url'),
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'send_push_service_role_key'),
      'x-send-push-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'send_push_shared_secret'),
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb
  );
  $$
);
