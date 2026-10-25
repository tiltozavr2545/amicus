# AGENTS.md

Context for an AI agent working in this repository — shared by any tool
(Codex, Claude Code, etc.).

This file holds only what isn't in the code: environment constraints, working
conventions and pitfalls. Everything else lives where it should be read:

| what | where |
|---|---|
| what the project is, what already works, the stack | [README.md](README.md) |
| version history | [CHANGELOG.md](CHANGELOG.md) |
| **why** a decision was made the way it was | the comment in the baseline migration, then the history archive (tags `pre-baseline-migrations` and `pre-baseline-migrations-2`), then `git log` |
| DB schema, the visibility rule, storage policies | [docs/data-model.md](docs/data-model.md) |
| how the client is built, default decisions | [docs/client-architecture.md](docs/client-architecture.md) |
| schedules, secrets, release, the "please update" broadcast | [docs/operations.md](docs/operations.md) |
| deferred work, open questions | [docs/future-development.md](docs/future-development.md) |
| building and deploying iOS, push via APNs (in English — the steps follow Xcode/App Store Connect, which are all in English) | [docs/ios-deployment-guide.md](docs/ios-deployment-guide.md), [docs/ios-push-apns-setup.md](docs/ios-push-apns-setup.md) |
| building iOS with Xcode Cloud instead of a local machine (in English, for the same reason) | [docs/xcode-cloud-setup.md](docs/xcode-cloud-setup.md) |
| triggering an Xcode Cloud build through the App Store Connect API instead of the web UI, without a password/2FA login (in English, for the same reason) | [docs/app-store-connect-api-automation.md](docs/app-store-connect-api-automation.md) |
| the published privacy policy and terms of use, the email confirmation and password reset pages | [docs/gh-pages/](docs/gh-pages/) — edited here, not on the `gh-pages` branch: CI overwrites it on every push to `main` |
| App Store listing draft (in English, for the same reason) | [docs/review/app-store-listing-draft.md](docs/review/app-store-listing-draft.md) |
| historical: the original idea, how the MVP went, the old deferred list | [docs/project-brief.md](docs/project-brief.md), [docs/implementation-plan.md](docs/implementation-plan.md), [docs/future-development.archive.md](docs/future-development.archive.md) |

## Project

A pilot/portfolio project: the author is new to mobile development but has
experience with SQL/PostgreSQL and C#/.NET. Work step by step, without getting
ahead — this is a deliberate decision, not the absence of a plan.

## Environment constraints

- **Two developers, two machines.** Android is on an old Intel MacBook Pro
  (with Touch Bar), macOS 12.7.6. Flutter newer than 3.32.8 doesn't run on it
  (needs macOS 14+), so the SDK is pinned to 3.32.8. Don't suggest upgrading —
  the machine physically can't run a newer macOS, it's a dead end. iOS is on an
  M4 MacBook Pro (Apple Silicon), which has no such constraint.
- **iOS.** Built and deployed to TestFlight; the current process and
  constraints are in `docs/ios-deployment-guide.md`. If the iOS build machine
  runs a beta macOS, a local `flutter build ipa`/`make release-ios` still
  succeeds, but App Store Connect rejects the binary (`ITMS-90111:
  Unsupported SDK or Xcode version`) — the binary embeds the build machine's
  host OS version (`BuildMachineOSBuild` in `Info.plist`), not just the
  Xcode.app version. Xcode Cloud gets around this by building on a stable Apple
  image regardless of the local macOS — see `docs/xcode-cloud-setup.md`.
- `compileSdk`/`targetSdk` are hard-coded to **36** in
  `android/app/build.gradle.kts` (a Play requirement), AGP **8.9.3** on Gradle
  **8.12** — a newer AGP would require Gradle 8.13.
- Running: `flutter run --dart-define-from-file=.env` from `app/`. `.env` is not
  in the repository; the template is `app/.env.example`.

## Working conventions

- **Write all repo-facing text in English**: commit messages, docs,
  code comments/docstrings, and GitHub release bodies. Exception:
  anything genuinely user-facing that the app itself produces, and any
  real localization resource — those stay as-is.
- **Migrations are applied manually** through the Supabase Management API
  (`POST /v1/projects/<ref>/database/query`). CI does **not** run
  `supabase db push`. The user provides the token for the duration of the
  task; it is never written to the repository or to memory. After applying —
  add a row to `supabase_migrations.schema_migrations`, otherwise a future
  `db push` will apply the migration again.
