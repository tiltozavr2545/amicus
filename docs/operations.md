# Operations

What runs on its own, where the secrets live and what to do by hand. Kept
separate from [data-model.md](data-model.md) because this isn't schema: the
schema answers "how is it built", this file answers "what do I press".

**Why** a given decision was made the way it was is still in the comment of the
corresponding migration, not here.

---

## Scheduled jobs (pg_cron)

All six live in the database, are created by migrations and can be seen with
`select jobname, schedule, active from cron.job`.

| Job | When | What it does | Migration |
|---|---|---|---|
| `drain-notification-outbox` | every minute | calls the `send-push` Edge Function, which drains `notification_outbox` | 20260818200000, header added in 20260820160000 |
| `inactive-week-nudge` | daily 12:00 UTC | enqueues the "week without posts" notice | 20260818190000 |
| `purge-abandoned-signups` | daily 03:40 UTC | deletes unconfirmed signups older than 30 days with zero activity | 20260822100000 |
| `purge-empty-posts` | hourly at :20 | deletes posts with no text and no `post_media` row at all, older than an hour | 20260822200000 |
| `reap-orphaned-media` | hourly, at :45 | deletes bucket objects older than a day that no row references — at most 100 per run | 20260823110000, 20260826120000 |
| `purge-notification-outbox` | daily 05:10 UTC | deletes `notification_outbox` rows older than 90 days | 20260823100000 |

The schedules are deliberately spread across different minutes instead of all
running at :00.

Hourly, not daily (20260826120000). The batch of 100 objects stayed — it keeps
the size of the Storage request predictable — but with a daily run that was a
cap of 100 objects **per day**, while the composer accepts 20 media per post,
each video up to 100 MiB, and uploading happens BEFORE the rows are inserted:
a single abandoned draft leaves up to 40 objects behind. Add to that whatever
`create_post_with_media()` didn't finish on a retry, and an account's entire
media library if cleanup on deletion failed. Garbage could pile up faster than
the reaper hauled it away, and the only place that would show is the Storage
bill.

To see what `reap-orphaned-media` is going to delete, without deleting
anything:

```sql
select * from public.orphaned_media_paths();
```

It's also the only safe way to check the predicate after editing it: the job
itself deletes the bytes through storage-api and there's no getting them back.
Never delete `storage.objects` rows by hand — it's a metadata index, the files
live in S3, and without storage-api they'll stay there forever, now invisible.

