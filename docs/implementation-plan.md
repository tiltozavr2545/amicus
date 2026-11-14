# Implementation plan: Amicus (formerly "Круг", "Circle") (MVP)

A step-by-step plan for implementing the MVP from [project-brief.md](project-brief.md), with CI and deployment built into the stages rather than postponed to the end. The project is mobile-first (Android; iOS via Flutter is deferred — see [future-development.md](future-development.md)), web is out of scope.

**This document is historical.** The MVP is done, all five stages are complete; below is how it went, not how everything works now. The current state of the schema is in [data-model.md](data-model.md), operations are in [operations.md](operations.md), what shipped in which version is in [../CHANGELOG.md](../CHANGELOG.md). Notes like "later narrowed/replaced" are placed where reality has since moved on.

## Progress

- [x] Stage 0 — Setup + CI skeleton
- [x] Stage 1 — Auth + profile
- [x] Stage 2 — Connections
- [x] Stage 3 — Main feed
- [x] Stage 4 — Reactions and comments
- [x] Stage 5 — Polish + deployment (Android; iOS deferred)

**The MVP (0.1) is fully implemented and deployed.** Further work follows [future-development.md](future-development.md).

---

## Stage 0 — Setup + CI skeleton

**Status:** done

1. ✅ Flutter SDK installed — **version pinned to 3.32.8**: the latest (3.44.x) requires macOS 14+, and this machine runs macOS 12.7.6 (Monterey). Newer versions can't be installed until macOS is upgraded. The SDK lives in `~/development/flutter`, added to PATH via `~/.zshrc`.
   - ✅ Android toolchain: Android Studio + cmdline-tools installed, licenses accepted, `flutter doctor` is green for Android.
   - ⏸️ Xcode: not installed — decided to do Android only first, iOS deferred until macOS is upgraded (see future-development.md).