- **The history is squashed into a baseline.**
  `20261018000000_baseline_schema.sql` is not a step of history but the final
  state of the schema; later migrations go on top of it in the usual order. It
  has been squashed twice, and both parts live in tags: the first 104
  migrations (`20260707221946`…`20260825120000`) are in
  `pre-baseline-migrations`, the first baseline and the 27 migrations on top of
  it (`20260826000000`…`20261010100000`) are in `pre-baseline-migrations-2`.
  Comments in `app/lib`, `docs/` and the baseline itself refer to them by
  number: `git show <tag>:supabase/migrations/<version>_*.sql` — the first tag
  for numbers up to and including `20260825120000`, the second for the rest.
  The baseline is **not applied** to the live project — it is already applied
  there row by row; its job is to bring up an equivalent schema on a clean
  database. How to squash and verify the squash — "Migration squash" in
  [docs/operations.md](docs/operations.md).
- **Verify RLS by simulation**, not by eye: `begin; set local role
  authenticated; select set_config('request.jwt.claims','{"sub":"<uuid>"}',true);
  … rollback;`. The Management API runs as a superuser and doesn't apply RLS.
  First reproduce the hole, then close it, then compare the control numbers
  before/after. Order inside the transaction: `set_config` BEFORE
  `set local role` — after the role switch, the subquery that looks up the
  test subject's uuid itself goes through RLS, returns NULL, and all the
  control numbers honestly come out as zeros for an entirely different reason.
- **Run the whole migration inside `begin; … rollback;` before applying it.**
  The Management API accepts a multi-statement query, DDL in Postgres is
  transactional, and the rollback undoes everything — including
  `alter function`, `create trigger` and grants. This is not a formality: on
  20260924100000 the dry run caught that "closing an unneeded endpoint" would
  have switched off all attachments in chats (the function was used in a
  storage policy), and a behavioral probe in the same rolled-back block caught
  that the name-change item didn't work at all, even though the migration
  itself and all its checks passed. Write the probe so that the ABSENCE of a
  rejection fails it (`raise exception` if the forbidden action went through),
  otherwise it only checks that the query is syntactically valid.
- **The version is bumped in every PR**: `make verify-version BASE_REF=origin/main`,
  format `name+build`.
- **Before handing off**: `make verify` (deps, format, analyze, tests) for
  `app/`. The console isn't part of it — it isn't deployed anywhere and doesn't
  affect the app build, so it has its own workflow,
  `.github/workflows/console-ci.yml`: it runs `npm run lint` (Biome),
  `npm run typecheck`, `npm test` and `npm run build` on changes in
  `console/**`. The same can be run locally before pushing:
  `cd console && npm run lint && npm run typecheck && npm test && npm run build`.
  Console tests run on `node --test` via the already present `tsx`; there is
  deliberately no separate test runner in the dependencies (see "What's next"
  in [console/README.md](console/README.md)).
- **Localization**: strings live in `app/lib/l10n/app_{en,ru}.arb`, generated
  with `flutter gen-l10n`, and the generated files are committed. Edit ARB files
  **as text**: rewriting them via `json.dump` eats the blank lines that split
  the file into meaningful groups.
- **`CLAUDE.md` is a thin wrapper around this file**, holding only Claude
  Code-specific differences (there are none right now — the file redirects here
  entirely). Shared conventions and pitfalls live only here; don't duplicate
  them.

## Pitfalls

- **The visibility rule lived in four copies; two fell behind mute/block and
  became holes.** Consolidated into a single `is_author_visible(uuid)`; the
  schema and its consumers — [docs/data-model.md](docs/data-model.md). Change
  the rule only there; never create a second copy.
- **RLS applies to subqueries inside a policy too.** A subquery against
  `blocked_users` is itself filtered by the `blocked_users` policy, so the
  "I've been blocked" branch silently fell off. That is where the whole
  `security definer` + `set search_path` pattern comes from. This is the most
  load-bearing idea in the entire schema.
- **The planner doesn't inline a `security definer` function.** Don't use it as
  a per-row filter in `using` if it depends only on `auth.uid()` — lift it into
  an uncorrelated `IN (SELECT …)`, which is hashed once. The difference on the
  feed was 217 ms → 3.5 ms.