**There is deliberately no seventh job — age-based cleanup of push tokens.**
`device_tokens` rows are kept clean by three unscheduled mechanisms: the
`enforce_device_token_limit()` trigger (20 per person, the one that has gone
longest without checking in is evicted), `claim_device_token()` (deletes the
row with this token from the device's previous owner) and pruning in
`send-push` on an explicit FCM `UNREGISTERED` response. They share one gap: the
last one only fires on send, so for a person who is never sent anything a dead
row lies around forever. Closing that gap with a "hasn't signed in for a long
time" cleanup is dangerous — it hits exactly the `inactive-week-nudge`
audience, for whom a push is the only way back, and only launching the app
re-registers the token, which is exactly what doesn't happen for these people.
So the threshold, if the job is ever needed, must be well above FCM's own
staleness window (≈270 days), i.e. it's a backstop, not a cleaner. The trigger
for adding it is the tail in the "Возраст пуш-токенов" (push token age) section
of the local console; at the time of the decision the oldest token in the
database was 13 days old, and there was nothing to delete.

## Secrets

None of the ones listed here are in the repository. There are three different
stores, and mixing them up is costly — see the pitfall about
`SUPABASE_SERVICE_ROLE_KEY` in [../AGENTS.md](../AGENTS.md).

**Database Vault** (`select name from vault.secrets`) — read by the
`drain-notification-outbox` cron job:

| Name | What it is |
|---|---|
| `send_push_function_url` | Edge Function URL |
| `send_push_service_role_key` | bearer for the platform's `verify_jwt` gate. The name is historical: it's the project's service-role key, and since 20260823110000 `reap-orphaned-media` reads it too. A second copy of the same value under a second name was deliberately not created — having one copy of a secret matters more than an accurate name |
| `send_push_shared_secret` | proof that "it really is cron calling", travels in its own `x-send-push-secret` header |
| `storage_object_url` | batch delete endpoint in the `media` bucket, read by `reap-orphaned-media`. Not a secret but an address — it lives here for the same reason as `send_push_function_url`: the cron command has nowhere else to get it from |

Created once, outside migrations:

```sql
select vault.create_secret('<value>', 'send_push_shared_secret');
```

**Edge Function secrets** (`supabase secrets set …`): `FCM_PROJECT_ID`,
`FCM_SERVICE_ACCOUNT_JSON`, `SEND_PUSH_SECRET` — the last must match
`send_push_shared_secret` from Vault and be at least 32 characters, otherwise
the function deliberately refuses to start. `SUPABASE_URL` and
`SUPABASE_SERVICE_ROLE_KEY` are injected by the platform itself, don't set
them.

**GitHub secrets** (needed by `deploy-closed-testing.yml`, the workflow checks
that all eight are present before building): `ANDROID_KEYSTORE_BASE64`,
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`,
`PLAY_SERVICE_ACCOUNT_JSON`, `SUPABASE_URL`, `SUPABASE_ANON_KEY`,
`GOOGLE_SERVICES_JSON`.

**Local**: `app/.env` (`SUPABASE_URL`, `SUPABASE_ANON_KEY`), template —
`app/.env.example`. Plus `app/android/key.properties` and
`app/android/app/google-services.json` — both in `.gitignore`, their source of
truth is Play Console and Firebase, not git.

## Release

A push to `main` triggers `deploy-closed-testing.yml`: it runs `make verify`
and the version bump check itself (without relying on CI having been green),
builds a signed `.aab` and uploads it to **Google Play → Closed testing,
`alpha` track**, then posts a reminder comment on the PR. The rollout itself
has no manual steps.

**The Edge Function is deployed separately from the app.** CI doesn't touch
it: after editing `supabase/functions/send-push/index.ts` you need `supabase
functions deploy send-push`, otherwise production keeps running the previous
version. For example, the deep link on tap (`data` in the FCM message) won't
start working from an app release alone: `data` is added by the function, and
without deploying it a tap still just opens the app. A new notification kind
always takes TWO edits: the `kind` in the `notification_outbox` CHECK
constraint (migration) and the texts in `TEXTS` (function). Without the second
one the queue row is simply skipped, and the push silently never arrives.

Everything below is now done from the local console (`console/`, the
"Рассылки" (Broadcasts) and "Новости" (News) sections) — it also shows the
audience by name before sending, a breakdown by version, and the report queue.
SQL remains the fallback: it works when the console isn't running, and when
you need to do something the console can't.

What's still manual after a rollout:

1. A post from the Amicus news account, if the release is worth it (that's
   what the PR comment is a reminder of). Such a post does **not send**
   notifications by itself — that link was removed in 20260820190000.
2. An "update the app" broadcast, if needed:

   ```sql
   select public.enqueue_app_update_notifications(44, '0.17.0');
   ```

   The first argument is the `versionCode` (`+44` from `pubspec.yaml`), the
   second is for human reading only. A person counts as behind if the maximum
   `app_build` across all their devices is below the target. Calling again
   with the same build is safe: deduplication is by `payload->>'build'`, one
   notification per release. The function isn't granted to anyone — only via
   the Management API.

   The third argument is `p_important` (default `false`). With it the
   notification goes out as a different kind, `app_update_important`, and its
   text is insistent ("Important Amicus update…"). Use it rarely and only when
   it's true: without the update an old client shows the wrong thing — or
   doesn't work at all. This has happened twice. With 0.17.0: build 43 and
   older didn't filter on `posts.in_general_feed` and showed a post addressed
   only to a room in the general feed as well. With 0.17.3: that column went
   away along with room feeds, and build 46 and older gets a 400 on the feed
   request and a 404 on publishing until it updates. If every release is
   flagged as important, by the third time the word stops meaning anything,
   and the regular `app_update` is kept neutral precisely for that reason.
   Deduplication is shared across both kinds: a person gets exactly one
   notification about a given build.

   ```sql
   select public.enqueue_app_update_notifications(44, '0.17.0', true);
   ```

To see who is on which version (in the console that's the "Обзор" (Overview)
section, the "Версии приложения" (App versions) block — it also shows the
platform and why pushes aren't reaching someone):

```sql
select coalesce(app_version, 'unknown') as version, count(*)
  from device_tokens group by 1 order by 1;
```

## Migrations

Applied manually via the Supabase Management API; CI doesn't do it. The
procedure, the requirement to add a row to
`supabase_migrations.schema_migrations` and the rule "check RLS by simulation,
not by eye" are in "Working conventions" in [../AGENTS.md](../AGENTS.md); they
aren't repeated here so the two don't drift apart.

History is squashed into the baseline `20261018000000_baseline_schema.sql`;
everything before it lives in the tags `pre-baseline-migrations` (numbers up to
`20260825120000`) and `pre-baseline-migrations-2` (from `20260826000000` to
`20261010100000`). The baseline describes the final state of the schema and is
**not applied** to the live project — it's already applied there line by line;
its job is to bring up an equivalent schema on a clean database.

### Migration squash

Done twice (2026-08-26 and 2026-10-18), and the second time so that the result
could be verified mechanically rather than by reading:

1. Backup: a tarball of `supabase/migrations/` and a dump of
   `supabase_migrations.schema_migrations` including `statements` — outside
   the repository, plus a ready-made script that restores the table as it was.
2. A clean PostgreSQL emulating the platform: the `anon`/`authenticated`/
   `service_role` roles, `auth.users` and `auth.uid()` (bodies taken via
   `pg_get_functiondef` from the live project), `storage.buckets`/`objects`,
   `realtime.messages`, the `supabase_realtime` publication,
   `vault.decrypted_secrets`, `pg_cron`/`pg_net` stubs (in PG 18 — via
   `extension_control_path`) and Supabase's default privileges for `postgres`
   in `public`.
3. The entire current history is replayed on this emulation, and its
   fingerprint (a catalog query: columns and their order, constraints,
   indexes, function bodies and ACLs, triggers, `public`/`storage`/`realtime`
   policies, grants, default privileges, publication, bucket, cron) is
   compared with the same query on the live database via the Management API.
   Only the platform is allowed to differ.
4. The new baseline is derived from the catalog of the replayed history, not
   from the migrations; it's applied to a clean emulation and checked against
   the history by fingerprint, a full `pg_dump --schema-only` and the same
   behavioural run under `authenticated`/`anon`.
5. Only after that is a single service history table edited on the live
   project — `supabase migration repair`; schema and data are not touched.

To check that the repository and the database haven't drifted apart — file
names against table rows (the counts no longer match: the database has one row
for the baseline):

```bash
ls supabase/migrations/*.sql | sed 's#.*/##; s/_.*//'
```
```sql
select version from supabase_migrations.schema_migrations order by version;
```