2. ✅ `flutter create --platforms=android,ios` in `app/` (org `com.github.tiltozavr2545`), added `supabase_flutter`, `go_router`, `flutter_riverpod`, `cached_network_image`.
3. ✅ Supabase: project `lk-system` created, Auth (email/password) enabled, Storage bucket `media` created (private, access policies to be set up in Stage 1/3). (Later the bucket was also created by a migration so the project can be built from the repository from scratch — 20260822260000.)
4. ✅ `.env` filled in (`SUPABASE_URL`, `SUPABASE_ANON_KEY` — the Publishable key is used), in `.gitignore` (with an exception for `.env.example` as a template).
5. ✅ GitHub repository: [github.com/tiltozavr2545/amicus](https://github.com/tiltozavr2545/amicus) (public).
6. ✅ CI: `.github/workflows/ci.yml` — `dart format`, `flutter analyze`, `flutter test` on every push/PR, the first run passed.

## Stage 1 — Auth + profile

**Status:** done

1. ✅ Sign-up/sign-in screens (`sign_in_screen.dart`, `sign_up_screen.dart`) via the Supabase Auth SDK; go_router with a redirect based on auth state (`router.dart`).
2. ✅ `users` table created by a migration, RLS: read — any authenticated user, insert/update — own row only (`auth.uid() = id`). (Read was later, in 0.4.0, narrowed to "own row OR my Connection" — see CHANGELOG.md.)
3. ✅ Profile screen: editing the name, picking and uploading an avatar to the private `media` bucket (`avatars/{user_id}/...`), displayed via `storage.download()` — the SDK adds the access token itself, manual signed URLs weren't needed. (The Storage SELECT policy for avatars was later, in 0.5.0, also narrowed to Connections — see CHANGELOG.md.)
4. ⏸️ A CI job for checking migrations (`supabase db push --dry-run` in the pipeline) — **not done**, deferred. Migrations are applied manually; at the time of this stage — via the Supabase CLI, later switched to the Management API (`POST /v1/projects/<ref>/database/query`) with a token that is provided for the duration of a task and never stored — the current procedure is in the "Working conventions" section of [../AGENTS.md](../AGENTS.md). For a solo project this is acceptable; if it becomes painful — add the token to GitHub Secrets and set up the job.

Secrets are passed into the app via `--dart-define-from-file=.env` (not `flutter_dotenv`) — this way `.env` doesn't need to be declared as a Flutter asset, and CI (`flutter analyze`/`flutter test`) doesn't break because the secrets file is missing.

## Stage 2 — Connections

**Status:** done

1. ✅ `invite_links` table (code, owner_id, is_used), the code is generated on the server (`create_invite_link()`, hex from `gen_random_bytes`), not on the client.
2. ✅ "Connections" screen (`connections_screen.dart`): create/copy your own code, enter and activate someone else's.
3. ✅ RLS: `connections`/`invite_links` have no insert/update policies for regular users — writes go only through the security-definer functions `create_invite_link()`/`activate_invite_link()`, which makes "mark as used + create connection" an atomic operation. The `user_a_id < user_b_id` check + a unique constraint rule out duplicates and self-connections at the schema level.
4. ✅ Manual test on two accounts — passed on a physical device (Nothing Phone, USB debugging). The full cycle (sign up two users → code → activation → check `connections`/`invite_links`) worked cleanly.
   - During the test we found and fixed two real bugs: (a) `router.dart` read the auth status through a cached Riverpod provider that lost a race with the separate `_GoRouterRefreshStream` subscription — sign-in/sign-out didn't redirect live, only a full app restart helped; now the redirect reads `currentSession` directly from the client; (b) creating the profile on sign-up failed under RLS when email confirmation hadn't been completed yet (no session → no `auth.uid()`) — moved the creation of the `users` row into the `handle_new_user()` trigger on `auth.users`, which doesn't depend on a session.

## Stage 3 — Main feed

**Status:** done

1. ✅ `posts` table (`posts.author_id` references `public.users`, not `auth.users` — so PostgREST can embed `.select('*, author:users(name)')` in a single query), a post creation screen (text + photo), upload to the private `media` bucket (`posts/{author_id}/...`).
2. ✅ RLS on `posts`: SELECT — the author or their Connection (the same logic as in `activate_invite_link`, but as a regular policy, not a function — no atomicity needed); Storage policies for `posts/...` mirror the same condition.
3. ✅ Feed: pull-to-refresh + infinite scroll (keyset pagination on `(created_at, id)`, 20 posts at a time — a cursor on the last post instead of a `range()` offset, so that inserting/deleting posts at the top between pages doesn't cause duplicates/gaps; the pure function `keysetFilter()` in `feed_repository.dart` is covered by unit tests). Photos — via `createSignedUrl` (the bucket is private), the URL lives 24 hours. (It was assumed to be stable and therefore fit for a cache key; in fact it is reissued on every visit, which caused photos to be downloaded again — in 0.14.0 the Storage path became the cache key, see CHANGELOG.md.)
4. ✅ Manually tested on a device: publishing with and without a photo, visibility by Connections is correct.
   - Found and fixed a bug: `RefreshIndicator` didn't trigger on a non-empty feed — the default scroll physics doesn't allow pulling if the content doesn't overflow the screen. Added `AlwaysScrollableScrollPhysics`.
   - Based on feedback: added a "My connections" list to the Connections screen (this required switching `connections.user_a_id`/`user_b_id` to FKs to `public.users` instead of `auth.users` — just as was done earlier for `posts`, so the embed works on both sides of the connection). The button to go to Connections moved from the profile to the feed (it's now the landing screen, the profile is at `/profile`).

## Stage 4 — Reactions and comments

**Status:** done

1. ✅ `reactions` table (post_id, user_id, `unique(post_id, user_id)` — a repeated like is impossible at the schema level).
2. ✅ `comments` table (post_id, author_id, text), an index on `post_id`; `author_id` references `public.users` — embedding the author's name in a single query, as with posts.
3. ✅ RLS: instead of duplicating the "author or Connection" logic, the `reactions`/`comments` policies simply check `exists (select 1 from posts where id = post_id)`; since `posts` already has its own RLS, the subquery run as the current user automatically returns a row only if the post is visible. Nothing to fix in three places if the post visibility rules change.
4. ✅ Like — a toggle with an optimistic UI update (the icon/count changes immediately, rolled back on a network error). Comments — a separate screen, a flat list.
5. ⏸️ Supabase Realtime — not added, as planned (not required for the MVP).
6. ✅ Manually tested on a device: like/unlike, comments, counts — all correct.

The comment count on a feed page was computed with a batch query (`comments` with `post_id in (...)`), not one query per post; since 0.16.x it's `comment_summary(uuid[])` — `security invoker`, so RLS does the filtering itself, and one row per post goes over the wire rather than one per comment. Since 0.4.0 reaction counts arrive in a single call to the `security definer` function `reaction_summary(uuid[])` (numbers + your own reaction, without other people's `user_id`) — previously this was also a batch query on `reactions`, but it exposed who reacted with what.

## Stage 5 — Polish + deployment (mobile-first)

**Status:** done (Android). iOS was deliberately deferred beyond the MVP — see [future-development.md](future-development.md).

1. ✅ Signing config (keystore, `android/key.properties`, not in the repository) + `.aab` build.
2. ✅ Google Play Console — the app is published. (Started with Internal Testing; now releases go to Closed testing, the `alpha` track.)
3. ✅ Empty states (no posts/no connections/no comments) — strings `noPostsYetMessage`/`noConnectionsYetMessage`/`noCommentsYetMessage` in `app_en.arb`/`app_ru.arb`.
4. ✅ README with a description and screenshots.
5. ⏸️ Demo video — deliberately decided not to make one.

CI/CD for builds remained a manual process at the time of this stage. It was later automated without Fastlane/Codemagic: a push to `main` triggers `deploy-closed-testing.yml`, which verifies, builds a signed `.aab` and uploads it on its own — see [operations.md](operations.md).

Minor polish of error handling (don't show raw exception text to the user) — closed in 0.9.1, see CHANGELOG.md.

---

## Default technical decisions

Moved to [client-architecture.md](client-architecture.md): that list is live —
it's what the project is built with now — while this document is historical,
and keeping a reference here that is supposed to be updated would mean
promising accuracy where there is none.