- **In new policies write `(select auth.uid())`, not a bare `auth.uid()`.** A
  bare call is evaluated per row, a wrapped one once per query (Advisor:
  `auth_rls_initplan`, migration `20261010100000`).
- **Every function in `public` is a PostgREST endpoint.** Grant
  `grant execute … to authenticated` only if every argument is about the caller
  themselves; otherwise it answers questions about other people.
- **Supabase's default grants let `authenticated` write every column.** Any
  new column filled in by the server must be explicitly mentioned in the
  INSERT policy.
- **`order()` in postgrest-dart defaults to `ascending: false`.** This cost a
  real bug with reversed threads.
- **`timestamptz` from PostgREST is parsed as UTC.** Convert with
  `parseTimestamp()` at the "string → model" boundary, not where it's displayed.
- **The back gesture must not be tested on screens reached via
  `context.go()`** — it replaces the route, the stack is empty, and
  backgrounding the app is legitimate on any Android version. Test only
  `Navigator.push()` screens. Cancelling the gesture can't be reliably tested
  via `adb` — the system makes the call, and injected events carry no velocity.
- **A `BEFORE INSERT` trigger fires before `ON CONFLICT` arbitration.** A row
  that `DO NOTHING` will eventually discard still passes through the trigger —
  that's how the backstop limit of 20 media caught not the 21st item but a
  retry of an already published post, and locked the user into an error
  forever. A trigger that counts rows must itself skip a duplicate on the same
  key the conflict is resolved by.
- **`SUPABASE_SERVICE_ROLE_KEY` in an Edge Function is not the key stored in
  Vault.** The project has two generations of keys alive at once (legacy JWT
  and `sb_secret_…`): cron sends the legacy JWT from Vault, while the platform
  injects into the function a value of a different format and length. Comparing
  the bearer against this variable looks obvious and switches off pushes
  entirely. Create a separate secret for "us/them", in its own header —
  `Authorization` is taken by the `verify_jwt` gate.
- **`create or replace function` rewrites the ENTIRE body, it doesn't patch a
  branch.** Take the source from the migration that touched this function
  last — not the one you remember. Twice in a row `enqueue_post_notifications()`
  was recreated from the pre-reform text to edit a single branch, bringing back
  the write to `pending_post_counts`, which an intermediate migration had
  dropped. `check_function_bodies` checks plpgsql only syntactically — table
  names are resolved at runtime, so the migration applied silently, and the
  `AFTER INSERT` trigger started rolling back the post itself: nobody who had a
  Connection without mute/block/favorites could publish. After applying, check
  not "did it apply" but `prosrc` for signs of the old body.
- **Ask the live schema what is allowed right now, not the migration that
  introduced it.** The finding "anyone can write `users.avatar_path`" was
  derived from `20260820140000` (`grant update (name, avatar_path)`) and turned
  out to be wrong: `20260822210000` had already revoked that grant and made the
  sync trigger `security definer`. Migrations are a journal of intentions, not
  state, and the older the project, the more often the line you need has been
  undone by a later one. The answer costs one query:
  `information_schema.column_privileges` for grants, `pg_policy` for policies,
  `prosrc` for function bodies (see the item above). The same goes the other
  way — before revoking a grant, check whether it's reachable: a command with no
  policy under it is always rejected, and a `revoke` on it changes nothing
  except the future.
- **An invariant that rests on a best-effort call from a departing client is
  not an invariant.** The right to an FCM token was removed only by
  `unregisterDevice()` before sign-out, wrapped in an empty catch (signing out
  has to work without a network too) — normally it doesn't fire reliably, and
  the next owner of the device received someone else's pushes. The rule moved
  to the server (`claim_device_token()`); history and details — "One device,
  one account" in [docs/data-model.md](docs/data-model.md). Ask not "does
  anyone call the cleanup", but "what happens if this call never happens even
  once".
