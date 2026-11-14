# Amicus console

A local admin console: reports, posts from the news account, database
breakdowns and broadcasts. It runs **only on the developer's machine**: it is
never deployed anywhere and has no login, because all access rests on the
service_role key, which bypasses RLS entirely.

## Running

```bash
cd console
npm install
cp .env.example .env   # fill in SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY
npm run dev
```

This starts two processes: the API on `127.0.0.1:5174` and Vite on
`127.0.0.1:5173`. Work with the second one; it proxies the first.

## Why it is built this way

- **The key lives only on the server.** The browser talks to `/api`, and
  nothing in it talks to Supabase: service_role in the frontend bundle means
  the whole database is exposed. That is why the console has a server half. It
  was read-only only during the first stage: now it is used to hide and delete
  content, ban people, handle reports, publish news-account posts and enqueue
  notifications.
- **Loopback only, plus a `Host`/`Origin` check on top of it.** Both the API
  and Vite listen on `127.0.0.1`, not `0.0.0.0`. But loopback closes off the
  network, not the developer's browser: a foreign domain with an A record of
  `127.0.0.1` (DNS rebinding) becomes the SAME origin as the console from the
  browser's point of view, no CORS kicks in, and a script on that page reads
  the console's responses as its own, i.e. gets the whole database, because
  the console goes around RLS. So `server/local_only.ts` rejects anything whose
  `Host` is not a loopback hostname, whose `Origin` is foreign, or for which
  the browser itself said `Sec-Fetch-Site: cross-site`. The check runs BEFORE
  body parsing and is covered by tests (`npm test`), including the spoofed
  `Host` case.
- **Aggregation in memory, not in SQL.** The console reads tables whole and
  computes breakdowns in Node: on a pilot project that is cheaper than creating
  views and migrating them along with the schema. The ceiling is 100,000 rows
  per table (`server/db.ts`); if it is hit, that is the signal to move
  aggregation into SQL, not to raise the number.
- **A version belongs to an install, not a person.** One user's phone and
  tablet can be on different builds, so the version table counts installs and
  people separately, and counts someone as "behind" when their maximum
  `app_build` is below the latest, exactly like
  `enqueue_app_update_notifications()`. Details: "App version and update
  notification" in [../docs/data-model.md](../docs/data-model.md).

## What's done

- **Overview** ("Обзор"): database totals, sign-ups and posts over 30 days,
  breakdown by version, platform and language, push-token age, **why pushes
  don't arrive** (permission denied / registration failure / old version),
  notification queue state, disabled settings.
- **Users** ("Пользователи"): a list with search and sorting, and a person's
  card: devices with versions and OS, notification settings, recent posts and
  notifications.
- **News** ("Новости"): an editor for news-account posts: text with a "how it
  will look in the feed" preview, media with reordering, drafts, editing and
  deleting published posts. Publishing sends no notifications: the queue
  trigger bails out for the system account (20260820190000). Until
  publication, a selected file sits on the console's disk, not in the bucket;
  for why, see "About the news editor" below.
- **Reports** ("Жалобы"): the review queue: what the object is, its text at
  the time of the report, who reported it, how many reports there are on the
  same object. Actions: hide and unhide, delete, ban from writing for a period,
  ban sign-in, lift restrictions, close or reject the report.

- **Broadcasts** ("Рассылки"): the "a new version is out" notification: the
  target is taken from `app/pubspec.yaml`, the audience is computed in advance
  and shown by name, with their own builds. Shown separately are those who
  will be filtered out by the repeat protection and those who turned off
  notifications from the system account.

### About targeted notifications

- **You can send to a single person** from their card in the "Users" section:
  "Обновитесь" ("Please update"), "Важное обновление" ("Important update") and
  "Сообщение модерации" ("Moderation message"). The first two respect the same
  things as the mass broadcast: disabled system-account notifications and the
  per-build repeat protection.
- **The list of kinds is closed and shorter than the table's CHECK.** The
  other kinds are event-driven: sending "you have a new comment" where there
  was no comment means lying to a person in the app's voice.
- **"Написать автору" ("Message the author")** also exists as a separate
  action on the report card, for when there is nothing to remove but something
  to say: the content stays, the report is not closed.
- **There is deliberately no separate "message the reporter" button.** Both
  ready-made texts for them describe the OUTCOME of the review, so they go out
  together with "Закрыть" ("Close") or "Отклонить" ("Reject"), not on their
  own.

### About broadcasts

- **Sending is done by `enqueue_app_update_notifications()`**; the console is
  only an input form. The recipient list on screen mirrors its selection,
  computed in advance; the function itself is the source of truth, so after
  sending the console shows how many rows it actually created: a discrepancy
  becomes visible immediately, not when someone fails to get the notification.
- **Calling it again with the same build is safe.** A person gets exactly one
  notification per build, and the regular and the urgent ones don't stack.
- **The urgent kind is rare and only when warranted.** In the whole history of
  the project it has been used twice. The console shows a warning about this
  exactly when the checkbox is ticked.
