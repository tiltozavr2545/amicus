-- Drains notification_outbox by calling the send-push Edge Function every
-- minute. Up to a minute of latency instead of real-time — acceptable for
-- this app, and avoids the Vault + pg_net webhook-auth wiring a per-insert
-- trigger would need just to carry a service-role bearer token.
--
-- The Edge Function's own URL and the service_role key it needs in the
-- Authorization header are both secrets, so they go through supabase_vault
-- (already installed, see pg_extension) rather than inline in this file —
-- consistent with never writing tokens into migrations that get committed.
-- Set once, outside of any migration:
--   select vault.create_secret('<url>', 'send_push_function_url');
--   select vault.create_secret('<service_role_key>', 'send_push_service_role_key');

select cron.schedule(
  'drain-notification-outbox',
  '* * * * *',
  $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'send_push_function_url'),
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'send_push_service_role_key'),
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb
  );
  $$
);