- **`upsert` from PostgREST requires a NON-partial index and an UPDATE grant.**
  `on_conflict=a,b` asks the planner to infer an index, and inference from a
  partial index (`where … is not null`) only works if the query repeats its
  predicate — PostgREST can't send that, and the response is 42P10 "there is no
  unique or exclusion constraint matching the ON CONFLICT specification". On
  top of that, `upsert` always expands into `DO UPDATE`, i.e. it requires the
  UPDATE privilege — which the table may deliberately lack. That is how ALL
  message sending in rooms silently didn't work. If UPDATE isn't needed,
  idempotency is done with a plain `insert` and handling 23505: a duplicate on
  the unique index means "this send already went through", and the row it
  collided with is the answer. And a third privilege, which surfaced on
  `push_registration_status` (20260913120000): `ON CONFLICT DO UPDATE` also
  requires **SELECT, and on the table, not on a column**. It reads the row it
  collided with to apply the policy's `using` expression to it, and a
  per-column grant on exactly the column in the expression is NOT enough — it
  gets rejected with 42501 "permission denied for table". A probe checks this
  in a minute: a plain `insert` goes through, an upsert on the same key
  doesn't. And a fourth, which is why the same table broke a second time:
  PostgREST puts **all the columns sent, including the conflict column**, into
  `DO UPDATE SET`, i.e. it always writes `user_id = excluded.user_id`. A
  per-column UPDATE grant without the key column ("no reason to change the
  key") rejects the whole upsert. The general lesson is worth more than the
  specific one: **simulate the query shape the client actually sends, not the
  one convenient to type by hand** — a hand-written `SET` without `user_id`
  passed the simulation and caught nothing.
- **Adding a parameter to an RPC means dropping the old function first.**
  `create or replace function f(a, b, c default …)` with a new argument list
  doesn't replace `f(a, b)` but creates a SECOND overload. After that, a
  PostgREST call with three named parameters becomes ambiguous (300 Multiple
  Choices), i.e. it breaks for every released client at once. There is only
  one order: `drop function` with the old signature, then `create`, then
  `grant execute` again — the grant goes away together with the function.
- **A prefix branch in a storage policy equals the per-row rule only until
  the first narrower audience.** For `avatars/<uid>/…`, three branches (own,
  system account, Connection) answered "yes" for the whole prefix, and that
  matched the RLS on `profile_photos`, which shows a Connection the whole
  gallery. The "room peer" branch broke the match: a room peer doesn't see the
  gallery rows at all, yet saw all the objects — `storage.list()` goes through
  the same SELECT policy and listed up to 80 photos. When adding an audience to
  a storage policy that the per-row rule grants LESS, rewrite the branch from
  prefix to object (`is_room_peer_avatar()`), don't add it alongside. Same
  class as "the visibility rule in four copies", only here the copies are in
  different subsystems. Details — "Storage" in
  [docs/data-model.md](docs/data-model.md).
- **`if not f(...)`, where `f` can return NULL, never fires.**
  `owns_room()` is `room_owner_id(...) = auth.uid()`, i.e. NULL for a
  nonexistent room; `not NULL` is also NULL, and the branch is skipped
  entirely. In `set_room_avatar()` this was covered by an existence check
  higher up, and it surfaced exactly when that check was removed. The
  `is distinct from` form has no NULL trap and always works.
- **An idempotent retry is an UPDATE, and an `AFTER INSERT` trigger won't
  fire on it.** The `on conflict` branch in `create_post_with_media()` brings
  the post to the submitted state, but everything the trigger put into queues
  on the first (committed) attempt stays there — having narrowed the audience
  with a retry, there was nobody to revoke the push about the post. When
  creating an RPC that rewrites an already existing row, ask not only "is the
  row right now", but also "what did its triggers manage to do last time".
- **Riverpod's `ref` throws after `await`, in release too.** `WidgetRef`
  hangs on a `BuildContext`; leave the screen while the request is in flight —
  and `ref.invalidate()` throws a `StateError`, which the method's own `catch`
  catches and swallows together with the refresh itself. Moving `mounted`
  higher doesn't fix it: the lists that need re-reading belong to other, still
  alive screens. The container is captured BEFORE `await` —
  `refreshAfterAwait()`, details in
  [docs/client-architecture.md](docs/client-architecture.md).
- **On-device testing**: switch to the English locale per app
  (`adb shell cmd locale set-app-locales <pkg> --locales en-US`), not via the
  system setting — it doesn't touch the user's phone and is reverted with an
  empty value.
- **`flutter build appbundle`/`make build-android` uses Android Studio's JDK,
  not `JAVA_HOME`.** On newer Studio versions the bundled JBR reports a version
  like `25.0.2`, which Gradle's Kotlin compiler can't parse — the build fails
  with a bare `25.0.2` instead of a meaningful error. The fix is not in
  `gradle.properties` (that's a committed file, and everyone's JDK path is
  different) but per-machine:
  `flutter config --jdk-dir="$(/usr/libexec/java_home -v 21)"`.
- **The write ban is enforced by a trigger, not an INSERT policy — because all
  writes in this project bypass RLS.** Nineteen writing RPCs
  (`create_post_with_media`, `request_connection`, `create_room`, …) are
  `security definer`, granted to `authenticated`, and `force row level security`
  is not enabled on any table: inside such a function policies are NOT applied
  at all. A "banned" condition in the `posts` INSERT policy wouldn't have
  stopped anyone, because posts are created by an RPC, not a direct insert. A
  trigger is bound to the table, not the role, and fires the same way on both
  paths — which is why `reject_write_when_banned()` (20260913100000) sits on
  seven tables with a single body. Check "will this even reach the policy"
  EVERY time a rule concerns writes: the answer here is almost always "no".
- **A new table and a new function in `public` arrive with full privileges for
  `authenticated`.** The schema's default privileges (`pg_default_acl`) grant
  `a/r/w/d` on tables and `execute` on functions; the baseline removed this
  for good only for `anon`, while for `authenticated` it narrowed privileges
  PER COLUMN on each existing table individually. So for anything new there is
  only one order: first `revoke all … from anon, authenticated`, then grant
  exactly the needed columns. Functions are worse: the default `execute` makes
  EVERY one of them a PostgREST endpoint, including helper predicates that were
  meant to be internal. The same default is why a per-column grant added
  without a `revoke` narrows nothing and just lands on top of what's already
  granted for the whole table.
- **A subquery against the table's OWN self inside its policy is not "an extra
  filter" but 42P17 `infinite recursion detected in policy`.** With
  `blocked_users` ("RLS applies to subqueries", above) it was a hole: the
  subquery silently returned a narrower result than expected. Here it's
  `room_messages`: a bare `EXISTS (SELECT 1 FROM room_messages …)` inside its
  own INSERT policy (the "`reply_to_id` is from this same room" check,
  20260911100000) broke ANY insert into the table, including rows without a
  `reply_to_id` at all: RLS compiles the subquery plan at the query level, not
  per row, so it didn't depend on a particular row's value. It's noticeable
  immediately — the app can't write to the table at all — but it had already
  managed to take down all message sending in prod once. The cure is the same
  trick as for `blocked_users`: move the check into a `security definer`
  function (`room_message_in_room()`), inside which RLS doesn't apply at all.
  Rule: as soon as a policy on table T refers to T itself — whether as a row
  or a subquery — that reference belongs only inside a `security definer`.
- **Realtime doesn't replay what was missed, and the socket drops every time
  the app goes to the background.** Postgres Changes is a stream, not a
  journal: a subscriber gets what happened while it was subscribed. Meanwhile
  `supabase_flutter` itself drops the socket on `AppLifecycleState.paused` and
  reconnects on `resumed`, so a disconnect isn't an edge case but what happens
  on every switch between apps. Which means **any** screen on a subscription
  must be able to catch up on what it missed, otherwise it shows the state as
  of going to the background and stays silent. The room chat didn't have this:
  loading only knew the `before` cursor, i.e. older pages, and what was said
  while in the background never appeared — until the screen was closed and
  reopened. Deletions got lost too: a deletion arrives as an edit of an
  existing row, not an insert. Ask not "is the screen subscribed", but "what
  will it show if the subscription stays silent for ten minutes".
- **A channel buffers what was sent before join, and delivers it BEFORE the
  `subscribe` callback.** The hook that flushes `_pushBuffer` is attached by
  `RealtimeChannel` in its own constructor, while the callback from
  `subscribe()` is registered afterwards — and they're called in registration
  order. So "announce state on join" overwrites whatever the user managed to do
  while the channel was coming up: in rooms, `track({typing: false})` in the
  callback cleared the just-raised "typing…", and by then the screen already
  considered the announcement made and didn't repeat it on any subsequent
  keystroke. State announced on join must be asked of whoever knows it, not
  assumed. And remember that the callback is called on EVERY join, including
  reconnects after the background.
- **Riverpod refuses to modify a provider from any widget lifecycle method** —
  `build`, `initState`, `didChangeDependencies`, `didUpdateWidget`,
  `deactivate` and `dispose` alike ("Tried to modify a provider while the
  widget tree was building"). Deferring to `Future.microtask` from `dispose` is
  no way out either: by the time it runs, the container may already be gone.
  The working form is `addPostFrameCallback` from `deactivate()` on a container
  captured in `initState` (see "A refresh that outlives its screen" in
  [docs/client-architecture.md](docs/client-architecture.md)), with a `catch`
  for the case when the whole `ProviderScope` is torn down in the same frame.
- **`State` inside a lazy list item doesn't survive an index shift.** Slivers
  don't reorder elements by key the way a regular multi-child element does:
  `SliverMultiBoxAdaptorElement` updates a slot by index, and if the key
  doesn't match, the old element is torn down and a new one is built from
  scratch. Only `findChildIndexCallback` helps, and `ScrollablePositionedList`
  doesn't pass it through. So inserting at the start of the chat destroyed the
  `State` of every visible bubble, and the signed photo URLs that lived in that
  `State` were signed again — once per bubble, for every message. Adding keys
  doesn't fix this, it makes it worse. Rule: anything expensive to obtain must
  live not in a list item's `State` but in a cache that outlives that `State`.
- **`SelectionArea` doesn't insert a separator between adjacent selectable
  widgets, and a `\n` inside a single `TextSpan` is not a cheap way to add
  one.** Verified empirically (with a widget test simulating drag-select and a
  tap on "Copy" in the toolbar, not by guesswork): a selection across several
  consecutive `Text`/`Text.rich` is copied as one fused string, with no space
  and no line break. Adding `\n` as the last span inside your own paragraph
  doesn't work for two independent reasons: (1) any extra line in `Text.rich`
  costs a whole extra line height — the height doesn't depend on that
  particular run's `fontSize` at all (checked at 0/1/4/8/16 — always the same
  height as the first line); (2) a `\n` that is the very last character of the
  selectable content is silently trimmed on copy, i.e. it wouldn't even show up
  in the result. The working combination: an invisible marker (`​`,
  added as the last span — it has no width or height, unlike `\n`) at the end
  of each message's text, plus a custom `contextMenuBuilder` on
  `SelectionArea` which, after the stock press of the "Copy" button, reads
  `Clipboard.getData` once more and replaces the marker with a real `\n`
  before putting it back. On mobile, copying goes through a tap on the toolbar
  button (`SelectableRegionState._copy()`), not through `Actions`/`Intents` —
  an override of `CopySelectionTextIntent` higher up the tree intercepts only
  Ctrl+C/Cmd+C and won't fire one bit on a real toolbar tap, so the fix goes
  through `contextMenuBuilder`, not `Actions`. Example —
  `_messageSeparator`/`_chatSelectionToolbarBuilder` in
  `app/lib/features/rooms/room_chat_screen.dart`.
- **`revoke ... from anon, authenticated` doesn't remove a grant given to
  PUBLIC.** `create function` in PostgreSQL grants EXECUTE to **PUBLIC** by
  default, and PUBLIC includes `anon` and `authenticated`. So listing the two
  roles by name closes the function only in appearance, and there's nothing to
  notice it by: a `revoke` from a role that never had the privilege passes
  silently, without a single NOTICE. That's how 20260913100000 "closed" six of
  its functions, and four of them answered anonymous callers until
  20260924100000 — including `is_write_banned(uuid)`, i.e. the moderation
  decision about any account by its uuid, available to anyone who has the
  app's public key (and it's baked into the APK). The baseline writes the
  correct form — `from public, anon, authenticated` — so this was a missed word
  in one migration, not ignorance.
  The same slip one level up also explains why it wasn't caught: the baseline
  runs `alter default privileges ... revoke all on functions from anon` and its
  comment considers the matter closed, but the default for functions is
  granted to PUBLIC, and that line didn't touch it. Both lines are there now
  (`from public` and `from authenticated`), so a new function is closed by
  default, and a forgotten `grant` breaks the feature loudly (42501) instead of
  quietly opening it.
  Check with privileges, not the ACL text: `has_function_privilege('anon', oid,
  'execute')` — reading `proacl` by eye is exactly what lets you down here,
  because PUBLIC shows up in it as a nameless `=X/postgres`.