- **A queue row is not a delivered push.** It also reaches a person with no
  devices and gets marked as sent, which is why there is a "без устройств"
  ("no devices") counter next to it.

### About the news editor

- **Editing rewrites the media entirely.** Otherwise there is no way to assign
  `position`. So the API requires `media` as an explicit list even when only
  the text is edited: a forgotten field would mean "there's no media anymore",
  and the request would silently wipe the attachments. Learned the hard way:
  during development this wiped a real post twice.
- **A system-account post is created by a direct insert, not through
  `create_post_with_media()`**: that function takes the author from
  `auth.uid()`, while the console runs as service_role without a JWT. So all
  of its checks (the 20-media limit, "a post needs text or media", an empty
  string meaning no text) are repeated in `server/routes/news.ts`; without
  them, the database would get things the client can't put there. The object
  path, meanwhile, is no longer checked but **issued**: the server builds it
  itself from a uuid and an extension derived from the type, so the uploaded
  file name plays no part in it (see the next item).
- **Until publication, a selected file sits on the console's disk, not in the
  bucket.** `POST /news/media` puts it into `news-staging/` and returns a
  reference of the form `staged:<name>`; it moves to the bucket from
  `prepareMedia()`, when a post is actually made from it.

  Otherwise drafts were not viable. An object with no row in `post_media` is
  referenced by nothing, so by the definition of `orphaned_media_paths()` it is
  an orphan, and the hourly `reap-orphaned-media` wiped the bytes after a day,
  while publishing a two-day-old draft **still succeeded**: the rows were
  inserted pointing at nothing, and the post went out broken into the feeds
  of all connections, along with an already-sent push. There was nothing to
  restore from; `drafts.json` is the only copy.

  Two more things went away along the way: an abandoned set of files no longer
  reaches the bucket at all, and draft thumbnails stopped expiring after an
  hour (the staging link is not signed). Staging cleanup hangs off
  `GET /news`: anything referenced by at least one draft is not touched at
  all, the rest is removed after a week. Details: the comment on `STAGING` in
  [server/news.ts](server/news.ts).
- **The video poster is captured in the browser** via canvas: on the server,
  one image would require ffmpeg. If the browser can't decode the file, the
  post is published without a poster.
- **Deleted files are not erased from the bucket immediately**: the row stops
  referencing them, and `reap-orphaned-media` removes them within a day.

### About queue actions

- **"Скрыть" ("Hide") is reversible, "Удалить" ("Delete") is not.** Hiding
  sets `hidden_at`, and the object disappears for everyone, the author
  included. Deleting a post removes the row; a comment or a message turns into
  a placeholder, the same way the app itself does it, otherwise the reply
  thread under them would break.
- **The "уведомить" ("notify") checkbox is on by default** and sends a real
  push. Untick it when you are handling something of your own or testing the
  console.
- **The note added to a notification is not translated.** The text skeleton
  is localized (`send-push`), but your words go out as is: a person with an
  English locale will get half of it in Russian. That is why the note is
  optional: without it, the text stays entirely in the recipient's language.
- **Deploy the Edge Function first, then use the "notify" checkbox.** The
  `moderation_notice`, `report_resolved` and `report_rejected` kinds were added
  to `send-push`, but CI doesn't deploy it: you need to run `supabase functions deploy send-push` by hand.
  Until that is done, the notification is not postponed but **lost**: drain
  picks up the row, finds no text for its kind, skips it, and still sets
  `sent_at`, because otherwise it would keep reselecting it forever. In the
  queue it will look sent, but nothing will reach the phone.

## What's next

There are no greyed-out menu items left: all five sections work. What to keep
in mind: the console is never deployed, so it is not part of the app's
`make verify`; it has its own workflow,
`.github/workflows/console-ci.yml`, which on changes to `console/**` runs
`npm run lint` (Biome), `npm run typecheck`, `npm test` and `npm run build`.
The same locally:

```bash
cd console && npm run lint && npm run typecheck && npm test && npm run build
```

Tests run on `node --test` via the already-present `tsx`; there is
deliberately no separate test runner in the dependencies: the only candidate
pulled in over a hundred packages and came with its own vulnerability, while
what needs testing here is pure functions. They live next to the code under
test, `server/*.test.ts` (the `test` script picks up exactly that level).

## Structure

```
server/            local API; the only place that has service_role
  routes/          endpoints by section
  db.ts            paginated PostgREST reads + the admin Auth API
  aggregate.ts     shared breakdowns (versions, languages, daily series)
  local_only.ts    the "request came from this machine" check, before everything else
  ban_duration.ts  parsing and bounds of the penalty period
  news.ts          drafts, media staging, the "type ↔ extension" table
  uuid.ts          id shape check before it goes off to PostgREST
  *.test.ts        tests (node --test via tsx)
shared/types.ts    contract between the server and the frontend
src/               React app (Vite)
drafts.json        news drafts, not in the repository
news-staging/      bytes picked in the composer that haven't become a post yet,
                   also not in the repository
```

The last two appear on their own the first time the "News" section is used
and are listed in `.gitignore`: they are the state of one machine, not of the
project.
