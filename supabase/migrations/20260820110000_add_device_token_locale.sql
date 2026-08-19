-- Push notification bodies (supabase/functions/send-push) were hardcoded
-- Russian-only. To localize them, each device_tokens row now carries the
-- locale the app was showing when the token was (re)registered, checked
-- against the same two locales the Flutter app ships (see
-- app/lib/l10n/app_localizations.dart's supportedLocales). Per-token rather
-- than per-user: device_tokens is already what send-push reads to resolve a
-- recipient's tokens, so this needs no extra join, and it degrades
-- gracefully if the same account is ever signed in on two devices set to
-- different languages.
--
-- Default 'ru' (not the app's own 'en' fallback) so existing rows, which
-- predate this column, keep getting the Russian text they already got until
-- the client's next registerDevice() call overwrites it with the real value.
alter table public.device_tokens
  add column locale text not null default 'ru'
  check (locale in ('en', 'ru'));

-- device_tokens' insert grant is an explicit column allowlist (see
-- 20260819140000), not the default "all columns" — locale has to be added to
-- it or the client upsert's insert branch fails on this new column.
grant insert (locale) on public.device_tokens to authenticated;