- **A policy expression runs as the CALLING role.** So every function named
  directly in `using`/`with check` must have EXECUTE for `authenticated`,
  otherwise the policy is rejected with 42501 and the feature stops entirely.
  Nested calls inside a `security definer` function don't fall under this
  rule — they already run as the owner, and that is exactly why the closed
  `are_connected`/`has_muted`/`is_post_visible` work. This nearly broke all
  attachments in chats: `room_message_media_visible()` is used in the
  `storage.objects` SELECT policy and relied precisely on the PUBLIC grant, so
  "closing an unneeded endpoint" would have switched them off for everyone. Get
  the list from `pg_policies` with a query, not from memory; 20260924100000 has
  a check for this.
- **`<>` with `auth.uid()` yields NULL, not true, when the server writes.** For
  service_role (console, cron, migration) `auth.uid()` is NULL, and the branch
  `if v_author is null or v_author <> auth.uid() then return new` didn't fire:
  `false or NULL` is NULL, i.e. "not our business" didn't execute, and the
  function went on to check the ban of the author of SOMEONE ELSE'S row.
  `is distinct from` is right in both directions at once. While the trigger
  was only on INSERT, what saved it was that only one system account writes
  that way, and it isn't banned.
- **"Write" is not just INSERT.** `reject_write_when_banned` sat on seven
  BEFORE INSERT triggers, and a banned user couldn't create a new post but
  could rewrite the text of any of their old ones (`grant update (text)` on
  `posts`) and change their name (`grant update (name)` on `users`). A ban
  that doesn't prevent rewriting is a delay, not a ban. Ask not "where does
  the row come from", but "which commands can change its contents", and
  cross-check with the per-column grants. Update triggers must be per-column
  (`before update of text`): a full BEFORE UPDATE on `users` would have taken
  away from a banned user the ability to delete their own photo, because that
  rewrites `avatar_path` via the sync trigger.
- **A shared body for all tables finds the author by column name, and `users`
  doesn't have one.** `reject_write_when_banned` takes the author from NEW via
  `coalesce(author_id, user_id, owner_id, requester_id)`, while in
  `public.users` the row's author is its primary key `id`. The trigger fired,
  found no author and exited as "the server is writing", i.e. a name change
  under a ban remained allowed. An unconditional `id` as the fifth element of
  the chain would have been worse: `posts`, `comments` and `rooms` have an
  `id` too, and there it isn't a person — so the branch is conditional on
  `tg_table_name`. Caught by a probe in a transaction with `rollback`, not by
  reading the code: the migration applied, the migration's checks passed, and
  only the behavioral probe showed that the item didn't work.
- **git merges a duplicate YAML key without a conflict, and YAML silently
  keeps the last one.** Two branches each added their own `analyzer:` key to
  `app/analysis_options.yaml` — one with `exclude:` for
  `build/`/`android/`/`ios/` (`flutter build ios` itself appends it), the other
  with `language:`/`errors:` with strict modes. The lines differ, there are no
  overlapping regions, so the merge went through cleanly and the file became
  syntactically valid — with two `analyzer:` in a row. One would win, i.e.
  either the excludes or the strict modes would be quietly switched off, and
  `flutter analyze` would keep answering "No issues found". Hence a rule wider
  than one file: **after merging configs where a top-level key can repeat
  (YAML, TOML, `.plist`), look at more than the conflict markers.** A clean
  automerge of a config is not the same as a correct automerge. Checked with
  one line: `grep -c '^analyzer:' app/analysis_options.yaml` must answer `1`.
- **`[ "$x" -le "$y" ]` on a non-number is not false but a usage error.** `[`
  writes `Illegal number` to stderr and returns 2, and inside an `if`
  condition any non-zero code reads as "false", and `set -e` doesn't reach
  there. That is, the check doesn't just fail to fire — it leads into the
  "all good" branch. `scripts/verify-version.sh` did exactly that:
  `version: 0.18.13+` gives an empty `${v##*+}`, the old pattern
  `*[!0-9:]*|:*` didn't catch it (no non-digits, no colon at the start), and
  the only check that guarantees a PR carries a build number printed
  `Version check passed` for a version with no number at all. The fix is not
  adding yet another "what can go wrong" pattern but enumerating what's
  allowed for each value separately (`'' | *[!0-9]*`).
  In general: **in shell, validate before comparing, not by comparing** — a
  comparison has no way to say "the input is wrong".
