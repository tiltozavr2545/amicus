# Changelog

Amicus version history. Moved out of CLAUDE.md/AGENTS.md so that they are not
loaded into context in full on every session — here it is read on demand, when
it is actually needed.

For **why** a particular decision was made this way, look not here but at the
comment in `supabase/migrations/` (it sits next to the code) or at `git log`.
Migration numbers before `20260826000000` are file names in the
`pre-baseline-migrations` tag, where the history was squashed out of the
repository: `git show pre-baseline-migrations:supabase/migrations/<version>_*.sql`.
Numbers from `20260826000000` to `20261010100000` are in the
`pre-baseline-migrations-2` tag (the second squash, 2026-10-18).
Here: the chronology and what appeared in which version.

Everything listed was done out of order relative to the step-by-step plan
(`docs/implementation-plan.md`) — a deliberate deviation, see the same place.

The first code audit (before 0.4.0) — a full review of the project (RLS, Storage
policies, the client, secrets, the entire git history) came back clean: no
critical holes, no secrets in the repository or in git history, the
`service_role`/secret key is not used in the client, the anon key is public by
design. Strong points — `security definer` + `set search_path` on functions,
`for update` against the race on invite activation, the canonical pair order,
`revoke execute … from anon`, the size limit + MIME allow-list,
`enable_anonymous_sign_ins = false`, email confirmation, `additional_redirect_urls = []`.
Below is what the audit did find after all and what was closed by the following versions.

Added out of order (before Stage 5, a deliberate deviation from the step-by-step plan):
- deleting your own posts and comments (0.2.0) — DELETE RLS policies on `posts`/`comments`/post photos + confirmation in the UI, release [v0.2.0](https://github.com/tiltozavr2545/amicus/releases/tag/v0.2.0);
- several reaction types (0.3.0) — instead of a single like, three mutually exclusive reactions 👍/😐/👎: a `type` column in `reactions` (`like`/`neutral`/`dislike`, the `(post_id, user_id)` uniqueness stayed — one reaction per post) + an UPDATE RLS policy for changing a reaction, upsert in the repository, each reaction has its own counter, tapping again removes it.
- data visibility privacy (0.4.0) — narrowed two broad read RLS policies, closing two items from the "Security and privacy" section of future-development.md: (1) profiles (`users`) are now visible only to yourself and your own Connections instead of `using(true)` — previously any logged-in user could enumerate the whole address book; (2) reactions — SELECT only of your own rows, while the real per-post counter is served by the `security definer` function `reaction_summary(uuid[])` (only numbers + your own reaction, no other people's `user_id`), so "who reacted with what" no longer leaks, and the counter stays a true total. Migration `20260712100000_scope_profile_and_reaction_visibility.sql`.
- "Known for N days/months/years — since DD MMM YYYY" (0.5.0) on the Connections screen — a label under each connection's name, computed from the `created_at` of the `connections` row (it was already being read for sorting, it just wasn't passed further before). A purely client-side feature: no migrations or RLS, covered by unit tests for pluralization (день/дня/дней etc.) and for the date format. Originally implemented by hand — its own `_pluralize()` function in `connection_duration.dart` and a global `Intl.defaultLocale = 'ru'` in `main.dart` (at the same time we found and fixed a bug: `DateFormat` without an explicit locale did not pick up `ru` on a real device, months came out in English). In 0.7.0 this manual logic was fully replaced by the official Flutter localization — see below.
- Connection avatars on the Connections screen (0.5.0) — previously the list showed only the `Icon(Icons.person)` placeholder for everyone. `Friend` now carries `avatarPath` (from `users.avatar_path` via a join), and the shared `avatarBytesProvider` (a family by path, `keepAlive` on a successful result — doesn't re-download when returning to the screen) in `profile_repository.dart` is genuinely reused by the profile screen and the connections list (the profile screen was moved onto it, its own separate provider was removed). `uploadAvatar()` writes a unique file name on every upload (the old file is deleted best-effort), so changing the photo changes the path → the cache resets itself, no sticking. The Storage policy on the `media` bucket was narrowed in 0.5.0: an avatar is visible only to yourself and your own Connections (migration `20260712120000_scope_avatar_storage_visibility.sql`, replaces the broad `20260707222025`).
- Password reset (0.6.0) — the "Forgot password?" link on the sign-in screen leads to `ForgotPasswordScreen` (`/forgot-password`), which calls `auth.resetPasswordForEmail()`. The same approach as with email confirmation (see the deep link note above): since a deep link into the app is not set up, the email leads to a separate interactive page `reset-password.html` on the same GitHub Pages (`gh-pages`, next to `index.html`) — it reads `access_token`/`refresh_token` from the URL itself through the Supabase JS SDK, calls `setSession()` and lets the user enter a new password (`auth.updateUser()`), without reading RLS tables and without persisting the session in `localStorage` (`persistSession: false`). The page URL was added to `additional_redirect_urls` in `supabase/config.toml` and applied to the live project through the Management API.
  An important detail: `Supabase.initialize()` in `main.dart` now explicitly sets `authFlowType: AuthFlowType.implicit` instead of the default PKCE. PKCE works in such a way that only the client that originally stores the code verifier (the phone) can exchange the `code` from the link for a session — not the browser where the link from the email actually gets opened. Implicit flow puts `access_token`/`refresh_token` right into the URL, so `reset-password.html` can read them itself. Email confirmation is not affected — that page doesn't read tokens at all, the confirmation is counted on the server before the redirect. Verified end-to-end on a physical device: requesting the link → the email → `reset-password.html` → new password → sign-in.
- Bottom navigation (0.6.0) — a shared bottom `NavigationBar` (modeled on Instagram) with four items: Feed / Connections / New post / Profile. Previously, transitions between the feed, connections and profile went through buttons in the `AppBar`, and post creation went through a `FloatingActionButton` on the feed; now all entry points are gathered in one place. `router.dart` wraps the three tabs (`/`, `/connections`, `/profile`) in a `StatefulShellRoute.indexedStack` (`MainShellScreen`) — when switching, a tab keeps its own scroll/form state, unlike a plain `push`. "New post" is not a tab but a modal screen (`CreatePostScreen`), opened on top of the shell by the button in the bar; so that the feed refreshes even when its screen is not active at the moment of publishing, `feedRefreshTickProvider` was added — a counter notifier that the feed subscribes to via `ref.listen`. A purely client-side feature: no migrations or RLS. Verified manually on a physical device: switching all the tabs preserves state, the modal post screen opens and correctly returns to the tab it was opened from. (Both 0.6.0 features — password reset and bottom navigation — were deployed to Google Play; a separate GitHub release/`v0.6.0` tag was not created for this version, unlike 0.2.0–0.5.0/0.7.0/0.8.0.)
- Localization (0.7.0) — closed the "Localization (i18n)" item from future-development.md: the interface was translated into English (the default language), Russian is shown only if the system locale is Russian. Official Flutter tooling rather than a home-grown one: `flutter_localizations` + `intl`, `l10n.yaml` (`arb-dir: lib/l10n`) generates `AppLocalizations` from `lib/l10n/app_en.arb`/`app_ru.arb` (`flutter gen-l10n`, enabled via `generate: true` in `pubspec.yaml`). `MaterialApp.router` in `app.dart` declares `localizationsDelegates`/`supportedLocales: [en, ru]` without an explicit `locale:` — Flutter itself takes the first matching system locale from the list, otherwise the first one in the list (en), and this gives the desired "default" behavior. `connection_duration.dart` (pluralization of "Known for N days" / "Знакомы N дней/месяцев/лет" (Russian: "Known for N days/months/years")) was moved to ICU plural forms right in the ARB — the `one/other` categories for English and `one/few/many/other` for Russian are handled by the `intl` package itself, the old manual `_pluralize()` function is no longer needed. `DateFormat` everywhere (feed, comments, connections) now gets the locale explicitly from `AppLocalizations.localeName` instead of the old global `Intl.defaultLocale = 'ru'` in `main.dart` — there, `initializeDateFormatting()` is now called for each locale from `AppLocalizations.supportedLocales` instead. The unit tests `connection_duration_test.dart` and the widget tests of the sign-in/sign-up/password-reset screens were updated and check both locales explicitly (via `AppLocalizationsEn()`/`AppLocalizationsRu()`, without depending on the test environment's system locale). Verified on a physical device by switching the system locale between `ru-RU` and `en-US` without reinstalling: the feed, Connections (including the correct pluralization "день/дня/дней" and "day/days" on real connection data), "New post", the profile — correct text in both languages with no regressions.
- Dark theme (0.8.0) — closed the "Dark theme" item from section 1.0 of future-development.md: a light/dark toggle in the `AppBar` of each of the three main tabs (Feed/Connections/Profile), on the side opposite the title — a reusable `ThemeToggleSwitch` (`lib/theme/theme_toggle_switch.dart`). The state is a Riverpod `NotifierProvider<ThemeModeNotifier, ThemeMode>` (`lib/theme/theme_mode_provider.dart`): by default `ThemeMode.system` (the app theme = the device's system theme, `MaterialApp.router` in `app.dart` got a `darkTheme` variant of the same `ColorScheme.fromSeed`), and after the first tap on the toggle the choice is fixed explicitly (`ThemeMode.light`/`ThemeMode.dark`, computed from the current system brightness at the moment of the tap) and survives an app restart via `shared_preferences`. A purely client-side feature: no migrations or RLS. The tooltip string is localized (`darkThemeToggleTooltip` in both ARBs). Verified on a physical device: on first launch the theme matches the system one, manual switching with the toggle works on all three tabs and persists after restarting the app.
- Bugfixes and minor hardening (0.8.1) — a batch of fixes with no change in functionality, found by a code review: (1) sign-up and the profile reject an empty name (`nameRequiredError` in both ARBs), the server fallback `'Без имени'` ("No name") in `handle_new_user()` is also fixed for the case of a direct API call bypassing the client (`coalesce(nullif(trim(...), ''), ...)`, migration `20260714120000_fallback_empty_display_name.sql`); (2) invite activation on an empty code shows a clear error (`inviteCodeRequiredError`) instead of the raw "Invite code not found", and `activateInviteLink()` in `connections_repository.dart` no longer throws a `StateError` on an empty RPC response; (3) the feed was moved from offset pagination (`range()`) to keyset (a cursor on the last post, `(created_at, id)` in `feed_repository.dart`) — inserting or deleting a post at the top between page loads no longer produces duplicates/gaps; the pure function `keysetFilter()` is covered by unit tests; (4) `_refresh()`/`_loadMore()` in the feed (`feed_screen.dart`) are protected by a `_loadEpoch` counter against a race between pull-to-refresh and an in-flight load; the rollback of an optimistic reaction and the post deletion look up the record by `id`, not by a captured `index`, which could have shifted during the `await`; (5) `setState` after `dispose` is guarded by `mounted` checks in the feed, comments and connections; (6) the file extension for a photo/avatar is taken by the safe helper `fileExtension()` (`lib/shared/file_extension.dart`) instead of `name.split('.').last`, which returned garbage for a file with no dot in its name; (7) `ColorScheme.fromSeed` for both themes in `app.dart` was moved into top-level constants instead of being recomputed on every rebuild of `KrugApp` — the heavy cross-fade animation of the theme switch no longer stuttered in a debug build. Verified manually on a physical device (debug and profile) across all the listed scenarios — no exceptions in the log.
- Mute and block of a connection (0.9.0) — on the Connections screen each connection has two reversible buttons that do not break the Connection record itself: mute (I stop seeing their posts in the feed, they still see mine) and block (mutual hiding of posts in both directions). Both tables are new and symmetrically designed: `muted_users (muter_id, muted_id)` and `blocked_users (blocker_id, blocked_id)`, RLS — access only to your own rows; separate tables rather than a general "relation type", because the visibility semantics differ (one-way vs mutual). Post visibility, as before, is entirely up to RLS — the `posts` SELECT policy was extended with mute/block conditions, `feed_repository.dart`/`feed_screen.dart` were not touched. Migration `20260715120000_add_muted_and_blocked_users.sql`. Mute and block ask for confirmation through the same `AlertDialog` pattern as deleting a post/comment (muting/blocking is an action that is potentially unexpected for the other side); undoing — unmute right on the Connections screen, unblock on the new "Blocked" screen (`blocked_users_screen.dart`, opened by a button in the `AppBar` of Connections), both without a dialog, in a single tap.
  A bugfix the same day, found during a manual check on two live accounts (mute worked, block didn't): originally the block check in the `posts` policy was an inline `not exists (... from blocked_users where (blocker_id=auth.uid() and blocked_id=author) or (blocker_id=author and blocked_id=auth.uid()))` — but this subquery is itself subject to the `blocked_users` RLS policy (`blocker_id = auth.uid()`), and the second OR branch (which needs to see a row where `blocker_id` is the post's author, not the caller) was silently filtered out before the OR was even evaluated. As a result, the blocked person still saw the posts of whoever had blocked them (mute was unaffected — its check is always self-referential on `muter_id = auth.uid()`, which satisfies the `muted_users` RLS anyway). Fixed following the `reaction_summary()` pattern — moved into a `security definer` function `is_blocked_pair(uuid, uuid)`, which reads `blocked_users` with the function owner's rights, bypassing the per-row RLS check, and returns only a boolean. Migration `20260715150000_fix_mutual_block_visibility_check.sql`. Verified on the live schema by simulating RLS through the Management API (`set local role authenticated` + `set_config('request.jwt.claims', ...)`) in both directions — before the fix the blocked person saw 2 posts of the blocker, after the fix they see none, while the regular feed by Connections was unaffected. After the fix the user confirmed manually on two live accounts on a physical device: mute and mutual block both work correctly.
- Text length limit and hiding raw errors (0.9.1) — closed the "Minor hardening" item from the "Security and privacy" section of future-development.md: (1) post and comment text is now limited to 5000 characters both on the client (`maxLength: 5000` on the `TextField` in `create_post_screen.dart`/`comments_screen.dart`, with the built-in Flutter character counter) and on the server (`check (char_length(text) <= 5000)` on `posts.text`/`comments.text`, migration `20260716120000_add_post_comment_text_length_limits.sql`) — previously there was no limit in either place; (2) error messages on all screens where they were shown (sign-in/sign-up/password reset, feed, connections, blocked, comments, profile) stopped showing the raw exception text (it used to be `"Failed to load feed: $e"`) — replaced with generic localized wording (`"Failed to load feed. Please try again."`), the `{error}` placeholder was removed from the corresponding strings in both ARBs and from the generated `AppLocalizations*`. A purely client-side UI fix + one DB migration, with no RLS change. Verified: the server constraint was confirmed by a direct SQL query against the live DB through the Management API (both checks are in place, the migration is recorded in `supabase_migrations.schema_migrations`, a repeated `supabase db push` won't duplicate it); hiding of the raw error was verified on a physical device by turning off the network while publishing a post — the generic message was shown instead of the raw exception.
- Nested comments (0.10.0) — closed the "Nested comments" item from section 1.0 of future-development.md and, along with it, the old open question "do we need threads": every comment has a "Reply" button, replies are drawn indented under their root. Nesting is **exactly one level** (as on Instagram/YouTube): a reply to a reply goes into the same thread rather than a third level, and who it is addressed to is shown by an "In reply to: Name" label (only when the addressee is not the thread's root itself, otherwise it would be noise). So the indents don't run off the screen, and reading stays a single flat query with no recursion.
  Schema (migration `20260725120000_add_nested_comments.sql`): an important discrepancy with the documentation — `parent_comment_id`, which the brief and future-development.md claimed was "already provisioned in the schema for the future", was **absent** from the real MVP schema (it remained only in the data model draft), so the column was added from scratch. Three were added in total: `parent_comment_id` — the thread root (`on delete cascade`), `reply_to_id` — the reply addressee, for the label only (`on delete set null`), `deleted_at` — the tombstone marker; plus an index on `parent_comment_id`. Storing the root separately from the addressee is exactly what makes it possible not to recurse on read: `order by created_at` + grouping by `parent_comment_id` on the client.
  Depth and consistency cannot be expressed as a check constraint (they depend on another row), so this is the trigger `enforce_comment_reply_rules()` — and it is `security definer`, like `is_blocked_pair()`: the `comments` SELECT policy is narrowed to your own Connections, and a subquery under RLS on an invisible parent would return "no rows", which would be read as "the parent is a root" and allow bypassing the depth limit with a direct API call. The trigger checks: the parent exists, belongs to the same post, is itself a root, is not deleted; the addressee is within the same thread and not deleted; a root comment has no `reply_to_id`.
  Deletion: a comment **with replies** turns into a tombstone (`deleted_at` + the text is actually wiped, the row lives on so the thread stays readable), **without replies** — it is really deleted, as before. The decision is made on the server in the `security definer` function `delete_own_comment()`, not by policies, because the hard/soft choice must be atomic and because the alternative (an UPDATE policy on `comments`) would have given the client the ability to edit comment text, which is deliberately not a feature. The DELETE policy from 0.2.0 was **dropped** in the process: with it the client could bypass the RPC and hard-delete a root, taking other people's replies along by cascade. Replying to a tombstone is impossible both in the UI and on the server.
  Client: the pure function `threadComments()` (`comment_thread.dart`) builds the display order and cuts out two things — a reply whose root is not visible (the root's author is not my Connection: RLS returned the reply but not the parent, and showing it as a root would tear it out of context, so the whole thread is hidden) and a tombstone under which no visible replies remain (it is only needed to hold the thread). The comment counter on a post in the feed is untouched — it counts everything, including replies (`feed_repository.dart` was not changed here).
  A bugfix the same day, found during a manual check on the device (a reply to a reply was drawn **above** what it replied to): `order()` in postgrest-dart defaults to `ascending = false`, while `fetchComments()` had just `.order('created_at')` — meaning comments had been coming from newest to oldest since the MVP; in a flat list this looked like "newest on top", while in threads it gave a reversed order within the thread. Fixed with an explicit `ascending: true` + `id` as a tiebreaker, and in addition the order itself is now guaranteed by `threadComments()`, not by the query — a regression test with a reversed input rests on this. Side effect: root comments now go oldest on top (like in a conversation), not newest on top.
  Verified: the migration was applied to the live DB through the Management API and checked by simulating RLS (`set local role authenticated` + `request.jwt.claims`, all inside a transaction with `rollback`) — 12 checks, including the rejections "depth 2", "addressee from another thread", "parent from another post", "reply to a tombstone", "deleting someone else's comment", "direct UPDATE of a comment" (0 rows — there is no policy), and that deleting a root with replies yields a tombstone with a live reply, while deleting a leaf yields a real delete. Then manually on a physical device: threads, the label, both kinds of deletion, the counter, the English locale.
  Known adjacent holes found at the same time: (1) the mute/block from 0.9.0 did not extend to comments — closed in 0.10.1, see below; (2) time labels show UTC rather than local time (`DateTime.parse()` on a string with `Z` gives a UTC instant, `.toLocal()` is not called) — this affects not only comments but also post dates in the feed and the connection date on Connections; closed in 0.10.2, see below.
- Mute/block on comments + two tombstone bugfixes (0.10.1) — the mute and block from 0.9.0 filtered only posts, so under a post by a mutual connection the comments of a muted/blocked person kept being shown; this is the only place where two people who had hidden each other still met. The rule (keeping the one-level nesting in mind): a root comment is visible if its author is visible; a reply is visible if its author is visible **and** the author of the thread's root **and** the author of the comment it is addressed to. That is, nothing that hangs under a muted person or talks to them. Migration `20260725150000_scope_comment_visibility_to_mute_and_block.sql`.
  "The author is visible to me" was extracted into the `security definer` function `is_comment_author_visible(uuid)` (myself, or a Connection with no mute and no block in either direction) — `definer` for two independent reasons: the lesson of `is_blocked_pair()` from 0.9.0 about RLS on `blocked_users`, plus the function is called from the `comments` policy about the author of *another* comment and must not be re-filtered by the same policy it helps to evaluate. Reading another comment's author from inside the table's own policy is recursion through that same policy, so the second function `comment_author(uuid)` is also `definer`; the one-level depth means `parent_comment_id` is always a root and one hop suffices, with no recursive traversal. The INSERT policy was narrowed too: you can only reply to a comment visible to you (impossible in the UI anyway, but a direct API call could park replies under the comment of someone blocked).
  A consequence of the rule that is not obvious at first glance: **your own** reply under a muted person's comment also disappears from your comment feed (the row is alive, others see it) — the thread is hidden entirely. And a remark by an unmuted connection disappears from a thread if it is addressed to the muted person. Both behaviors were chosen deliberately.
  Incidentally: after this policy an "orphaned reply" (the reply is visible, the root is not) in principle stops arriving from the server — if the root's author is visible, so is the root. The filter in `threadComments()` has therefore become a safety net rather than the main rule.
  Two tombstone bugfixes found during a manual check on the device: (1) the comment counter on a post counted **all** rows, including tombstones, so a post with one orphaned tombstone showed "1" on an empty screen (the client doesn't draw a tombstone without replies) — `.isFilter('deleted_at', null)` was added in `feed_repository.dart`, the number now means "this many live comments", not "this many rows on screen" (for a post with a tombstone and one reply the counter will show 1, while there will be two rows on screen); (2) the orphaned tombstone itself no longer stays in the database — `delete_own_comment()`, after deleting a leaf reply, also deletes the parent if it is a tombstone and no replies remain under it, plus a one-off cleanup of the ones already accumulated. Migration `20260725180000_drop_childless_comment_tombstones.sql`. The client filter in `threadComments()` was kept nonetheless: a tombstone can still become orphaned bypassing the RPC — if a reply's author deletes their account, their replies go away by FK cascade, bypassing the function.
  Verified: both migrations were applied to the live DB through the Management API and checked by simulating RLS (`set local role authenticated` + `request.jwt.claims`, in a transaction with `rollback`) — 30 visibility checks on a tree of seven comments in four scenarios (no mute/block — a control that we didn't over-tighten; I muted; I blocked; **I was blocked** — the side that RLS swallowed in 0.9.0) plus the INSERT rejection under a hidden root, and 5 tombstone lifecycle checks (a root with replies → a tombstone, the tombstone holds as long as at least one reply is alive, the last reply takes it along, no orphans left in the database). Then manually on a physical device.
- Local time instead of UTC in labels (0.10.2) — closed the last tail from 0.10.0: PostgREST returns `timestamptz` with an explicit offset (`...Z`), so `DateTime.parse()` returned a `DateTime` with `isUtc == true`, and `DateFormat` printed it as is — a comment written at 13:02 Moscow time was labeled 10:02. For a label without a time ("Знакомы N дней — с 25 июл. 2026" ("Known for N days — since 25 Jul 2026")) the same shift could name the neighboring day. The conversion was added with a single helper `parseTimestamp()` (`lib/shared/parse_timestamp.dart`) at the "string from the DB → model" boundary, not at the display sites, so that a new screen can't forget it; all four parsing points were moved onto it (`Post.fromRow`, `Comment.fromRow`, `Friend.connectedAt`, `BlockedUser.blockedAt`), there are no others in `lib`. A purely client-side fix: no migrations or RLS. The feed's keyset pagination was not affected — `keysetFilter()` sends the cursor back to PostgREST via `.toUtc()`, the instant is the same, the existing tests for "there is no `+` in the filter" pass. Three unit tests for the helper are written against the instant in time and the `isUtc` flag, not against expected clock digits, otherwise they would fail on a machine or in CI in a different zone. Verified on a physical device: the label of a fresh comment matches the phone's clock.
- targetSdk 36 for the Google Play requirement (0.10.3) — Play Console sent a warning: from August 31, 2026 updates are not accepted if `targetSdk` is more than a year older than the latest Android release; the app was on 35. The change adds no functionality, it is pure compliance with the store's requirement. `compileSdk`/`targetSdk` are set in `android/app/build.gradle.kts` as the number 36 instead of inheriting from `flutter.compileSdkVersion`/`targetSdkVersion` — Flutter itself raises the default to 36 only from 3.35, and the SDK is pinned at 3.32.8 because of macOS (see below). AGP had to be raised 8.7.3 → 8.9.3 (`android/settings.gradle.kts`): 8.7.3 was tested at most up to `compileSdk 35` and fails against 36; 8.9.x is the first line with 36 support that still works on the current Gradle 8.12 (8.11+ would have required Gradle 8.13). The fallback in case of problems — `android.suppressUnsupportedCompileSdk=36` with the old AGP — was not needed, Flutter 3.32.8 with AGP 8.9.3 built without a single edit. In `deploy-closed-testing.yml`, `platforms;android-35` was replaced with `android-36`, otherwise the deploy build in CI would have failed (`build-tools;35.0.0` was left — AGP 8.9 pulls in exactly that one itself).
  The worry that macOS 12.7.6 would not allow installing SDK 36 did not pan out: Android SDK Platform packages are jars and resources, they are processed by the JDK 21 from Android Studio, the OS version has nothing to do with it. The macOS 14+ restriction concerns only the Flutter SDK and Xcode, where there are native binaries.
  Verified on a physical device with Android 16 (API 36) — the very version where the new behavior shows up. Two targetSdk 36 risks: forced edge-to-edge (can no longer be disabled) and predictive back, which the system enables by default — `enableOnBackInvokedCallback` is not declared in the manifest at all, so the system default applies. Neither one went off: the layout did not slide under the system bars on any screen, and the "back" gesture from pushed screens (comments, "New post", "Blocked") returns to the previous screen rather than minimizing the app.
  A pitfall during verification, for the future: sign-in screens are not suitable for testing the "back" gesture — they navigate via `context.go()`, which replaces the route, the stack is empty, and "back" legitimately minimizes the app on any Android version. It looks like a regression without being one. Only `Navigator.push()` screens should be tested. Cancelling an unfinished gesture via `adb` cannot be reliably verified: the "complete or cancel" decision is made by the system, and the injected events come without velocity and with pauses of hundreds of milliseconds — its verdict on them says nothing about the app, a live finger is needed.

- Code review: visibility rule, hardening and performance (0.11.0) — twelve fixes following a code review of the 0.8.1→0.10.3 branch, eight migrations plus the client. Adds no functionality; grouped by what was being fixed.

  **The main thing — the visibility rule had been duplicated.** "Whose content is visible to me" (myself, or a Connection with no mute and no block in either direction) existed in **four** copies: inline in the `posts` SELECT policy, inline inside `reaction_summary()`, as the separate function `is_comment_author_visible()`, and inline in the storage policy on post photos. When 0.9.0 added mute/block, only the first (and later the third) were updated — and the other two stayed on "the author or a Connection" since 0.4.0. Both turned out to be real holes: a blocked person who had kept the ids of the blocker's posts (they had been in their feed before the block) received, through `/rpc/reaction_summary`, live reaction counters of posts hidden from them, and, knowing the path `posts/<author_id>/<uuid>.jpg`, could endlessly mint new signed URLs for the photo (links already issued live for 24 h and are not revoked by this; what got closed was precisely the ability to issue new ones). It was fixed not with patches on the lagging copies but by merging all four into a single `security definer` function `is_author_visible(uuid)`; `is_comment_author_visible()` was exactly it under a name tied to comments, and was removed. Migrations `20260726120000_unify_author_visibility_rule.sql`, `20260726130000_scope_post_photo_visibility_to_mute_and_block.sql`. Avatars were deliberately **not** narrowed: a block doesn't break the Connection, the blocked person stays in the Connections list, and the blocker sees them on the "Blocked" screen — the very one where the block is lifted — and both screens draw the avatar.

  **Definer functions answered other people's questions.** Every function in the exposed schema is a PostgREST endpoint, so a grant to `authenticated` means "call it with any arguments". `is_blocked_pair(a, b)` did not bind either argument to `auth.uid()`: a caller to whom RLS returns zero `blocked_users` rows found out through the RPC whether two **strangers** had blocked each other. The grant was revoked — after merging the rule the function had no calls left outside `is_author_visible()`, and `security definer` executes the body as the owner, so the nested call is checked with `postgres` rights. For `comment_author(uuid)` (the author of any comment bypassing RLS) the grant couldn't be revoked — it was called directly from policies, and a policy is evaluated with the rights of the requesting role; so what was removed was not the grant but the disclosure of identity: the author lookup and the visibility check were folded into `is_author_of_comment_visible(comment_id) → boolean`, and `comment_author` itself was removed. Migration `20260726140000_lock_down_visibility_helpers.sql`.

  **`delete_own_comment()` failed in the dangerous direction.** The check `if v_author <> auth.uid()` is three-valued: with `auth.uid()` = NULL the comparison yields NULL, the `if` doesn't fire, and control falls through into the deletion — and this is the function's only permission check, the DELETE policy on `comments` was dropped in 0.10.0 precisely for this. Reproduced on the live schema: a session with the `authenticated` role and empty claims deleted someone else's comment. Now there is an explicit guard for the unauthenticated plus `is distinct from`. The second fix in the same place is a race: the function asked "are there replies?" and did the hard delete with a **separate** statement, so a reply committed in between is invisible to the check, yet the FK cascade takes it away (while the author's client reports success). The row is now taken `for update` before the check: an insert with an FK takes `for key share` on the parent, which conflicts with `for update`. Verified with two parallel connections on a throwaway schema of the same shape — without the lock the insert "succeeded" and vanished by cascade, with the lock it gets an honest `23503`. Migration `20260726150000_harden_delete_own_comment.sql`.

  **The client could forge server state.** `deleted_at` wasn't mentioned in the INSERT policy, so a comment could be inserted already as a tombstone (not counted by the counter, drawn as "deleted", can't be replied to, only the author can clean it up) — `20260726160000_pin_comment_tombstone_state_to_server.sql`. `created_at` could be forged the same way, and that is worse: the feed is ordered by `created_at desc`, so a post dated 2099 permanently stands first for all of the author's connections and can't be scrolled past; for a comment, backdating pins it to the start of the thread. It was pinned to the server clock via `created_at = now()` in both INSERT policies, rather than by revoking column rights: a column-level `revoke` requires removing the table-level INSERT and listing all the other columns by name, maintaining the list by hand with every new one. `now()` is `transaction_timestamp()`, exactly what the DEFAULT evaluates in the same transaction, so legitimate inserts pass by construction (neither repository sends the column at all). Incidentally the DEFAULT becomes load-bearing: changing it to `clock_timestamp()` will break inserts — but loudly and on the very first test. Migration `20260726190000_pin_created_at_to_server_clock.sql`.

  **Invite errors got codes.** `_activate()` was the last place where a raw `e.message` went to the screen (0.9.1 removed this everywhere except there — the message is useful there). But everything the database says comes through the same channel: a timeout, a constraint violation, a pool error, with table names in the text; plus three useful messages were hardcoded English inside the migration and were shown in English in the Russian locale. Separated: the `raise`s got stable SQLSTATEs following the PostgREST convention `PTxyz` (`PT404` not found, `PT409` already used, `PT422` your own), the client does a `switch (e.code)` and takes the text from the ARB, everything unknown gets the generic message. `'Not authenticated'` was deliberately left at `P0001`: it is unreachable from the screen behind a session. Migration `20260726170000_give_invite_errors_stable_codes.sql`, three new keys in both ARBs.

  **RLS performance — the biggest finding by the numbers.** The planner can't inline a `security definer` function (it must execute as the owner), so `using (is_author_visible(author_id))` is an opaque call on **every scanned row**, and each call itself scans `connections`, `muted_users`, `blocked_users`. For the feed this is not "the 20 rows of the page": visibility has to be decided before the `LIMIT`, that is, the filter goes over the whole posts table, and the cost of the first page grew with everything ever published. Measured with `EXPLAIN ANALYZE` on a synthetic volume in a transaction with `rollback`: the feed over 2000 posts — **217 ms / 10,216 buffers**, comment counters per page at 1000 comments — **115 ms / 5,135 buffers**. The rule depends only on the caller and never on the row, so it is asked once per query: `visible_author_ids()` enumerates your own connections (bounded by the number of connections, not by the volume of posts), and the planner hashes an uncorrelated `IN (SELECT ...)` once. It became **3.5 ms / 254** and **5 ms / 314** — 62× and 23×. The `posts`, `comments` (SELECT) policies and the storage policy on photos were switched over. This is not a fifth copy of the rule: the enumeration still asks the same `is_author_visible()` about each connection. The `parent_comment_id`/`reply_to_id` clauses were deliberately left per-row — they fire only for replies and short-circuit on NULL for roots, and hoisting them would mean materializing the ids of all comments with a visible author, trading a bounded per-row cost for an unbounded per-query one; `reaction_summary()` was not touched — there `p.id = any(...)` narrows by primary key before the filter. Migration `20260726180000_hoist_author_visibility_out_of_row_filters.sql`.

  **Client fixes.** (1) Mute/block did not reach the feed: the tab lives in a `StatefulShellRoute.indexedStack` and holds the loaded page, so after a block its posts stayed on screen with working buttons, and a tap on a reaction went off into an insert that RLS already rejects — the optimistic update silently rolled back. Now `_run()` in `connections_screen.dart` and `_unblock()` in `blocked_users_screen.dart` poke `feedRefreshTickProvider` (the mechanism from 0.6.0, added exactly for this), and only after a successful request. (2) Unblocking on the "Blocked" screen did not update the connections list beneath it: the screen is opened via `Navigator.push` **on top of** Connections, which stays mounted and keeps its `autoDispose` provider alive — on returning, the user saw a red icon with the tooltip "Unblock" and, pressing it, called `unblockUser` a second time to no effect. The list provider moved from the screen's private scope to `connections_repository.dart` as `friendsProvider`, and the "Blocked" screen invalidates it. (3) A failure to send a comment wasn't shown at all: `_errorMessage` is drawn **instead of** the list, and sending happens when the list is already loaded — the assignment went nowhere, and the user saw only a flickering spinner. It moved to a `SnackBar` (by the same means the deletion in the same file already used), `_errorMessage` now honestly means "the list itself failed to load" and is reset on a successful load. The branch became reachable in normal operation precisely because of nested comments: while you type a reply, the addressee may get deleted or blocked. Incidentally `comments_screen.dart` switched from `supabaseClientProvider...currentUser!.id` to `currentUserIdProvider` — the same source, but overridable in tests, as already done on Connections and in the profile.

  Verified: all eight migrations were applied to the live DB through the Management API and checked by simulating RLS (`set local role authenticated` + `request.jwt.claims`, in transactions with `rollback`) — each hole was first reproduced on the live schema, then closed. The equivalence of the rewritten policies was proven by running a matrix: eight counters (posts, the author's posts, comments, the author's comments, photos, the author's photos, avatars, `reaction_summary`) in three scenarios (no restrictions / block / mute) before and after — 24 comparisons, all matched, plus a matrix of branches and the write paths. The client fixes are covered by tests (58 green, `analyze` clean); for each of the three bugs the test was first verified to fail against the old code. Then everything was verified manually on a physical device with Android 16 (API 36), debug build: the three invite-activation messages (a nonexistent code, an already used one, your own) — in both locales, the English one switched on with the per-app language of Android 13+ (`cmd locale set-app-locales`), not the system setting; the snackbar on a failed comment send — in airplane mode; blocking a connection on the Connections tab → the feed, on switching, **itself** turned out without their posts, with no pull-to-refresh; unblocking on the "Blocked" screen → going back showed the row already with a gray icon, and the feed brought their post back on the same tick. The check left no live data behind: 0 rows in `blocked_users`/`muted_users`, the post/comment/connection counts did not change.

  Noticed along the way and **not fixed**: the request has no client-side timeout — in airplane mode sending a comment hung with a spinner for ~3.5 minutes before falling into the snackbar. The error branch works correctly, but the user doesn't know what is happening all that time. Server-side rejections (a reply to a deleted comment, a block) are not affected — they arrive immediately.

  Deferred deliberately: a server-side aggregate instead of the client-side comment count (`comment_summary(uuid[])`, `security invoker` — RLS does the counting itself, no duplication of the rule) — measured, the server time doesn't change, the gain is only on the wire (10 rows instead of 849, ~40 KB per feed page), but it is a change to the client data path without test coverage.

- Debt from the second code audit (0.11.1): three findings that 0.11.0 above explicitly named ("noticed and not fixed" / "deliberately deferred") and left hanging are now closed.

  **Client-side timeout.** Every Supabase call (`postgrest`, `rpc`, `storage`, `auth`) is now wrapped in `.timeout(networkTimeout)` (12 s, `lib/shared/network_timeout.dart`). Sending a comment while offline no longer hangs on a spinner for minutes; it falls into the already existing localized snackbar of the same error branch (`TimeoutException` is caught by the same generic `catch` as any other network problem, so no separate ARB key was needed). Server-side rejections (RLS, constraints) are unaffected; they always came back instantly.

  **`comment_summary(uuid[])`.** The feed no longer has to pull a row per visible comment just to count them: a `security invoker` function does `count(*) ... group by post_id` right on the server, and RLS is applied to its own scan automatically (the comment SELECT policy already defines exactly the visibility needed, so unlike `reaction_summary()` the rule did not have to be duplicated). `feed_repository.dart` calls it as a second RPC alongside `reaction_summary`; the swap removes one client-side counting loop. Migration `20260817120000_add_comment_summary_function.sql`, `grant execute ... to authenticated` / `revoke ... from anon`.

  **Bucket check.** `media` confirmed as `public = false` by querying `storage.buckets` directly through the Management API (not the UI dashboard: logging into the web console would have required entering credentials).

  Verified: the migration is applied to the live DB and recorded in `supabase_migrations.schema_migrations`; RLS on `comment_summary` was checked by simulation (`set local role authenticated` + `request.jwt.claims`, transactions with `rollback`) in two scenarios: no restrictions (the function's count matched a manual count under the same RLS policy) and with the comment author muted (both dropped to zero identically). On top of that, `anon` gets `permission denied` when calling it. No live data changed. `flutter analyze`/`dart format`/`flutter test` are clean (68 tests).

- Two code-review remarks on 0.11.1 (0.11.2), both purely client-side, no migration.

  **`reaction_summary`/`comment_summary` ran sequentially.** Both RPCs in `fetchPage()` take the same `postIds` and read nothing from each other, yet were called `await` after `await`: an extra network round trip on every feed page load. They now go into a single `Future.wait([...])`.

  **`.timeout()` does not cancel the request, so a retry after a timeout could duplicate a post/comment.** `.timeout(networkTimeout)` (0.11.1) merely stops waiting: if the network is slow but not dead, the insert can commit on the server after the client has already shown an error. `_submit()`/`_send()` don't clear the input field on error, so the user's natural move, tapping "Publish"/"Send" again, went out as a second `insert()` with the same content; neither `posts` nor `comments` has a uniqueness constraint. Fixed with an idempotency key: `createPost`/`addComment` now take an `id` chosen by the client (`generateUuidV4()`, `lib/shared/uuid.dart`) and do `upsert(..., onConflict: 'id', ignoreDuplicates: true)` instead of `insert()`. `ON CONFLICT DO NOTHING` is allowed by the existing INSERT policy; no UPDATE policy is needed (the project deliberately has none, since editing posts/comments is not a feature). The screens keep the id in widget state and reuse it until an attempt succeeds, so resending the same content is a no-op rather than a second row.

  Accepted residual risk: the id is tied to the attempt, not the content, so if the user manages to edit the text (or drop the reply target) between the timeout and the retry, and the first attempt actually did land on the server, the edit is silently lost (`ON CONFLICT DO NOTHING` won't apply it), though there's no duplicate. The condition is compound and unlikely (all three are required: a timeout, actual success on the server, and an edit in exactly that window), so we decided not to complicate things further.

  Verified: `flutter analyze`/`dart format`/`flutter test` are clean (68 tests; the fakes in `comments_screen_test.dart` were updated to the new signature). No manual RLS simulation was run, since the change doesn't touch policies: `upsert` with `ignoreDuplicates` is `INSERT ... ON CONFLICT DO NOTHING`, allowed by the same INSERT policy that was already verified for `insert()`.

- Re-audit of 0.11.2 (0.11.3): a self-review of the previous change found three defects in it (two of which it introduced itself), plus three items of debt. All six are closed.

  **A row-existence oracle: it turned out to go deeper than it looked, and the cure is a grant.** 0.11.2 handed the primary key to the client and did `upsert(onConflict: 'id')`. `ON CONFLICT DO NOTHING` doesn't distinguish "inserted" from "already there" (2xx both times), and `id` is global, so the conflict could happen with SOMEONE ELSE's row. Knowing the id of a post that RLS hides from them (the scenario from `20260726130000`: a blocked user keeps the ids of posts seen before the block), the caller could tell from whether their own post appeared if the other row was still alive, which is exactly what the SELECT policy conceals.

  The first fix moved the client to a `client_token`: `id` is server-side again, uniqueness is composite `(author_id, client_token)`, and `author_id = auth.uid()` is pinned by the INSERT policy, so a conflict is only possible with one's own row. The index is deliberately not partial: PostgreSQL infers a partial index for `ON CONFLICT` only together with the `WHERE` predicate, while PostgREST passes only a column list via `on_conflict=`. Migration `20260818120000_add_client_token_idempotency.sql`.

  **But a simulation on the live schema showed this wasn't enough.** An attacker doesn't use our app; they send the request with curl, and the right to write `id` comes from Supabase's default table grant (the very pitfall from CLAUDE.md). The hole was reproduced under the `authenticated` role with someone else's claims: a user who isn't connected to the author can't see their post (`can_select_hidden = 0`), but an insert with that post's id silently does nothing and **returns no error** (`probe_known_landed = 0`), while an insert with a free id creates a row (`probe_free_landed = 1`); the difference is the leak. `ON CONFLICT` isn't even needed for this: without it, the duplicate raises `23505`, and error versus success is the same oracle. So the client fix corrected the form but didn't close the hole. I was wrong when I called it "reachable for the first time" in the review: it existed before 0.11.2 too.

  Closed where it belongs, in the grant: `revoke insert on posts/comments from authenticated` plus a per-column `grant insert (...)` on every column except `id`. There is no value pin for `id` like `created_at = now()` in 20260726190000 (it's random by design, there's nothing to compare against), so what remains here is exactly the "expensive" option that migration rejected for `created_at`. The cost is real (the column list has to be maintained by hand), but the default flips to the safe side: a forgotten column becomes unwritable rather than open to everyone. `created_at`/`deleted_at` are deliberately left in the list: policies already pin them by value, and silently breaking the behavior described there isn't worth it. Migration `20260818130000_revoke_client_write_on_row_id.sql`. After it the probe gets `42501` in both forms: the response no longer depends on whether the row exists.

  **Retrying with a photo spawned orphan files.** The image path was built from `DateTime.now().microsecondsSinceEpoch`, so every retry uploaded a NEW object while the post row (thanks to `DO NOTHING`) kept pointing at the first one. `deletePost` deletes only the path stored in the row, so every extra upload stayed in the private bucket forever. The path is now built from `client_token` and is therefore stable within a single submission; re-uploading to the same path returns 409, which is treated as "already done" (overwriting via `upsert: true` won't work: there's no UPDATE policy on `storage.objects` for post photos, only SELECT/INSERT/DELETE).

  **The idempotency key is tied to the content, not the attempt.** Otherwise an edit made between the timeout and the retry was silently lost: the server answered a familiar token by doing nothing, and the screen reported success. Now changing the text, the reply target or the photo produces a new token. This is the very "accepted residual risk" from 0.11.2, and it turned out cheaper to close than to describe.

  **Tests for idempotency itself.** In 0.11.2 the fake accepted `commentId` and threw it away, so the mechanism wasn't covered at all: a refactoring that brought duplicates back would have left every test green. Added a group of four tests (`comments_screen_test.dart`); the fake records every token it receives, including failed attempts. Per the project convention, each was first checked to fail against the old code: the "token per attempt" variant breaks the retry test, and the 0.11.2 variant ("the token lives for the whole attempt") breaks both content-change tests.

  **The hand-rolled UUID was replaced with a package.** `uuid` was already in `pubspec.lock` transitively, so promoting it to a direct dependency pulls in nothing new; `lib/shared/uuid.dart` was deleted.

  Verified: both migrations are applied to the live DB through the Management API and recorded in `supabase_migrations.schema_migrations`. RLS was checked by simulation (`set local role authenticated` + `request.jwt.claims`, transactions with `rollback`); the hole was first reproduced, then closed:

  - the new write path passes the policy: `created_at` takes its DEFAULT and satisfies `created_at = now()` (`created_at_is_txn_now = 2` out of 2 rows), so the worry "PostgREST will send the column and everything will break" was settled by measurement, not by reasoning;
  - idempotency works: a retry with the same token doesn't create a second row (2 tokens → 2 rows, the third insert is a no-op), and the edited text is **not** applied on retry (`edit_applied = 0`), which is precisely why the key had to be tied to the content;
  - the same for comments, including a reply with `parent_comment_id` (threading is intact);
  - after `20260818130000` a probe with someone else's id gets `42501` both with `on conflict` and without it;
  - legitimate writes didn't break: a post with a photo, a post without one, a root comment and a reply all insert under the per-column grant.

  No live data changed: the control counts before and after matched (posts=10, comments=9, users=10), all simulations rolled back.

  **`anon` grants removed entirely.** It started as minor cleanup ("a stray INSERT on `posts`/`comments`"), but a review of privileges showed that Supabase's default had given `anon` the full set on six tables (`users`, `posts`, `comments`, `connections`, `invite_links`, `reactions`): SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER. There isn't a single policy that applies to `anon` in the schema, so RLS was already rejecting everything row-level for it; this wasn't a hole.

  Except for one item: **row-level security doesn't apply to TRUNCATE at all**. It isn't a row operation, and there's nothing for a policy to filter. This was the one privilege on the list with no second line of defense whatsoever, and the only thing holding it back was that PostgREST doesn't map TRUNCATE to any HTTP verb. Relying on the API surface instead of the privilege isn't worth it when the privilege simply isn't needed.

  The tables themselves proved the grants were legacy: `muted_users` and `blocked_users` were added later through ordinary migrations, `anon` has no privileges on them at all, and everything works. The other six were brought to the same state (`revoke all ... from anon`). Sign-up is unaffected: `public.users` is populated by the trigger function `handle_new_user()`, which is `security definer` owned by `postgres`; this was checked before the change. Migration `20260818140000_revoke_anon_grants_on_public_tables.sql`.

  Verified afterwards: `anon` privileges are empty on all eight tables; `anon` now gets `42501` at the privilege level rather than at the RLS level (i.e. the rejection moved one line of defense earlier); the per-column INSERT grants for `authenticated` are intact and still don't include `id`; inserting a post and a comment as `authenticated` works. The control counts matched again (posts=10, comments=9, users=10, connections=9), and no stray rows from the simulations remained.

  **Tests brought to symmetry.** The first pass covered idempotency only for comments, while posts have the same logic, slightly more complex (the photo is compared too), and weren't covered at all: `create_post_screen_test.dart` didn't exist in the project. Exactly one barrier stood in the way: the screen took the user from `supabaseClientProvider...currentUser!.id`, which in a test requires a real `SupabaseClient`. This was the last screen still using the old approach; it was switched to `currentUserIdProvider`, the same change 0.11.0 already made for "Connections", the profile and comments.

  New: `create_post_screen_test.dart` (validation of an empty post, an error message that keeps the text, a retry reuses the token, editing the text produces a new one) and a group for `postImagePath()`: building the photo path was pulled out of `createPost` into a pure function next to `keysetFilter()`, using the same technique and for the same reason: both halves of the path string matter, and either can be broken unnoticed. The first two segments (`posts/<author uuid>/`) are what the storage policies look at; the third is the token, which decides whether a retry overwrites its own file or leaves an orphan.

  Every new test was checked to fail against broken code: the "token per attempt" variant breaks the retry test, the "token for the whole attempt" variant (the previous pass's bug) breaks the text-edit test, and swapping the path segments breaks the storage-policy test.

  Deliberately left uncovered: the "user changed the photo between attempts" branch. `_pickImage()` calls `ImagePicker()` directly, and there's nothing to substitute it with in a widget test without a separate refactoring, which is out of scope for this change. The branch's logic is a single `identical()` next to the covered text comparison.

  `flutter analyze`/`dart format`/`flutter test` are clean (80 tests).

- The Amicus news account, favorites and push notifications about posts (0.12.0). Closes item 8 of the "Near-term plan" in future-development.md (the news account), a new "favorites" item (requested separately, it wasn't on the list), and partly item 7 "Push notifications" (posts; comments/reactions remain, see future-development.md).

  **The news account.** A real account that logs in (`projectamicushelper@gmail.com`, originally created as `amicus@amicus.app` and renamed after the first post), not a record automatically linked by a Connection to every user. The row in `auth.users`/`auth.identities` was created directly through the Management API (Postgres itself computes the bcrypt password hash via `pgcrypto`; the password isn't stored anywhere, neither in the repository nor in memory), and `handle_new_user()` from 0.1 created the profile in `public.users` the same way as a normal sign-up. Visibility isn't a new Connection to everyone but a single hardcoded id in `is_author_visible()`/`visible_author_ids()`: `is_system_account(uuid)`, the only place the id is mentioned at all. Migration `20260818150000_add_system_news_account.sql`.

  This, rather than a Connection-for-everyone, was a deliberate choice: an auto-Connection would have had to be hidden from the connections list by a separate filter in every place that reads `connections` (the very rule-duplication pattern that already cost us a hole once, in the second audit), and on top of that it would have left the account mutable/blockable through the normal UI. Instead, nothing had to be hidden: the `friends` list is built from `connections` anyway, and there's no row there, so mute/block buttons for this account simply have nowhere to come from in the UI; no client change was needed at all. If a row in `muted_users`/`blocked_users` is inserted bypassing the UI anyway, it has no effect: `is_author_visible()` returns `true` for the system id before it gets to the mute/block check.

  **The first version broke the feed for everyone who opened it, and was only caught on a real device.** The RLS simulation (`set local role authenticated` + `request.jwt.claims` of an unrelated user) after migration `20260818150000` showed exactly what it should have: the system account's post is visible, mute/block have no effect, zero rows in `connections`. But that only checked the `posts` policy, whereas `flutter run` on a physical phone (`--dart-define-from-file=.env`, real keys, not the CI placeholder) showed "Failed to load feed" on the very first feed open under a live account. A temporary `print` in the `feed_screen.dart` catch handler and a row-by-row dump of the raw responses in `fetchPage()` (`feed_repository.dart`, removed right after diagnosis) pinpointed the exact spot: `Post.fromRow` does `row['author'] as Map<String, dynamic>`, and `author` was `null`, but only for the Amicus post; for every other author it arrived fine.

  The cause: the SELECT policy on `users` was never part of `is_author_visible()`. Migration `20260726120000`, which unified the visibility rule, merged `posts`/`reaction_summary()`/`comments` into one function; `users` didn't make that list, deliberately (its rule is simpler: "me or a Connection", no mute/block, because a block must not hide the name/avatar in "Connections" and on the "Blocked" screen; see the visibility rule in CLAUDE.md). The system account has no rows in `connections`, so its profile was readable only by itself: the post was shown to everyone via `posts`, but the PostgREST join on `users` embedded in `.select('*, author:users(name, dislikes_disabled)')` returned `null` for every viewer. A fourth place where the question "whose profile is visible" lives, not three as was believed.

  The fix is targeted, not a merge into `is_author_visible()`: the `users` policy got `or is_system_account(id)` in the same order as before, and mute/block still don't affect it. Migration `20260818160000_expose_system_account_profile.sql`. Separately, it surfaced that `is_system_account()` is no longer called only from inside `security definer` functions (like `is_blocked_pair()`) but directly from the body of the `users` RLS policy, and a policy's `using` expression runs as the calling role, not the function owner, so an explicit `grant execute … to authenticated` was needed. Formally this is a grant on a function whose argument isn't bound to `auth.uid()` (the very CLAUDE.md pitfall about definer helpers), but it's not a hole: the system account's id is already visible to everyone as `author_id` on each of its posts, so the function reveals nothing new.

  Verified by RLS simulation on the live DB (posts, `users`, both RPCs) and manually on a physical Android device via `flutter run` with real keys: a clean build without the temporary `print`s, logged in as a real account, the feed opens, the Amicus post is shown first.

  **The same failure, mirrored: the Amicus account couldn't read comments under its own posts.** The symmetry with the finding above isn't accidental: `20260818160000` closed "others can't see me" but not "I can't see others". The `comments` policy requires `comments.author_id in (select visible_author_ids())` **from the viewer's perspective**, and Amicus has no rows in `connections`, so `visible_author_ids()` for it is just itself. A commenter who left something under an Amicus post without being its Connection (and Amicus posts are visible and commentable by everyone, not just Connections; that's the whole point of the feature) was invisible to Amicus, and for the same reason as with posts, `.select('*, author:users(name)')` in `comments_screen.dart`/`feed_repository.dart` would have returned `null` and crashed the comments screen via the same `Comment.fromRow` pattern.

  Treating this as a bug of the system account alone would be wrong: the `comments` INSERT policy never required the commenter to be a Connection of the post author (only that the post exists and, for a reply, that the parent is visible). An outsider could already leave a comment under someone else's post by knowing its id, and the post author couldn't see it. Amicus merely made this scenario reachable through the normal UI instead of a crafted request. So the fix is a general rule, not a workaround for one account: a post author sees any comment under their own post and the profile of any commenter regardless of Connection, but not regardless of their own mute/block; those still cut visibility, as in every other case. Two new `security definer` helpers, `is_comment_visible_to_post_owner(uuid)` and `is_commenter_visible_to_post_owner(uuid)` (both mirror the mute/block check of `is_author_visible()`, just without the Connection requirement), were added to the `comments` policy (all three predicates: the comment itself, `parent_comment_id`, `reply_to_id`) and to the `users` policy. Migration `20260818170000_expose_commenters_to_post_owner.sql`.

  Verified by RLS simulation on the live DB: a test comment from an unrelated user under an Amicus post became visible to Amicus along with the author's profile; Amicus blocking that commenter hides both the comment and the profile again (rolled back, nothing left over); a third party, neither the post owner nor a Connection of the commenter, still can't see their profile, so there's no regression. `flutter test`: 80/80 (the change is purely server-side, the client is untouched).

  Publishing is done by logging into the app normally under this account (the password was generated separately and shared only in the chat), not via the service key and not fully automatically on deploy: after a successful upload to Google Play, `deploy-closed-testing.yml` only leaves a comment on the merged PR with the new version number; what to post and when is up to the author. Auto-generated text from `CHANGELOG.md` was deliberately not considered: the file is written for developers and contains internal details (migration names, RLS fixes) that have no place in a public feed.

  **Favorites.** `favorite_users (user_id, favorite_id)`, the same shape as `muted_users`/`blocked_users` (0.9.0): its own table instead of a shared "relationship type", RLS on one's own rows, no requirement at the DB level to be a Connection (as with mute/block, the only restriction is that the button exists only in the "Connections" list). A star next to mute/block in `connections_screen.dart`, with no confirmation dialog: unlike mute/block, this isn't an action that affects the other party in any way, and it's undone with one tap. Migration `20260818180000_add_favorite_users.sql`.

  **Why push and not just polling.** Amicus and favorites should always notify, ordinary connections as a digest after 6 posts, and the user's own silence once a week. Three events, different rhythms, and the first of them should be "right away" rather than only while the app is open, so without a server sending pushes the idea doesn't work at all.

  **Architecture: one queue, three producers, one consumer.** `notification_outbox (user_id, kind, payload, sent_at)`: RLS is enabled, but there isn't a single policy for `authenticated`/`anon` (`revoke all`, not just an empty filter: a direct client SELECT fails with `42501` instead of returning 0 rows, the same decision as before for purely internal tables). Three sources of rows:
  - The trigger `enqueue_post_notifications()` on `posts` (`after insert`): for the system account, immediately to everyone except itself; for a favorite, immediately to everyone who favorited them and hasn't muted/blocked them; for an ordinary visible author, it doesn't write to the queue directly but accumulates `pending_post_counts.pending_count` per non-favorite viewer (a Connection who hasn't muted or blocked them), and on the seventh post writes a `digest` row with the count and resets the counter to zero.
  - `enqueue_inactive_week_notifications()`: a daily `pg_cron` (`0 12 * * *`) for anyone without a post in 7 days (provided the account itself is older than a week and hasn't already been nudged in the last 7 days, to avoid spamming).
  - None of this knows about FCM. Sending is a separate `pg_cron` once a minute (`* * * * *`) that pokes the `send-push` Edge Function via `pg_net.http_post`; the function URL and the `service_role` key live in `supabase_vault` (already installed) rather than inline in the migration: the same principle as with the tokens in this session, the secret doesn't end up in a committed file. Migration `20260818190000_add_push_notification_backend.sql` (queue and triggers) + `20260818200000_drain_notification_outbox_via_cron.sql` (the drain cron).

  **A bug in the first version of the digest, caught by simulation, not by eye.** The draft did the bump-and-check as a single `with` query: a CTE `bumped` (`insert … on conflict … returning`) and a CTE `notified` (a conditional `insert` into the outbox), with the counter reset as a final `update` of the same `pending_post_counts` that read `notified`. It worked for *detecting* the threshold (the `digest` row appeared with the right number) but not for the *reset*: after the seventh post the counter stayed at 7 instead of 0. The cause lies in Postgres semantics itself: multiple modifications of the same row within a single statement (here, INSERT…ON CONFLICT in one CTE and UPDATE in the final part of the same WITH) are not guaranteed to be applied in order; the second one simply didn't land. Caught by row-by-row tracing through a temporary log table (`insert into debug_log select …` after each of the seven posts, in a rolled-back transaction); without it only the final result "7 vs the expected 0" would have been visible, not the point where things diverged. Rewritten as an explicit PL/pgSQL loop (`for … loop`, with the bump and reset as two separate `insert`/`update` statements rather than one CTE chain): the same case as already happened with `pending_post_counts` in this migration, only for read-after-write within one statement rather than for RLS subqueries.

  **The `send-push` Edge Function** (Deno, `supabase/functions/send-push/index.ts`): once a minute it reads unsent queue rows (`limit 200`), picks for each a random one of four prepared texts for its `kind` (placeholders `{author_name}`/`{count}` from `payload`) and sends it through the FCM HTTP v1 API. V1 has no legacy server-key authorization: it needs an OAuth2 access token, obtained by signing a JWT with the service account's private key (RS256) and exchanging it at `oauth2.googleapis.com/token`. This is done by hand via `crypto.subtle` (WebCrypto) rather than `firebase-admin`, which targets Node, not the Deno runtime of edge functions. The token is cached in the function's memory until it expires. FCM's response for a given token is handled differently: 404/400 means the token is dead (unregistered/invalid), and it's then deleted from `device_tokens`; anything else (5xx, network) is just "not this time", with no retries (push here is best-effort, not at-least-once; a lost notification isn't worth a separate retry queue). Secrets (`FCM_PROJECT_ID`, `FCM_SERVICE_ACCOUNT_JSON`) go through `supabase secrets set`, not in code; `SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY` are injected by the platform itself into every edge function.

  **The Firebase project and service account aren't something that can be set up from this session**: they require the author's Google account. Instructions were given in the chat (Firebase Console → Add app → package `com.github.tiltozavr2545.amicus` → `google-services.json`; Project settings → Service accounts → private key); the file and key were obtained from the author, and the key was passed only through `supabase secrets set` and isn't stored anywhere (neither in the repository nor in this session's memory), the same principle as with the Management API token. `google-services.json` goes into `android/.gitignore` next to `key.properties`: it's the config of a specific build, the source of truth is the Firebase console, and there's no reason to commit it. One step (creating two `vault` secrets with the `service_role` key) tripped the harness's safety classifier; it wasn't bypassed, and the author ran the SQL himself through the Supabase SQL Editor.

  **Client**: `firebase_core`/`firebase_messaging` were added, and `com.google.gms.google-services` is applied in Gradle (it reads `google-services.json`, so it was applied only after the file was in place; otherwise the build fails). `firebase_messaging` requires `minSdk 23`, raised from `flutter.minSdkVersion` (21); the release build was verified (`flutter build appbundle`) before and after the change. `PushNotificationsRepository.registerDevice()` requests permission (`requestPermission()`, a no-op on Android below 13, where it's already granted), takes the FCM token, upserts it into `device_tokens`, and subscribes to `onTokenRefresh`. It's invoked through `pushRegistrationProvider` (a `FutureProvider`, not `autoDispose`: it lives for the whole session and restarts only when `currentUserIdProvider` changes), `watch()`ed in `MainShellScreen`, the only place reachable only once logged in. `POST_NOTIFICATIONS` was added to `AndroidManifest.xml` (required from Android 13/API 33 to show notifications).

  Deliberately not done: foreground messages (`FirebaseMessaging.onMessage`) aren't handled. Android doesn't show a system notification on its own while the app is open, and no banner/local notification was added for this case (that needs `flutter_local_notifications`, a separate dependency). The main scenario, a notification while the app is closed/in the background, works; a notification while the user is already looking at the feed adds almost no value.

  Verified: all the queue logic by RLS/PL-pgSQL simulation on the live DB (rolled-back transactions, including row-by-row tracing of the counter and the edge case of the 7th post); `send-push` by calling it directly with a dummy token (confirms that the JWT signing and the OAuth2 token exchange really work: FCM responds rather than us failing on our side); the cron via `cron.job_run_details`. Then an end-to-end run on a physical Android device (`flutter run --dart-define-from-file=.env`): the token actually appeared in `device_tokens` after login, `flutter build appbundle --release` with the real `google-services.json` built (which is what CI checks), and most importantly, a real notification actually showed up on the device screen ("Amicus: В ленте уже 9 новых постов", i.e. "There are already 9 new posts in your feed") after `pg_cron` drained the queue on its own, without a manual call, within seconds. `flutter analyze`/`dart format`/`flutter test` are clean (80 tests; there are no client tests for the push module itself, since it doesn't lend itself to a cheap unit test without real Firebase; it was verified manually on the device).

- Fix for the placeholder in push notification text (0.12.1): the first real post from Amicus after the 0.12.0 release arrived on the device as "Новый пост от — загляните в ленту" ("New post from — check your feed"), with no author name. The cause was a field-name mismatch between the DB and the function: migration `20260818190000` puts the key `author_name` into `payload` (snake_case, as everywhere in the schema), while the draft of `send-push/index.ts` built its templates with `{authorName}` (camelCase), so `payload['authorName']` wasn't found and the interpolation silently substituted an empty string. None of the earlier tests caught this: the RLS simulations checked only the shape of the `notification_outbox` row, and the end-to-end test on the device used a `payload` with an `author_name` field set by hand in the test `insert`, not what the trigger actually writes under the real field name; the coincidence masked the typo in the template. Fixed in `send-push/index.ts` (`{author_name}` instead of `{authorName}`), redeployed, and verified: first by calling the function directly on a test row, then with a real post from Amicus, confirmed on the device.

- A list of your own posts on the "Profile" screen (0.13.0) — below the profile card there is now a "My posts" section with the same paginated feed as on the main tab, but filtered by author. Post pagination from `feed_screen.dart` (`_PostCard`, reactions, deletion, keyset scrolling, `feedRefreshTickProvider`) was extracted into a reusable `PostListView` (`lib/features/feed/post_list_view.dart`) with an optional `authorId` — `FeedScreen` is now a thin wrapper around it with `authorId: null`, while `ProfileScreen` passes the current user's `authorId` and its own empty-state text (`noOwnPostsYetMessage`). `FeedRepository.fetchPage()` got the same optional `authorId`, translated into `.eq('author_id', ...)` on top of the RLS already in force — post visibility is neither widened nor narrowed; the filter only trims what the user is already allowed to see. A purely client-side feature: no migrations or RLS. Verified with `flutter analyze`/`dart format`/`flutter test` (80 tests; the fake in `comments_screen_test.dart` was updated for the new `fetchPage` signature).

- A connection's profile on tapping their avatar + the connection date moved to a second line (0.13.1). The avatar in the "Connections" list (`_FriendListItem` in `connections_screen.dart`) is wrapped in a `GestureDetector` that opens the new `FriendProfileScreen` (`lib/features/connections/friend_profile_screen.dart`) — the same body as the "My posts" section from 0.13.0 (avatar, name, `PostListView(authorId: friend.userId)`), but without the edit form: the name/avatar come from the already loaded `Friend` rather than from another query to `users`. Post visibility is not widened — if the connection is muted/blocked, `is_author_visible()` returns an empty list as before, and the screen simply shows "This user hasn't posted anything yet" (`noAuthorPostsYetMessage`). The section has its own heading — `postsTitle` ("Posts") — so it isn't confused with "My posts" on your own profile.

  Along the way, the connection date caption under the name in the same list was fixed — the author reported that the string `"Знакомы N дней — с DD MMM YYYY"` ("Connected for N days — since DD MMM YYYY") overflowed for narrow names. `connectionSummary` in both ARBs replaced `" — since "`/`" — с "` with `"\n"`: duration and date are now on two lines with no dash between them; `formatConnectionSummary()` was not changed — the line break lives entirely in the template. `connection_duration_test.dart` was updated for the new separator. A purely client-side change: no migrations or RLS.

  Verified: `flutter analyze`/`dart format`/`flutter test` are clean (80 tests). Manually on a physical device.

- Third code audit: push notifications and favorites (0.13.2) — an independent check "from scratch" (not prompted by a suspicion, without relying on past reviews), in two passes: the first went through the whole project, the second through the first pass's diff, also deliberately not relying on its conclusions. Eight findings were found and closed; one turned out to be false. The lesson is closer to the second audit than to the first: almost everything found lived in the newest migrations at the time (system account, favorites, push notifications — 0.12.0/0.13.0/0.13.1, i.e. already **after** the 0.11.0 lesson about a single visibility rule) and was the same class of error in new clothes — not because the lesson was forgotten, but because each new feature on its own seemed too small to justify introducing a shared helper for it.

  **Favorites sent pushes about posts from non-Connections.** `favorite_users.favorite_id` was never checked against an actual Connection (deliberately, as with mute/block), but the `enqueue_post_notifications()` trigger used it as the sole condition for an instant push, without asking `is_author_visible()`. A Connection check was added to the function itself. The same migration fixed the order of row locks in the loop over subscribers (`order by viewer_id`) — without it, two simultaneous posts from authors with shared connections could acquire `pending_post_counts` locks in different orders, and Postgres would kill one of the transactions entirely, failing the `insert` into `posts` itself, not just the notification. Migration `20260819100000_fix_favorite_notification_leak_and_lock_order.sql`.

  **The push token leaked between accounts on a shared device.** `device_tokens` wasn't cleaned up on sign-out — `signOut()` was fire-and-forget, without deleting the token — and the `(user_id, fcm_token)` PK kept a new record from overwriting the old one. `PushNotificationsRepository.unregisterDevice()` now deletes its record before `auth.signOut()`, while the session is still alive. `registerDevice()` returns an `onTokenRefresh` subscription that `pushRegistrationProvider` cancels via `ref.onDispose` — and right at this spot the second pass caught a race in the very first fix: Riverpod throws `UnmountedRefException` if `ref` is used after the provider has already been recreated, and `registerDevice()` waits on the system permission dialog, which can stay open indefinitely. Signing out at that moment left the subscription uncancelled — the race brought back the same leak. A `ref.mounted` check was added before `ref.onDispose`.

  **A post's owner couldn't reply to someone else's comment visible to them.** The `comments` SELECT policy learned to show other people's comments to the post owner in 0.13.1; the INSERT policy didn't. The same exception (`is_comment_visible_to_post_owner()`) was added to `with check`. Migration `20260819120000_let_post_owner_reply_to_visible_comments.sql`.

  **`reactions` was left without the protection against spoofing `id`/`created_at`/`post_id` that `posts`/`comments` got back in 0.11.0.** On INSERT, Supabase's default grant was narrowed to the needed columns, with `id` excluded — the existence of someone else's reaction can no longer be distinguished by a 23505 conflict versus success (migration `20260819130000_lock_down_reactions_write_columns.sql`). The second pass found the hole remained on UPDATE: the policy only pinned `user_id`, and you could move your reaction to any existing post, including a hidden one — "success with an empty response" versus "foreign key error" revealed the same "does the post exist". Solved not with a grant (verified live: a client upsert without `onConflict` sends `post_id`/`user_id` in SET on every call, not just `type`, and a grant would have broken legitimate reaction switching), but with a BEFORE trigger — `post_id`/`id`/`created_at` silently revert to their old values on any attempt to change them. Migration `20260819150000_pin_reaction_identity_columns.sql`.

  **Duplication of the visibility rule, found in the same new migrations.** The mute/block check had been rewritten by hand in five places instead of reusing `is_blocked_pair()` — a symmetric `has_muted()` was introduced (migration `20260819110000_extract_has_muted_helper.sql`). The second pass found a third copy of the "is there a Connection" check — in the favorites branch of `enqueue_post_notifications()` from this same batch. `are_connected(a, b)` was introduced but not exposed (like `is_blocked_pair` after 0.11.0) — for the single place that needs a direct grant (the `users` RLS policy), a one-directional wrapper `is_connected_to_caller(other)` was made. Migration `20260819160000_extract_are_connected_helper.sql`.

  **Minor hardening.** `profile_screen.dart`: `_saveName`/`_pickAndUploadAvatar` had no `catch` — a network error was silently swallowed, and the spinner just stopped with no message; along the way `_showError()` was extracted instead of three copies of the same `ScaffoldMessenger`/`SnackBar`. `connections_screen.dart`: activating an invite didn't bump `feedRefreshTickProvider` — a new connection with posts didn't appear in the open feed without a manual pull-to-refresh. `AuthException.message` was shown as raw English text on three auth screens, bypassing the project's own convention — switch on the code, not on the text — already adopted for `PostgrestException`; `authErrorMessage()` was introduced (`lib/shared/auth_error_message.dart`), switching on `AuthException.code`, with 5 new strings in both ARBs and 9 new tests for the function itself.

  **A false finding, for the record.** The second pass suspected that `parent_comment_id`/`reply_to_id` in the `comments` INSERT policy don't check that the parent is on the same post — but that is already rejected by the existing `comments_enforce_reply_rules` trigger, which was missed when reading only the RLS policies. Confirmed by an exploit simulation (rejected) and a control legitimate scenario (works). The migration written for this finding was rolled back in the same session and never shipped — none of it remains in the repository.

  There are still no tests for the push module itself — `FirebaseMessaging.instance` can't be substituted without Firebase mocking infrastructure, which the project doesn't have, and setting it up for this change was considered disproportionate.

  Verified: each finding with an RLS simulation on the live DB (a rolled-back transaction, `set local role authenticated` + `request.jwt.claims`), including a control positive scenario, not by eye. Migrations applied and recorded in `supabase_migrations.schema_migrations`. `flutter analyze`/`dart format`/`flutter test` are clean (89 tests).

- Offline feed mode + photos from the disk cache immediately on open (0.14.0) — closes the "Offline mode" item from the "Near-term plan" in future-development.md, and along the way fixes an everyday complaint from the author: on every restart the post text was drawn first, and the photo loaded a second later.

  **Offline mode.** The new `FeedCache` (`lib/features/feed/feed_cache.dart`, `shared_preferences`) stores a JSON snapshot of the last successfully loaded first page — separately for the general feed and for each "own"/someone else's wall (`authorId` from `PostListView` — exactly the same parameter that already distinguishes `FeedScreen` from `ProfileScreen`/`FriendProfileScreen`, so no second cache was needed). Not the whole pagination, just one page: the point of the feature is "not an empty screen without a network", not offline scrolling of the entire feed. `Post` got `toCacheJson()`/`fromCacheJson()` — its own format rather than reusing `fromRow()`, because the cache stores things already computed on the client (`imageUrl`, counters, your own reaction) that aren't in the raw row from PostgREST.

  `PostListView._PostListViewState` in `initState()` starts reading the cache (`_primeFromCache()`) and the real request (`_loadMore()`) in parallel, without waiting on each other — the cache is almost always faster, so the list gets drawn before the network responds, and the real first page, whenever it arrives, always **replaces** the list entirely (`_posts..clear()..addAll(page)`) rather than being appended on top of the cache — otherwise the preview and live data would be duplicated. For this, the pagination cursor (`_cursor`) was separated from the last element of `_posts`: previously a cache preview in the list itself would have been indistinguishable from an already loaded page, and pagination would not have started counting from the beginning.

  If the real request fails (no network), the list isn't cleared or replaced by an error screen — if something is already on screen (a cache preview or an earlier live page), a `SnackBar` reports the error without losing content; the full-screen error (`_errorMessage`, as before) remains only when the list is empty **and** there's no cache. The same path closes old dead code: previously `_errorMessage` was set when loading the next page failed but was never shown (the render condition was tied to an empty list) — now such a failure also goes to a `SnackBar`.

  A race caught not by eye but by a test (`falls back to the last-seen posts…` in `post_list_view_test.dart` initially duplicated a post): `_primeFromCache()` and the failure branch in `_loadMore()` independently read the cache, each via its own `await FeedCache.load(...)`, and both managed to see an empty `_posts` and both appended the cache — the post appeared twice on screen. Fixed with a single `late final Future<List<Post>?> _cacheLoadFuture`, started once in `initState()`: both sides await the same `Future`, and the second one, seeing that the list is no longer empty, does nothing. A separate `_firstFetchSettled` flag closes a rarer case of the same nature: if the real request arrived first and honestly returned an empty page (the author really has no posts at all), that should not mean "the list is empty, there's a chance to substitute the cache" — a confirmed empty result isn't overridden by a stale cache that may arrive later.

  **Photos from the disk cache immediately.** `CachedNetworkImage` in `_PostCard` got `cacheKey: post.imagePath` — previously the default cache key was `imageUrl` itself, and that's a signed Storage link reissued (a new token query parameter) on every `createSignedUrl()`, i.e. every time the app is opened. A formally different URL is, for `cached_network_image`, formally a different file, so even an already downloaded photo was re-downloaded on the next launch, and because of this asynchronous `Image` widget the post text (available immediately, part of the already loaded model) invariably beat the photo onto the screen. The Storage path (`image_path`) for an existing post is stable, so it's now the cache key — the second and all subsequent displays of the same photo come from disk without a network, while `imageUrl` is still passed separately and used only on a cache miss. The comment on the field deliberately states that the stability holds only "as long as there's no post editing" — item 3 of the "Near-term plan" (post editing) will sooner or later let a post change its photo under the same `image_path`, and at that point the cache key will have to be either versioned or explicitly invalidated; this isn't needed now, because changing the photo of an existing post doesn't exist yet.

  A purely client-side feature — no migrations or RLS, post visibility isn't widened (the on-device cache is just a local copy of what RLS already gave this user last time).

  Along the way, `post_list_view.dart` was switched from a direct `ref.read(supabaseClientProvider).auth.currentUser!.id` to `currentUserIdProvider` (already in `auth_providers.dart`, used by `comments_screen.dart`/`create_post_screen.dart`) — this was needed so that widget tests could substitute the current user at all without a real Supabase client; as a bonus, all feed screens now use one and the same way of finding out "who am I".

  New tests: `feed_cache_test.dart` (round-trip of `Post.toCacheJson`/`fromCacheJson`, including a post without a photo/reaction; `FeedCache` — save/load, separation of slots between the general feed and a specific author, overwrite by a newer snapshot, resilience to corrupted JSON) and `post_list_view_test.dart` (blocking error with no cache and no network; a cache preview keeps the screen from being empty offline; the real page fully replaces the cache preview; the photo's `cacheKey` is `image_path`, not `imageUrl`). The double-post race was discovered precisely by the second of these tests; it wouldn't have been noticed by hand — it doesn't reproduce reliably by eye. Verified with `flutter analyze`/`dart format`/`flutter test` — 100 tests, all green. No real airplane-mode check on a physical device was done in this session — it's worth doing before the next Google Play release.

- Push notifications for comments and replies (0.14.1) — closes the last non-push piece of the "Push notifications" item from 0.12.0: posts/digest/week of silence already sent pushes, comments didn't. Two new `kind`s in `notification_outbox`: `post_comment` (someone commented under your post) and `comment_reply` (someone replied to your comment), with a single `enqueue_comment_notifications()` trigger on `comments` (modeled on `enqueue_post_notifications()` from 20260818190000). Migration `20260819170000_add_comment_reply_notifications.sql`.

  **Deduplicating one event into two notifications.** A reply to your own comment under your own post is simultaneously "your post got a comment" and "your comment got a reply" for the same recipient. Instead of two pushes for one action: if the reply's addressee is the post owner, only `comment_reply` is sent (the more specific one) — `post_comment` for that same recipient is skipped, because it has exactly the same mute/block predicate and skipping it is safe.

  **The visibility check is from the recipient's point of view, not the commenter's.** The `comments` INSERT policy already guarantees that the commenter sees the post/parent/addressee (`is_author_of_comment_visible()`/`is_comment_visible_to_post_owner()`) — but that's the *commenter's* view, and mute isn't symmetric: the fact that I haven't muted you doesn't mean you haven't muted me. The trigger is `security definer`, so it additionally asks `has_muted(recipient, comment_author)` and `is_blocked_pair(recipient, comment_author)` directly, the same way `enqueue_post_notifications()` already does for `viewer`/`author`, rather than relying on the fact that the INSERT went through at all.

  The system account (Amicus) as a recipient is excluded explicitly (`is_system_account()`) — a comment under its post is technically possible (this was opened up in 0.12.0 so Amicus could collect comments from anyone), but the account has no real owner, so there's no one to send a push to.

  Unlike posts, there's no digest for comments — the volume is an order of magnitude lower, and batching would now only add delay without a real spam problem for it to solve.

  No client changes — `kind`/`payload` are read entirely by `send-push` alone, which got four new text templates for each `kind` (`supabase/functions/send-push/index.ts`), following the same rotation pattern as `new_post`/`digest`/`inactive_week`.

  Verified on the live DB with eight scenarios at once, in a single rolled-back transaction (real users and real Connections, not made-up ids): a regular root comment; a reply addressed to someone other than the post owner (two different recipients from one row); the owner's comment under their own post (no notification); a reply to your own comment under your own post (dedup — only `comment_reply`, with no second copy as `post_comment`); a comment from a muted user; from a blocked user; the author replying to themselves (no `comment_reply`); a comment under a system-account post (no notification). All eight gave the expected result on the first try; nothing had to be added afterwards; after `rollback` no test posts/comments/mute/block remained in the database. The migration was applied and recorded in `supabase_migrations.schema_migrations`, `send-push` was redeployed (`supabase functions deploy`, without Docker — deploying the asset doesn't require a local build).

- Settings tab: notification type toggles (0.14.2) — the first half of the "Settings tab" item from the "Near-term plan" in future-development.md (showing the app version on this same screen remains open). A gear icon in the `AppBar` next to the theme toggle — now on all three main tabs (Feed/Connections/Profile), not just where the toggle used to sit individually — opens the new `SettingsScreen` (`lib/features/settings/`) with a "Notifications" section and five independent toggles, one for each source that already wrote to `notification_outbox`: Amicus posts, posts from favorites, comments/replies, digest, week of silence. Each toggle applies immediately — the same pattern already used by theme/mute/block/reactions (optimistic `setState`, rollback on a network error + `SnackBar`), with no separate "Save" button.

  **Schema.** A new `notification_preferences` table (`user_id primary key`, five `boolean not null default true`) — migration `20260819180000_add_notification_preferences.sql`. RLS has the same shape as `device_tokens`: `for all using/with check (user_id = auth.uid())`, `revoke all from anon`. There's no row until the user has opened settings at least once — that reads as "everything on" via `coalesce(..., true)` in each of the five places, rather than being backfilled for all existing users; exactly the same assumption the client model `NotificationPreferences.fromRow(null)` already makes.

  **Five sources — five points of change in two existing triggers**, with no shared helper: `enqueue_post_notifications()` (Amicus posts, favorites, digest) and `enqueue_inactive_week_notifications()` got a `coalesce` check before their `insert`s into `notification_outbox`; `enqueue_comment_notifications()` (0.14.1) — before both of its own. Not extracted into a shared function: five different columns of one table, used once or twice each, aren't the kind of rule duplication that already gave the project `is_author_visible()` (see CLAUDE.md, "Pitfalls"), just ordinary extra indirection.

  **The digest counter keeps accumulating even when the digest itself is turned off.** `pending_post_counts` is always reset to 0 when it crosses 7 — the notification inside the `if` is skipped by a separate check, while the reset happens independently of it. Otherwise someone who turned the digest back on a month later would get one push with a random number accumulated while it was off, instead of simply continuing to get one for every next 7 posts, as if nothing had been turned off.

  **A small detail of the dedup from 0.14.1 holds here unchanged**: if the recipient is both the post owner and the reply's addressee, and has `notify_comments` turned off, both branches don't fire on one and the same condition — there was no need to check this specifically again.

  Verified on the live DB with six scenarios (one for each of the five toggles plus RLS) in a single rolled-back transaction: an enabled RLS check via `set local role authenticated` — an attempt to write someone else's `notification_preferences` row was rejected (`insufficient_privilege`); then, separately, `notify_comments` turned off for the post owner (no `post_comment`), for the reply's addressee (no `comment_reply`, while `post_comment` to another recipient from the same event still arrives); `notify_favorites` turned off for the user who favorited (no `new_post`); `notify_system_account` turned off for one user versus a control user with the default (the second one gets the notification); `notify_digest` turned off — no notification, but the counter still reset, versus a control user with the same counter and the default setting (gets the notification); `notify_inactive_week` turned off versus a control. All six on the first try; the control user for the digest had to be picked after the fact (the first choice, Тимоха, had already favorited the author of the triggering post in the real data, which by itself excludes her from the digest — unrelated to the toggle, but it would have muddied the result). After `rollback` — no test posts/comments, no `notification_preferences` rows, and no edits to `favorite_users`/`pending_post_counts` remained in the DB. The migration was applied and recorded in `supabase_migrations.schema_migrations`. New tests: `notification_preferences_repository_test.dart` (model round-trip, the "everything on" default for a missing/incomplete row) and `settings_screen_test.dart` (all toggles on by default; turning one off doesn't touch the others; a failed save reverts the toggle and shows a `SnackBar`) — 8 new tests, 108 total. `flutter analyze`/`dart format`/`flutter test` are clean.

- Digest: "since the last visit" rather than a raw counter (0.14.3) — a fix right after 0.14.2 following the author's remark: `pending_post_counts` counted posts in a row regardless of whether the user had opened the app in between, so the digest could arrive about posts the person had already scrolled through in the feed days ago. It now counts "how many posts from Connections not chosen as favorites have appeared since the user last opened the app" — genuinely unread, rather than an arbitrary accumulated number.

  **"Opened the app" needs a signal from the client.** `auth.users.last_sign_in_at` doesn't work for this: the session is kept alive via a refresh token for weeks without a new "real" sign-in, so for most users this field would almost never update and would read as "since registration". A new `security definer` function `touch_user_activity()` writes `user_activity.last_active_at = now()` for `auth.uid()`, with no arguments and no direct grant on the table (RLS is enabled, there are no `authenticated` policies at all — the only write path is the RPC itself, bound to the caller, which avoids the dance of "pin `last_active_at` to the server clock via a trigger" that a regular table grant would require). Client side — `UserActivityRepository.touch()` (`lib/features/notifications/user_activity_repository.dart`), called via `userActivityProvider` from `MainShellScreen` the same way and in the same place as the existing `pushRegistrationProvider`: once per session, only for a signed-in user, fire-and-forget.

  **`enqueue_post_notifications()`**: `pending_post_counts` with its trigger increment was removed entirely (`drop table`); instead, for each new post and each viewer, a live `select count(*)` over `posts`, filtered by that viewer's Connections/mute/block/favorites and `created_at > last_active_at`. A viewer who has never opened the (updated) app reads as "became active just now" (`coalesce(last_active_at, now())`) — otherwise the very first post after the feature rolled out would have given someone a digest for the whole feed history at once. It isn't sent again until the condition "there's already a `digest` row in `notification_outbox` with `created_at` later than the start of the current window" holds — the window moves only via a `touch_user_activity()` call, i.e. the next real visit to the app, not with time.

  There are no per-row calls to `has_muted()`/`is_blocked_pair()` inside the recount — that same pitfall from CLAUDE.md ("security definer doesn't get inlined"), only this time it's about filtering candidate posts rather than all of `posts`/`comments`, so instead of the helpers there are direct `join`/`not exists` over `muted_users`/`blocked_users`/`favorite_users`. Along the way, `posts (author_id, created_at)` was added — previously `posts` had nothing but the primary key index, and the new query filters by exactly this pair.

  Verified on the live DB in a single rolled-back transaction: the RPC part (`touch_user_activity()` writes its own row under `set local role authenticated`; a direct `select` on `user_activity` bypassing the RPC was rejected — `insufficient_privilege`, there really are no RLS policies); then a digest scenario on a real pair of Connections — 3 posts before `last_active_at` (forcibly moved an hour back) weren't counted, 6 after it plus a seventh real `insert` (gives a live increment through the trigger itself) — the digest arrived exactly once with a count of 7; an eighth post in the same window — no second digest; manually moving `last_active_at` forward (emulating reopening the app) and a ninth post — the window is fresh, the viewer is below the threshold again, no third digest either. All checks on the first try. After `rollback` — no test posts or `user_activity` rows remained in the DB. Migration `20260819190000_switch_digest_to_since_last_active.sql` was applied and recorded in `supabase_migrations.schema_migrations`. No client Dart tests were added — `userActivityProvider` literally repeats the (for the same reason) already untested `pushRegistrationProvider`, and the server logic was verified live. `flutter analyze`/`dart format`/`flutter test` are clean (108 tests, no change in count).

  **An add-on in the same version** (no new number — the version hadn't been released anywhere yet, so there was no reason to bump): a line with the app version/build appeared at the bottom of the settings screen (`package_info_plus`, `PackageInfo.fromPlatform()` — reads the same value that `flutter build` sees, rather than a separately hardcoded string that would sooner or later drift from `pubspec.yaml`) — fully closes "Settings tab" from the "Near-term plan", the second half of the item after 0.14.2. Along the way, the icons in the `AppBar` were swapped: the theme toggle is now first and the settings gear second, on all three tabs.

  Verified live on the device, not just in the DB: the settings screen opened and showed "Версия 0.14.3 (32)" ("Version 0.14.3 (32)"); turning off `notify_comments` through the real UI, then a real comment from a connection — `notification_outbox` got no rows at all (not just "not sent" but "not queued" — the preference check sits before the `insert`), and the notification shade was empty; turning the toggle back on the same way and a new comment — the push arrived ("Ваш пост прокомментировал(а) Райан Гослинг", i.e. "Ryan Gosling commented on your post") and appeared in the shade with the app minimized. Both test comments were deleted after the check.

- Multimedia posts: up to 20 photos/videos, a carousel, editing (0.15.0) — a post is no longer limited to one photo. The foundation for this is the new `post_media` table (`post_id`, `position`, `media_type`, `storage_path`, `poster_path`), which replaced the single `posts.image_path`; in the feed, media is paged by swiping left via a `PageView` instead of being shown all at once, with an "i/N" counter instead of dots (20 dots in a row wouldn't fit sensibly). Video — a poster (a JPEG of the first frame, generated on the client by `video_thumbnail`) with a play icon; a tap starts `video_player`, with no autoplay on scroll; the duration is capped on the client at ~60 sec when the file is picked. For the first time in the project, editing a published post became possible — its text and its set of media (add/remove/reorder).

  **Schema.** `post_media` has its own SELECT/INSERT/DELETE policy mirroring `is_author_visible`/`visible_author_ids()` via a join to `posts` (an uncorrelated `in (select …)`, not per row — that same pitfall from CLAUDE.md). **There is no UPDATE policy on `post_media`**: replacing a file and reordering are always delete+insert of rows, never an in-place update, so a single row doesn't drag along a separate analysis of "what can be changed on it". The limit of 20 media per post is a backstop `BEFORE INSERT` trigger (`CHECK` can't do cross-row), the main gate is the client. Migrations `20260819200000_add_post_media.sql`, `20260819210000_add_posts_update_policy.sql` (the very first UPDATE policy on `posts` — only `text`, identity columns are unreachable through the grant, the existence oracle was checked: a PATCH of someone else's post matches 0 rows, not a 403 with details), `20260819220000_migrate_image_path_to_post_media.sql` (moving the existing 11 photos into `post_media` with position 0 and `drop column image_path`/`drop constraint posts_has_content` — deliberately applied right together with rolling out the new client rather than postponed; `posts_has_content` wasn't replaced with an equivalent, the "text or media" invariant became purely client-side, since it can no longer be checked atomically at the DB level without an RPC wrapper for multi-upload).

  **Storage.** The path changed to `posts/<author_id>/<post_client_token>/<media_client_token>.<ext>` — the first two segments are untouched, so the existing storage policies needed no changes. `media_client_token` is minted on the client at the moment the file is picked (not on submit), which gives idempotency at the level of an individual file on retry, not just the whole submission. No storage UPDATE policy is needed: each file is its own object, and a replacement is always an upload of the new one + delete of the old. The `media` bucket limit was raised from 20 MB to 100 MB, and `video/mp4` was added to the allow-list — applied directly via the Management API (not a migration, as before for this bucket).

  **Client.** `Post.imagePath`/`imageUrl` were replaced with `List<PostMedia> media`; `fetchPage()` resolves a signed URL only for the first slide of each post, in a batch (`createSignedUrlsResult`) — resolving all 20×20 per page would bloat a single request many times over for slides most readers won't swipe through — the rest are resolved lazily in `onPageChanged`. `FeedRepository.updatePost()` is a new method that diffs `originalMedia`/`finalMedia` (kept/new); reordering is delete+insert of the remaining `post_media` rows; no step requires a shared transaction: deleting an already deleted row is a no-op, a repeated upload is 409-tolerant, and the `(post_id, storage_path)` unique index provides `ignoreDuplicates` for a repeated insert. `create_post_screen.dart` became a shared composer for create/edit modes (`existingPost` is optional) — multi-select via `pickMultipleMedia()`, a preview grid with drag-reorder (`reorderables` — the SDK only has a linear `ReorderableListView`), video duration check via a one-off `VideoPlayerController`. A new "Edit" item in the post menu next to "Delete".

  Verified: 6 RLS simulations on the live DB in rolled-back transactions (someone else's INSERT into `post_media` rejected; SELECT hides media from an outsider and shows it to a connection; the 21st insert fails on the limit trigger; someone else's UPDATE of `posts.text` matches 0 rows; your own UPDATE goes through; changing `author_id` is rejected by the grant) — no leftover data after rollback. Migrations applied and recorded in `supabase_migrations.schema_migrations`; moving the 11 existing photos into `post_media` was confirmed by a control count before/after (11 = 11), and the `image_path` column is confirmed absent. `flutter analyze`/`dart format` are clean, `flutter test` is green across all 19 files (run one at a time — a parallel run of the whole suite in this environment lost the output of some files, which looks like a quirk of the tool capturing multi-threaded `\r` output rather than a real test failure). **Not verified on a physical device in this session** — there's no connected Android device/emulator in the environment (`adb` is unavailable); the carousel, tap-to-play video and the full editing cycle are worth going through by hand before the next Google Play release.

- Account deletion and moving sign-out into settings, both with confirmation (0.16.0) — closes item 1 of the "Near-term plan" (future-development.md), the last MVP-level feature still unimplemented at that point; until now an account could only be deleted manually by an admin upon an email request. `delete_own_account()` is a `security definer` RPC with no arguments (`auth.uid()` inside, like every other self-scoped RPC in the schema), and its body is a single `delete from auth.users`; the existing FK cascade handles everything else (`on delete cascade` on `public.users` and from there across the whole schema — see data-model.md), so nothing had to be cleaned up separately. Reviewing the cascade before writing the migration found a real hole: `invite_links.used_by_id` had no `on delete` action at all — deleting a person who had once activated **someone else's** invite would have failed with a raw foreign key violation on someone else's row. Fixed to `set null` in the same migration. Storage (avatar, post photos/videos) isn't touched by FKs at all — the client deletes its own objects by known paths (`avatar_path` from `users`, `storage_path`/`poster_path` from `post_media` by its own `post_id`s) before calling the RPC, best-effort, and deliberately doesn't block account deletion on failure: once the RPC commits, any object left behind is unreachable (storage policies require `connections`/`users` rows that no longer exist), i.e. an orphan in the bucket, not a leak.

  **Client.** The sign-out button was removed from the profile `AppBar` (it had lived there from the very beginning, without confirmation) and moved into a new "Account" section on the settings screen — next to it there's now "Delete account" (in red, `colorScheme.error`). Both buttons open the same `showDialog<bool>` + `AlertDialog` with Cancel/Confirm as everywhere else in the project (`_confirmAndRun` in `connections_screen.dart`, the post/comment deletion dialogs) — previously sign-out fired instantly on tap, with no confirmation at all. Both operations, plus push token unregistration and (for deletion) Storage cleanup, moved into a new `AccountRepository` — previously `signOut()` called `SupabaseClient.auth` directly from `ProfileScreen`, with no wrapper; now it's testable through a fake, like the other repositories. Account deletion uses `SignOutScope.local` for the final `signOut()` — a server-side revoke request is pointless there (the row itself and its refresh tokens were already deleted by the RPC call just above), and it shouldn't block local session cleanup should the network hiccup exactly at that step. Neither path has explicit navigation after success: `router.dart`'s `redirect` already reacts to the auth state change and takes the user to `/sign-in` on its own.

  Verified: `flutter analyze`/`dart format` are clean, `flutter test` is green on the full suite (125 tests, including new ones for the confirm/cancel/failure paths of both buttons in `settings_screen_test.dart`). Migration `20260819230000_add_delete_own_account.sql` was applied to the live DB and recorded in `supabase_migrations.schema_migrations`. The `used_by_id` hole was first reproduced (`delete from auth.users` on the activator of someone else's invite failed with `foreign_key_violation`), then the same thing after the migration — `used_by_id` quietly becomes `NULL` and the delete goes through. The `delete_own_account()` RPC was checked as a real caller, not as a superuser: `anon` gets `permission denied` (no grant), `authenticated` without JWT claims gets the function's own guard exception "Not authenticated", and `authenticated` with `sub` = its own uid wipes the profile, post, connection, mute, favorite, device token and notification preferences in a single call — while the other side's (the friend's) profile stays untouched. All checks ran in explicitly opened transactions with temporary auth.users rows and a `rollback` at the end, with no side data left in the DB (confirmed by a separate query: 0 test rows remained).

  Also walked through on a physical Android device via the real UI (`flutter run` on a connected phone): for both scenarios an empty temporary account was created directly in the DB (only `id`/email/`crypt()` password — without going through email confirmation). "Delete account": confirmation dialog, tap "Delete" → the app redirected to `/sign-in` on its own (no explicit navigation in the code; the router's reactive `redirect` on the auth state change fired) → the DB confirmed 0 rows in `auth.users`/`public.users`/`device_tokens` → signing in again with the same credentials was correctly rejected ("Incorrect email or password", no crash). "Sign out": the same dialog pattern, after confirming — the same clean redirect to `/sign-in`, while the account itself remained in the DB (unlike deletion), and `device_tokens` is empty — the push token was removed before sign-out, as intended. Both temporary accounts were deleted after the check; no stray `amicus-test-*`/`zz-*` rows remained in the DB.

- A profile photo gallery instead of a single avatar, up to 80 photos (0.16.0) — until now a profile had exactly one photo, replaced wholesale on every upload. Now there's `profile_photos(user_id, position, storage_path)` — the same scheme as `post_media` (one row per photo, non-dense `position`, delete+insert instead of update on reorder, a backstop trigger for the limit instead of a `CHECK`), only the limit is 80 rather than 20, and it has its own, broader visibility.

  **Schema.** `profile_photos` visibility is self or Connection, **without** regard to mute/block: the same rule the avatar itself already had in Storage (20260712120000), not the `is_author_visible()` used for posts — a blocked user must still see the avatar on the "Blocked" screen, which is where the block is lifted. `is_connected_to_caller()` (20260819160000) turned out to be a ready-made one-directional wrapper for exactly this case, so no third copy of the rule had to be written. `users.avatar_path` remained the only field the rest of the client reads (feed, connections list, `friend_profile_screen`) — instead of rewriting those places for the gallery, a new trigger `sync_avatar_path_from_profile_photos()` keeps it in sync with the photo with the lowest `position` on every `profile_photos` mutation (insert/update/delete), including cascading account deletion: by the time the trigger fires on the child rows, the parent `users` row has already been deleted further up the chain, and the `update` simply finds nothing to update. Migration `20260819240000_add_profile_photos.sql`.

  **Storage.** The same `avatars/<uid>/…` prefix as the single avatar — the existing storage policies (SELECT/INSERT/UPDATE/DELETE, 20260707222025) needed no changes; each gallery photo's file is its own object under its own client-minted token.

  **Client.** `ProfileRepository.uploadAvatar()` (one photo, full replacement) was replaced by `fetchPhotos`/`addPhotos`/`reorderPhotos`/`deletePhotos`. The profile screen was rebuilt: the avatar (the position-0 photo, radius 72 — noticeably larger than the original 48) and three buttons "Add photo"/"Reorder"/"Delete photo" sit in a `Row` of two equal `Expanded`s, each centering its child — this puts the avatar's center exactly at a quarter of the screen width from the left and the buttons' center at a quarter from the right, regardless of the actual size of either (not a `Spacer`, which would just dock the buttons to the right edge with no guarantee where their center ends up). Tapping the avatar opens a full-screen swipeable gallery of all photos. Reorder and delete are two separate screens (`profile_photos_screen.dart`): drag-reorder on `ReorderableWrap` (the same widget as post media, 140×140 previews — larger than the original 96×96 so that the photos in the grid are actually visible rather than guessed at) saved with a single tap, and tap-to-select with one confirmation dialog for the whole batch instead of a dialog per photo. The name field and the "Save" button, together with this section, moved inside `PostListView` as its `header` (the first list item) — previously the profile section was a separate non-scrolling block above the post list; now everything scrolls as a single list, leaving more screen space for the posts themselves. The name's "Save" button is shown only when the field text differs from the loaded profile, not always as before. The same technique (`header` on `PostListView`) was applied to `friend_profile_screen.dart` too — a connection's profile screen now also scrolls as a single list, its avatar has the same radius 72 as on your own profile, and tapping it opens the same full-screen gallery (`fetchPhotos(friendId)` — the same table, the same "self or Connection" visibility that already allowed reading `avatar_path` itself).

  **Backfilling legacy avatars.** Found during a manual check on a live account: a user who had set an avatar through the old single-file `uploadAvatar()` (path `avatars/<uid>/avatar_<millis>.<ext>`, and for some seed data the very old `avatars/<uid>/avatar.jpg`) had no row in `profile_photos` — the table didn't exist back then. As soon as such a user added even one photo through the new gallery, `sync_avatar_path_from_profile_photos()` recomputed `avatar_path` **only** from `profile_photos` — the old photo, never listed there, quietly stopped being the avatar, and the file itself stayed in Storage as an orphan. Migration `20260820100000_recover_orphaned_legacy_avatars.sql` finds such files structurally (a file under `avatars/<uid>/` whose name is not a UUID; that's the only way the new gallery names files, so everything else predates it) and appends them to `profile_photos` at the **last** position rather than zero: for an account that has already added new photos, the current `avatar_path` is left alone, and the old photo is simply visible again and available for reordering; for an untouched account `profile_photos` was empty, so this is the only (and therefore zero) row — no visible change, `avatar_path` already pointed there anyway.

  Verified: `flutter analyze`/`dart format` are clean, `flutter test` is green (125 tests). Both migrations were applied to the live DB and recorded in `supabase_migrations.schema_migrations`. RLS and the `profile_photos` triggers were checked in rolled-back transactions on real users (no side data — 0 rows left after all runs): your own INSERT goes through, someone else's (`user_id` not your own) is rejected by the policy; SELECT shows photos to a connection and doesn't show them to a stranger; `avatar_path` updates to the position-0 photo right after an insert and falls back to the next row by position after the current position 0 is deleted (and to `null` when no photos remain); the limit trigger lets exactly the 80th photo through and fails with `profile_photos_limit_exceeded` on the 81st; someone else's DELETE matches 0 rows. The backfill migration was first run in a rolled-back transaction against all affected rows (5 untouched accounts + 1 already affected) and reconciled row by row, and only then applied for real; after applying, a separate query confirmed that the affected account's `avatar_path` didn't change and its old photo appeared at the third position.

  Walked through manually on a physical Android device (`flutter run` on a connected phone, real login) — that run is what found the legacy avatar hole above, plus several rounds of layout tweaks after the live review (button position and size, avatar size on both screens, preview size in reorder/delete), each redeployed to the device and reviewed again. A full scenario pass (adding/reordering/deleting photos on both screens — your own and a connection's) still needs to be done end to end before the next Google Play release — this session checked the effect of each specific tweak, not the end-to-end scenario as a whole.

- Language switching in settings + localized push notifications (0.16.0) — closes both items of the "Near-term plan" (future-development.md); the list there is now empty. Previously the UI language always followed the system locale (`AppLocalizations.supportedLocales` already covered `en`/`ru`, there was no switcher), and the push text in `send-push` was hardcoded in Russian regardless of the recipient's language.

  **Client.** A new `LocaleNotifier` (`lib/l10n/locale_provider.dart`) — the same "null = system" pattern `ThemeModeNotifier` already uses: `null` until the first explicit choice, persisted in `shared_preferences` (`app_locale`, language code only). `KrugApp` (`app.dart`) passes it into `MaterialApp.router`'s `locale:` — previously this parameter wasn't set at all and Flutter resolved it from the device's list itself. On the settings screen there's a new "Language" row between "Notifications" and "Account" with a dropdown (System default / English / Русский); the choice applies instantly, without reopening the screen. A separate `effectiveLocaleCodeProvider` implements the same fallback logic `MaterialApp` does internally (the override, otherwise the device locale, otherwise `en`) — it's needed separately because push token registration (`pushRegistrationProvider`) happens before any widget exists and can't ask `Localizations.localeOf(context)`.

  **Schema.** `device_tokens` gets a new column `locale text not null default 'ru' check (locale in ('en','ru'))`, migration `20260820110000_add_device_token_locale.sql`. The locale is stored per token (device), not per user: `device_tokens` is exactly what `send-push` already reads when resolving the recipient, so no join is needed, and if one account is signed in on two devices with different languages, each gets text in its own. The default is `'ru'`, not the `en` the client itself resolves to without an explicit choice — on purpose: existing rows created before this column must keep receiving Russian text (as before) until the very first `registerDevice()`, rather than silently switching to English because of the column default. The insert grant on `device_tokens` (20260819140000) is an explicit column list, not "everything", so `locale` had to be added there with a separate `grant insert`.

  `PushNotificationsRepository.registerDevice()` got a required `locale` parameter and writes it on every token upsert — both on first registration and on `onTokenRefresh`. `pushRegistrationProvider` now watches not only for a user change but also `effectiveLocaleCodeProvider` — switching the language in settings rebuilds the provider entirely (the old `onTokenRefresh` subscription is cancelled, `requestPermission()`/`getToken()` are called again, but that's cheap — permission is already granted, the token is cached) and upserts the same `device_tokens` row with the new locale, so the record doesn't go stale until the next restart.

  `supabase/functions/send-push/index.ts`: `TEXTS` is now `Record<locale, Record<kind, string[]>>` instead of a flat `Record<kind, string[]>` — four English variants were added for each `kind` (`new_post`, `inactive_week`, `digest`, `post_comment`, `comment_reply`), in the same tone as the Russian ones. `pickText(locale, kind, payload)` takes the locale of the specific token (`TEXTS[locale] ?? TEXTS.ru` — a fallback in case a future row has a value outside the current check constraint); text selection moved from the loop over outbox rows into the loop over the recipient's tokens, since it's now a per-token decision rather than per-row.

  Verified: the migration was applied to the live DB and recorded in `supabase_migrations.schema_migrations`; the column and its default were confirmed by a direct query against `information_schema.columns`. An RLS insert with `locale='en'` from a real user (not a superuser) goes through; an insert with `locale='fr'` fails on `device_tokens_locale_check` — both runs in rolled-back transactions, with no side rows. `send-push` was redeployed (`supabase functions deploy send-push`, without Docker — deploying the asset doesn't need a local build). `flutter analyze`/`dart format` are clean. `flutter test`: three scenarios in `settings_screen_test.dart` that tapped "Delete account" directly started failing — the new "Language" row pushed that button outside the test's fixed 600px viewport; `ensureVisible()` + `pumpAndSettle()` were added before the tap in all three. Separately, and unrelated to this feature, "Asset 'shaders/ink_sparkle.frag' not found" surfaced on 6 tests unrelated to language/push — it also reproduced on an unmodified `develop`, i.e. an environment problem, not a code one; `flutter clean && flutter pub get` rebuilt the asset cache and cleared it — all 125 tests are green.

  Walked through on a physical Android device (`flutter run` on a connected phone): the settings screen showed the new "Language" row, and switching to English instantly redrew the whole UI in English without a restart; a direct DB query right after the tap confirmed that `device_tokens.locale` for this token was updated to `'en'` within the same second. Going back to "System default" reverted it to `'ru'` (the device locale is `ru-RU`). **Not verified in this session**: actual delivery of a localized push to the device — that would have required inserting a test row into `notification_outbox` and waiting for the per-minute `pg_cron` drain; the author decided to postpone that run. It's worth doing manually before the next Google Play release.

- Second full audit: 14 findings closed (0.16.1) — a review of the whole project, not a diff: 68 migrations, the edge function, all the Dart, the Android and CI config. The tests were green throughout (125/125), meaning they caught none of the findings. Below, in decreasing order of severity.

  **The feed cache served the previous account's feed.** `FeedCache` was keyed only by scope (`feed_cache_main`), without the user, and was cleared neither on sign-out nor on account deletion. Sign in with a different account on the same device — and `_primeFromCache()` drew the previous account's posts for them: texts, author names and signed media URLs, still live for 24 h, from people they aren't connected to. Offline this stayed on screen indefinitely, because `PostListView` deliberately falls back to the cache when a request fails. The key is now `feed_cache_<viewer>_<scope>`, plus `FeedCache.clear()` by prefix (which also sweeps the old unnamed keys) in `signOut()` and `deleteAccount()`. Both lines of defense are needed independently: the key holds if `clear()` didn't run (crash, force-stop), and `clear()` ensures the bytes don't stay on disk after the account is gone.

  **The carousel drew another post's media.** `_MediaCarouselState` initialized `_items` from `widget.media` once (a `late` field) and had no `didUpdateWidget`, while `build()` reads exactly `_items`. Cards in `ListView.separated` have no keys, so after a refresh, when a new post appears at the top, Flutter reuses State by index — and the old post's photos ended up under the new post's name and date. Added `didUpdateWidget` comparing by row ids (not by list identity: `Post.copyWith` on a reaction returns the same `List`, and already-resolved URLs must not be reset) and a generation counter so that a late-arriving resolve for the old post isn't written into the new list. The regression test was checked with the fix removed — it fails with exactly the expected "old URL shown".

  **`send-push` could be drained by anyone.** The function does privileged work under `service_role`, but didn't check the caller at all, and the platform's `verify_jwt` by default accepts any project JWT — including the anon key, which sits inside the APK (`--dart-define`) and is public by design. Anyone who unpacked the app could call it in a loop: each call is a token exchange with Google plus an FCM request per recipient device, and `sent_at` is set regardless of delivery success, i.e. undelivered notifications were simply lost (there's deliberately no retry here). Added a caller check against a separate shared secret in a custom `x-send-push-secret` header, using a constant-time comparison rather than `===`.

  The first version of this fix compared the bearer with `SUPABASE_SERVICE_ROLE_KEY` and **turned off pushes for four minutes in production** — worth recording, because I did check the premise, just the wrong pair. What was checked was that the key in Vault, which cron uses to call the function, matches the `service_role` from the Management API: it matched byte for byte. But the function compares not against that, but against what the platform injects into `SUPABASE_SERVICE_ROLE_KEY` — and the project has two generations of keys live at once (legacy JWT and the new `sb_secret_…`), which are different values of different lengths. Every legitimate call got a 401, visible in `net._http_response`. Nothing was lost: `sent_at` is set only on success, so rows would simply have waited in the queue (which was empty at the time). That's why the secret is now separate and exists purely for this handshake: `Authorization` must remain a valid JWT — it's checked by the `verify_jwt` gate in front of the function — and there's no longer anywhere for the key format to diverge. Migration `20260820160000` adds the header to the cron job. Also, `sendToToken()` was wrapped in try/catch: previously an exception from the token exchange broke the whole drain, `sent_at` wasn't set, and the next minute re-sent what had already been delivered.

  **The last media slot was unreachable.** `remaining` went into the picker's `limit` as is, and `image_picker` throws `ArgumentError` on anything less than 2 — i.e. on the 19th of 20 post media and the 79th of 80 profile photos, tapping "add" blew up instead of opening the gallery. And **synchronously**, before the method's first `await`, so a `try` around the result wouldn't have caught it either. A shared helper `pickerLimit()` returns `null` ("no limit") where one slot is left; the real cap is enforced by `take(remaining)` on both screens anyway. The test also pins the premise itself — if the picker ever accepts 1, the helper becomes dead weight and that will be visible.

  **A post with 20 media couldn't be resubmitted.** A `BEFORE INSERT` trigger in Postgres fires before `ON CONFLICT` arbitration, so a row that `DO NOTHING` would discard anyway still went through `enforce_post_media_limit()`. On a retry (`.timeout()` doesn't cancel the request — the post is already published, but the screen showed an error) the very first of the 20 rows hit `count(*) = 20 >= 20`, and the user was permanently stuck on "Failed to publish". Both limit triggers now let through a repeat of an already existing item by the same unique key the conflict is resolved on; a genuine 21st item is rejected as before. Migration `20260820120000`, verified by simulation under the `authenticated` role: a retry of 20 rows goes through and leaves 20, a new 21st fails with `post_media_limit_exceeded`.

  **Adding profile photos didn't survive a timeout.** `addPhotos()` uploaded via a bare `uploadBinary`, whereas the feed had long had a 409-tolerant wrapper for the same case: retrying a batch, part of which had already landed, failed with "resource already exists" — every time. The wrapper was extracted into a shared `shared/tolerant_upload.dart` and is used by both repositories.

  **The `media` bucket in the repo lagged behind production and didn't cover the client anyway.** `20260709134154` left the bucket image-only at 20 MiB; when videos appeared, the limits were edited by hand in the dashboard (at the time of the audit the live bucket was at 100 MiB and `video/mp4`), and that never made it into a migration — rebuilding from migrations would have produced a schema where video doesn't upload at all. Plus the hole was wider: `storage_client` takes the content type from `lookupMimeType()` by the object's **name**, and the composer accepts six extensions (`mp4, mov, m4v, 3gp, webm, mkv`) against one allowed type, so a `.mov` shot on an iPhone went up as `video/quicktime` and bounced. Migration `20260820130000` pins 100 MiB and all six video types.

  **Android Auto Backup carried the refresh token off the device.** `<application>` had neither `allowBackup="false"` nor extraction rules, and Auto Backup is on by default and picks up SharedPreferences — exactly where `supabase_flutter` keeps the session (`SharedPreferencesLocalStorage`, plain XML) and where the feed cache lives. Restored on another device, that refresh token is a working session for the account, no password needed. Added `allowBackup="false"` (closes cloud backup on all versions) and `data_extraction_rules.xml`/`backup_rules.xml` (close device-to-device on Android 12+, which `allowBackup` doesn't). Verified on the merged manifest of the release build — all three attributes survived into it, and no library manifest overrode them.

  **`public.users` was the last table without a narrowed write grant.** The technique from `20260818130000` reached posts/comments/reactions/favorite_users/device_tokens/post_media/profile_photos, but not `users`: the UPDATE policy only checks "is this my row", while the grant remained on all columns. So with a plain PATCH any user could turn on `dislikes_disabled` for themselves — a flag that, by the design of `20260711120000`, is set by a separate data update and is never written anywhere in the client — and forge `created_at`, bypassing the "account younger than a week" check in `enqueue_inactive_week_notifications()`. Now it's `update (name, avatar_path)` and no INSERT at all (the row is created by a trigger). Also, `name` is capped at 100 characters (`posts.text`/`comments.text` have been capped since `20260716120000`, but the name, which ends up in every feed row, wasn't), with truncation in `handle_new_user()` so that a long name from `raw_user_meta_data` doesn't turn into a sign-up error, and with `maxLength` on the profile screen. Migration `20260820140000`, all four scenarios verified by simulation.

  **Reorder could wipe out the entire gallery.** Both `profile_photos` and `post_media` deliberately have no UPDATE policy; reordering is delete+insert of rows. But the client sent this as two PostgREST requests, i.e. two transactions: a disconnect after the first (and `.timeout()` makes this an ordinary case) left not "the order wasn't saved" but missing rows. For the gallery this is the worst case in the schema — up to 80 rows plus the `sync_avatar_path_from_profile_photos()` trigger, which would have already nulled `users.avatar_path`, so the avatar disappeared from the feed, the connections list and the "Blocked" screen all at once, while the files stayed in Storage without a single reference: exactly the kind of orphaning `20260820100000` was written to clean up. Only the server can provide a transaction here — PostgREST makes one request per call. Added `reorder_profile_photos(photo_ids)` (requires the **whole** gallery: positions are rewritten to a dense 0..N-1, and a partial reorder would collide with untouched rows; a mismatch is `PT422`) and `set_post_media(post_id, items)`, which takes the desired final state and returns the paths nothing references anymore — the client deletes the objects only AFTER the rows are rewritten (an orphaned object is wasted space, while a deleted object with a live row is a broken image in everyone's feed). Diffing moved to the server, and `updatePost()` lost its `originalMedia` parameter. Migration `20260820150000`.

  **A slide kept playing the old video.** `_MediaSlideState` held the `VideoPlayerController` from the previous `widget.item` and, lacking `didUpdateWidget`, returned `VideoPlayer(_controller)` for whatever came next. Added a reset on a row id change (specifically id: a rebuild that merely substituted the resolved URL for the same row must not interrupt playback). Also, `_play()` got a try/catch — an unplayable codec or an expired URL previously produced an unhandled async error and a leaked controller.

  **Account deletion didn't remove the gallery.** Only `users.avatar_path` (which is just the top photo, position 0) and post media were cleaned up — `profile_photos` appeared in a migration later than account deletion itself, so up to 79 objects stayed in the bucket forever, and by that point the cascade had already taken the rows away, so there was nothing to find them by. Now the paths are collected as the union of both sources (a legacy avatar has no row of its own).

  **The "add media" button got stuck for good.** `_pickMedia()` set `_isPicking = true` without `try/finally`: an exception inside the file-processing loop (an unsupported codec crashes `initialize()`, a huge file crashes `readAsBytes()`) left the button disabled forever, and the only way out was to lose the draft. Processing is now per file — one broken file doesn't cost the user the rest of their selection — with a new `failedToAddMediaError` string in both locales.

  **Documentation.** In `docs/data-model.md` the table list still contained `pending_post_counts`, dropped in `20260819190000`, and lacked `notification_preferences` and `user_activity`; the reorder and Storage descriptions were brought up to date. An item about `BEFORE INSERT` firing before `ON CONFLICT` was added to "Pitfalls" (CLAUDE.md/AGENTS.md, byte-for-byte twins).

  Verified: `make verify` is green (136 tests versus 125 before the changes), the `bundleRelease` release build builds, all four migrations were applied to the live DB and recorded in `supabase_migrations.schema_migrations`. The grant narrowing, the limit retry, both RPCs and the rejection of another user were verified by simulation with `set local role authenticated` + `request.jwt.claims` in rolled-back transactions, not by eye.

- Photo carousel: prefetching the adjacent slide and remembering the position (0.16.2) — two complaints about swiping through photos in posts, both about the same place (`_MediaCarousel` in `post_list_view.dart`).

  **The second and later photos took a long time to load.** `fetchPage()` deliberately signs URLs only for the first slide of each post (otherwise a feed page would cost up to 20x the signatures for slides that mostly go unviewed), and the carousel fetched the rest lazily — but kicked off signing from `onPageChanged`, i.e. **after** the swipe had already finished: the user stared at a spinner while signing + download ran. Now resolution runs in a `_prefetchRadius = 1` window around the current slide (`_resolveAround`), as a single batch via the new `FeedRepository.resolveMediaUrls()` (`createSignedUrlsResult` — one round trip for slide+poster+neighbors instead of six), and `allowImplicitScrolling: true` on the `PageView` keeps the adjacent page in the tree, so `CachedNetworkImage` starts downloading bytes before the swipe rather than after. The same technique was applied to the full-screen viewer. Also closed an old nit: a failed resolve (offline, timeout) used to be an unhandled async error — now the slide just stays with a spinner and is retried on the next swipe. `fetchPage()` was switched to the same `resolveMediaUrls()`, and the duplicate batch signing was removed.

  **The carousel position reset when scrolling the feed.** A post that scrolled out of the `ListView` window is destroyed along with the carousel state, and when it came back it was rebuilt from the first photo — leave a post at 3/4, scroll down and back, and it's 1/4 again. Added `CarouselPositionCache` (`carousel_position_cache.dart`) — an LRU map `post_id → slide index` with 200 entries, **in memory only**: this is the context of the current pass through the feed, and after the app is closed a post honestly opens from the first photo (exactly as the user asked). The key is the post id, not the list position, so a reused `State` doesn't inherit someone else's place; the index is clamped to the length (the media may have been edited), and `clear()` is called on sign-out and deletion — the next account has no need for other people's post ids.

  Verified: `make verify` is green (143 tests versus 136). Both changes are covered by widget tests on a real `ListView` — the adjacent slide is signed and built before the swipe, and the position survives the post going beyond the cache extent and coming back; the memory test fails if the cache write is removed.

- Notification texts, settings labels and the feed filter (0.16.3) — entry added retroactively: commits `0f20237` and `890aff4` bumped the version to `0.16.3+37`, but it never made it into the CHANGELOG (found by the third full audit, see below).

  **Register in the Russian locale.** Imperatives using the informal "ты" were switched to the formal "вы" — the English original keeps a single register throughout, while the Russian drifted between the two. Along the way the notification toggle labels were named after what they control instead of repeating the word "Уведомления" ("Notifications") under a section heading that already says it.

  **The system account toggle was renamed** to app update alerts: `send-push` gained an `app_update` text set, and `notification_outbox.kind` was extended with that value (`20260820180000`). In `890aff4` the link went further: a system account post no longer enqueues anything on its own — the kind and the setting remain for whoever will send this notification separately (`20260820190000`).

  **Feed.** The system account was removed from the general feed query — its posts are only visible when you open its profile directly.

- Third full audit: 22 findings closed (0.16.4) — again a review of the whole project, not a diff: 74 migrations, the edge function, all of the Dart code, Android and CI config, documentation. The tests were green again (143/143) and again caught none of the findings. Below, in decreasing order of severity.

  **Publishing posts was broken in production.** `20260819190000` replaced the digest counter with a window over `user_activity` and dropped the `pending_post_counts` table. The next two migrations only changed the system account branch of `enqueue_post_notifications()`, but they were written on top of the *pre-reform* text of the function and applied it in full via `create or replace` — together with the loop that writes into the dropped table. `check_function_bodies` checks plpgsql only syntactically, and table names are resolved at runtime, so both applies went through silently. An `AFTER INSERT` trigger runs in the transaction of the insert itself, so `42P01` rolled back the post itself: nobody who had at least one Connection without mute/block/favorite could publish — 7 of 15 live accounts at the time of the fix. `20260821100000` rebuilds the body explicitly from both sources. Along the way, the "since your last visit" digest itself came back, and `user_activity`/`touch_user_activity()`/`posts_author_id_created_at_idx` stopped being orphans: the client called the RPC on every launch, but nothing read it.

  **The dislike opt-out could be bypassed with a direct request.** `20260819130000` recreated the INSERT policy on `reactions` to pin `created_at` and did not carry over the `dislikes_disabled` guard from `20260711120000`. Its UPDATE twin kept it, so the rule was only half alive: someone who had not reacted yet could dislike a protected author with a plain POST and land in `reaction_summary()`; someone who already had a reaction got refused. Reproduced by simulation before the fix, closed by `20260821110000`.

  **Draining the notification queue sent duplicates.** Rows were selected by `sent_at is null` and not marked in any way while being processed, and `sent_at` was set after the whole loop — while cron fires once a minute and `net.http_post` is fire-and-forget. 200 rows × ~2 devices × ~400 ms of sequential requests ≈ 160 s, so a run overlapped the next two and sent the same push 2–3 times. Added `notification_outbox.claimed_at` and `claim_notification_outbox()` with `for update skip locked` and a 5-minute reclaim window (`20260821150000`); sends go out in a pool of 10, and the Google token is fetched once before the batch — its failure now releases the claim and returns 500 instead of silently losing the whole batch disguised as a 200.

  **Pruning device_tokens could wipe out every registration at once.** Any 404/400 from FCM was treated as a dead token, and the delete went by `fcm_token` without `user_id`. A wrong `FCM_PROJECT_ID` returns 404 for every token in the batch — meaning one typo in the config wiped pushes for everyone at once. Now the error body is read and an explicit `UNREGISTERED` is required (a bare `NOT_FOUND` is deliberately not accepted — it is also the response for someone else's project), and the delete is keyed by the `(user_id, fcm_token)` pair: two accounts on one phone hold the same token string, and pruning took out the other account's registration.

  **The post menu deleted the wrong post.** `onEdit`/`onDelete` closed over `index` from `itemBuilder` and lived inside the `PopupMenuButton` route, outliving the replacement of `_posts` by the first network page on top of the cached preview. The write side was already protected against this (`removeWhere` by id), the read on entry was not: a `RangeError` or an irreversible deletion of the neighboring post. All three methods were switched to take a `Post` instead of an `int`.

  **The "files → row" order cost data in three places.** Account deletion cleared the bucket before `delete_own_account()`, so an RPC timeout left a live account with no photos or media at all — for the account itself and for all of its Connections. The same in `deletePost` (the post remained as a broken slot in everyone's feed) and in `deletePhotos` (plus `users.avatar_path` pointed to a deleted object, and the avatar disappeared everywhere). Everywhere it was flipped to "row → files", and bucket cleanup became best-effort. This turned out to be possible because the storage DELETE policies only check the path prefix against `auth.uid()` and do not read `users`/`connections` — verified against `pg_policy`; the comment in 0.16.0 on this point was wrong.

  **Notification toggles silently switched themselves back on.** The optimistic rollback restored the whole snapshot, so a failed request reverted a neighboring toggle that had already been saved — and since `save()` upserts all five booleans at once, the next save wrote that stale snapshot to the server. The rollback became per-field. Covered by a test that fails on the old code.

  **The name in the profile could not be cleared.** Seeding the field checked whether it was empty, and the listener from `initState` rebuilt the screen on every keystroke: backspace over a selected name immediately brought the old text back, caret and all. Replaced with a `_nameSeeded` flag — the same seed-once shape as in `SettingsScreen`.

  **Deploy ran on `pull_request_target`.** The job built post-merge code (including `build.gradle.kts`/`settings.gradle.kts` submitted by the PR author) with `ANDROID_KEYSTORE_BASE64` and `PLAY_SERVICE_ACCOUNT_JSON` in the environment — the only barrier was the person who pressed Merge, and the key, per the comment in `build.gradle.kts`, "can be neither replaced nor recovered". Switched to `push` to main (BASE_REF is `github.event.before` with a fallback to `HEAD^`, the PR number is looked up by commit). All four third-party actions in both workflows are pinned to SHAs instead of moving tags. The release path no longer trusts that CI was green: a `make verify` step was added before the build. The silent fallback of the release to the debug key is closed, but not on the first try — see the separate item below.

  **Oracles and excess grants.** `is_author_of_comment_visible()` returned three values instead of two (`false` — the comment exists, the author is hidden; `null` — there is no comment) and through PostgREST worked as a row-existence oracle: a blocked user who had saved someone else's id could poll it to track whether the row was still alive. Reduced to a strict boolean (`20260821130000`) — this does not affect the policies, where the function only appears in `or` chains. Separately, `post_media` and `profile_photos` were created after `20260818140000` and again received Supabase's default grants for `anon`, including **TRUNCATE**, which RLS does not apply to at all; revoked by `20260821120000`.

  **Indexes for queries that already existed.** `connections` had an index only on the `user_a_id` half, while every visibility decision asks about both (`visible_author_ids()`, `are_connected()`, the loop in the posts trigger) — `a = X or b = X` without a second index degenerates into a seq scan of the whole table. Plus `favorite_users(favorite_id)` (a full scan inside the trigger on every publish) and `posts(created_at desc, id desc)` for the feed sort.

  **Cleanup.** N+1 URL signing in the post editor (up to 40 requests for a post with 20 items) was replaced by a single batch via the existing `resolveMediaUrls()`, after which the single `resolveMediaUrl()` became dead and was removed. `fetchFriends` no longer makes four sequential round trips instead of one. Avatars and gallery tiles are decoded at their render size (`ResizeImage`) rather than at the full ~12 MB of ARGB each, and the photo deletion screen became a lazy `GridView` instead of a `Wrap` that built all 80 tiles at once. The easter egg was pulled out of the theme provider: tap counting moved to `TapStreak`, navigation to the widget, and the network request got error handling. `systemAccountId` no longer filters the feed with a compiled-in literal — the set is returned by `system_account_ids()` (`20260821160000`), and the constant stays as a fallback for offline. Removed three copies of `const _bucket = 'media'`, the `_run`/`_runFavoriteToggle` duplicate, the dead `userId` parameter in `reorderPhotos` along with its chain across four places, and a duplicated English variant of the push text. The sign-up screen stopped distinguishing an already taken email from a free one — Supabase deliberately returns a user without identities precisely so that accounts cannot be enumerated, but the screen read that signal and printed "email already registered". Added missing `mounted` checks in four `catch` blocks where the adjacent `finally` already did them.

  **The last three items of the same audit.** `muted_users`/`blocked_users` remained the only tables where `authenticated` could write the server-side `created_at`: they appeared before the project settled on the column-grant technique. Narrowed to `(muter_id, muted_id)`/`(blocker_id, blocked_id)` the same way and for the same reason as `favorite_users` in 20260819140000 — pinning by value would have broken the regular repeated upsert through the DO UPDATE branch. Next, `device_tokens`: `fcm_token` was a free-form `text` with no length limit, and the number of rows per user was not limited by anything, even though one outbox row expands into an FCM request per token — ten thousand junk rows would have brought back the overlapping drain runs that the claim had just closed. Added `check (char_length between 64 and 4096)` and a backstop trigger at 20 rows. The trigger **evicts the oldest row rather than failing** — deliberately unlike the media limits: device registration is fire-and-forget and has no screen behind it, so an exception would mean that a user who has accumulated expired tokens silently stops receiving pushes forever. A duplicate on `(user_id, fcm_token)` is let through by the first condition — that very `BEFORE INSERT` ahead of `ON CONFLICT` arbitration from "Pitfalls", and here hitting DO UPDATE is not rare but the norm: `_upsertToken` is sent on every launch and every language change.

  **Video no longer sits in memory for the whole composer session.** `PendingMedia.bytes` was replaced with `MediaSource`: images stay as bytes (the preview draws them anyway, and they are downscaled to `maxWidth: 1600`), video carries a file path. Previously `readAsBytes()` was called on every selected clip right at selection time, and up to 20 clips of 50–100 MB each sat in memory from selection until sending.

  It is worth writing down separately what this is NOT, because the first version of the fix was worse than the original. The obvious `storage.upload(path, File)` looks like streaming and is not: in `storage_client 2.6.0` it does `file.readAsBytesSync()` (`src/fetch.dart`, `_handleFileRequest`) and passes the result into the same `MultipartFile.fromBytes` as `uploadBinary` — the same bytes in memory, but read **synchronously** on the calling isolate, i.e. a frozen UI on a hundred-megabyte clip. The win here is not that there is no read, but WHEN it happens: a clip is read asynchronously at the moment of its own upload and released after it, instead of being read at selection time and sitting next to nineteen others. This is recorded in the comment on `uploadTolerantFile` so that the next person does not "fix" it back to `upload(File)`.

  **Email validation before sending the request.** Until now the sign-up screen validated only the name — the address went to the server as is. Hence three accounts in the database on `@example.com`: the domain is reserved by RFC 2606 precisely so that mail to it is never delivered, so the confirmation email physically could not arrive, and the account stayed unconfirmed and unable to sign in forever. Added `validateEmail()` (`shared/email_validation.dart`): syntax plus a list of domains and TLDs that are undeliverable by specification (`example.com/.net/.org`, `.test`, `.example`, `.invalid`, `.localhost`, `.local`). Wired into sign-up and password recovery — both paths send an email.

  Disposable email services are deliberately NOT blocked: that is a judgment about real domains, the list needs constant maintenance, and a single mistake locks out a real person. The list contains only what is undeliverable by standard — rejecting it costs nobody anything. The check is purely client-side and is not a security control: anyone can still call the auth API directly, so nothing depends on it being enforced.

  The widget tests for this rely on the same property as the existing empty-name test: their `ProviderScope` has no Supabase client, so if the check ever stops firing BEFORE `signUp()`, the call will crash instead of showing the message. A passing test is proof that the request was not sent.

  **Cleaning up abandoned sign-ups.** Supabase does not delete unconfirmed accounts on its own: the row in `auth.users` (and, via `handle_new_user()`, in `public.users`) appears at the moment "Sign up" is pressed, not when the link in the email is followed. Six such accounts had piled up — three on `@example.com`, where the email could never arrive in principle, and three unconfirmed ones on a real gmail; all six had zeros in every table. Deleted manually, database 16 → 10 accounts, content untouched (22 posts, 11 connections, 54 reactions, 9 comments before and after).

  To keep them from piling up again — `purge_abandoned_signups()` and a daily cron at 03:40 UTC (`20260822100000`). The conditions are deliberately narrow, because the function deletes people: only unconfirmed, only older than 30 days, only with zero rows in every table, and explicitly not the system account. The last two checks are redundant today — without confirmation there is no session, and hence no data — but they are exactly what will turn out to be the only protection if someone ever changes the email confirmation rules.

  Verified by simulation in a rolled-back transaction on fake accounts: an old abandoned one is deleted, a fresh one (3 days) stays, a confirmed one aged 400 days stays, and old unconfirmed ones with a post or a connection stay, while an identical one with no activity is deleted. On the live database the run returned 0.

  **Release build falling back to the debug key: on the second try.** Without `android/key.properties` a `--release` build was signed with the world-famous debug key and named `app-release.aab`, like any other. The first fix put a `logger.warn` with a banner here — and that was the wrong remedy for two reasons at once. A warning gets lost in the build log that nobody reads; but worse, on a machine where `key.properties` is present — that is, on every machine where this matters at all — the warning branch is unreachable, so you cannot tell a working warning from a broken one without deliberately hiding the key. That is exactly how it came to light: there was no banner in the `pre-push` log, I first explained that by Gradle output being filtered in `flutter build` — and was wrong, because the real reason was that the fallback simply wasn't triggering.

  Now the build **fails** instead of warning. Flutter always shows the failure, and that is the right default: nobody needs an unsigned release. A deliberate compile check stays available via `-PallowDebugSigning=true` — `make build-android` and the CI build step pass it explicitly. The deploy workflow deliberately does not pass it, so a keystore that failed to show up there will stop the build instead of shipping a debug-signed bundle to alpha.

  Verified by real builds, not by reasoning: without the key and without the flag — failure with the full banner in the `flutter build` output; without the key with the flag — the build passes; `make build-android` without the key passes; with the key in place it passes as before. `key.properties` was moved away and put back for the checks, and its checksum was compared before and after.

  **Auditing the tests themselves.** A coverage measurement showed 46.8% of lines and a very uneven distribution: screens that were written together with tests are covered at 77–87%, while the whole profile area and the repositories are barely covered. Worse, a line-by-line check against recent fixes gave an unpleasant result: **eight out of ten changed places were not executed by any test** — both deletion orders, account deletion, the whole video fix, `system_account_ids()`, reorder and the name field fix. That is, fixes described as "preventing data loss" rested on reasoning alone.

  No redundant tests turned up, though, and that is partly a property of the language: a test referring to a removed symbol won't compile, so there are no dead tests here. There are no duplicates between files and no outdated assertions about behavior either.

  The deletion-order rule was extracted into `deleteRowsThenObjects()` — it lived in three copies and was inverted the same way in all three, exactly the same pattern as with the visibility rule in 0.11.0. Now it is stated once and checked by four tests; the other three places inherit it. Added tests for the gallery screens (selection, deleting only what is checked, cancel, error, grid laziness), for the name field in the profile, for email validation in password recovery and for both screens with a photo loading error. Coverage 46.8% → 55.4%, tests 143 → 203.

  Every new regression test was checked for breakage — run against the old code, and it fails on it: the inverted deletion order breaks 3 of 4, the old name field seeding breaks the clearing test.

  **A dead localization string turned out to be a missing branch.** `failedToLoadPhotosError` was declared in both locales and used nowhere. The reason was found right there: both `profile_screen` and `friend_profile_screen` read the gallery as `.value ?? const []`, so **a loading failure was indistinguishable from "no photos"** — the buttons just sat disabled, the avatar did not open, and there was no explanation. The string had been written for exactly this and never wired up. Now wired up in both places.

  **Update notification — only for those who have fallen behind.** The `app_update` kind had lived without a sender since 20260820190000: the setting exists in the UI, but there was nothing to send it with and, more importantly, nothing to base it on — without knowing the version, any broadcast would also tell people who had already updated to update. Now the device reports its version (`device_tokens.app_version`/`.app_build`, 20260822110000), and `enqueue_app_update_notifications(build, version)` (20260822120000) enqueues only those who are behind.

  The version lives on the device, not on the user, because it is a property of the installation: one person's phone and tablet may well be on different versions, and "the user is on 0.16.4" is a meaningless statement. The table is upserted on every launch anyway, so the field is kept fresh without a single new request. The comparison uses only `app_build` (versionCode, monotonic) — comparing `0.9.0` with `0.16.0` as strings is the classic way to get it wrong, so `app_version` is stored purely for human reading.

  A user counts as behind if the MAXIMUM build across all their devices is below the target. The mechanical reason: the queue is addressed to a user, and send-push fans out to all of their tokens; it cannot address a single device. The semantic reason matters more: if you updated on your phone, you know about the update, and there is no point nagging because of a tablet in a drawer. NULL is read as "oldest of all": a client that cannot report its version is by definition older than one that can.

  A separate precaution: the new columns have CHECK constraints, and token registration is fire-and-forget — a constraint violation would bring down the registration itself, silently and together with all of the user's notifications. So the client normalizes both fields to what the database will accept (`shared/app_version.dart`, 8 tests), and the constraint remains a defense against a forged value rather than the first line.

  Calling it again is safe: deduplication on `payload->>'build'`, one notification per release regardless of the number of runs — this is deliberately stricter than a time window, because "update to 38" twice is spam even with a week in between. The next release will come with a different build and trigger the broadcast on its own.

  Verified by simulation: a user with an outdated AND a fresh device is not notified, one with a single outdated device is notified, one with a NULL version is notified, three runs in a row produce exactly one row per person, a zero argument is rejected. Separately verified that the values the client sends are accepted by the database, and forged ones are not.

  **`updated_at` on device_tokens lied.** Surfaced in passing while working through the grants for the previous item. The column was NEVER updated: `default now()` only fires on insert, and the client upsert rewrites the row on every app launch and language change without mentioning it in the payload. On the live database every row had `created_at = updated_at`, even though the app touches them regularly — so the column could not tell you when a device was last in contact.

  The second half of the same hole: the UPDATE grant on the table is table-wide (unlike INSERT, narrowed to columns back in 20260819140000), so the client could also rewrite `created_at` in its own row. There is no harm from this today — no decision in the schema reads these dates — but it is the same class of forgeable server-side column that has already been closed six times.

  The grant cannot be narrowed: PostgREST puts all payload columns into SET, including `user_id` and `fcm_token`, so a column-level UPDATE grant would break push registration entirely. Exactly this case was already worked through for `reactions` (20260819150000), and the solution was carried over verbatim — a BEFORE UPDATE trigger `pin_device_token_timestamps()` that puts `created_at` back and sets `updated_at = now()`.

  Verified by simulation: a normal re-registration moves `updated_at` forward and leaves `created_at` in place; an attempt to set both dates to 2019 is discarded — `created_at` keeps its original value, `updated_at` becomes the current time.

  Verified: `make verify` is green (211 tests versus 143). Ten migrations applied to the live DB and recorded in `supabase_migrations.schema_migrations`, the edge function deployed (v11, `verify_jwt` preserved) and confirmed via `net._http_response` — cron consistently gets 200. Both holes (dislike and oracle) were reproduced by simulation with `set_config('request.jwt.claims', …)` before the fix and checked after, `anon` grants verified against `information_schema.role_table_grants` (there were two tables, now zero). The toggle rollback test fails if the old code is restored. Column grants and the token limit were verified by simulation in rolled-back transactions: a legitimate write goes through, forging `created_at` is rejected with 42501, 25 inserts leave 20 rows, re-registering the same device evicts nothing. Video streaming was not checked on a device — the phone was not connected.
- Fourth full audit: 11 findings closed (0.16.5) — again a review of the whole project rather than a diff: 79 migrations, the edge function, all of the Dart code, Android and CI config. The tests were green this time too (211/211) and again caught none of the findings. Below, in decreasing order of severity.

  **Reply rules worked as an existence oracle.** `enforce_comment_reply_rules()` is a `security definer` BEFORE INSERT trigger, and in Postgres such triggers fire BEFORE the policy's `WITH CHECK` (`ExecBRInsertTriggers` runs before `ExecWithCheckOptions`). It read `comments` without RLS and raised five different messages, so a blocked user who had saved the id of someone else's comment could send a reply on a post visible to them and read the state of the hidden row from the error text: "no such comment" / "exists, but on a different post" / "exists, and it is a reply" / "exists, and it is a placeholder" / RLS refusal. Five distinguishable responses where there must be one. The same class that had already been closed three times (`20260818130000`, `20260819130000`, `20260821130000`) — it slipped past those fixes precisely because it lives not in the policy but in front of it. Now the trigger says nothing about anything the caller cannot see: not visible — `return new`, and the policy delivers the verdict, with the same 42501 in every case. Visibility is checked by the new `is_comment_visible()`, which was also used to rewrite both branches of the INSERT policy — this also closed a gap that made the policy broader than the right to read the row (a comment by a visible author under an invisible post passed it; previously it was the trigger that caught this). `20260822140000`.

  **Video could not be published over mobile data.** `uploadTolerant` applied the general `networkTimeout` — 12 seconds — to the Storage upload, even though the bucket accepts objects up to 100 MiB, and the composer up to 60 s of non-transcoded 1080p, i.e. 50–100 MB. Fifty megabytes in twelve seconds requires ~33 Mbit/s; on a typical uplink the `TimeoutException` fired before the request body was even sent. Worse, `.timeout()` does not cancel the request, so the abandoned upload often made it through — and the third or fourth retry "succeeded" by colliding with it and getting a 409, which `uploadTolerant` treats as success. Introduced `uploadTimeout(bytes)`: `networkTimeout + bytes / 128 KiB/s`, capped at 15 minutes. A 300 KB photo still times out at 14 s, 50 MB gets ~7 minutes.

  **`delete_own_comment()` distinguished "no such comment" from "someone else's".** The same "is the row alive" question, asked directly: the difference in responses could be used to poll the fate of a hidden comment. Both branches were collapsed into a single `PT404` — exactly as `set_post_media()` already does with "not mine"/"doesn't exist". `20260822140000`.

  **A leaked invite code could not be revoked.** After the first press the button is labeled "Create new code" and did not create one: `create_invite_link()` is idempotent and returned the same string, and `invite_links_one_active_per_owner` did not allow a second active one. The code is a bearer code — whoever redeems it becomes a Connection with the whole feed, profile and gallery — so someone who sent it to the wrong chat could do nothing. Added `rotate_invite_link()`: it deletes the owner's unused rows and mints a new one. It deletes rather than setting `is_used`, so that a revoked code reads as `PT404` ("no such code") rather than `PT409` ("already used") — the latter is untrue. The client calls it only from the "code is already on screen" branch and only after confirmation. `20260822150000`.

  **Editing a post lost the caption.** In `updatePost`, cleanup of orphaned Storage objects sat BETWEEN the committed `set_post_media()` and the text update, and unprotected. An edit that changed the caption and removed a photo committed the media, failed on a `remove()` timeout and never got to the text — while the composer reported that nothing had been saved. Both row writes were moved inside `deleteRowsThenObjects`; cleanup goes last and is best-effort, as in all other deletion paths.

  **Push token eviction threw out a working phone.** `enforce_device_token_limit()` keeps the 19 rows with the highest `created_at` — and that was right as long as `created_at` was the only timestamp in the table. `20260822130000` (0.16.4) pinned it to the date of first registration and introduced `updated_at` as "last in contact", after which the sort came to mean "the 19 most recently created". For a person with a year-old phone opened every day and two dozen younger dead tokens, the twenty-first registration evicted precisely the phone. The sort key was switched to `updated_at`. `20260822160000`.

  **`set_post_media()` accepted an arbitrary `storage_path`.** The function is `security definer`, meaning it writes to `post_media` bypassing the INSERT policy and the column grant — both checks remained only on the direct insert path. Via the RPC you could attach a row with the path `posts/<someone-else's-uuid>/…` to your own post. This was not a read leak: the object is signed by the viewer, and the storage policy matches the second segment against the viewer's own `visible_author_ids()`. But an invariant called load-bearing both in the client and in data-model.md stopped being an invariant. Added a check of the `posts/<auth.uid()>/` prefix, the same as the storage INSERT policy has; the migration starts with a block that fails if even one live row does not satisfy the rule. `20260822170000`.

  **An empty `system_account_ids()` response killed the feed dead.** The list was substituted into `not.in.(…)` without a check: an empty one produced `author_id=not.in.()`, which is not a filter but a 400. And it was cached for the whole lifetime of the repository, so one such response hung the feed until restart — while the offline fallback next to it would not have kicked in, since the request itself had succeeded. An empty list is now simply not turned into a filter.

  **Video was checked only by duration.** 45 seconds of 4K/60 passes the one-minute limit and is certainly over 100 MiB, and Storage answers that with a 413 only after the whole file has been read into memory and sent. The composer showed a generic "Failed to publish", so the clip looked like a stalled network rather than something that will never go through. Added a size check before poster extraction and a dedicated string in both locales.

  **`PageController` was created in `build()`** of `ProfilePhotoViewerScreen` — the only place in the project where a controller is not owned by a `State`. Every rebuild (system theme, text scale, rotation) produced a new controller with `initialPage`, so the viewer jumped back to the photo it had been opened on, and the previous `ChangeNotifier`s were never disposed. The screen was converted to a `StatefulWidget`.

  **A second hardcoded system account id.** `20260821160000` (0.16.4) moved the feed to the server-side `system_account_ids()` and kept the constant as a fallback — but the easter egg on the theme toggle kept reading the literal directly. That is exactly the kind of copy that breaks silently: after a rotation, `fetchProfile` would throw on `.single()` for a nonexistent uuid, the `catch` next to it swallows that, and six clicks on the switch would simply stop doing anything. The lookup moved to `shared/system_accounts.dart`; both consumers ask the server, and the cache is shared.

  Verified: `make verify` is green, 220 tests versus 211 (6 for `uploadTimeout`, 3 for code rotation). Four migrations applied to the live DB and recorded in `supabase_migrations.schema_migrations`. The oracle was reproduced by simulation before the fix — "existing invisible" and "nonexistent" produced different messages; after the fix both produce a byte-for-byte identical 42501; regressions checked on three legitimate paths, including the post owner replying to a commenter. `delete_own_comment` returns a single `PT404` for someone else's and for a nonexistent comment, and your own is still deleted. Rotation: after the call there is exactly one open row, the old code is gone, and it answers `PT404` to its bearer. Someone else's `storage_path` and someone else's `poster_path` give `PT422`, your own works. Eviction was checked on 20 synthetic tokens where the oldest by `created_at` is the freshest by `updated_at`: it survived, and the oldest by `updated_at` was the one evicted. Control counts across eleven tables matched before and after applying. Nothing was checked on a device — the phone was not connected.
- Fifth full audit: 10 findings closed, one withdrawn (0.16.6) — again a review of the whole project, not of a diff: 83 migrations, the edge function, all of the Dart, the Android and CI config. The tests were green again (220/220) and again caught none of the findings. Below, in decreasing order of severity.

  **A media row could be created with someone else's path.** `20260822170000` (0.16.5) closed this in `set_post_media()` — that is, on the post EDITING path — and didn't touch the CREATION path: `createPost` writes `post_media` with a plain INSERT, and its policy only asked "is this my post". `profile_photos` had had the same thing since `20260819240000`, and there it's worse: the `sync_avatar_path_from_profile_photos()` trigger copies the `storage_path` of the row with the lowest `position` into `users.avatar_path`, so the foreign path spreads to every screen that draws an avatar. Nothing has to be guessed — a connection's `avatar_path` reaches the client as is, `fetchFriends` requests exactly that. No bytes leak (the viewer signs the object, the storage policy matches the second segment against the viewer's own `visible_author_ids()`), what breaks is authorship. Both INSERT policies got the same prefix check that the RPC and the storage policy already have. `20260822180000`.

  **`users.avatar_path` was writable by the client.** A second door into the same room, and the grant was left over from the pre-gallery version: only the trigger writes the column, the client only ever reads it (`grep -rn avatar_path app/lib` — every hit is a read), yet `grant update (name, avatar_path)` from `20260820140000` was still alive. The RLS policy on `users` only says "is this my row", so a PATCH with a foreign path went through and stuck until the owner touched their own gallery — the trigger hangs off `profile_photos`, it has nothing to recompute the column from. The grant is narrowed to `update (name)`. It could only be narrowed together with switching the trigger to `security definer`: it was `invoker`, and without the grant its UPDATE would fail with "permission denied for column avatar_path", taking down every add, delete and reorder of photos with it. `20260822210000`.

  **An empty name and a post with no content.** `users_name_length` bounded the name from above but not from below, and the `'Без имени'` fallback lives only in `handle_new_user()` — a PATCH with `{"name":""}` went through, and the author vanished from the post header, the connections list, the comment line and the `{author_name}` slot in the push. `users_name_not_blank` added. Posts are trickier: `posts_has_content` was dropped in `20260819220000` together with `image_path` and never replaced, but a synchronous CHECK can't express it anyway — `createPost` inserts the post and its `post_media` in two PostgREST requests, i.e. two transactions, and a check at post-insert time would reject a legitimate photos-only post. So `posts_text_not_blank` catches what can be checked right away (whitespace-only text), and a post left without any content is cleaned up by the new `purge-empty-posts` cron — an hour with margin to spare; media are uploaded BEFORE the post row is inserted, the legitimate gap here is one round trip. `20260822200000`.

  **A second hardcoded system account id, this time on the server.** `20260821160000` introduced `system_account_ids()` precisely so the id wouldn't live in two places, and in 0.16.5 it was removed from the client — yet the server still had two copies, `is_system_account()` with its own literal and `system_account_ids()` with its own, unconnected. A rotation that edits only one function doesn't fail loudly: if only the first moves, the new account's posts show up in everyone's general feed; if only the second, the feed hides an account that the visibility rule no longer considers system. Now `system_account_ids()` declares the set, and `is_system_account()` asks it. Along the way `immutable` -> `stable` (otherwise it can't call a `stable` function) and `exists (…)` instead of `p_id in (…)` — a strict boolean instead of a three-valued one, the same motive as `is_author_of_comment_visible` in `20260821130000`. `20260822220000`.

  **The post editor, opened offline, threw an unhandled exception.** `_resolveExistingMediaUrls()` is started from `initState` without `await` and was the only network call on the screen without a `catch` — with no connection (or on the 12 s timeout) the throw escaped the orphaned future straight into `FlutterError.onError`. Both copies of the same resolve in the carousel have long been guarded. Now it's caught and reported; no photos are lost in the process — `_ExistingSlot` holds its own `PostMedia` independently of the preview, and saving sends it as `KeptMedia`, so a grey placeholder is just a grey placeholder.

  **The photo reorder screen built all 80 tiles at once.** `ReorderableWrap` inside a `SingleChildScrollView` — exactly the shape the neighbouring delete screen replaced with `GridView.builder` for exactly this reason, and here it had stayed: opening a full gallery started 80 loads and 80 decodes before the first tile appeared on screen. A Wrap is never lazy (it has to measure every child to lay out the rows), so the grid gave way to a lazy `ReorderableListView` — one photo per row. As a bonus the numbering became visible, and with it the "the first photo is your avatar" rule, which the grid only implied. Heads-up when reading the diff: `ReorderableListView` reports `newIndex` before the item is removed, while `ReorderableWrap` (the composer still uses it) reports the final one, so a shared handler for them looks appropriate and isn't.

  **Composer tiles decoded full photos into a 96×96 box.** `Image.memory` bypassing `sizedMemoryImage`, even though every other small image in the project goes through it. Photos arrive with `maxWidth: 1600`, i.e. ~12 MB of ARGB each regardless of the render size; the twenty allowed items come to ~240 MB against a 100 MB `ImageCache`, which then thrashes and re-decodes on every composer rebuild.

  **`avatarBytesProvider` kept every photo ever opened in memory.** A bare `keepAlive()` with no bound: the cache was written for avatars that lists reuse, but whole galleries go through the same family — opening the delete or reorder screen with 80 photos meant pinning 80 JPEGs at `maxWidth: 1600` in memory, with nobody to release them. It also left the previous account's photos resident after sign-out — the same thing `FeedCache` closes on disk with per-user keys. Now the keep-alive is released 5 minutes after the last listener leaves (`onCancel`/`onResume`), so returning to a screen still re-downloads nothing.

  **A comment about the storage policies was half wrong.** `tolerant_upload.dart` justified not using `upsert: true` by there being no UPDATE policy "for any prefix". True for `posts/`, not for `avatars/`: the policy had been there since `20260707222025` and was used by no path at all. This is the reasoning the next reader will point to before reaching for `upsert`, so the policy was dropped rather than the comment rewritten. `20260822210000`.

  **Withdrawn: "the backstop limits don't work on a batch insert".** The claim was that a `BEFORE ROW` trigger doesn't see rows inserted by the same statement (Postgres doesn't advance the command counter between rows of a single INSERT), so the 20 and 80 limits hold on no live path — both send the batch in one upsert. Checked with an isolated trigger on a temporary table: inserting five rows in one statement with a limit of three stops exactly at the fourth. plpgsql calls `CommandCounterIncrement()` before every SPI query, so the snapshot inside the trigger already sees what was inserted. The limits work, the finding is withdrawn, and the migration written for it is deleted.

  Verified: `make verify` green, 223 tests vs 220. Four migrations applied to the live DB and recorded in `supabase_migrations.schema_migrations` (83 -> 87). Every hole was reproduced by simulating `set_config('request.jwt.claims', …)` in a rolled-back transaction BEFORE the fix and re-checked after: a foreign path in `post_media` and in `profile_photos` was accepted, now 42501, one's own prefix still passes; a direct write to `avatar_path` went through, now "permission denied", while the sync trigger writes the column as before — checked on add, delete and a full reorder; a whitespace-only `name` and whitespace-only post text were accepted, now 23514. `purge_empty_posts()` was checked on three decoys: the old empty post deleted, a fresh empty one (its `post_media` still in flight) and an old one with media left untouched. After the rewrite `is_system_account()` returns a strict `false` on NULL, the visibility rule didn't shift — `visible_author_ids()` was independently recomputed by a query without a single function call and matched; both branches of `enqueue_post_notifications()` were checked by inserting a post from a regular account and from the system account. Both new tests were checked for discrimination: without the `catch` the offline-editor test fails, without the `newIndex` correction the reorder gives `[p1, p2, p0]` instead of `[p1, p0, p2]`. Nothing was checked on a device — the phone wasn't connected.
- Sixth full audit: 7 findings closed (0.16.7) — again a review of the whole project, not of a diff: 87 migrations, the edge function, all of the Dart, the Android and CI config, the build scripts and the documentation. The tests were green again (223/223) and again caught none of the findings. Below, in decreasing order of severity.

  **A dislike could be given to an author who had opted out of them.** The `dislikes_disabled` ban lives in two `reactions` policies — on setting a reaction and on changing it. `20260821110000` (0.16.4) had already fixed the INSERT branch, restoring the lost guard; its UPDATE twin, however, was left without the condition the guard rests on in the first place: `exists (select 1 from posts p where p.id = reactions.post_id)`. The guard itself is written as a subquery on `posts`, which runs with the caller's rights and is therefore itself filtered by the `posts` policy: post not visible — subquery empty — the guard reads that as "no flag", not as "can't check". Exactly the same class as the `blocked_users` hole from 0.11.0. You can hide someone's post from yourself on your own, with a mute, no one else's participation needed: like the post, mute the author, send a PATCH changing your own row to `dislike`. The counter is computed by `reaction_summary()` — `security definer`, bypassing RLS — so the author will see the dislike. The visibility condition is added to both halves of the policy: to `using`, so a row on an invisible post doesn't fall under the UPDATE at all, and to `with check`, so the guard has something to stand on. `created_at = now()` was deliberately not added to the UPDATE branch — `pin_reaction_identity()` (`20260819150000`) resets the column to its old value on every update, so such a condition would reject any legitimate reaction change. DELETE is untouched: removing your own reaction from a post that has become invisible is a legitimate action. `20260822230000`.

  **The logged-in role still had the right to wipe tables entirely.** `20260818140000` took Supabase's default grants away from `anon` and stated a reason there that wasn't about tidiness: **row-level security does not apply to TRUNCATE at all** — policies filter rows, and it isn't a row operation, it has no second line of defence whatsoever. `20260821120000` repeated the same cleanup for `post_media`/`profile_photos`. Both touched only `anon`; `authenticated` — the role every signed-in user carries — kept the same right on all thirteen tables, held back by exactly one circumstance: PostgREST doesn't map TRUNCATE to any HTTP verb. The very argument those same migrations had judged insufficient. `TRUNCATE`, `TRIGGER` and `REFERENCES` revoked; the `revoke all` used to close `anon` doesn't fit here — the role needs SELECT/INSERT/UPDATE/DELETE. `MAINTAIN` is kept on purpose: it doesn't allow reading, changing or deleting a single row. The second half of the fix is `alter default privileges`, otherwise the next table created would get everything back, as indeed happened between `20260818140000` and `20260821120000`. `20260822240000`.

  **No migration created the `media` bucket.** `20260709134154` and `20260820130000` configure it via `update … where id = 'media'`, i.e. they assume it already exists — true for the production project, where it was created by hand, and false for any other. `20260820130000` stated outright why the restrictions were brought back into the repository ("rebuilding the project from migrations would reproduce a state in which video doesn't upload"), but the argument was carried only halfway: the values were fixed, while the object they belong to stayed outside. On a clean project both `update`s find no row and silently pass green. The second problem is worse: `public` is pinned nowhere, and all four SELECT policies depend on it — a public bucket cancels them all at once, and when created by hand that's exactly one toggle in the wrong position. Now it's `insert … on conflict do update`: on a clean project the bucket is created right away, on production it's a no-op value-wise, and `public = false` goes from an initial value to an invariant that a re-apply will restore. `20260822260000`.

  **Notification token refresh lost its error.** The `onTokenRefresh` subscription called `_upsertToken()` without awaiting the result or catching it: a token rotation (reinstall, Play Services data reset) with no connection turned the write timeout into an unhandled async exception — there's no one to hand it to from a stream callback, so it goes to `FlutterError.onError`. The new identifier isn't saved in the process, there's no one to retry, and pushes to the device stay silent until the next app launch. The same technique already applied to the offline post editor in 0.16.6. The same shape was also fixed in the background save of the feed cache: `unawaited` silences the linter, not the failure.

  **Video kept playing after swiping past its slide.** `allowImplicitScrolling` in the carousel deliberately keeps the neighbouring page alive so the photo is already loaded by the time of the swipe — free for an image, but for a playing video it meant nobody disposed or paused it: the sound played over the next photo until the viewer swiped two slides further or scrolled the post off screen. A slide now knows whether it's the current one, and on losing that flag it pauses rather than disposes — swiping back resumes from the same spot. The fullscreen viewer got the same, for the same reason.

  **`visible_author_ids()` looked up the system account by scanning the whole users table.** The function answers "whose records may I be shown" and sits under the SELECT policies of `posts`, `comments`, `post_media` and under the storage policy for post photos, i.e. it's called on every feed, every comments screen and every media link signing. The branch was introduced by `20260818150000`, when the only way to learn that id was the predicate "walk `users` and ask about every row"; since then a direct source appeared, and `20260822220000` (0.16.6) made it the only one — so the scan stayed by inertia and went to `users` for a constant sitting right next to it. In milliseconds there's almost no difference today; what matters is the shape: the cost grew with the number of registered users, even though the branch's answer doesn't depend on them. Exactly the same shape — a call per row of a growing table — was cleaned out by `20260726180000`, winning 217 ms -> 3.5 ms on the feed; here it came back one floor lower, inside a function written by that same migration. `20260822250000`.

  **Clearing the comment input after leaving the screen.** `_send()` cleared the `TextEditingController` before the `mounted` check, not after: pressing "back" during sending destroys the State together with the controller, and writing to it throws "A TextEditingController was used after being disposed" (checked separately — it really throws, rather than silently doing nothing). **The finding was overrated, though, and that's worth recording honestly:** a debug crash was claimed, but in fact the throw is caught by the same method's own `catch`, which immediately exits on `!mounted`, so nothing gets out. All that was actually skipped was reloading the list and clearing the idempotency token — on a screen that no longer exists, that costs nothing. The fix is kept (it will become a real bug the day that `catch` is narrowed to the cases it was written for), but as hygiene, not as a hole. A regression test was written and deleted: a run against the old code showed it passes there too — from the outside the two variants are indistinguishable, the same `catch` swallows everything.

  **Documentation review.** A separate pass — cross-checking all nine files against each other and against the code, because they had drifted apart silently. Found and fixed: `README.md` listed four of the seven feature folders, sent readers to the brief for the data model (where its first draft lives, not the current schema), didn't mention `supabase/functions/` at all, and called the Play track "Internal Testing", although releases go to Closed testing (`alpha`); `implementation-plan.md` claimed migrations are applied via the Supabase CLI — a direct contradiction of CLAUDE.md, which says Management API — and that CI/CD for builds "remained a manual process", although a push to `main` ships a release by itself; `project-brief.md` opened with "what we're doing now" about an MVP closed many versions ago. The brief and the implementation plan got honest "historical document" headers — they are history, valuable as is, but they can't be read as reference.

  `docs/future-development.archive.md` turned out to be an orphan file: 154 lines, not a single link to it from anywhere, a header indistinguishable from the live plan, and content that is the previous revision of `future-development.md`, in which some items were done long ago (the news account, one's own wall, timeouts, the server-side comment counter). It's marked as an archive with a list of what in it is already closed, and linked from the live file. Deleting it is still a single `git rm` with no consequences, but that's the author's decision, not a cleanup one.

  Added `docs/operations.md` — the one thing that genuinely had no home: the pg_cron schedules, the inventory of secrets across three stores (the database Vault, Edge Function secrets, GitHub secrets), the release path and the "please update" broadcast. Previously this was scattered between the schema (`data-model.md` held the runbook for `enqueue_app_update_notifications()` and the cron list), migration comments (secret provisioning) and workflow comments. The operational material was **moved** out of `data-model.md`, not copied — the schema stayed there. The migration apply order is deliberately not duplicated: it lives in "Working conventions" in CLAUDE.md, and `operations.md` links to it. The reference to CHANGELOG was removed from "Pitfalls" in CLAUDE.md — the rule stands on its own, and that file shouldn't drag the version history along with it. `app/README.md` got rid of the `flutter create` boilerplate about a "starting point for a Flutter application". All internal links in all files were checked — none are broken.

  Verified: `make verify` green, 223 tests (no new ones — see the last finding). Four migrations applied to the live DB and recorded in `supabase_migrations.schema_migrations` (87 -> 91). The reactions hole was reproduced by simulating `set_config('request.jwt.claims', …)` in a rolled-back transaction BEFORE the fix: after the mute the post was visible in 0 rows, yet the UPDATE still switched the reaction to `dislike` and gave the author a count of 1; after the fix the same scenario touches 0 rows and leaves `like`, while a legitimate like->neutral change works, a dislike to a regular author works, a dislike to a protected author on a visible post is still 42501, and deleting one's own reaction from an invisible post still goes through. TRUNCATE was reproduced just as vividly: a user whom the policies showed 3 rows of `reactions` wiped all 56; after the fix — 42501, the table intact, while inserting a comment, editing one's own name and mute/unmute work as before. The default for future tables was checked via `pg_default_acl`: `arwdDxtm` -> `arwdm`. The body of `visible_author_ids()` was checked not by "did it apply" but by `prosrc` for traces of the old text (see "Pitfalls" in CLAUDE.md about `create or replace`), and result equality was confirmed by running the old and the new formula for all 12 live users — 0 discrepancies; `Seq Scan on users` disappeared from the plan, 3.00 -> 2.26 ms. The bucket didn't change in a single field after the apply, including the creation date — the migration was supposed to be a no-op on the live database. A control snapshot of "how much content each user sees" was taken for all twelve after all the fixes: nobody lost anything. Nothing was checked on a device — the phone wasn't connected.

- Seventh full audit: 8 findings closed (0.16.8) — again a review of the whole project, not of a diff: 91 migrations, the edge function, all of the Dart, the Android and CI config, the build scripts and the documentation. The tests were green again (223/223) and again caught none of the findings. Below, in decreasing order of severity.

  **`notification_outbox` grew forever, and its own deduplication ran without an index.** Nobody deleted rows — none of the four crons. Meanwhile three places query the table the same way, "has THIS user already had this kind", and the hottest of them is the digest guard inside `enqueue_post_notifications()`, i.e. on EVERY post insert and once per each of the author's connections. The only index, `notification_outbox_unsent_idx (created_at) where sent_at is null`, is written for `claim_notification_outbox()` and is useless for these queries twice over: `user_id` isn't in the key, and the partial condition stops holding a minute after insertion, when the drain sets `sent_at`. At the time of the audit all 62 rows had been sent, i.e. the guard read the whole table. The same shape that `20260822250000` cleaned out: the cost of a narrow question about one person grows with the entire history of the project. Added an index on `(user_id, kind, created_at desc)` and a `purge-notification-outbox` cron with 90-day retention — no less, because the digest guard looks back as far as the reader's `last_active_at`, and `app_update` deduplication goes by `payload->>'build'` with no time bound at all. Migration `20260823100000`.

  **Nobody deleted bucket objects that no row references.** The "20 media per post" and "80 photos" limits are row-based — triggers count them over tables, and the INSERT storage policy checks exactly one fact: whether the second path segment matches `auth.uid()`. An object without a row violates nothing. This isn't a hypothesis but normal operation: `createPost` uploads files BEFORE inserting rows, so every abandoned draft leaves behind whatever it managed to upload (up to 20 objects of 100 MiB each). Plus two historical sources — files of deleted users (`delete_own_account()` cascades only through the DB, the client deletes from the bucket, and that's best-effort by construction) and paths in the pre-reform format whose rows didn't survive the move to `post_media`. Found 5 such objects out of 31. Added a `reap-orphaned-media` cron with three safeguards: a day since upload (the legitimate gap is one round trip, the most generous client deadline is 15 minutes), a strictly recognized path shape (`posts`/`avatars` + a uuid as the second segment, so service `.emptyFolderPlaceholder` files aren't touched) and no more than 100 objects per run. It deletes through the storage-api, not `delete from storage.objects`: the row there is a metadata index, the bytes live in S3, and deleting the row directly would leave the file forever, now invisible. The self-healing property comes from the same place — the function doesn't touch rows itself, so a failed HTTP call simply repeats the next night. Next to it sits `orphaned_media_paths()`, to view the list without deleting anything. Migration `20260823110000`.

  **Publishing a post could leave the post without its photos and say it failed to publish.** `createPost` made three PostgREST requests in a row — insert the post, read the `id`, insert the media — i.e. three transactions, and `.timeout()` stops waiting without cancelling the request. It's enough for the first to commit and the second not to arrive: the post is already live in the feed of all the connections, the "new post" push has already gone out, and the composer showed "Failed to publish". `purge_empty_posts()` doesn't catch this and can't — it deletes posts that have `text is null` AND no media, while a post with text doesn't match the condition and stays forever in exactly the form the author never published. `20260820150000` had already cleaned the same shape out of the EDITING path by introducing `set_post_media()`; it didn't touch the creation path, even though the consequences there are worse. Added `create_post_with_media(client_token, text, items)` — one transaction, the same idempotency on `(author_id, client_token)`, the same path prefix check as `set_post_media()`. As a bonus, "neither text nor media" is finally checked synchronously (`PT422`), not just by a cron an hour later. The grants for a direct INSERT were deliberately NOT revoked: builds installed from Play use them. Migration `20260823120000`.

  **The invite code was 40-bit, eternal and unprotected against brute force.** `encode(gen_random_bytes(5), 'hex')` — 10 characters, 2^40 variants. For a bearer credential that lives until activation and opens the feed, the profile and the whole gallery, that's too little: brute force doesn't go after one code but the whole pool of unclaimed ones at once (with N live codes the expected work is 2^40/N), and `activate_invite_link()` doesn't slow it down in any way — no delay, no failure counter. Now 16 bytes, 32 characters, 128 bits; along the way the possibility of a collision on `invite_links_code_key` disappeared, which the functions had no retry loop for. The code was already meant to be "copied and forwarded", so the length breaks nothing. Existing codes weren't rewritten: the nine used ones are dead, and the only live one is revoked with the "Create new code" button — silently revoking via a migration a code the owner might have sent to someone would be making the decision for them. Migration `20260823140000`.

  **The composer accepted image formats the bucket will never accept.** Video had an explicit extension list matching `allowed_mime_types`; images didn't. Storage takes the content-type from the extension in the object's NAME, not from its contents, so `.gif` (or `.bmp`, `.tiff`) is rejected on upload and will be rejected on every retry, while the user sees a generic "Failed to publish" — exactly the dead end `_maxVideoBytes` closed for clips that are too large. Both lists were moved to `shared/media_extensions.dart` (one declaration for the composer and the profile gallery), both pickers now filter out unsuitable files themselves, with a clear message. Tellingly, one of the orphans found in the bucket is `1784056582678764.png` with a JPEG inside.

  **Nobody could see the system account's avatar and gallery.** The "the system account is visible to everyone" exception was introduced in four steps — the `users` SELECT policy, `is_author_visible()`, `visible_author_ids()`, the post photos storage policy — and it never reached either the avatars storage policy or the `profile_photos` SELECT policy. The system account is nobody's Connection, so both answered "no" to absolutely everyone. This surfaces through the theme toggle easter egg: it opens the Amicus profile, which draws the avatar and, on tap, the gallery. It would have fired silently — as a grey person icon, without a single error anywhere — at exactly the moment the account was given an avatar (at the time of the audit it had `avatar_path is null`, so the hole was latent). Both policies now ask the same `is_system_account()`. Migration `20260823130000`.

  **Fixes on the editing path and one unguarded `setState`.** In `updatePost` the text write came AFTER `set_post_media()`, inside `rows()`: a timeout on the text threw an exception after the media had already been rewritten, so `objects()` didn't run and the removed file stayed in the bucket — and a retry no longer cleaned it up, because `set_post_media()` saw the rows as correct and returned an empty list. The text was moved first, so the only statement that fills `orphanedPaths` is now the last one in `rows()`, and a successful media rewrite is always followed by its own cleanup. Plus `_pickMedia` in the composer called `setState` right after `await`ing the system picker without a `mounted` check — the only such place on a screen where all the other `await`s are already wrapped and commented about exactly this; the same in `_addPhotos` on the profile screen.

  Verified: `make verify` green, 228 tests (5 new — on the invariants of the extension lists, including the one the `fileExtension` fallback to `jpg` relies on). Five migrations applied to the live DB and recorded in `supabase_migrations.schema_migrations` (91 -> 96). All RLS fixes were checked by simulation as `authenticated` with a rollback: `create_post_with_media` — six scenarios (creation, a retry with the same token without duplicates, a foreign prefix, an empty post, 21 items, text without media), system account visibility — five control numbers, including no regression for an unrelated user. The bucket cleanup was done live: 31 objects -> 26, 5 orphans deleted via the storage-api after being downloaded to disk, not a single `post_media` row left pointing at a deleted file. A separate lesson with no file changes: one intermediate visibility check showed a "regression" that wasn't there — the control sample included a user who turned out to be a Connection, and the query over bucket objects ran without a prefix filter. The error was in the expectations, not the simulation; a separate test confirmed that RLS inside `do $$ … $$` applies the same way as for top-level statements.

- Eighth full audit: 5 findings closed (0.16.8) — a review of the whole project, not of a diff: 96 migrations, the edge function, all of the Dart, the Android and CI config, the build scripts and the documentation. The tests were green (228/228) and caught none of the findings. Not a single migration was needed: the schema was right everywhere, the client was wrong — which is why everything listed was rejected by exactly the constraints already in the schema. In decreasing order of severity.

  **Adding a profile photo could lock itself up for good.** `_addPhotos` invalidated the gallery providers only on success, and `.timeout()` stops waiting without cancelling the request — so an upsert that committed after "Failed to add photos" left `photosAsync.value` as it was BEFORE the attempt. `addPhotos()` computed `position` from that list, so the next add targeted occupied positions and ran into `profile_photos_user_position_key`: the upsert's arbiter is `(user_id, storage_path)`, and the new files have their own paths, so the position conflict wasn't absorbed but failed. And there was no way out from the screen: "Reorder" is disabled below two photos, "Delete" on an empty list, both buttons read the same stale list, and `ProfileScreen` lives as a `StatefulShellRoute` branch, so its autoDispose providers never die. Only an app restart cured it. The invalidation moved into `finally`.

  **The composer didn't check the video extension.** Images got their allow-list in the seventh audit, video didn't, even though `videoExtensions` existed: it only took part in `_looksLikeVideo()` as a classifier for when the picker didn't report a mime type. Storage takes the content-type from the object's NAME, so `.avi` is rejected on upload and on every retry, it surfaces as a generic "Failed to publish", and it surfaces AFTER the whole clip has been read into memory and sent over the network. A clip with no extension in its name is worse: `fileExtension()` returns its default `jpg`, the bucket accepts the object as `image/jpeg`, and the feed is left with a slide with `media_type = 'video'`, a poster and a play button that plays nothing. Meanwhile `data-model.md` claimed the video gate had been in place from the very start, and `media_extensions_test.dart` checks the exclusion of `avi` on the assumption that someone applies it; the documentation was fixed together with the code.

  **A deleted post stayed on screen in all the other lists.** The feed and the profile are two live `PostListView`s in the shell's `IndexedStack`, plus `FriendProfileScreen` on top, and `_deletePost` removed the row only from its own `_posts` and, unlike `_editPost`, didn't poke `feedRefreshTickProvider`. The ghost card stayed tappable: RLS rejects a reaction on it, and `_react` silently rolls back the optimistic counter; comments open empty; a second "Delete" affects zero rows and counts as success. Deletion was the only feed mutation that didn't go through the tick.

  **Leaving the photo delete screen left the parent with a stale list.** Both gallery editors return `true` only when the mutation went all the way through, and `deletePhotos` goes through `deleteRowsThenObjects` — rows first — so a timeout can leave the rows already deleted while the screen shows an error and stays open. The return then comes back with `null`, `ProfileScreen` holds rows that no longer exist, and reordering locks up for good: `reorder_profile_photos()` requires the WHOLE set, the deleted ids drop out on the join inside, and the function answers `PT422` on every attempt. Both places now re-read the gallery unconditionally, through a single helper.

  **The comment counter on the card never changed at all.** `CommentsScreen` was opened without `.then`, returned nothing and didn't poke the tick, so a person wrote a comment, came back — and saw the old number; deleting one's own comment left the number inflated. Until the first pull-to-refresh. Now the screen reports the counter via a callback: it's closed with the system "back" button, which has no result, and intercepting that gesture via `PopScope` for the sake of a counter means meddling with something this project has no way to verify (see "Pitfalls" in CLAUDE.md). The tick would be wrong on cost: it reloads the first page of EVERY open list for the sake of one number on one card.

  Separately, and deliberately left as is: `reap-orphaned-media` calls `net.http_delete` with a `body` argument that only a recent `pg_net` has, and plpgsql bodies aren't checked at apply time — so a version mismatch would apply green and then silently fail every night. One manual `select public.reap_orphaned_media();` is enough to settle the question.

  Verified: 231 tests, 3 new — deletion pokes the tick, the number on the card follows what the branch loaded (stubs excluded, exactly as `comment_summary()` excludes them), and the delete screen re-reads the gallery on a plain "back". Two picker-side fixes aren't covered: both sit behind `ImagePicker`, which this test suite has no way to fake, and inventing an abstraction just for the test seemed worse than saying so here.

- Ninth full audit: 6 findings closed, one withdrawn (0.16.8) — again a review of the whole project, not a diff: 100 migrations, the edge function, all of the Dart, the Android and CI config, build scripts and documentation. Tests were green again (231/231) and again caught none of the findings. The version was not bumped: the work landed in the same 0.16.8 as the seventh and eighth audits — build 42 had not yet been rolled out to Play.

  **Withdrawn: `users.avatar_path` not bound to the user's own prefix.** The finding was based on the grants from `20260820140000` and turned out to be wrong: `20260822210000` had already removed `update (avatar_path)` and made `sync_avatar_path_from_profile_photos()` `security definer`. The live database confirms it — on `users`, `authenticated` has UPDATE only on `name`. The mistake was in the method, not the schema: the finding was checked against the migration file that GRANTED the privilege, without checking whether a later one had revoked it. The policy had already been changed on the live database and was restored to its original form with `ALTER POLICY`; after the rollback there is no drift between the repository and the DB (101/101 in `schema_migrations`).

  **Editing a draft after a failed publish published a second post.** `.timeout()` stops waiting without cancelling the request, so `create_post_with_media()` regularly commits AFTER the composer has shown "failed to publish": the post is already live in the feed, the push has already gone out. The composer stays open with the draft, the person fixes a typo and taps "Publish" again — but the idempotency token was tied to the CONTENT (`_pendingFingerprint`), because the server answered a repeat of the same token with `do nothing`, and otherwise the edit would have been lost silently. So the edit went out under a new token, the unique index `(author_id, client_token)` matched nothing, and a second post was inserted, with a second push to every connection. The rule was moved to where both attempts are visible: the conflict branch now brings the post to the submitted state — it updates the text and rewrites the media set entirely (not "fills in what's missing": `on conflict do nothing` would keep the old `position`, so reordering slides would silently not apply). The composer now mints the token once per session and knows nothing about fingerprints; in edit mode the same token also stopped shifting the upload prefix of legacy posts between attempts. Build 41 does not call this function at all (it publishes with the old trio of requests), so installed builds don't see the change. Migration `20260824100000`.

  **`comments.text` had no lower bound.** The upper bound of 5000 has been there since `20260716120000`; the lower bound — nothing; the only emptiness check lived in `_send()`. `POST /rest/v1/comments` with `{"text":"   "}` passed both the policy and the CHECK, after which the row was rendered empty for everyone who could see the post, was counted in `comment_summary()` (it discards only tombstones) and took a push to the post's author along with it. `20260822200000` closed exactly this class for `posts.text` and `users.name` and never got to comments. The condition has a disjunction on `deleted_at`, not just `btrim(text) <> ''`: `delete_own_comment()` turns the placeholder into an empty string, and there it isn't junk but the value itself. Migration `20260824110000`.

  **Editing a post didn't hold the "text or media" invariant and was still two transactions.** `create_post_with_media()` has checked it since `20260823120000`, while the edit path — `PATCH posts {text}` plus `rpc set_post_media` — checked it with nothing but `if (text.isEmpty && _slots.isEmpty)` in the composer. Anything hitting the same two endpoints while bypassing the screen left an empty card in the feed of every connection until the next hourly tick of `purge-empty-posts`, which doesn't reject it but deletes the author's post out from under them. The check can't be bolted into `set_post_media()` itself: it sees only media, and by the time it's called the text is either already new or still old — depending on the order in which the client sends the two commands, and the "text first" order only appeared in build 42, whereas what's in the field is 41 (`min(app_build)`), which sends media first. For it, such a check would break the legitimate edit "remove all the photos and write text instead". So not a check inside the old function but a new entry point, `update_post_with_media(post_id, text, items)`, which has both halves in hand at once; internally it calls the same `set_post_media()`, so that the "which paths are orphaned" rule and the prefix check stay in one place. Along the way this closed what the comment on `updatePost` already called by name: "What is still not atomic is the pair itself". `set_post_media()` remains granted — build 41 uses it. Migration `20260824120000`.

  **Adding profile photos computed `position` on the client.** The position was taken from the cached value of `_profilePhotosProvider`, and that value lags in exactly the cases that all the rest of the retry tolerance exists for: the previous batch could have committed after "failed to add photos", plus a second device. A stale list targeted occupied positions and ran into `profile_photos_user_position_key`, and `upsert` can't absorb that — its arbiter is `(user_id, storage_path)`, new files have their own paths, so a position conflict isn't resolved but brings down the whole batch. The eighth audit already treated the consequences (invalidating the providers on error too) but didn't touch the cause itself. `20260820150000` purged the same shape from REORDERING by introducing `reorder_profile_photos()`; it never got to adding. Now the server assigns positions — `append_profile_photos(items)`, in the same transaction the rows go into. Resubmitted items are filtered out BEFORE numbering, rather than absorbed by `on conflict` after it, otherwise a retry would leave gaps in the numbering. Direct INSERT remains granted. Migration `20260824130000`.

  **A failed system-account lookup wasn't remembered, and the feed paid for it on every page.** `SystemAccounts.ids()` cached only success; the fallback was returned without being written to the cache. `fetchPage` waits for this answer BEFORE it even sends the posts request, so offline the feed paid a full `networkTimeout` here and another one on the request itself — about 24 seconds until "failed to load feed" and the cached page, and the same 24 seconds again on every pull-to-refresh and every pagination page. Now failure is remembered too — for a minute, not for the whole session: the fallback is compiled into the app, and a session that started offline shouldn't keep using it after the account is rotated. Also a shared in-flight future, so that two concurrent pages don't open two round trips for the same constant.

  **Both pickers set their busy flag AFTER the picker.** While the system picker brings up its activity, the "Add" button stayed enabled — its `onPressed` looks at `_isPicking`/`_isAddingPhotos` and at the list length, and both are pre-pick. A second tap opened a second picker, both batches were trimmed via `take(remaining)` with the same `remaining`, computed before the first selection, and together could exceed the limit: publishing then failed on the server's `post_media_limit_exceeded`, and the composer could only show the generic "failed to publish". The flag moved earlier, and with it came handling of a throw from the picker itself — previously that was harmless (the flag wasn't set yet), but now it would lock the button for the rest of the session; along the way this stopped being an unhandled async error, because both methods are called as a `VoidCallback`.

  **Write privileges with no policy under them.** Cross-checking "which commands a grant allows" against "which commands have a policy" turned up five tables: `comments` UPDATE, `post_media` UPDATE, `profile_photos` UPDATE, `connections` INSERT+UPDATE, `invite_links` INSERT+UPDATE. In every case it's Supabase's default table grant that outlived whatever revoked it, and the absence of an UPDATE policy on the first three is a stated decision (`docs/data-model.md`). Today it's unreachable: RLS is enabled, `authenticated` isn't the owner, a command without a policy is always rejected — which is also why revoking can't break anything, installed builds included. Revoked precisely because it's unreachable now: the day someone adds an UPDATE policy on such a table for the sake of a single column, the grant will silently expose the rest — `comments.author_id`/`text` (retroactively spoofing authorship and text), `post_media.storage_path` (bypassing the prefix check, which lives only in the INSERT policy), `connections.user_a_id`, `invite_links.is_used`. Same technique as `20260822210000` and `20260822240000`. Tables with a `for all` policy (`muted_users`, `blocked_users`, `favorite_users`, `device_tokens`, `notification_preferences`) and `reactions` with its own UPDATE policy were left alone — there UPDATE is reachable and needed for client `upsert`s. The migration has a built-in control check: after it's applied, no "grant without policy" pairs may remain. Migration `20260824140000`.

  Verified: `make verify` green, 231 tests. Five migrations applied to the live DB and recorded in `supabase_migrations.schema_migrations` (96 -> 101), no drift between the repository and the DB. All changes were verified by simulation as `authenticated` in a rolled-back transaction, reproducing the hole first: an empty comment was accepted before the migration and returns `23514` after it, with tombstones intact and `delete_own_comment()` working on a thread with replies; a retry with an edit yields one post with the new text, the new media set and correct positions, a retry without an edit is a no-op; `update_post_with_media()` was checked with six scenarios (a regular edit returning orphaned paths including a video poster, emptying the post `PT422`, whitespace instead of text `PT422`, media only with no text — legitimate, someone else's post `PT404`, someone else's prefix `PT422`); a retry of adding photos yields dense numbering with no duplicates and a working avatar sync trigger. After the grants were revoked, a smoke test ran over all live write paths — comment, deleting a comment via RPC, creating and rotating an invite, adding and deleting profile photos, publishing and editing a post, settings upsert, device_tokens upsert, mute — all pass, and the four UPDATEs that became impossible return `42501` already at the privilege level, not at RLS. The body of `create_post_with_media()` was checked against the live database's `prosrc` before the edit (see "Pitfalls" in CLAUDE.md about `create or replace`), and after the edit it was checked for traces of the old text. Nothing was tested on a device — the phone isn't connected.

- Tenth full audit: 8 findings closed, one withdrawn (0.16.8) — of the closed ones, seven came from the review, and the eighth was found underneath the withdrawn one while cross-checking against the live schema. Again a review of the whole project, not a diff: 103 migrations, the edge function, all of the Dart, the Android and CI config, build scripts, both ARBs. Before fixing, each finding was checked against the LIVE schema via the Management API, not against the migration that introduced it — and the very first one fell away in that check.

  **Withdrawn: a direct comment DELETE would cascade-delete other people's replies.** The finding was derived from `20260710113710`, which introduced a DELETE policy on `comments`, and from `on delete cascade` on `parent_comment_id`. Wrong: `20260725120000` dropped that policy — for exactly the reason described in the finding, and says so in plain words in its comment. `pg_policy` on the live schema returns only INSERT and SELECT for `comments`, i.e. DELETE is always rejected. The same class of mistake as the withdrawal in the ninth audit: migrations are a journal of intentions, not state.

  **A blind spot in the "grant without policy" check itself.** Underneath the withdrawn finding, though, a real one turned up: the control block from `20260824140000` matches grants against policies via `information_schema.column_privileges` — the right source for INSERT and UPDATE, which can be column-level, and blind to DELETE, because in the standard DELETE is a table-level privilege and NEVER appears in `column_privileges`. An entire command slipped past a check written precisely against this. Behind it stood four dead grants: `comments`, `connections`, `invite_links`, `users`. Today they open nothing (without a policy, RLS always rejects); they were revoked so that tomorrow's policy doesn't silently switch them on; the block now also consults `role_table_grants` and covers all three commands. Migration `20260825100000_close_delete_grants_blind_spot.sql`.

  **Rewriting a post with the same token left media in the bucket with no references.** Since `20260824100000`, a repeated `client_token` is not a no-op but a rewrite: the `post_media` set is wiped and the submitted one is inserted. It forgot to return the list of what dropped out, and `createPost` returns `void` and cleaned up nothing. The scenario is routine, not rare — the very one the rewritable token was introduced for: `.timeout()` stops waiting without cancelling, the publish commits after "failed to publish", the author removes a photo and taps "Publish" again. `create_post_with_media()` now returns `table (storage_path text)`, like `update_post_with_media()`, and the client runs cleanup through `deleteRowsThenObjects`. `reap_orphaned_media()` is the last line of defense here, not the first: a day's grace period and a hundred objects per run is not the tool for a 100 MB clip removed from a draft a second ago. Migration `20260825110000_return_orphaned_media_from_create_post.sql`. Simulation surfaced a bug in the migration itself: `returns table (storage_path text)` introduces a plpgsql variable named after the column, and `on conflict (post_id, storage_path)` fails with 42702 "ambiguous" — the conflict target must be a bare name and can't be qualified. Fixed with `#variable_conflict use_column`; `set_post_media()`, with the same signature, works only because it never writes `storage_path` without a table prefix.

  **Reverting a reaction restored a snapshot taken before the tap.** On error, `_react()` wrote the captured `post` into the list, not the inverse delta. Two taps in a row on a bad connection — and `.timeout()` makes "the request failed" and "the request got through" indistinguishable from here, so this is a common case: 👍, then 👎, the 👍 times out — and the revert set the state from BEFORE 👍, i.e. "no reaction", over the dislike that the server held and the person had just seen. Until the next pull-to-refresh. Now the revert is a transition applied to what's on screen now, and only if this request is still the latest one for the post; the revert target is the last reaction CONFIRMED by the server, so two failed taps in a row return the card to its original state, not to the state between them. Two widget tests, both verified to fail against the old code.

  **All selected profile photos were read into memory at once.** `_addPhotos` assembled `items` via `await file.readAsBytes()` for each file, and the whole batch — up to 80 at `maxWidth: 1600` — stayed resident throughout the sequential upload, on top of the copy that `MultipartFile.fromBytes` makes for the file in flight. The same residency that is the reason video in the composer lives as `MediaFile(path)`. `PendingPhoto` now carries a path, and the upload goes through `uploadTolerantFile`: a file is read when its turn comes, and then released.

  **An invite code got burned even when the connection already existed.** The `connections` insert goes through `on conflict do nothing`, while `is_used = true` was set right after it unconditionally, so a code presented by someone already connected with the owner burned the code for nothing — meanwhile the screen reported success, and the owner found out the code was gone only when they decided to send it to its intended recipient. It's easy to end up there: a repeated tap on "Activate" after a timeout is normal behaviour. Now the code is burned only if the insert actually created a row (`get diagnostics ... = row_count`). The different outcomes are deliberately not distinguished to the outside: "you are now connected with X" is true in both, and a distinct code would answer the presenter's question about someone else's connection graph. Migration `20260825120000_keep_invite_code_when_already_connected.sql`.

  **Three dead fields.** `ProfilePhoto.position` (the server has assigned positions since `20260824130000`; nobody read the field, but it invited the next reader to conclude that the order is decided on the client), `ActivatedConnection.ownerId` (parsed from the RPC response, while only `ownerName` was shown) and `BlockedUser.blockedAt` (run through `parseTimestamp` on every row, while the screen draws an avatar, a name and a button). Removed together with the columns that were selected for their sake.

  Verified: `make verify` green, 233 tests (231 + two new ones for the reaction race). Three migrations applied to the live DB and recorded in `supabase_migrations.schema_migrations` (101 -> 104), no drift between the repository and the DB. Both SQL changes were verified by simulation as `authenticated` in a rolled-back transaction: rewriting a post with a removed video returned two paths (the clip and its poster) and left one `post_media` and one `posts`; the invite code of an already connected pair stayed alive, while for an unconnected pair it was burned and created the connection. The version was not bumped.

- Consolidation of the migration history into a baseline (0.16.9) — 104 files
  (`20260707221946`…`20260825120000`) squashed into a single
  `20260826000000_baseline_schema.sql` that describes the end state of the
  schema rather than the path to it. Review and development no longer require
  reading dozens of intermediate migrations to understand what is in the
  database right now.

  **The source of truth was the live schema, not the migrations.** The
  baseline's content was derived from `pg_catalog` via the Management API —
  following the rule from the "Pitfalls" in CLAUDE.md: a migration is a
  journal of intentions, not state, and in a project of this age the line you
  need has often been undone by a later one. No drift between the repository
  and the database turned up along the way: all 104 migrations replayed from
  scratch on an empty PostgreSQL produced exactly what is in production — the
  only differences are platform ones (`ensure_rls`/`rls_auto_enable` and four
  triggers on `storage.objects`/`storage.buckets` that Supabase itself creates,
  not the project).

  **The baseline was verified on a clean database, not by eye.** It was applied
  to an empty PostgreSQL 18 with emulated platform roles/schemas and compared
  against production in two independent ways: via `pg_catalog` (columns,
  constraints, indexes, function bodies, triggers, RLS policies, grants,
  default privileges, the bucket, cron jobs) and via `information_schema`
  (`columns`, `table_constraints`, `check_constraints`,
  `referential_constraints`, `role_table_grants`, `column_privileges`,
  `routines`, `parameters`, `triggers`). No differences other than the platform
  ones listed. Separately, a set of behavioural checks was run as
  `authenticated` and `anon` (feed visibility with mute/block/the system
  account, rejections of TRUNCATE, of forging `author_id`/`created_at`, of
  writing `avatar_path`, of other users' storage prefixes, `dislikes_disabled`
  on both reaction write paths, the reaction identity pin): the output on the
  baseline and on the replayed history matched line for line.

  **The only intentional difference is the column numbers of `posts`.** In
  production, `attnum` 4 holds the tombstone of `image_path`, which
  `20260819220000` moved into `post_media` and dropped; on a clean database
  there is no gap, so `created_at`/`client_token` are 4 and 5 there instead of
  5 and 6. Nothing makes this visible from outside: the relative order is the
  same, and PostgREST returns objects, not tuples. Reproducing the gap would
  have meant creating a column only to drop it right away — exactly the
  historical junk that getting rid of was the whole point.

  **Default privileges for `anon` — closed.** The audit's only finding.
  `alter default privileges` for the `postgres` role in the `public` schema
  kept granting `anon` the full set of table privileges, `EXECUTE` on
  functions and `SELECT/UPDATE/USAGE` on sequences: privileges on existing
  objects had been revoked one by one (`20260818140000`, `20260821120000`),
  but the default itself remained, and the next table created would have
  gotten them back. For `authenticated` this half was closed by
  `20260822240000`, for `anon` it wasn't. The main issue here is TRUNCATE
  again: RLS doesn't apply to it at all, so a new table without a single
  policy could still be wiped by an anonymous user; just as important is
  `EXECUTE` — every function in `public` is a PostgREST endpoint. A tail of
  the same story: ten trigger functions still had `EXECUTE` for `anon` from
  the default — past migrations revoked grants by name and skipped the
  trigger ones. It couldn't have fired (a trigger function is invoked by the
  trigger machinery, not with the caller's privileges), but it was revoked,
  otherwise the default and the live schema drift apart. After the fix,
  `anon` has nothing left in `public` except the platform's
  `rls_auto_enable`.

  **History was not destroyed.** The previous 104 files live in the tag
  `pre-baseline-migrations` — 259 places in `app/lib`, `docs/` and the
  baseline itself refer to them by number:
  `git show pre-baseline-migrations:supabase/migrations/<version>_*.sql`.
  Plus a tarball and a dump of `supabase_migrations.schema_migrations` with a
  ready-made restore script outside the repository.

  **The CLI's bookkeeping table was brought in line using the standard
  mechanism.** 104 rows marked `reverted`, the baseline `applied`, both
  operations via `supabase migration repair`, not direct SQL. Before: 104
  remote-only entries and one local-only file, and `db push --dry-run` offered
  to apply the baseline to the live database. After: `migration list` shows a
  single row `20260826000000` on both sides, and `db push --dry-run` says
  "Remote database is up to date". Schema and data were unchanged: the schema
  checksum (`6a8c1b32…`, 252 objects) and the row counts of all tables match
  before and after, and the six pg_cron jobs are active.

  Verified: `make verify` green, 233 tests.

- Eleventh full audit (0.16.9) — a review of the whole project, not a diff:
  the entire baseline schema, the edge function, all of the Dart, CI/deploy,
  the manifest, both ARBs. `flutter analyze` is clean, 233 tests are green and
  **caught none of the findings** — just like the previous ten times. Each
  server-side finding was checked against the LIVE schema via the Management
  API before fixing: the bodies of all four recreated functions matched the
  baseline byte for byte, so the source for `create or replace` was the
  baseline, not memory. Migration
  `20260826120000_close_eleventh_audit_findings.sql`. The version was
  deliberately not bumped — that's the user's call.

  No "someone else's feed"-level holes. The visibility rule, `security definer`
  + `set search_path`, column-level grants, the control block at the end of
  the schema, the timing-safe secret comparison in `send-push`, the "rows →
  objects" order, the epoch/seq guards in the feed, per-viewer `FeedCache`
  keys, `allowBackup=false`, pinning GitHub Actions by SHA and avoiding
  `pull_request_target` — all in place and verified.

  Eleven findings closed:

  - **An abandoned `device_tokens` row diverted other people's pushes.** The
    claim on an FCM token was released only by `unregisterDevice()` on sign-out,
    and that is best-effort and wrapped in an empty catch (it can't be
    otherwise: signing out must work offline too). Signing out offline — or a
    rotation that has already happened, which makes `getToken()` return a
    different string than the one registered — left the row behind forever,
    and the next account on the same phone got the previous one's
    notifications: commenter names, digests. Nothing fixed it on its own:
    `send-push` removes a token only on an FCM `UNREGISTERED` response, and the
    token is alive; the client can't retry the removal, since after sign-out
    there is no session. The rule moved to the server: a BEFORE INSERT trigger
    `claim_device_token()` (`security definer` — the row belongs to someone
    else) gives the token to whoever registered it last. Along the way,
    `pin_device_token_timestamps()` now also restores the
    `(user_id, fcm_token)` pair itself: the UPDATE grant covers the whole
    table, the policy checks only `user_id`, and without the pin a row could be
    switched to someone else's token without violating a single policy. There
    were no shared tokens in the live data — the finding is latent, not an
    active leak.
  - **A double tap on a video left a player that couldn't be cleaned up.**
    `_play()` had no re-entry guard: while `initialize()` is running (seconds,
    on a slow network), `_controller` is still null, and the poster and an
    active play button are on screen. The second tap created a second
    controller, the first one's `setState` rendered it, the second one's
    `setState` overwrote the field — and not a single reference to the first
    was left. Nobody disposed it: `didUpdateWidget` watches for a change of
    `item.id`, `dispose` looks at the field. The native player kept decoding
    and playing sound under the second one until the app was killed. Added an
    `_isPreparing` flag and an `item.id` check before/after the `await` — which
    also closes the case where the slide changed while the controller was
    being prepared.
  - **`FeedCache.load()` swallowed the feed error message.**
    `SharedPreferences.getInstance()` sat outside the `try`, and this future is
    awaited in two places — the second one right INSIDE the `catch` in
    `_loadMore`, before the line that sets `_errorMessage`. A storage failure
    produced an unhandled async error from `_primeFromCache` and, worse, the
    first cold start offline showed "no posts yet" instead of "failed to load
    feed" — a message saying the exact opposite of what was happening. The
    neighbouring `save()` was protected against this, `load()` wasn't.
  - **A dead grant exposed `/rpc/is_author_visible`.** All four calls to the
    function sit inside `security definer` functions, i.e. they run as the
    owner, and it appears in no policy (verified with a query to `pg_policy`
    on the live schema, 0 matches). It wasn't a hole — its only argument is
    about the caller themselves — but there's no reason to expose an endpoint
    nobody uses. `revoke`.
  - **`set_post_media()` failed on a duplicate path, while its counterpart
    `create_post_with_media()` didn't.** Two functions writing to the same
    table by the same unique key behaved differently: the same `storage_path`
    arriving in `p_items` twice was silently dropped on publish but failed on
    edit with a raw 23505, which the client shows as the generic "failed to
    save changes". Added `on conflict (post_id, storage_path) do nothing` — and
    with it the mandatory `#variable_conflict use_column`: `returns table
    (storage_path text)` introduces an OUT parameter with that name, and the
    conflict target must be a bare column name, otherwise 42702. Exactly what
    the comment in `create_post_with_media()` warned about.
  - **`reorder_profile_photos()` let an array with repeats through.** The
    check compared only lengths: for a gallery `{a, b}`, the set `[a, a]`
    yields two rows on the join, the lengths match 2 = 2 = 2, `PT422` doesn't
    fire. Then `delete` wiped both photos, and the INSERT failed on
    `profile_photos_user_storage_path_key`. The transaction rolled back, the
    data stayed intact, but instead of a clear "the set doesn't match your
    gallery" the person got a generic error. Repeats are now rejected with
    `count(distinct)` before the table is read — `array_length` can't catch
    them, since the length is exactly what matches.
  - **`create_invite_link()` lost a race against itself.** Read-then-insert
    without a lock: two concurrent calls from the same owner — exactly the
    retry after a timeout that the function was written idempotent for,
    because `.timeout()` stops waiting without cancelling the request — both
    found no live code, both reached the INSERT, and the second failed with
    23505. The client showed "unexpected error", even though the code had been
    issued. Now it's `on conflict (owner_id) where not is_used do nothing`
    (the predicate is required, the index is partial) with `row_count` under
    it: the loser returns the winner's code.
  - **Bucket cleanup on account deletion went out as a single unbounded
    request.** The only place where the list of paths has no ceiling (a post
    has 20 media with posters, a gallery 80, but here it's the account's
    entire media library: 50 posts already mean several hundred paths in one
    request body). A request that's too large is rejected as a whole, and this
    half is best-effort by design — the failure is swallowed, and NOTHING gets
    deleted. Split into batches of 100.
  - **`fetchComments` had no ceiling** — the only query in the app without
    one, even though the feed right above it uses keyset pagination. A post
    with thousands of comments didn't fit into `networkTimeout`, and the
    screen showed "failed to load comments" on every attempt: not a slow load
    but a dead end. A limit of 500 (+1 row, to learn about truncation without
    a second query), a footnote at the end of the list and — importantly —
    `onCountChanged` isn't fired when truncated: the length of a truncated list
    is a ceiling, not a count, and passing it on would drop the counter on
    the card from the real number to 500. The tail is cut, not the head:
    comments go from oldest to newest, and cutting the tail can separate a
    reply from its root (`threadComments()` hides such replies anyway), but
    never a root from its replies.
  - **The digest ran O(N) queries inside the post-insert transaction.** The
    branch was a loop over all of the author's connections, and for each one a
    separate `count(*)` over `posts × connections` was run — in an AFTER
    INSERT trigger, where any error rolls back the post itself and publishing
    latency grows linearly with the number of connections. Rewritten as a
    single `insert ... select` with `materialized` CTEs (without them the
    planner is free to inline the CTE and compute the expensive lateral for
    every connection, including those filtered out — i.e. exactly what the
    fix gets rid of). This is the very function that was twice recreated from
    pre-reform text, and both times nobody could publish, so equivalence was
    verified **with an A/B test on live data**: the same post was published
    by the old and the new version in rolled-back transactions, and the
    `notification_outbox` rows matched byte for byte — five digests with
    counters 8/12/12/8/7 and one `new_post`.
  - **The bucket reaper couldn't keep up with the garbage.**
    `orphaned_media_paths()` is capped by `limit 100`, and the job ran once a
    day — a ceiling of 100 objects **per day**, while a single abandoned draft
    leaves up to 40. `reap-orphaned-media` was switched to hourly: 2400 a day
    with the same batch, with no increase in the size of the request to
    Storage.

  Verified after applying: the `prosrc` of every changed function was compared
  with the migration file (matches), the baseline control block passed, the
  trigger order on `device_tokens` is `claim` before `enforce_limit`, the six
  pg_cron jobs are active, `schema_migrations` has two rows. `make verify`
  green, 235 tests.

- A third value for `connections.method` (0.17.0) — `manual`, for rows created
  by hand via the Management API. `qr_code` in the CHECK is groundwork for a
  future feature (scanning a QR code as a second way to connect), not an
  implemented path: the only place that writes to `connections` is
  `activate_invite_link()`, and it always sets `invite_link`. Manual inserts
  were labelled `qr_code`, i.e. they looked as if they had gone through a
  non-existent path; now they have their own value, and `qr_code` stays free
  until the feature itself. Migration
  `20260826130000_add_manual_connection_method.sql`.

- Rooms, Stage 1: a room and its feed (0.17.0) — a separate feed for the
  people who were invited, isolated from everyone else. Schema:
  `20260826180000_rooms.sql`; description: "Rooms" in
  [docs/data-model.md](docs/data-model.md).

  **The bottom bar was rearranged**: labels removed (five labels on a phone
  either wrap or shrink to unreadable — the `label` stays in the tree, where
  the screen reader reads it and a long press shows it), the "connections"
  and "new post" buttons swapped places, and rooms took the middle slot:
  feed · new post · rooms · connections · profile.

  **A room has no `creator_id`.** The owner is the member with the lowest
  `seq`, so "the creator left — the oldest remaining member gets the rights"
  happens by itself: deleting the row in `room_members` is the transfer of
  rights. A stored column would need a trigger on every leave and would fall
  out of sync exactly where someone forgot to call it.

  **A two-person room is not a small group but a different entity.** It has
  no name at all (`rooms_direct_shape` requires `name is null`): each side
  sees the other person's name, and the client assembles it. A third person
  can't be added, and either side leaving takes the room away from both.
  There is exactly one pair per room — `direct_a`/`direct_b` under a unique
  partial index — and that same index makes creation idempotent: "message"
  the same person again and the existing room opens instead of a second one
  being created.

  **Multi-posting.** A post goes to the general feed, to several rooms at
  once, or only to a room — in which case it is visible nowhere else,
  including the author's profile wall. The recipients arrive in the same
  transaction as the post itself (`create_post_with_media()` gained
  `p_room_ids`/`p_in_general_feed` with default values, so already shipped
  clients keep publishing to the general feed). The old overload of the
  function was **dropped** rather than kept alongside: two overloads would
  have made a call with three named parameters ambiguous for PostgREST — that
  is, they would have broken publishing for everyone at once.

  **The post visibility rule became two-branched** — "a general-feed post
  whose author is visible" OR "the post is in my room" — and everything that
  depends on post visibility followed. `post_media` was switched to a nested
  `exists (select 1 from posts …)` (RLS also applies to a subquery inside a
  policy, so "the post is visible" comes for free) — there are now fewer
  copies of the rule, not more: two of them, the `posts` policy and
  `is_post_visible()`.

  **Room members don't have to be Connections of each other** — the owner
  gathered them from their own connections. So post visibility alone isn't
  enough: `shares_room_with_caller()` was added to the `users` policy
  (otherwise a post in the room feed would have no author name), to the
  avatar storage policy and, together with `is_comment_author_room_peer()`, to
  both branches of comment visibility; post photos go from the path to the
  post via `media_path_in_my_rooms()`. Mute and block deliberately have no
  effect inside a room; the only thing a block still does is prevent creating
  a room with the person it's with.

  **There are no notifications about room posts at all yet**:
  `enqueue_post_notifications()` exits first thing on
  `not new.in_general_feed` and counts the digest with the same filter —
  otherwise the push "Petya has a new post" would tell someone about a post
  they won't be shown. Room pushes will come together with the chat (Stage 2,
  see [docs/future-development.md](docs/future-development.md)).

  **A simulation right after the rollout found a hole in storage — closed by
  `20260826190000`.** The object path (`posts/<author_id>/…`) only knows the
  author, and before rooms that was enough: all of an author's posts lived in
  the general feed, so "the author is visible" meant "their files are visible
  too". With rooms that stopped being true — a connection of the author who
  wasn't invited to the room could open the photo file of a post addressed
  only to the room (while the `post_media` row and the post itself were
  hidden from them). The policy was switched from the author to the POST:
  `post_media_path_visible()` asks `is_post_visible()`, i.e. the same single
  rule. The author branch stays first and deliberately doesn't require a row
  in `post_media` — the client uploads files before the post exists.
  `media_path_in_my_rooms()`, added the day before, is fully absorbed by this
  and dropped, so it doesn't linger as a second, narrower copy of the same
  question.

  Verified: `make verify` green, 246 tests (235 + eleven new ones for the
  room name, parsing a `my_rooms()` row and recipients in the composer). The
  bodies of all four recreated functions were checked against the live
  schema by md5 before the edit and matched. Both migrations were applied to
  the live DB and recorded in `supabase_migrations.schema_migrations`
  (3 rows -> 5). RLS was verified by simulation under `authenticated` in
  rolled-back transactions, 26 checks: room feed isolation (a member sees it,
  a connection of the author outside the room doesn't: not the post, not a
  comment, not reaction counters, not the room, not its members), visibility
  of a roommate who is not a Connection (their profile and comments are
  visible), a "room-only" post produces neither `new_post` nor `digest` (the
  only outbox row is `post_comment` to the author, and the post is visible to
  them), a regular post still produces notifications, ownership (the creator
  is the owner, a member can't rename or remove anyone, the owner leaving
  keeps the room and passes rights to the oldest member, the last one to
  leave takes the room away), the two-person room (one per pair, creating
  again returns the same one, a third person can't be added, it can't be
  renamed, one side leaving takes it away from both), storage before and
  after the fix.

- Rooms, Stage 2: chat (0.17.0) — the second half of a room. Schema:
  `20260826200000_room_chat.sql`; description: "Room chat" and "Room
  notifications" in [docs/data-model.md](docs/data-model.md).

  Messages arrive on their own: `room_messages` was added to the
  `supabase_realtime` publication — **the first use of realtime in the
  project**. Postgres Changes checks the subscriber's SELECT policy row by
  row, so other people's rooms don't leak through the subscription: the rule
  is the same as for a normal read, and the chat has no second copy of the
  visibility rule at all — a message is visible to whoever is in the room.

  **Deleting your own message is a placeholder, not a `delete`,** and not
  only for consistency with comments: realtime delivers a DELETE without the
  row's contents (replica identity default — only the key), so there's
  nothing to check RLS against, whereas an UPDATE arrives as a whole row and
  is filtered by the policy like a normal read. The table has no UPDATE or
  DELETE policies at all: the only way is `delete_own_room_message()`. An
  UPDATE policy can't restrict WHICH columns change and would open the whole
  row to editing — including `created_at`, which unread counts are based on.

  **Unread is a `last_read_at` column on the member row**, not a separate
  table: that would duplicate `(room_id, user_id)` one-to-one. It also
  suppresses pushes: the screen marks every incoming message as read, so
  "read less than a minute ago" means "the person is in this chat right now",
  and no notification is created. The second safeguard is that the queue
  collapses: while the previous push from this room hasn't gone out, a second
  one doesn't appear — otherwise a chat that comes alive turns into forty
  identical notifications arriving at once.

  **A post to a room finally notifies — the members and nobody else.** The
  trigger sits on `post_rooms`, not on `posts`: when the post is inserted
  there are no recipients yet; they arrive with the next statement of the
  same transaction. The safeguard here is different: one notification per
  post per person of ANY kind — otherwise a member who also has the author in
  favorites would get both `new_post` and `room_post` about the same thing.

  The room name is deliberately absent from the push text: it's different
  for everyone (for a room without a name it's a list of members), the client
  assembles it, and a second copy of this rule on the server would diverge
  from the first at the very first rename.

  `my_rooms()` was recreated via `drop`+`create` — `create or replace` isn't
  allowed to change OUT columns — and now returns the last message and the
  unread count: the room list doubles as the chat list. The grant was issued
  again after the drop, exactly as for `create_post_with_media()` one step
  earlier.

  Nothing changed in the bottom bar, but the room row got a second button —
  chat, with an unread counter; the same button is in the room feed header,
  so you can switch between the halves without going "back". Notification
  settings have two new toggles: room messages and room posts — separately,
  because messages come often and posts rarely.

  Verified: `make verify` green, 260 tests (246 + fourteen new ones for
  message parsing, the chat half of `my_rooms()` and the chat screen —
  sending, an empty message, a send error, the deleted placeholder, arrival
  via realtime, the echo of your own message, unsubscribing when leaving the
  screen).

- Rooms: group avatar and fixes after on-device testing (0.17.0).
  Schema: `20260826210000_room_avatar.sql`.

  **Sending a message didn't work at all** — the `upsert` could never
  succeed, for two independent reasons. `on_conflict=author_id,client_token`
  asks to infer an index, but the index behind it is partial
  (`where client_token is not null`): inference from a partial index
  requires repeating its predicate, which PostgREST can't send — the server
  answers 42P10. On `posts` and `comments` the same technique works precisely
  because their indexes aren't partial; the technique was copied, but not
  that condition. On top of that, `upsert` expands to `DO UPDATE`, and
  `room_messages` deliberately has neither an UPDATE grant nor an UPDATE
  policy. Fixed on the client, not with a grant: a plain `insert`, with the
  duplicate handled where it shows up — a 23505 from the unique index means
  "this send already went through", and the row it collided with is the
  answer. The server-side restrictions stayed as they were.

  **A group room has an avatar**, set by the owner. The permission is
  computed not by comparing with `auth.uid()` but by asking "do I own this
  room" (`owns_room()` — a one-directional wrapper over `room_owner_id()`,
  which itself answers about any room and is therefore not granted to the
  client). A CHECK on the column holds two invariants at once: a two-person
  room has no avatar at all, and the path is always under its own room's
  prefix — without the second, the owner of one room could write themselves
  a path to another room's file.

  **A group room doesn't borrow a member's face.** A borrowed avatar read as
  "this is that person": the row looked like them, a tap opened their
  profile — even though they were chosen only because they joined before
  everyone else. Now a group without its own picture has a neutral icon, and
  a tap leads to the room details; a member's face stays on the two-person
  room, which that person effectively is.

  **The owner isn't shown in a two-person room.** In the schema there always
  is one (the minimal `seq`), but there's nothing for them to do there — no
  adding, removing or renaming — and a label next to one of the two names
  would only raise the question of why it's there.

  Verified: `make verify` green, 273 tests. The migration was applied to the
  live DB and recorded in `schema_migrations` (7 rows). RLS was verified by
  simulation, 13 checks: the owner sets and replaces the avatar (replacement
  returns the old path for removal), another room's prefix and a two-person
  room are rejected, a member can't change it but sees and opens the file, an
  outsider sees neither the room nor the file, and only the owner can upload
  into the room's folder.

- A separate notification kind for an important update (0.17.0) — kind
  `app_update_important` and the `p_important` parameter of
  `enqueue_app_update_notifications()`. Migration
  `20260826220000_important_app_update_notice.sql`.

  The text of the regular `app_update` was deliberately not rewritten: it
  goes out on every notable release, and if it were made insistent, by the
  third time the insistence would stop meaning anything. The new kind is for
  releases without which an old client shows the wrong thing; 0.17.0 is
  exactly that: clients on build 43 and older don't filter
  `posts.in_general_feed` and show a post addressed ONLY to a room in the
  general feed as well (no data leaks, though — RLS only lets room members
  reach it).

  Deduplication looks at both kinds at once: a person must not get two
  notifications about the same build — neither identical ones nor "a regular
  one followed by an insistent one". The texts, as always, live in the Edge
  Function, and these are two paired edits: the `kind` in the CHECK and
  `TEXTS` in `send-push`, otherwise the queue row is silently skipped.

  Sent after the 0.17.0 release: a queue of 3 recipients (everyone without a
  single device on build 44), 3 of 3 delivered.

- Read/delivered on every message (0.17.2) — closes an item from
  future-development.md without adding a separate table for message status.
  Migration `20260827100000_room_message_receipts.sql`.

  Next to `last_read_at` on the `room_members` row, a second marker is
  added, `last_delivered_at`, using the same technique as unread
  (20260826200000): a specific message's status isn't a stored value but a
  comparison on the client (the message's `created_at` against the other
  person's marker). `mark_room_read()` now moves both markers at once — a
  read message is never undelivered — and the new RPC
  `mark_rooms_delivered()` moves "delivered" in all of the caller's rooms at
  once and is called on every load of the room list: without its own push
  acknowledgement infrastructure, that is the only "delivered" signal the
  app has. `room_members` was added to the realtime publication — the second
  use of this mechanism in the project (after `room_messages`) — under the
  same SELECT policy as a normal read, so the sender's check mark can flip
  while they are still looking at the screen.

  In the UI — on YOUR OWN messages: in a two-person room a WhatsApp-style
  icon (sent/delivered/read), in a group an aggregate "Read N/M", because a
  single icon can't say "three out of five have read it".

  Verified: `make verify` green, 273 tests. The migration was applied to the
  live DB and recorded in `schema_migrations`. RLS was verified by
  simulation: an outsider doesn't see `room_members` of someone else's room
  (0 rows), `mark_rooms_delivered()` and `mark_room_read()` move only the
  caller's marker — in a room of three members, other people's markers never
  changed.

- The room became a chat, the room feed was removed (0.17.3) — together with
  post addressing: `post_rooms` and `posts.in_general_feed` were dropped,
  posts that lived only in rooms were deleted (8 of them on the live
  database, with no media or comments). Migration
  `20260828100000_rooms_without_feeds.sql`.

  The reason isn't that nobody opened the room feed, but the cost of the
  second branch of the post visibility rule: every new post-related feature
  is obliged to remember it, and 20260826190000 closed exactly such a finding
  a day after rooms rolled out — the photo of a post addressed only to a room
  could be opened by a connection of the author outside it. Addressing will
  come back as a visibility setting on the post itself
  (future-development.md), not as a room.

  The visibility rule was collapsed back into one branch — the `posts` policy
  and `is_post_visible()`; `create_post_with_media()` went back to three
  arguments; `my_rooms()` was recreated without `last_post_at` (the fourth
  time, and all for the same reason — `create or replace` doesn't change OUT
  columns); the `room_post` notification kind, its trigger and the
  `notify_room_posts` setting went away along with what they notified about
  (and along with the texts in send-push — it's always two edits). In the
  client: the room feed screen was removed, a row in the room list opens the
  chat, members and renaming moved to a button in the chat AppBar, and the
  recipient check boxes left the composer.

  Found by simulation right after the rollout: the "comment author is my
  roommate" branch relied on the dropped `post_in_my_rooms()`, and the body of
  a `security definer` function is resolved at runtime — reading comments
  would have failed with 42883 for everyone for whom the first branch wasn't
  enough. The `comments` policy and `is_comment_visible()` went back to their
  pre-rooms text, both copies of the rule at once.

  BREAKS SHIPPED CLIENTS, deliberately: build 46 and older sends
  `.eq('in_general_feed', true)` in the feed query (now a 400) and calls the
  RPC with five parameters (now a 404). So the release is followed by an
  `app_update_important` broadcast — see the "update the app" broadcast in
  operations.md.

  Verified: `make verify` green, 269 tests. The migration was applied to the
  live DB and recorded in `schema_migrations`. RLS was verified by simulation
  on three accounts: posts are visible exactly per `visible_author_ids()`
  (not a single extra row), the number of visible objects in `storage/posts`
  matched the number of visible `post_media` rows for each account, chat and
  rooms unaffected.

- Mute a single room (0.17.3) — closes an item from future-development.md.
  Migration `20260828110000_mute_one_room.sql`.

  The `notify_room_messages` setting answers "do I want pushes from chats at
  all", and the `room_members.notifications_muted` flag answers "do I want
  them from this chat": previously a group chat that came alive had to be
  silenced entirely, along with conversations that matter. A third marker on
  the member row, for the same reason as the first two (`last_read_at`,
  `last_delivered_at`): the "person ↔ room" relationship is already
  described by this row, and a separate table would duplicate its key
  one-to-one. The flag is written by the `set_room_muted()` RPC — the table
  has no UPDATE grant and this migration doesn't add one, and a policy can't
  restrict WHICH columns change and would open both markers that unread
  counts and check marks are based on.

  Mute is about pushes and nothing else: unread is still counted, the badge
  stays, and a crossed-out bell appears next to it on the list row. The
  toggle is on the room screen, and it isn't owner-only: a muted room is
  about your own phone, not about the room. `my_rooms()` was recreated for
  the fifth time (the set of OUT columns) so the flag comes with the list
  rather than in a second query.

  Verified: `make verify` green. The migration was applied to the live DB and
  recorded in `schema_migrations`. RLS was verified by simulation:
  `set_room_muted()` changes only the caller's row (other rows in the same
  room untouched), and a call for a room the caller isn't in changes nothing.

- Media in room messages (0.17.3) — up to 10 photos/videos per message,
  closes an item from future-development.md. Migration
  `20260828120000_room_message_media.sql`.

  Attachments live in a column, `room_messages.media` (jsonb), not as rows of
  a separate table, and this is the only such place in the project. Reason
  one: realtime delivers a ROW — rows of a second table would need a separate
  query, which the subscription doesn't have, and a bubble with a photo would
  appear empty for everyone else. Reason two: the CHECK "either text or
  attachments" can finally be expressed, because it's a single-row condition
  (for posts the same rule is checked procedurally inside
  `create_post_with_media()`). Reason three: the reverse path from a file to
  a row isn't needed here — message visibility is room membership, and the
  room is written right in the path `messages/<room_id>/<author_id>/…`.

  Shape and paths are enforced by a CHECK via the immutable
  `room_message_media_ok()` — a CHECK itself can contain neither a subquery
  nor `jsonb_array_elements`. It verifies that each path lies under its own
  room and its own author, so the rule lives on the row, not just in the
  policy. The function is granted to `authenticated` not for calling from the
  client but because a CHECK is evaluated with the writer's privileges:
  without the grant, sending would fail with 42501, as the simulation showed.

  Sending stayed a plain `insert` (no RPC was needed),
  `delete_own_room_message()` now also removes attachments, returning the
  orphaned paths, and `orphaned_media_paths()` learned the `messages/`
  prefix — before that, nobody would have picked up an abandoned attachment.

  In the client, what is now shared between the post composer and the chat
  was moved to `lib/shared/`: file picking with all its gates
  (`media_picking.dart` — format, duration, size, video poster), the viewer
  and slide (`media_gallery.dart` around the `GalleryMedia` interface) and URL
  signing (`signed_urls.dart`). There is now one copy of each of these rules,
  not two.

  Verified: `make verify` green, 274 tests. The migration was applied to the
  live DB and recorded in `schema_migrations`. Verified by simulation: a
  message with a valid attachment goes through, a path into someone else's
  folder and an eleventh element are rejected by the CHECK,
  `delete_own_room_message()` returns both paths (the video and its poster),
  an object in a room is visible to its member and not visible to an
  outsider.

- Tapping a push opens what it's about (0.17.3) — closes an item from
  future-development.md, and not only for rooms: there's one rule for all
  notification kinds. An edit to the `send-push` Edge Function + the client;
  no migration was needed.

  It turned out the ids weren't going anywhere: they had been in the queue
  row's payload ever since rooms, but `sendToToken()` sent only a
  `notification`, without `data`. Now the function adds `kind` and the ids
  found in the payload (`room_id`, `post_id`, `comment_id`, `author_id`) — as
  strings, as FCM requires, and a missing key is simply not added rather than
  going out as "undefined".

  Where each kind leads is decided by one pure function, `pushTargetFrom()`,
  and the table there is complete: room → its chat, comment and reply → the
  post's comments, new post / digest / "week of silence" → the feed, the
  update notification and any unknown kind → nowhere. A kind without its own
  id also leads nowhere: an empty screen is worse than none. The tap is
  handled by the app shell — the only widget that is always mounted while
  there's a session, which is exactly what a cold start needs, where the tap
  arrives before the screen itself.

  The function was deployed (`supabase functions deploy send-push`) and
  answers 200 on an empty run; old clients don't care about the extra
  `data`. `make verify` green, 280 tests — the whole table of kinds is
  covered.

- "typing…" and "online" in the room chat (0.17.3) — closes an item from
  future-development.md. Migration `20260828130000_room_presence.sql`.

  Neither a table nor a column: Realtime presence keeps this in memory and
  distributes it to subscribers itself, and a value that goes stale a second
  after it's written has nowhere to be stored. Hence the feature's boundary —
  "online" means "in this chat right now", not "opened the app"; "last seen
  at 12:40" would need its own column and a separate conversation about
  privacy.

  The key decision is that the channel is PRIVATE. A regular Realtime channel
  is open to anyone who knows its name: presence and broadcast, unlike
  Postgres Changes, don't check RLS at all, because they don't read anything
  from tables. A private one does check — via `realtime.messages`, where RLS
  is enabled but there were no policies at all (meaning private channels were
  forbidden entirely). Two were added, both asking
  `is_my_room_topic('room:<uuid>')`: the regex before the type cast is
  mandatory, otherwise `'room:мусор'::uuid` would not be "false" but an error
  inside the policy.

  The client announces `track({user_id, typing})` and clears the flag in
  three ways: by sending, by leaving the screen, and by a 4-second timer after
  the last keystroke. The line under the room name shows "typing" first (in a
  group — with the name), otherwise "online" / "N online", and your own
  presence doesn't count.

  Verified: `make verify` green, 284 tests. The migration was applied to the
  live DB and recorded in `schema_migrations`; simulation confirmed the topic
  predicate answers `true` for your own room and `false` for someone else's,
  a nonexistent one, and garbage.

- A connection request to a room member (0.17.3) — the last item of the
  "Rooms" section in future-development.md, and the only one of the six that
  required a new entity. Migration `20260828140000_connection_requests.sql`.

  Until now a Connection was created in exactly one way — an invite code
  shown in person. Rooms created a situation where that isn't enough: the
  owner assembles a room from THEIR OWN connections, its members don't have
  to be connections of each other, and people who are already in the same
  chat have no way to exchange a code. So a request can be sent ONLY to
  someone you share a room with (`shares_room_with_caller()` on the server) —
  a narrow door that grows into neither people search nor the ability to
  message a stranger.

  The pair in `connection_requests` is ordered, unlike `connections`: a
  request has a direction. Uniqueness on (requester, recipient) holds the
  rule "one request per pair, ever, in any status" — a decline is final,
  because being able to ask again turns a decline into a negotiation;
  someone who changes their mind sends their own request in the opposite
  direction. A counter-request isn't created but accepted: two people who
  asked each other both agree.

  A block and the absence of a shared room answer with the same PT403 —
  distinguishing them would answer a question the block is obliged to hide;
  the block is also checked when responding, because it may have appeared
  after the request was sent. A decline notifies no one: a quiet decline
  shouldn't become an event. Neither of the two new push kinds has an
  off-switch setting (the only such ones besides `app_update`): a request is
  addressed personally and comes once every few months.

  In the UI: an "Ask to connect" button next to a member on the room screen —
  exactly where two strangers meet — and an incoming requests section first
  on the "Connections" screen. Tapping the push opens it too.

  Verified: `make verify` green, 292 tests. The migration was applied to the
  live DB and recorded in `schema_migrations`, the Edge Function deployed
  (texts are always the second edit for a new kind). Verified by simulation:
  the path "request → accept → Connection with method `connection_request`"
  goes through end to end, a counter-request immediately returns
  `connected`, a second request answers PT409, a request to someone you share
  no room with — PT403, a response to someone else's request — PT404, and an
  outsider doesn't see the request row itself.

- Who can see a post (0.17.4) — when publishing and when editing, an audience
  is chosen: all connections or favorites only. Migration
  `20260829100000_post_visibility.sql`.

  This replaces addressing posts to rooms, removed a day earlier together
  with their feeds, and the difference between them is the whole point of
  the replacement: a room was a GROUP, a separate place with its own members
  and its own feed, whereas visibility is a property of THE POST ITSELF,
  i.e. a column on its row. There's no longer a second table, a second feed,
  or a branch living a life of its own.

  The "favorites only" audience is the AUTHOR's favorites list; no separate
  "close friends" table was created, because such a list already exists. The
  side meaning is worth stating out loud: favorites used to be purely
  personal ("I want a push about their posts"), and now they are also an
  audience. You still can't find out that you're in someone's favorites —
  only the owner sees the rows, and the "favorites only" label is shown only
  to the post's author.

  The visibility rule is two-branched again and again written in two places
  — the `posts` policy and `is_post_visible()`. There are also two favorites
  predicates: the set `authors_who_favorited_me()` for the policy (hashed
  once) and the scalar `is_favorited_by()` for per-row callers. Both are
  `security definer`, otherwise a subquery into SOMEONE ELSE's favorites
  inside the policy would be filtered to zero by its own RLS — the same class
  as the `blocked_users` hole from 0.9.0.

  A simulation right after the rollout found a bug in the opposite
  direction: the author stopped seeing their own "favorites only" post — they
  would only pass the second branch by having themselves in favorites. Added
  as an explicit line to both copies of the rule and to the migration's
  checks.

  Notifications are computed by the same rule: the "new post" push goes to
  those who added THE AUTHOR, while the post is seen by those the author
  added — different lists, and without an explicit condition the push would
  go to someone the post won't be shown to. For the same reason the digest
  counts only what's visible.

  The edit's default value is `null` ("leave as is"), not `'connections'`:
  a build 47 client, which doesn't know about visibility, edits the caption
  of a "favorites only" post — and must not expose it to everyone with that
  edit.

  Verified: `make verify` green, 299 tests. The migration was applied to the
  live DB and recorded in `schema_migrations`. Verified by simulation with
  three viewers: a favorited one sees 5 of the author's posts and 4 files, a
  non-favorited one — 4 and 3 (media and files in Storage inherit the post's
  visibility), the author — their own 5.

- Twelfth full audit (0.17.5) — a review of the whole project without relying
  on past reviews: 15 migrations, `send-push`, all of `app/lib`, CI. Eight
  findings, all closed. Migrations
  `20260829110000_close_twelfth_audit_findings.sql` and
  `20260829120000_message_media_delete_by_author.sql`.

  **The main one — `/rpc/is_favorited_by` answered about other people's
  favorites.** 20260829100000 granted both functions of the pair to
  `authenticated`, but only one needed it: `authors_who_favorited_me()` sits
  in the `posts` SELECT policy, which is evaluated with the reader's
  privileges, and without the grant the feed would have shut off for
  everyone — whereas `is_favorited_by()` is called only by
  `is_post_visible()`, which is itself `security definer` and granted to no
  one, so inside it the call runs with the owner's privileges. The grant was
  dead, and through it any logged-in user could ask "does this person have me
  in favorites" about anyone — exactly the bit that `favorite_users` is
  locked down by RLS to a single owner's rows to hide. The same class as the
  dead grant on `is_author_visible()` (0.17.1), but, unlike that one, not
  harmless. Both sides verified by simulation: the endpoint answers 42501,
  while a "favorites only" post is still visible to a favorited user (along
  with its counters) and still not visible to other Connections.

  Also fixed the wording of the invariant that the same migration carried
  into docs: "you can't find out that you're in someone's favorites" stopped
  being true at that same moment — `authors_who_favorited_me()` with no
  arguments lists everyone who added the caller. This is the price of an
  audience, not an oversight: as long as someone else's list decides what a
  person will see, there's no way to hide from them the very fact of being on
  the list. The correct wording is "someone else's list is closed; your own
  'who added me' is open to its owner".

  **A deleted room's avatar was unreachable garbage.** The orphan collector
  knew `posts/`, `avatars/` and `messages/`, but not `rooms/`
  (20260826210000 introduced the prefix, 20260828120000 extended the
  collector and missed it). Worse than "not collected": both storage policies
  for the prefix compute the permission via `owns_room()` →
  `room_owner_id()` → a row in `room_members`, which an empty room no longer
  has, so the object could be neither read, deleted, nor found. A second path
  to the same place is a failed best-effort cleanup when replacing the
  avatar. A third branch was added that asks `rooms.avatar_path`. Verified by
  simulation: an orphan is collected, a live avatar and an upload younger
  than a day are not.

  **`room_messages.media` had no size cap** — the only client-writable column
  in the schema without one, and the only one that goes out not in response
  to a query but on its own: the table is in the realtime publication, and
  the subscriber receives the ROW. Ten paths with a legitimate prefix and a
  megabyte of padding were broadcast to the whole room in a single send. Now
  it's 400 characters per path and 8000 bytes per column — twice the honest
  maximum (the longest legitimate path is 161 characters, ten elements with
  all fields ≈ 3970 bytes).

  **The "Ask to connect" button got permanently stuck after a decline.** The
  screen read only requests with `pending` status, so a declined one vanished
  from the list — and a decline is silent by design, so nobody told the
  sender. The button came back and answered PT409 forever:
  `connection_requests_pair_key` won't allow a second row in the same
  direction. The client now fetches its own requests in any status
  (`fetchRequests()`), and PT409 is handled as "already happened" rather than
  a red error — a promise that until now existed only as a comment above the
  method. The reverse move remains legitimate: the person who declined is
  free to ask themselves, and that isn't the same request but their own
  decision. Two new widget tests for both halves of the rule.

  **Account deletion didn't remove chat attachments.** The method listed the
  avatar, the gallery and post media, but not `room_messages.media`. The fix
  ran into storage: the DELETE policy of the `messages/` prefix required room
  membership, and `delete_own_account()` removes `room_members` by cascade
  before the client gets to the bucket — so the author was refused their own
  files, and they stayed until `reap_orphaned_media()` (a hundred per hour,
  no sooner than a day). The membership condition was removed from DELETE,
  and only from DELETE: no one else's byte can be reached through the third
  path segment regardless of membership, whereas SELECT and INSERT are about
  the room and must ask about it. This also closes the same refusal for an
  author who deletes their message after leaving the room
  (`delete_own_room_message()` doesn't require membership even now).

  **Minor items.** The header of 20260828140000 referred to a "second,
  symmetric index" that doesn't exist and must not: it would forbid exactly
  the reverse move that the paragraph below in the same place calls
  legitimate — uniqueness is directional, and the docs were brought in line
  with this reading. Comments in `notification_preferences_repository`
  ("both room kinds", "seven booleans") and `feed_cache` ("`room_<id>` scope")
  described features removed in 0.17.2 together with room feeds.

  Verified: `make verify` green, 301 tests. Both migrations were applied to
  the live DB and recorded in `schema_migrations`. An end-to-end SQL test of
  the new DELETE policy is impossible — the platform forbids a direct
  `delete` from `storage.objects` (`storage.protect_delete()`), so the
  verdict was based on the policy text in the post-rollout checks.

- Mute is a feed filter, not a wall (0.17.5) — found by a user: mute a
  connection, tap their avatar — the profile opens, but there are no posts in
  it. That reads as "they have no posts" or "they blocked me", even though they
  did nothing and don't know about the mute: what hid them was MY personal
  setting. Migration `20260829130000_mute_is_a_feed_filter.sql`.

  The cause: mute was a conjunct of the single visibility rule
  (`is_author_visible()`: "a Connection I haven't muted and with whom there is
  no block"), so it hid the person entirely: posts, their media, comments,
  counters, files in Storage. Splitting "hide in the feed, show in the profile"
  inside RLS is impossible in principle — it's the same `select from posts`,
  differing only in the client-side `.eq('author_id', …)` — and adding a second
  copy of the rule for the profile would repeat the very mistake that the rule
  was consolidated into a single function to fix (0.11.0, 0.13.2).

  So mute left RLS entirely and now means exactly two things: **not in the
  main feed and no pushes**. There is still one visibility rule, and it got
  shorter: "me, the system account, or a Connection with no block in either
  direction". The same conjunct was removed from
  `is_comment_visible_to_post_owner()` and
  `is_commenter_visible_to_post_owner()` — otherwise a muted person's comment
  would become visible (it passes the policy's first branch) while the `users`
  row with their name would not, and a caption with no author would show up
  under the post.

  The feed now filters itself: `ConnectionsRepository.fetchMutedIds()` + a
  `mutedAuthorIds` parameter on `FeedRepository.fetchPage()`, which is mixed
  into the same `not.in.(…)` as the system account. One request per load cycle,
  not per page: every page hides the same people, and the answer can't change
  mid-scroll — while `_refresh()` re-reads it, and mute/unmute is exactly what
  pokes `feedRefreshTickProvider`, i.e. a refresh. On a profile (`authorId`
  set) the request isn't made at all. A failure to read the mute list drops
  the page into the usual "failed to load" with a fallback to cache, rather
  than substituting an empty set: quietly showing a feed full of the people
  you asked not to be shown is worse.

  **Blocking is untouched everywhere and remains the only privacy
  boundary**: it is mutual and entirely server-side. Mute never was one — it's
  a one-sided setting, invisible to the other side — but now the client
  enforces it, and it can't be relied on as a boundary. Nothing belonging to
  anyone else is exposed by this: the muted person is still a Connection whose
  `users` row and avatar the policies always showed
  (`is_connected_to_caller()` never asks about mute). `has_muted()` is alive
  and remains in exactly two notification functions — muting someone and
  still getting their pushes would be nonsense; a check for that is in the
  migration itself.

  Verified by an RLS simulation on a live pair with a mute, control numbers
  before/after: posts by the muted author 0 → 5, total visible posts 27 → 32,
  profile row 1 → 1 (it was visible before too — hence the empty page), the
  muted person's reaction counters 0 → 5. Control on a block: the blocked user
  saw 0 of the blocker's posts and 0 counters before the fix and the same
  after. `make verify` green, 306 tests (+5: feed filter, no filter and no
  request on a profile, one request per pagination, re-read on refresh, page
  failure when the mute list is unreadable).

- Documentation brought to a single shape (0.17.5) — not a feature but a
  cleanup: some files held things their names don't promise.

  **Added [docs/client-architecture.md](docs/client-architecture.md)** —
  "Client architecture". There used to be no such place, and client-side things
  settled wherever they were written: `data-model.md` ("Schema and visibility
  rule") described routing a push tap — which widget catches it, what happens
  on a cold start, why the provider isn't autoDispose — i.e. exactly what
  doesn't depend on the schema and could change entirely while the schema
  stays the same. The client half of presence ("typing…") and mute as a feed
  filter moved there too. In `data-model.md` pointers were left in their place,
  and the visibility rule itself stays where it belongs.

  **The living reference moved out of a historical document.**
  `implementation-plan.md` is declared historical in its very first line, yet
  held a section "Default technical decisions" with the note "deviations should
  be recorded here" — i.e. it promised currency where, by definition, there is
  none. The list (Riverpod, go_router, the Flutter 3.32.8 pin, the Supabase key
  format) moved to `client-architecture.md`.

  **Indexes reconciled.** The README and the table in CLAUDE.md/AGENTS.md list
  one and the same set and split it into living and historical;
  `future-development.archive.md` wasn't listed in them at all before, even
  though it was in the repository. The line "step-by-step MVP plan, CI/deploy"
  no longer lies: CI and deploy are described in `operations.md`, and the plan
  only tells how things went.

  **Style.** Every file now has the same header: a title, a paragraph "what
  this is and what it is not", and for historical ones **This document is
  historical.** as the first sentence (the archive of deferred items used a
  blockquote; now it's like everyone else). Living documents in `docs/` wrap at
  80 characters — `future-development.md` was the only one inconsistent with
  itself: header wrapped, body not. The rewrap was checked word by word; the
  text didn't change. Historical files were left as they are: they aren't
  supposed to be edited, and rewrapping lines in them would flood `git blame`
  with noise for the sake of cosmetics.

  Two outdated statements were fixed along the way: the README promised
  "media in messages" among deferred features (done in 0.17.3), and `docs/` was
  described as "DB schema, operations, plans".

- Fixed duplicated messages in rooms (0.17.6) — on a weak network
  `sendMessage()` sometimes sent the same message twice: `.timeout()` in Dart
  doesn't cancel the request itself, it just stops waiting for it, so the
  original insert sometimes still reached the server after the client had
  shown an error. The draft isn't cleared on error, and a repeated "send" tap
  used to mint a new `client_token` — the unique index on
  `(author_id, client_token)` didn't fire, and two different rows with the same
  text ended up in the DB. The token is now minted once per draft and reused
  as long as the text/attachments haven't changed: resending the same draft
  either creates the message once, or — if the previous attempt already got
  through — gets the same row back via the already existing `23505` handling
  in `RoomsRepository.sendMessage`.

- First iOS build and a custom icon instead of the default Flutter one
  (0.18.0) — the app was built and uploaded to TestFlight for the first time.
  `app/ios/Podfile` pins `platform :ios, '15.0'` (required by
  `firebase_core`), `IPHONEOS_DEPLOYMENT_TARGET` in `Runner.xcodeproj` was
  raised from 12.0 to 15.0 in all build configurations. `ExportOptions.plist`
  and `DEVELOPMENT_TEAM` in `project.pbxproj` use the same Apple Team ID;
  `Runner.entitlements` declares `aps-environment: development` — Xcode
  rewrites it to `production` itself when archiving for the App Store (see
  `docs/ios-deployment-guide.md`). `Info.plist` gained
  `NSPhotoLibraryUsageDescription`, `UIBackgroundModes: remote-notification` and
  `ITSAppUsesNonExemptEncryption: false` for push notifications via APNs (see
  `docs/ios-push-apns-setup.md`). The new `make build-ios` is a compile check
  without signing (`--no-codesign`), not for a real release. A custom icon
  (instead of the default Flutter one) was added both for iOS
  (`AppIcon.appiconset`, all 15 sizes without an alpha channel — otherwise the
  App Store rejects the 1024×1024 marketing icon) and for Android (`mipmap-*`).
  `app/pubspec.yaml` version — `0.18.0+51`.

- Section headers on the "Settings" screen (0.18.1) — "Notifications" and
  "Account" are set apart from the rows by a muted caption style
  (`titleSmall`, `onSurfaceVariant`, `letterSpacing: 0.1`, uppercase)
  instead of visually blending in with ordinary list items. Along the way,
  `SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)` in
  `main.dart` — Android 15+/`targetSdk 36` requires edge-to-edge explicitly,
  otherwise `MediaQuery.viewInsets.bottom` may not arrive on some
  devices. `app/pubspec.yaml` version — `0.18.1+52`.

- The Android icon switched to an adaptive icon (0.18.2) —
  `mipmap-anydpi-v26/ic_launcher.xml` composites separate
  foreground/background/monochrome layers instead of one flat PNG per
  density; the foreground fills 61% of the canvas (66/108 safe zone) —
  not 88% as on iOS: different Android launchers crop content that
  sticks out past the safe zone differently, which was confirmed on a Honor.
  Minimum supported Android version — 10 (`minSdk 29`).
  `app/pubspec.yaml` version — `0.18.3+54`.

- Android push-notification icon instead of a solid circle (0.18.4) —
  for background/terminated display FCM took the launcher's `android:icon`,
  which since 0.18.2 is a full-color adaptive icon, while the status bar
  draws only the alpha channel of the small icon; since the launcher
  background is fully opaque, the silhouette collapsed into a filled circle.
  Added `ic_stat_notify` (`drawable-*dpi`) — cut from the monochrome layer of
  the adaptive icon, but with smaller margins (~6% versus the launcher's ~40%
  safe zone), otherwise at 24dp the glyph reads as a dot; `AndroidManifest.xml`
  points to it via
  `com.google.firebase.messaging.default_notification_icon`. Verified
  on a physical device via `notification_outbox`/`send-push`.
  `app/pubspec.yaml` version — `0.18.4+55`.

- Thirteenth full audit (0.18.6) — seven findings, five server-side and two
  client-side. Migration `20260905100000_close_thirteenth_audit_findings.sql`.

  **A roommate could read the entire profile gallery.** The SELECT policy on
  the `avatars/` prefix since 20260826180000 contained a
  `shares_room_with_caller(...)` branch, so that a roommate wouldn't see an
  empty circle in the member list. The branch turned out PREFIX-based — it
  answered "yes" for any object under `avatars/<uid>/`, and that's where the
  whole gallery lives, up to 80 photos. RLS on `profile_photos` meanwhile
  doesn't let a roommate in at all, i.e. the rows were hidden but the bytes
  weren't: `storage.list('avatars/<uid>')` goes through the same policy and
  listed them all. Exactly the same mistake — prefix instead of object —
  20260826190000 had already fixed for `posts/`; for `avatars/` it went
  unnoticed until rooms, because before them both remaining branches (own and
  Connection) were equivalent to the prefix anyway. The branch was replaced
  with `is_room_peer_avatar(path)`: a roommate sees exactly one object — the
  current `users.avatar_path`. Reproduced and verified by an RLS simulation via
  the Management API on the fixture "the owner put together a room from two of
  their connections who aren't connected to each other": before the fix the
  roommate saw 0 gallery rows and 4 objects, after — 0 rows and 1 object
  (exactly the avatar); for a Connection and for the gallery owner themselves
  the control 4/4 didn't change.

  **A dead grant exposed `/rpc/set_post_media`.** The third finding of this
  class in a row (after `is_author_visible()` and `is_favorited_by()`) and the
  most costly: `set_post_media()` doesn't check "neither text nor media" and
  can't — it sees only media — so a call with empty `items` on one's own post
  without a caption left an empty post alive in the feed of all connections
  until the next `purge_empty_posts()`. The grant was kept for build 41, but
  the condition "when `min(app_build)` passes 42" was met from the other side:
  20260828100000 switched off the feed and posting for all builds 46 and
  below. The client doesn't call the function — `updatePost()` goes through
  `update_post_with_media()`, which calls it from inside `security definer`,
  where the grant isn't needed. The grant was revoked, the function stays. The
  `purge-empty-posts` cron stays: a direct INSERT into `posts` hasn't gone
  anywhere.

  **A retry that narrowed the audience didn't withdraw already queued
  pushes.** `enqueue_post_notifications()` is AFTER INSERT, while the
  `on conflict` branch in `create_post_with_media()` is an UPDATE. A post "to
  all connections" that committed after `.timeout()` had stopped waiting for
  it managed to fan out `new_post`; the composer stayed open with a live
  token, and the next tap — now with "favorites only" — changed the column
  without touching the queue. The push "Petya has a new post" reached someone
  who won't be shown the post. Now such a retry deletes from
  `notification_outbox` the not-yet-sent `new_post` entries about this post
  for everyone who isn't in the author's favorites. Already sent ones aren't
  touched (a push can't be recalled), `digest` isn't touched at all (it
  doesn't name the post, it counts them), and widening back doesn't send the
  missing pushes. Verified by simulation: after posting, `new_post` sits with
  both subscribers; after a narrowing retry it stays with the one in the
  author's favorites and disappears for the other.

  **Four room RPCs were an existence oracle.** `rename_room()`,
  `add_room_member()`, `remove_room_member()` and `set_room_avatar()` answered
  `PT404` for a nonexistent room and `PT403` for someone else's, and
  `security definer` carries the question past RLS — by brute-forcing uuids,
  the response code told a live room apart from a made-up one. The project
  closes such oracles everywhere and states the rule out loud ("'not mine' and
  'doesn't exist' must be indistinguishable" — `delete_own_comment()`,
  `set_post_media()`, `delete_own_room_message()`); these four were the only
  exception. Both checks were collapsed into one on
  `room_owner_id(...) is distinct from auth.uid()` — the NULL from a
  nonexistent room falls into the same branch. The form matters:
  `set_room_avatar()` asked about ownership via `not owns_room(...)`, and there
  NULL yields NULL and the branch doesn't fire at all — it only worked because
  the existence check stood above it. Verified by simulation: for all four, the
  error codes and texts for someone else's live room and for a made-up uuid now
  match byte for byte. The client wasn't affected: it never parsed `PT403`
  from these RPCs anywhere.

  **The redundant column-level grant `select (visibility)` on `posts`** was
  revoked: SELECT on the table is granted in full (`relacl` =
  `authenticated=rdm`), and a table privilege also covers columns added later.
  There was no harm, but the comment next to it asserted the opposite rule.
  Verified before applying by a simulation with rollback: the column's `attacl`
  becomes NULL, `has_column_privilege` stays `true`.

  **A null in the embedded `users` crashed the whole request list.**
  `ConnectionRequest.fromRow` cast the embed to a non-nullable `Map`, but what
  makes the request readable is not the request itself but a shared room: as
  soon as one side leaves the room, PostgREST returns `null`, the cast throws
  `_TypeError` from `fetchRequests()`, the provider goes into error, and both
  screens read it as `.value ?? const []`. Incoming requests disappeared from
  the "Connections" tab for good — the row that causes it never goes away by
  itself. `otherName`/`otherAvatarPath` became nullable, and the row stays in
  the list under `connectionRequestUnknownName` in both ARBs. It stays rather
  than being dropped: the sender's copy is what keeps the "ask to connect"
  button from coming back in the direction that `connection_requests_pair_key`
  won't accept a second time, and the recipient can still respond to such a
  request (`respond_to_connection_request()` doesn't require a shared room).
  The new `connections_repository_test.dart` covers both sides.

  **`ref` after `await` before the `mounted` check** — seven places.
  `WidgetRef` lives on a `BuildContext` and after unmounting it **throws**
  (`StateError`), in release too. The throw was caught by the method's own
  `catch`, which exited on `!mounted` — and the refresh silently didn't happen:
  the feed, rooms and connections tabs live in the shell's `IndexedStack`, stay
  mounted and showed the state from before the tap, offering an action the
  server had already performed. Moving `mounted` higher isn't a cure; it just
  swaps a swallowed throw for a deliberately skipped refresh. Added
  `lib/shared/refresh_after_await.dart` (a wrapper over
  `ProviderScope.containerOf(context, listen: false)`); the container is
  captured BEFORE the `await` and outlives the screen; the rule is described
  once there and in `docs/client-architecture.md`.

  Along the way, the header of `20260828140000_connection_requests.sql` was
  fixed: it claimed "one request per pair for all time" and referred to "a
  second, symmetric index below", which doesn't exist and mustn't — it would
  forbid the reverse direction, legitimate per the same paragraph. Only the
  comment text was edited; the migration's DDL didn't change;
  `docs/data-model.md` already described this discrepancy and was brought in
  line.

- Documentation checked against the code (0.18.6) — not a feature but a second
  cleanup after 0.17.5. That one brought the files to a single shape; this one
  checked that what's written in them is still true.

  **Four outdated statements, all about the same change.** After
  20260829130000 mute stopped being an RLS rule, yet the README kept promising
  that "posts and comments from a blocked or muted person are hidden regardless
  of client version" — i.e. it called a privacy boundary something that had
  stopped being one; the App Store listing draft promised exactly the same to
  future readers in the store. Both were rewritten: blocking is a boundary,
  mute is a personal feed setting. Three places in `data-model.md` that the
  edits hadn't caught up with went into the same bucket: `post_media`
  visibility was described as a join to `visible_author_ids()` (it hasn't had
  its own copy of the rule since 20260826180000), `profile_photos` visibility
  as "the same rule as for the avatar in Storage" (since 20260905100000 they
  diverge on the roommate branch), and `shares_room_with_caller()` was listed
  directly in the storage policy, although it now sits there via
  `is_room_peer_avatar()`. Plus, the scenario of the old hole with
  `dislikes_disabled` was written in the present tense and relied on mute,
  which can't be used that way today.

  **The App Store listing draft promised a nonexistent feature.** Twice —
  "connect through invite links or QR codes" and "a QR code at an in-person
  meeting" — although `qr_code` in `connections.method` is groundwork, not a
  path: not a single live row came through the app with it. Along the way, the
  listing gained what appeared after it was written (connection requests,
  media and "typing…" in rooms), and the character counts were recalculated —
  all three were off even before the edits. "Notes" records when and against
  what the copy was checked.

  **Links pointed to the wrong file.** Six links in `docs/` referred to "the
  'Working conventions' section" and "'Pitfalls'" in `CLAUDE.md` — a six-line
  file that has neither: the content has long been in `AGENTS.md`. They were
  repointed to it. Thirty such links in migration comments were left as is —
  that's a journal, not a living document; instead of editing them, a
  paragraph was added to `CLAUDE.md` that resolves this reference once and for
  all.

  **A rule referred to by name was written down nowhere.**
  `deleteRowsThenObjects` appeared in `data-model.md` three times as something
  everyone knows, but no document explained it. It's client-side, so it moved
  to `client-architecture.md` as a separate section ("Rows first, then
  objects"), together with why the object half is best-effort and why all
  seven places go through a single helper.

  **The indexes drifted from the repository again** — `docs/review/` was listed
  neither in the README nor in the `AGENTS.md` table, just like
  `future-development.archive.md` before 0.17.5. Added to both.

  **Pitfalls gained four entries** following the thirteenth audit: a prefix
  branch in a storage policy stops being equivalent to the per-row rule as
  soon as it gets a narrower audience; `if not f(...)` with a NULL return
  doesn't fire at all; an idempotent retry is an UPDATE, and `AFTER INSERT`
  triggers don't repeat on it; Riverpod's `ref` after `await` throws in release
  too.

  **Style.** `ios-push-apns-setup.md` had no intro paragraph "what this is and
  what it is not" — the only living document without one. The "Ideas for
  later" heading in `future-development.md` was a broken 94-character
  sentence; in the same file, a cut-off phrase in the item about importing
  from social networks was fixed, along with two links written in a different
  format from the rest of the file. 80-character wrapping was restored
  everywhere it had drifted (one line remains — a bare URL that can't be
  wrapped). No new files were created: everything found went into existing
  ones.

  **The published privacy policy promised too much** (found while merging the
  branch where it appeared). "Who you've muted, blocked or favorited is never
  shown to anyone else — including the person concerned" is true for mute and
  block, but not for favorites: ever since favorites became a post audience,
  `authors_who_favorited_me()` has been granted to `authenticated` and must be
  — without it the `posts` SELECT policy refuses the reader on every row — and
  it lists everyone who added the caller. The invariant in `data-model.md` was
  already phrased correctly ("someone else's favorites list is closed; one's
  own 'who added me' is open to its owner"); the policy wording was brought in
  line with it.

  **The Terms of Use promised an action the app doesn't have** — "you can
  always end a connection or leave a room to stop seeing someone's content".
  You can leave a room, but a Connection can't be ended by any means:
  `authenticated` has neither a DELETE grant nor a policy on `connections`, no
  such RPC exists, there isn't a single mention in `app/lib`, and the very
  question "is such an ability needed" is still open in
  future-development.md. The wording was replaced with what the app can really
  do: block, mute, leave a room. The spot isn't cosmetic — this is exactly the
  paragraph store reviewers read when checking that the declared anti-abuse
  tools exist.

  Three more clarifications in the privacy policy, all about things left
  unsaid: the gallery is visible to Connections, while a roommate sees only the
  current avatar (after 20260905100000); the read marker was described as
  "read/delivered markers for your own messages", although what's collected is
  the OTHER one — it's your marker, by which the other members see whether
  their message has reached you; along with the push token, the interface
  language (`device_tokens.locale`) is stored too, which is used to pick the
  notification language. The "Last updated" date in both documents was moved
  — their own "Changes to this policy" section requires it.

  **The rights holder's name differed in three places** — "Timofei Rusakov" on
  the published privacy policy and terms of use, "Andre Roussakoff" in the App
  Store listing draft, there with the note "confirm the name". It's "Timofei
  Rusakov" everywhere, and the draft has a reminder next to it to keep the
  three places in agreement.

  **`docs/gh-pages/` wasn't listed in any index** — it arrived with the same
  branch. Added to the README and to the AGENTS.md table, with a note that the
  source should be edited, not the `gh-pages` branch: CI rewrites it on push to
  `main`.

  **`ios-push-apns-setup.md` claimed the APNs key hadn't been uploaded yet.**
  It has — iOS pushes work; this wasn't visible from the repository, and the
  document remained written as "what's left to do". Now it starts with "This is
  done" and is kept for two things: checking that the key is in place, and
  redoing the upload if it ever disappears (revocation, someone else deleting
  it from Firebase, a new project). There are two checks — in the Firebase
  Console and, when you can't get there, from the database side:
  enqueue a single notification to yourself in `notification_outbox` and read
  the Edge Function response that `pg_net` puts into `net._http_response`
  (`{"processed":1,"sent":0}` on an account with only an iPhone — the
  signature of a missing key). It also records what proves NOTHING: a row in
  `device_tokens` (registration succeeds even without the key — that's what
  makes this breakage silent), `sent_at` on the queue row (`send-push` stamps
  everything it picked up, regardless of the FCM response) and a silent
  simulator (it doesn't receive pushes at all).

- GitHub Pages moved into the repository, and CI deploys them (0.18.6) —
  not done in this branch: it came in via a merge and **shipped to `main` as
  0.18.5**, which didn't get its own entry here. Recorded under 0.18.6 so the
  history doesn't lose a piece; the version it shipped in is named here
  explicitly.

  The privacy policy, terms of use and both auth-flow pages (email
  confirmation, password reset) previously lived only in the orphan `gh-pages`
  branch and were edited right there — i.e. they went through neither review
  nor history next to the code they describe. Now their source lives in
  `docs/gh-pages/`, and `.github/workflows/sync-gh-pages.yml` copies it into
  the branch on push to `main` and commits only on an actual change
  (`email-confirmed.html` is placed as `index.html` — `site_url` in
  `supabase/config.toml` is configured for it).
  Edit the source: CI will overwrite the branch.

  `CLAUDE.md` switched to `@AGENTS.md` there as well — that's import syntax; it
  loads the file into context rather than referring the reader to it.

- Day separators and replying to a specific message in chat (0.18.7) —
  two items from future-development.md closed.

  Separators are a purely client-side feature: `room_chat_screen.dart` rebuilds
  the item list from the already loaded messages on every `build()` (rather
  than keeping separate state), inserting a day label wherever two adjacent
  messages fall on different calendar days in the viewer's local time zone.
  Recomputing from scratch, rather than patching the existing list, is the only
  way not to introduce a duplicate or missing label at a page boundary: the
  message list changes in three different places (`_loadMore()` appends to the
  end, realtime inserts at the start, `_delete()` edits in place), and keeping
  a second synchronized structure for each of them would be the source of
  exactly the desync the separators are supposed to prevent. Values
  "Today"/"Yesterday" for recent days, a full date for the rest.

  Replying to a message — `room_messages.reply_to_id`, a nullable
  self-reference (`on delete set null`, migration
  `20260911100000_room_message_replies.sql`). Along the way we stepped on two
  pitfalls, both now in AGENTS.md:

  1. **The INSERT policy broke sending ANY message in prod**, not just
     replies. The check "`reply_to_id` is from the same room" was written as a
     bare `EXISTS (SELECT 1 FROM room_messages …)` right in the policy — a
     subquery on the table inside its own policy compiled into a loop
     (`42P17 infinite recursion detected in policy`), and the RLS planner
     builds the subquery's plan at the level of the whole query, regardless of
     what's in a particular row's `reply_to_id`. Fixed with the same technique
     as `is_comment_visible()`/`my_room_ids()`: the check was moved into a
     `security definer` function `room_message_in_room()`, inside which RLS
     doesn't apply at all. The hotfix was applied to the live project within a
     few minutes of the breakage — "Subquery on its own table" in AGENTS.md.
  2. **PostgREST didn't resolve a self-referencing FK embed via the usual
     syntax.** Both `room_messages!reply_to_id` and
     `room_messages!room_messages_reply_to_id_fkey` either didn't find the
     relationship (`PGRST200`) or resolved it in the opposite direction —
     every message got `reply_to: []` (who replied TO it, rather than what IT
     replied to). PostgREST documents self-reference via
     `alias:fk_column(...)` — the column as the embed target name, without the
     table name and without a `!` hint: `reply_to:reply_to_id(...)`; this is
     the only variant that resolves to-one and in the right direction.

  The feature itself: a swipe/long-press on a message opens a sheet with
  "Reply" (except on placeholders) and "Delete" (only your own, live ones) —
  previously `onLongPress` called delete directly; now there are two different
  actions under it. The composer shows a "Replying to: Name" preview + a
  snippet with a cancel button; the sent bubble has a quote (author + snippet),
  and tapping it scrolls to and highlights the original for a second. Scrolling
  to an arbitrary, possibly not yet loaded message is a problem with no
  solution via a regular `ListView.builder` (most items aren't physically
  built), so the list was switched to `ScrollablePositionedList` (the
  `scrollable_positioned_list` package) — following the example of
  `reorderables`, already accepted in the project: a targeted dependency for
  one specific UI task, not a general replacement of the screen's architecture.
  `RoomMessage.replyToPreview` is populated only for messages read via
  `fetchMessages`/`sendMessage` (the embed arrives with the row); for a
  message that arrived via realtime, Postgres Changes delivers only the raw
  `reply_to_id` column without a join — the screen looks up the original in
  the already loaded list itself, and if it doesn't find it (the page with it
  isn't loaded yet), it draws "original unavailable" instead of crashing.

  Verified: by an RLS simulation via the Management API (`set local role
  authenticated` + `request.jwt.claims`, in a transaction with `rollback`) —
  replying to a message from your own room is allowed; replying to a message
  from someone else's room and to a nonexistent id is rejected; the hotfix was
  re-verified separately as well (regular sending works again). Then manually
  on a physical device with two live accounts: date separators, the full reply
  cycle (pick a message → preview → send → quote in the bubble → tap the
  quote → scroll and highlight), realtime delivery of the reply to the other
  side.


- Platform and OS version of an install (0.18.8) — `device_tokens` learned to
  tell what an install runs on, not just which app version it reports itself
  as. Migration
  `20260912100000_device_platform_and_os.sql`, the client half —
  `shared/device_os.dart`, paired with the already existing
  `shared/app_version.dart`.

  The question came up from the local console (its first screen showed a
  breakdown by build): devices reported an `app_build` **one higher** than
  what's in `pubspec.yaml`, twice in a row — 0.18.6 as `+59` with `+58` in the
  repository and 0.18.7 as `+60` with `+59`. There was no way to localize this
  by platform: nothing in the token row distinguishes iOS from Android. For the
  same reason a targeted send "to everyone on iOS" was impossible too, and that
  is the nearest use for these columns.

  `platform` is an enumeration (`android`, `ios`, `macos`, `windows`, `linux`,
  `fuchsia`, `web`), exactly what `Platform.operatingSystem` can return, plus
  `web` for the deferred web version. It can't be free text: it's the key
  audiences are built by, and "iOS"/"ios"/"iPhone" in one column turn any
  `group by` into a lie.

  `os_version` — digits and dots only (`18.1`, `15`). The platform answers with
  a sentence, and each its own: iOS — `Version 18.1 (Build 22B83)`, Android —
  `Android 15 (API 35)`. Storing that verbatim would mean shifting the parsing
  onto every reader forever, and the build identifier inside is closer to a
  device fingerprint than to anything useful. The client extracts the first
  group of digits-and-dots, no more than three parts; `15.1.2.3` goes out as
  `15.1.2`.

  Both columns are nullable, and both CHECKs let NULL through — for the same
  reason as with `app_build`: the row is written by a background upsert on
  every launch, and a constraint rejection would break the push token
  registration ITSELF, silently and along with all notifications.
  Normalization lives on the client for exactly that reason, not because the
  server is lazy. Released versions don't know about the new columns, so until
  they update, all 14 live installs have NULL there — that's the expected
  state, not lost data.

  The INSERT grant on `device_tokens` is **column-level** (`grant insert
  (app_build, app_version, fcm_token, locale, user_id)` from the baseline), so
  the new columns had to be listed explicitly: without that, an upsert with
  them would fail on permissions — again silently and again together with
  token registration.

  Verified by a simulation as `authenticated`, not by eye: an insert with
  `('ios', '18.1')` passes, `'iPhone'` and the raw `Version 18.1 (Build 22B83)`
  are rejected by their CHECKs, a pair of NULLs passes. Plus eight unit tests
  on parsing real responses from both platforms
  (`test/shared/device_os_test.dart`), including that from
  `Android 15 (API 35), SDK 35` the release is taken, not the API number.

- Content reports and moderation (0.18.8) — closes the "Full moderation and
  reports" item in future-development.md and the App Store 1.2 requirement for
  apps with user-generated content. Migration
  `20260913100000_content_reports_and_moderation.sql`, a "Report" button on a
  post, a comment, a room message and a connection's profile, and the review
  queue in the local console (`console/`).

  Blocking a connection, which existed before, was never moderation and was
  never meant to be: it is a personal boundary between two people, and the app
  owner never learns about it at all.

  **Hiding is reversible and the same for everyone, the author included.**
  The half-measure "the author still sees their own post" would mean two
  answers to the question "is this object visible", i.e. the end of the
  visibility rule as a single rule. The author learns about the hiding from a
  notification, not from a hole in their wall. The condition went into
  `is_post_visible()`, and from there it propagated on its own to the comments
  under the post and to the media storage policy. Message media needed a
  separate fix: its branch in the storage policy was prefix-based ("an object
  in my room's folder") and knew nothing about the messages themselves — a
  hidden message would disappear from the chat while its photos stayed
  reachable by direct link. Same class as the room-neighbours' avatars finding,
  and fixed with the same technique.

  **The write ban is enforced by a trigger, not an INSERT policy, and this is
  the key decision of the whole task.** All nineteen writing RPCs in the
  project are `security definer`, granted to `authenticated`, and
  `force row level security` is enabled nowhere: inside such a function RLS
  does not apply at all. A "banned" condition in the `posts` policy would stop
  no one, because posts are created via `create_post_with_media()`. A trigger
  hangs on the table, not on the role, so one body covers both the direct
  insert and the RPC. Verified by simulating both paths: a banned user gets
  `AMB01` on both, and a non-banned one publishes as usual. The client tells a
  ban apart from a policy rejection by its SQLSTATE and shows the end date from
  DETAIL, instead of offering to retry.

  Three things on which this migration nearly broke production, worth
  remembering:

  1. **42P17.** The first draft added a subquery on `posts` to the post-edit
     policy — inside a policy on `posts` itself. That breaks every post
     update, exactly as in 20260911100000. The check turned out to be
     unnecessary: UPDATE on `posts` is granted per column and only on `text`,
     so the boundary is held by the grant, not the policy.
  2. **A lost notification kind.** The CHECK on `notification_outbox` is
     recreated via `drop`+`add`, and the list assembled from reading the
     migrations did not contain `connection_accepted` — notifications about an
     accepted request would silently have stopped arriving. The list is taken
     from `pg_constraint` of the live database, and in no other way.
  3. **Default grants.** A new table arrives with full privileges for
     `authenticated`, and a new function with `execute`, i.e. it becomes a
     PostgREST endpoint by itself. Hence `revoke all` on the table and explicit
     `revoke execute` on all new functions except the `can_report()`
     dispatcher: it alone is visible from outside. `is_post_visible()` can't be
     called directly from the policy — the policy expression runs as the
     caller, who has no grant, and the very first report would bounce with
     42501.

  Side effect: the menu on a post card now exists on every post, not only on
  one's own (on someone else's it holds "Report"), and it had to be shrunk to
  32×32 — the default 48px tap target added ~28px of height to every feed card.
  This was caught by the pagination test, which, with the increased height,
  started parking the scroll at the very bottom.

- It is now visible why pushes don't reach a person (0.18.8) — migration
  `20260913120000_push_registration_status.sql` plus recording the outcome in
  `registerDevice()`.

  The question was: some people are definitely using a version that collects
  the token, yet they are not in `device_tokens`. There was nothing to answer
  with, and this turned out to be a defect, not a gap in the data. Registration
  DEFINITELY runs for them — `pushRegistrationProvider` is watched in
  `MainShellScreen` on the line next to `userActivityProvider`, so a row in
  `user_activity` proves the shell was rendered — but `registerDevice()` has
  three exits that write no row, and all three are silent: permission denied,
  `getToken()` returned null, and a failed upsert. The third is the worst: the
  exception went into a `FutureProvider` whose state nobody reads, so OUR OWN
  failure was indistinguishable from the outside from an honest refusal by the
  user.

  Along the way it turned out the numbers lied too: `sent_at` in
  `notification_outbox` means "the row was processed", not "the push was
  delivered". Every claimed row is stamped, even when the recipient has no
  devices at all — 38 of 153 rows were marked as sent into the void. So "9
  pushes were sent to him" proved nothing about having a token.

  Now the client writes the outcome (`granted`/`denied`/`no_token`/`error`,
  with an error code for the last one) as one row per person, upserted on
  every launch. The platform and version columns duplicate `device_tokens` on
  purpose: there they appear only after a successful registration, i.e. for
  the people about whom everything is already clear. In the console this is a
  separate "why pushes don't arrive" breakdown and a badge in the people list.

  A pitfall for the future, moved into AGENTS.md: `ON CONFLICT DO UPDATE`
  requires not only INSERT and UPDATE but also **SELECT on the table** — it
  reads the row it collided with in order to apply the policy's `using`
  expression, and a per-column grant on exactly the column in the expression is
  not enough for it. A plain `insert` passes, so the mismatch is caught only by
  an upsert.

- The OS version is read via `device_info_plus` (0.18.8) — and two bugs that
  were found only by building onto a live phone.

  **First: recording the registration status silently didn't work.** The UPDATE
  grant in 20260913120000 was issued per column and without `user_id` — on the
  reasoning that "there's no reason to change the row's key". The reasoning is
  right, the conclusion is not: PostgREST expands `upsert` into
  `ON CONFLICT DO UPDATE SET` over ALL the columns sent, including the conflict
  column, i.e. it always writes `user_id = excluded.user_id`. Without the
  privilege on that column the whole upsert bounced with 42501. The simulation
  didn't catch this because the `SET` in it was written by hand — and, of
  course, without `user_id`. The general lesson is broader than this case and
  has been moved into AGENTS.md: test the query shape that the client actually
  sends. Fixed by migration `20260913130000`; there is no hole,
  `with check (user_id = auth.uid())` is in place.

  **Second: the OS version was made up.** `Platform.operatingSystemVersion`
  from `dart:io` on Android returns the build identifier, not the system
  version: on the A059 it is `B4.1-260810-1153` while the real version is
  Android 16. Parsing "the first number in the string" wrote `260810` to the
  database — a value that means nothing and looks like a version. The test that
  was supposed to cover this checked a string I had made up,
  `Android 15 (API 35)`, and was green precisely because of that.

  The source is now `device_info_plus` (`Build.VERSION.RELEASE` and
  `systemVersion`), parsing is anchored to the start of the string, and the
  tests now hold real device responses, including that very build id — with a
  check that no version is derived from it. Verified on the phone: both tables
  show `android 16`.

- Console: news-account editor and broadcasts (0.18.8) — the last two
  sections, after which no greyed-out items remain in its menu.

  **News.** A composer with a preview "as it will look in the feed", media with
  upload to the bucket and reordering, drafts, editing and deleting what has
  been published. The post is created by a direct insert, not via
  `create_post_with_media()`: that one takes the author from `auth.uid()`,
  while the console goes in as service_role without a JWT, and inside the
  function it is null. So all of its checks are repeated in the console — the
  20-media limit, the path prefix, "a post needs text or media", an empty
  string as absence of text. The video poster is captured in the browser via
  canvas: on the server it would need ffmpeg for the sake of a single image.

  Drafts live in a file next to the console, not in the database: the console
  is local and single-user, a draft is a personal note on this machine, and a
  table for it would require a migration, policies and grants for data that
  nobody else will ever read.

  The price paid for editing: a PATCH without a `media` field meant "there is
  no media anymore", because the set is rewritten wholesale (otherwise there's
  no way to assign `position`). It wiped a real news-account post twice before
  this became a 400 error demanding `media` as an explicit list. The post text
  was restored verbatim — it was found in the transcript of the very session
  that had published it.

  **Broadcasts.** The "a new version is out" notification: the default target
  comes from `app/pubspec.yaml`, the audience is computed in advance and shown
  by name with each person's own build, and separately — who will be filtered
  out by the repeat protection and who has turned off notifications from the
  system account. Sending is done by `enqueue_app_update_notifications()`; the
  console is only a form: this spot doesn't need a second implementation of
  the selection, the list shown is its mirror, and next to it is printed how
  many rows the function actually created.

- Local app-management console (0.18.8) — a new subproject `console/` (React +
  Vite + TypeScript). Before it, everything that can't be done from the app
  itself was done with queries through the Management API: seeing who is on
  which version, sending out "please update", publishing a post from the news
  account. Reports didn't exist at all.

  **It runs only locally, and that is part of the design, not a convenience.**
  The console uses the service_role key, i.e. bypasses RLS entirely, so both
  the API and Vite listen on `127.0.0.1`, and the key lives in `console/.env`
  and never reaches the browser: the page talks only to the local `/api`, and
  from there Node talks to Supabase. This is also why a tool that only read
  data in its first stage has a server half.

  Hosting it and adding a moderator role in the DB were deliberately
  rejected: the person with the service_role key is the entire authorization,
  and a second copy of it as a flag on `users` would pretend things could be
  otherwise. For the same reason there is not a single moderator RPC in the
  schema — every function in `public` is a PostgREST endpoint, and the only
  consumer, which bypasses RLS anyway, doesn't need it.

  The first stage is "Overview" (database totals, sign-ups and posts over 30
  days, breakdown by version and platform, push-token age, the notification
  queue) and "Users" (search, sorting, a person's card with devices and
  settings). Breakdowns are computed in memory, not with SQL views: at pilot
  volume that's cheaper and doesn't drag migrations along; a cap of 100,000
  rows per table is hard-coded explicitly and will be hit before it becomes
  untrue.

  How to run it and how it's built — in [console/README.md](console/README.md).

- Rooms: the chat stopped lying and lagging (0.18.10) — one batch of fixes for
  the complaint "online status and typing don't always show up, messages are a
  bit sluggish, sending a photo reloads the one above". All four symptoms
  turned out to have separate causes, and three of them are not about speed
  but about correctness.

  **The chat silently lost everything said while the app was in the
  background.** The heaviest of the findings. Postgres Changes is a stream,
  not a log: a subscriber receives what happened while it was subscribed. And
  the socket is dropped by `supabase_flutter` itself on `paused` and
  reconnected on `resumed`, so the disconnect happened on every app switch.
  There was nothing to backfill what was missed with: the screen only knew a
  `before` cursor, i.e. **older** pages, and an open chat stayed incomplete
  until it was closed and reopened. Deletions were lost the same way — a
  removal arrives as an edit of an already present row. Now, when the channel
  resubscribes (and on `resumed` as a safety net), a fresh page is re-read,
  and whether it can be stitched on is decided by its overlap with what's
  loaded: if there is overlap, new messages are appended and the rest are
  replaced in place; if not, the list restarts from that page, because a hole
  in the middle of a conversation is worse than a lost scroll position. The
  full design — "Realtime doesn't replay what was missed" in
  [docs/client-architecture.md](docs/client-architecture.md).

  **"Typing…" showed up only every other time, and the cause wasn't the
  network.** The channel buffers an announcement made before it came up and
  sends it on join — via a hook it registers in its own constructor, i.e.
  before the client callback. And the callback tracked a hard-coded
  `typing: false`. So "typing" raised during the join arrived first and was
  immediately overwritten, while the screen by then already considered the
  announcement made and didn't repeat it on any subsequent keystroke — the
  other person didn't see the indicator for the whole draft. The same thing
  repeated on every reconnect after the background. Now the announcement is
  asked from the screen on every join (only the screen knows what's in the
  input field), and a dropped channel yields two empty sets: presence is a
  statement about "right now", and a list left over from a channel that no
  longer exists is a lie that has outlived the only thing that made it true.

  **A photo in the chat flickered with a spinner and was re-signed on every
  incoming message.** The `media` bucket is private, links are signed by a
  request, and they were signed by the attachments widget itself in
  `initState`. The list, meanwhile, inserts a new message at index 0, all the
  indices below shift, and `ScrollablePositionedList` builds via a
  `SliverChildBuilderDelegate` to which the package doesn't let you pass
  `findChildIndexCallback` — the element in a slot simply gets the next
  message, the attachments key doesn't match, and the `State` is gone. Adding
  keys here would make it worse, so it's fixed at the root: the signed-URL
  cache (`lib/shared/signed_url_cache.dart`) answers **synchronously**, before
  the first frame, and `CachedNetworkImage` draws from its disk cache by the
  bucket path — no flicker, no request. In memory only and for the lifetime of
  the process, `clear()` on sign-out together with the feed cache: these are
  links to objects that RLS showed to **this** account.

  **One message cost three requests and a fan-out.** An incoming message
  triggered `mark_room_read()`, followed by a refetch of the whole room list:
  `my_rooms()` (a lateral for the last message, `count(*)` over unread and
  member aggregation for every room) plus `mark_rooms_delivered()`, which
  unconditionally rewrote **all** of the caller's `room_members` rows. The rows
  are published to realtime, so each rewritten one woke up all members of that
  room, whose screens did the same in response — and the more rooms people
  share, the more a single message cost. The client half: the room list is
  refreshed once on leaving the screen, not on every message (nobody is
  looking at it from inside the chat anyway). The server half — migration
  `20260923100000_delivered_marks_only_when_they_move.sql`: the delivery mark
  doesn't move where there is no live message from someone else newer than it
  — advancing it there is unobservable anyway. Control numbers on the live
  database: 16 rows per call before, 1 after, and that single one belongs to a
  person who really has something to be delivered.

  The rest from the same pass, smaller: the derived message list with day
  separators was rebuilt **on every scroll frame** (the positions notifier
  assigns a new list after every layout) — now it's computed once per change;
  `MediaQuery.of` in the bubble subscribed it to the whole `MediaQueryData`, so
  opening the keyboard rebuilt every bubble on screen (`sizeOf`); "is there
  more history" was read as "the page came back non-empty", i.e. after the last
  full page one extra request always went out (`page.length == limit`); a
  failed history load retried without stopping — the trigger fires on every
  frame, so the request was re-sent as soon as the previous one gave up, every
  12 seconds for as long as the chat was open (backoff added); read marks at
  screen start were replaced wholesale, wiping what the subscription had
  already brought — now they are merged by the later of the two.

  Deliberately not done: the list still jumps by a position or two when a
  message arrives while the person is reading history above.
  `ScrollablePositionedList` anchors by index, and compensating requires a
  `jumpTo` in a post-frame callback — which would kill scroll momentum if the
  message arrives mid-fling, because the package gives no way to know "a finger
  is on the screen right now". The cure is worse than the disease, and there's
  no way to verify it in tests.

- Deleting a profile photo on iPad + gallery polish (0.18.11) — deleting a
  profile photo on iPad had no effect: `ref.invalidate()`, guarded by a
  `mounted` check, silently skipped the refresh after navigation because of the
  iPadOS multi-window lifecycle. Fixed as a class, not in one spot — the
  provider container is captured via `refreshAfterAwait(context)` before the
  `await`, and invalidation happens unconditionally, on every affected screen.
  Also fixed while testing on the iPad simulator: the delete confirmation
  dialog no longer closes on the first stray tap outside (`barrierDismissible:
  false`); deleting a photo stays on the delete screen instead of returning to
  the profile — you can remove a batch of photos in one go; rows being dragged
  in reorder mode got a visible lift (shadow + highlight); the iOS launch
  screen changed its white background to lilac, and the icon from a fixed 180pt
  to 42% of the screen width/height (on iPad it was small and off-centre;
  follow-up — IMM-250).
- iPadOS: system window buttons no longer cover the top-left corner (0.18.11) —
  in the windowed (non-fullscreen) multitasking mode, iPadOS 26 draws its own
  "traffic light" window-control buttons over the app's top-left corner,
  covering, for example, the "back" button in settings (a known iPadOS 26
  regression, also seen in Obsidian and Firefox for iOS).
  There is no reliable public API to detect windowed/fullscreen mode, and it
  can change at any moment by dragging — per-screen spot insets are
  unreliable. Instead, `AppDelegate` once at launch reserves an extra 24pt at
  the top of the safe area on iPad, so the `AppBar` of any screen never slides
  under the system-button area regardless of window mode — the same technique
  other apps already use to work around it.
- Bottom navigation: equal spacing and larger icons on tablets (0.18.11)
  — the stock `NavigationBar` lays out an asymmetric icon row by design:
  it reserves space for a label even with
  `NavigationDestinationLabelBehavior.alwaysHide`, so the icons were never
  centred, however the outer paddings and safe area were tuned.
  The bar was rewritten from scratch (`_BottomBar`/`_BottomBarIcon` on `Row` +
  `Padding`), which gave full control over spacing: above and below the icon
  row there is the same padding (with a slight +8 skew at the top — by eye,
  this is what reads as "equal", checked on several renders); the bottom safe
  area (home indicator / iPad window frame) is reserved as a separate strip via
  `SafeArea(top: false)`, with no gap between the icons and that strip; icons
  on tablets are larger (38px vs 24–26px on a phone) by the breakpoint
  `MediaQuery.shortestSide >= 600`; the selected-item indicator is a
  fixed-size container with `Alignment.center`, so its icon is always centred
  regardless of the glyph's shape (the chat icon used to drift to the side).
  Verified live on the iPad Air 13" (M4) simulator, both fullscreen and in
  real windowed multitasking mode with the "traffic light" buttons visible.
- iOS: migrate to UIScene, fixes the launch crash on iOS 27 (0.18.11) —
  apps built against the iOS 27 SDK crash right after the launch screen
  if they haven't migrated to the UIKit UIScene lifecycle. Confirmed by crash
  logs from physical iPhone and iPad (both on iOS 27) and reproduced exactly on
  the iOS 27 simulator; a debug build on iOS 26.5 was unaffected — the crash
  turned out to be an iOS 27-specific regression.
  `Info.plist` got a `UIApplicationSceneManifest` pointing to a new
  `SceneDelegate`; `AppDelegate.swift` moved plugin registration into the new
  `didInitializeImplicitFlutterEngine` callback (per Flutter's migration
  guide) — responsibility for the window and the UI lifecycle moved to the
  scene; the new `SceneDelegate.swift` (a `FlutterSceneDelegate` subclass)
  inherited from there the top inset from IMM-170 for the iPad windowed mode,
  since it is tied to `window`, which now belongs to the scene;
  `ci_post_clone.sh` raised the Flutter pin for Xcode Cloud to 3.47.5 so that
  TestFlight builds get the same fix (3.38+ ships the UIScene API, 3.41+
  migrates an unmodified `AppDelegate` by itself); `.gitignore` now fully
  excludes local FVM files (`.fvm/`, `.fvmrc`) — the iOS build machine now uses
  a newer local Flutter via FVM, while the Android developer's machine is
  pinned to 3.32.8 by its macOS version and must not see a version hint not
  meant for it.
  Verified: the iOS 27 simulator (iPhone 17) launches without crashing and
  shows the sign-in screen; the iOS 26.5 simulator (iPad Air) still works,
  including the windowed inset from IMM-170; `make deps/format-check/analyze`
  are clean on the shared 3.32.8 toolchain (none of the changed files is a Dart
  file, so the shared toolchain changes nothing here). The
  `pubspec.lock`/`.yaml` files, Android CI and everything the Android developer
  works with are untouched.
- iOS: move Firebase from CocoaPods to Swift Package Manager, fixes the Xcode Cloud build (0.18.11) — `xcodebuild` in Xcode Cloud resolves dependencies via `-project Runner.xcodeproj` rather than via `-workspace Runner.xcworkspace` as it does locally; because of this, `Package.resolved` was missing at the path CI required, and the build failed at `ci_post_clone.sh` with an error — `firebase-ios-sdk` doesn't resolve. Flutter 3.47.5 (the same pin as for IMM-251), on `flutter build ios`, migrates `firebase_core`/`firebase_messaging` from CocoaPods to SPM by itself via `FlutterGeneratedPluginSwiftPackage` — reproduced locally via FVM, `Podfile.lock` lost its Firebase dependencies, `Runner.xcscheme` got a pre-build step `Prepare Flutter Framework Script`, `analysis_options.yaml` got auto-exclusions `build/**`/`android/**`/`ios/**`. The `Package.resolved` generated via `xcodebuild -resolvePackageDependencies -project Runner.xcodeproj -scheme Runner` (122 lines, the full graph of `firebase-ios-sdk@12.17.0` and its transitive dependencies) is committed at both paths — `Runner.xcodeproj/project.xcworkspace/.../Package.resolved` (the one Xcode Cloud actually reads) and `Runner.xcworkspace/.../Package.resolved` (for local work through the workspace). Along the way a `MinimumOSVersion` regression was found and fixed — during this same migration Flutter erases it from `AppFrameworkInfo.plist`, which can block upload to the App Store (known bug flutter/flutter#185039); the value `15.0` was restored, matching `IPHONEOS_DEPLOYMENT_TARGET`. `pubspec.lock` was rolled back to its pre-experiment state — the upgrade of 29 packages turned out to be a side effect of running a different Flutter version, not part of the fix, and it doesn't affect the Android developer's toolchain (3.32.8).
  Verified: the Xcode Cloud build on `develop` succeeded, and the app was tested on physical iPhone and iPad.
- Connections: the block icon is now unambiguously red (0.18.12, IMM-232) — the `Icons.block` icon on a blocked connection used `Theme.of(context).colorScheme.error`, a muted reddish-purple from the `ColorScheme.fromSeed` palette on the deep-purple seed colour, which made the "blocked" message read unclearly. Replaced with a fixed `Color(0xFFD32F2F)` (Material Red 700) — a saturated but not "neon" red, picked over several rounds of comparison on a real device (pure `#FF0000` turned out too bright and irritating).

- Text selection and copying, clickable links in the room chat
  (0.18.13) — closes two Linear tickets (IMM-248, IMM-249).

  Message text now lives in one shared `SelectionArea` for the whole list
  (not a `SelectableText` per bubble): this way a selection started in one
  message is correctly cleared by a tap anywhere else in the list — a
  standalone `SelectableText` has no way to know that a tap happened outside
  its own `RenderBox` at all. A long press on live text now selects it with
  the system handles, and the "Reply/Delete/Report" sheet moved from long press
  to a plain tap — otherwise the two gestures competed for the same text. The
  author, the time and the deleted-message placeholder are excluded from
  selection (`SelectionContainer.disabled`) — there's nothing to copy there.
  Date separators ("Today"/a date) are also excluded from selection, and the
  empty `onLongPress` interceptor on them exists for a separate reason:
  `disabled` doesn't stop `SelectionArea` from reacting to a long press within
  its bounds in principle — it only makes the result empty — so without the
  interceptor a long press on a separator still produced a haptic tick for
  nothing.

  Links use our own regex for `http(s)://`/`www.`, no third-party package:
  `_LinkifiedMessageText` splits the message text into plain and link chunks;
  a link chunk gets an underline/`colorScheme.primary` colour and a
  `TapGestureRecognizer` that opens `url_launcher` in the external browser.
  Recognizers are created anew on every rebuild and explicitly disposed in
  `dispose()` — per the class's own documentation, `TextSpan.recognizer` isn't
  managed by any of the obvious owners, but must be disposed by whoever created
  it.

  The least obvious part turned out to be a small thing: copying a selection
  spanning several messages glued their text together with no space and no line
  break — there isn't a single character between bubbles, only spacing in the
  layout. A literal `\n` inside the message text didn't work, for two reasons
  at once (see the new finding in AGENTS.md): an extra line inside `Text.rich`
  costs a full line height regardless of the `fontSize` of that particular
  `TextSpan`, and a `\n` as the very last character of the selectable text is
  silently trimmed on copy. The working combination is an invisible separator
  marker (zero-width space) at the end of each message's text, which costs
  nothing in height/width, plus a custom `contextMenuBuilder` on the
  `SelectionArea`: after the standard copy, the "Copy" button additionally
  reads `Clipboard.getData` and replaces the markers with real `\n`s before
  putting the text back. On a phone, copying happens by tapping the toolbar
  button (`SelectableRegionState._copy()`), not through `Actions`/`Intents` —
  an override of `CopySelectionTextIntent` doesn't intercept that button at
  all, only Ctrl+C/Cmd+C, so it was `contextMenuBuilder` that had to be
  changed.

  Verified: with unit and widget tests (`room_chat_screen_test.dart`, including
  a test that, the same way a real user does — drag-select plus a tap on "Copy"
  in the toolbar — checks that the clipboard ends up with a real line break
  between messages), then manually on a physical device over several rounds of
  fixes: selecting and copying text, links open in the external browser and
  don't get mixed up with the sheet gesture, date separators aren't copied and
  don't vibrate on long press.

- Fourteenth full audit (0.18.13 — the number was filled in at the bump before
  the PR: this pass deliberately didn't touch the version in
  `app/pubspec.yaml`).

  **The main finding — `revoke ... from anon, authenticated` doesn't remove a
  grant issued to PUBLIC.** `create function` in PostgreSQL by default grants
  EXECUTE to the PUBLIC role, and both `anon` and `authenticated` are members
  of it. So six functions that 20260913100000 considered closed were not
  closed, and four of them remained reachable through PostgREST. Verified not
  by reasoning but by a request with the app's public key and no session at
  all: `POST /rest/v1/rpc/is_write_banned {"p_user": "<uuid>"}` answered
  `HTTP 200` and `false`/`true` — i.e. the moderation decision about any account
  could be read by its uuid by anyone on the internet (the key is embedded in
  the APK and public by design). Along with it, `room_message_visible(uuid)`,
  `room_message_media_visible(text)` (the existence of an attachment in someone
  else's room by exact path) and `can_report(text, uuid)` answered. After
  20260924100000 all four answer 401/42501 — also verified with the same
  request.

  The same miss one level up also explains why it wasn't caught earlier: the
  baseline revokes default privileges on functions from `anon` and, in a
  comment, considers the matter settled, but the default is granted to PUBLIC,
  and that line didn't touch it — so EVERY function created after the baseline
  was published to the anonymous role unless it was closed with an explicit
  `public`. Now both defaults are revoked (`from public` and
  `from authenticated`), so a new function is closed by default and a
  forgotten `grant` breaks the feature loudly (42501) rather than quietly
  opening it.

  On the flip side of this same fix, all attachments in chats nearly got
  switched off: `room_message_media_visible()` sits in a SELECT policy on
  `storage.objects`, a policy expression runs as the calling role, and it
  worked solely thanks to the PUBLIC grant. Caught by a dry run of the
  migration in a transaction with `rollback` before applying it; the function
  was closed to the anonymous role and reopened to `authenticated`, like the
  neighbouring `post_media_path_visible()`. A general block was added to the
  migration's checks: every function from `pg_policies` expressions must have
  EXECUTE for `authenticated` — the list is taken by a query, so the next
  policy will fall under the check on its own.

  **The write ban now extends to editing.** `reject_write_when_banned` was
  attached as seven BEFORE INSERT triggers, i.e. a banned user couldn't create
  a new post but could rewrite the text of any of their old ones
  (`grant update (text)` on `posts`) and change their own name
  (`grant update (name)` on `users`) — via a direct PATCH through PostgREST.
  Added per-column `before update of text on posts` and
  `before update of name on users`; per-column not for speed, but so that the
  console can still hide a banned author's post (`hidden_at` isn't in the
  column list) and so that a banned user can still delete their own photo
  (deletion rewrites `avatar_path` via the gallery sync trigger). Along the way
  it was found that for `users` the row's author is its `id`, which wasn't in
  the `coalesce` chain at all: the trigger fired, didn't find the author and
  exited as "the server is writing". This was caught by a behavioural probe,
  not by reading the code — applying the migration and all of its checks
  passed.

  **`<>` with `auth.uid()` yields NULL, not true, when the server is
  writing.** The "not our business" branch in the same trigger was written as
  `v_author is null or v_author <> auth.uid()`, and for service_role
  `auth.uid()` is NULL, so the whole condition is NULL, the branch didn't fire,
  and the function went on to check the ban of the author of someone else's
  row. While the trigger was only on INSERT, it was saved by the fact that only
  one system account writes this way and it isn't banned; with the trigger on
  `posts.text` this would have broken editing a news post from the console.
  It's now `is distinct from`.

  **Reflected XSS on the published password-reset page.**
  `docs/gh-pages/reset-password.html` concatenated `error_description` from the
  link fragment into `innerHTML`, i.e.
  `#error_description=<img src=x onerror=…>` executed a foreign script on the
  domain where a new password is typed a second later. Verified in the browser
  both ways: the old code executed the payload, the new one renders it as
  text. The card is now built from nodes with `textContent`, a CSP was added
  (the most important parts of it are `connect-src` — the only address the
  page can send anything to — and `form-action 'none'`, which blocks the
  browser from submitting the form: without `preventDefault`, a form without
  `action` would have gone out as a GET request with the password in the query
  string, i.e. into the browser history and the logs), the double
  `decodeURIComponent` was removed (on `%ZZ` it threw a URIError and the page
  stayed on "Загрузка…" ("Loading…") forever), and `supabase-js` is pinned to
  an exact version with `integrity` instead of the floating `@2` tag — on this
  page a foreign script equals a password leak.

  **The local console is no longer reachable from browser tabs.** Loopback
  shuts out the network, but not the developer's browser: a foreign domain with
  an A record of `127.0.0.1` becomes, for the browser, the same origin as the
  console, no CORS comes into play, and a script on such a page reads the
  responses — while the console uses the service_role key and bypasses RLS.
  Added `server/local_only.ts` (a `Host`/`Origin`/`Sec-Fetch-Site` check before
  parsing the body) and the console's first tests ever — on `node --test` via
  the already present `tsx`, with no new runner in the dependencies. Fixed
  there as well: the penalty duration came from the form unvalidated,
  `Number("неделя")` made it all the way to `new Date(NaN).toISOString()` and
  turned into a 500 "Invalid time value", and a negative number silently
  assigned a ban that expired the same instant.

  Other: `pg_temp` is pinned last in `search_path` for all functions except two
  inlinable SQL functions that don't touch tables (`ALTER FUNCTION`, bodies
  untouched) — defence in depth, not a closed hole, because a temporary table
  can't be created through PostgREST; `reaction_summary()` went from VOLATILE
  to STABLE (it only reads); `actions/checkout` is pinned by SHA in
  `sync-gh-pages.yml` — the only workflow that didn't do so, and at the same
  time the only one with `contents: write`; `analysis_options.yaml` got
  `strict-casts`/`strict-raw-types` (both switched on without a single
  violation) and `unawaited_futures`/`use_build_context_synchronously` as
  errors; the `onAuthStateChange` subscription leak in `routerProvider` was
  closed with `ref.onDispose`; the doc comment about room mute was corrected —
  it promised that the flag is hidden from other members, and it isn't (what
  to do about that — in "Rooms" in docs/data-model.md).

  Verified: `make verify` (deps, format, analyze, 356 tests),
  `cd console && npm run lint && npm run typecheck && npm test && npm run build`,
  the migration — a dry run in a transaction with `rollback` plus a behavioural
  probe of seven cases (creating a post, editing text, changing the name,
  hiding a post from the console, editing a news post, deleting one's own photo,
  lifting a ban), and after applying — control visibility numbers as a regular
  room member (attachments, avatars, post media, rooms, messages, `my_rooms()`,
  `reaction_summary()`, `comment_summary()`) and external requests with the
  public key against the four closed functions. The new test on the profile
  screen was checked by reverting the fix: without it, it fails.

- Fifteenth full audit (0.18.13) — six findings, three in the app and three
  in the console. Once again the pass didn't lean on earlier reviews: all of
  `app/lib`, the whole console, the edge function, migrations, the gh-pages
  pages, workflows and scripts.

  **The main one — hunting for a reply's target spun idle instead of loading.**
  Tapping the quote of a reply whose original wasn't loaded yet started
  `_scrollToMessage`, which looped asking `_loadMore()` until the message
  turned up. But `_loadMore` returned `void`, so "I did nothing" was
  indistinguishable from "a page arrived, but what we need isn't in it". The
  offline backoff branch returned on an already-completed Future every
  iteration — the loop turned into a spin on the event loop: a core eaten for
  as long as the chat stayed open, cured only by the network coming back. Now
  `_loadMore` reports whether anything moved, and the loop stops on "no". A
  concurrent call meanwhile waits for the page already in flight
  (`_pageInFlight`) instead of sending a duplicate or giving up a round
  early — that's what keeps the loop both terminating and honest. Verified by
  a test in both directions: without the fix it never finishes at all.

  Chat attachments could stay on the spinner forever: `_MessageMedia` guarded
  signing with a bare `bool` that `didUpdateWidget` didn't reset on a
  generation change. An incoming message shifted the slot mid-request — the
  old response was discarded by the generation check, while the request for
  the new list was rejected by the guard and never went out at all; nothing
  was going to rebuild the `State`. The guard is now per generation, as in the
  feed carousel. The read-receipt subscription had no `onResubscribed`: a
  socket drop without going to the background left "delivered" ticks over a
  read message until you re-entered the chat.

  In the console — the same rule, "an invariant that rests on someone else's
  goodwill is not an invariant", only about bytes. The news draft froze into
  `drafts.json` the path of an already-uploaded object, but an object without
  a row in `post_media` has nothing to keep it from `reap-orphaned-media`:
  after a day the bytes were wiped, and publishing a two-day-old draft
  **succeeded** — the rows went in pointing at nothing, and the post went out
  broken to the feed of every connection, along with the push already sent;
  there's nothing to restore, `drafts.json` is the only copy. The draft no
  longer references the bucket: the file sits on the console's disk
  (`news-staging/`) and moves there at publish time. Along the way the whole
  class of "the console littered the bucket" ended too, and draft thumbnails
  stopped going stale. The object path is now minted entirely by the server:
  the extension was taken from the browser's file name and checked only for
  length — fine while the result was a Storage key, where an extra slash is
  just one more segment, but it became a file name on disk, and `..` fits
  within 2–5 characters.

  Two more: `parseBanDays` let through any finite number, so `days: 1e9`
  reached `new Date()` beyond its range and `writeBanUntil` crashed with
  exactly the `RangeError` the module exists to prevent (`authBanDuration`
  was covered by its own clamp, the write ban had none) — there's now one
  ceiling, enforced at input as well; the broadcast history was sorted by
  `Number(build)`, and the `?` substituted when there's no build is NaN, i.e.
  no ordering at all, and a single such row was enough to throw the whole
  table off.

  Merging a colleague's branch caught a seventh, this time not by the audit:
  both branches added their own `analyzer:` key to `analysis_options.yaml`,
  git merged them without a conflict (the lines differ, after all), and YAML
  silently keeps the last of a duplicate key — so either the iOS exclusions
  or the strict modes would have quietly switched off. Merged into one key,
  with a comment in place.

  Verified: `make verify` and the full console check suite (lint, typecheck,
  tests, build) are green before and after the merge. There are six more
  tests — two in the app (the spin, catching up on receipts) and four in the
  console (escaping the directory, the "type ↔ extension" round trip, the
  term ceiling, the date being parseable across the whole accepted range).

- Tail of the fifteenth audit (0.18.14 — the number was filled in at the bump
  before the PR: this pass deliberately didn't touch the version in
  `app/pubspec.yaml`) — three small things the audit itself found but didn't
  take into its list of findings as too narrow; filed as IMM-254, IMM-255,
  IMM-256 and closed together.

  **`verify-version.sh` answered "passed" for a version without a build
  number** (IMM-254). `[ "$x" -le "$y" ]` on a non-number isn't a comparison
  that comes out false but a usage error: `[` writes `Illegal number` to
  stderr and returns 2, and inside `if` that reads as "false", where `set -e`
  doesn't reach. `version: 0.18.13+` yields an empty `${v##*+}`, which the old
  pattern `*[!0-9:]*|:*` didn't catch (no non-digits, no leading colon) — and
  the only check that guarantees a PR carries a build number printed success
  for a version without one at all. Now both numbers are checked separately,
  by enumerating what's allowed. Also, the two versionName failures are now
  told apart: awk exits with 1 on "went backwards" and with 2 on "not
  major.minor.patch", but both printed "must not decrease" — wrong for the
  second, and that's exactly how a version with two `+` ends up here
  (`${v%+*}` leaves `1.0.0+1` as the "name" for `1.0.0+1+2`). Verified by
  running ten versions through the script, not by reading.

  **`posterFor` didn't clear its fallback timer** (IMM-255). The ten-second
  timeout that keeps it from hanging on an unparseable file wasn't cancelled
  on success — after the poster was captured it still fired and called `done`
  a second time. The promise doesn't care, but `revokeObjectURL` ran twice,
  and until it fired the timer kept the closure, the `<video>` and the blob
  URL alive. Harmless only because `done` contains nothing else; a flag and
  `clearTimeout` removed that dependency.

  **A malformed id in the console answered 500 instead of 400** (IMM-256).
  Ids went to PostgREST without a shape check, Postgres answered `22P02`, and
  the handler turned any throw into a 500 with the driver's text — even
  though the same endpoint honestly answers 404 for a well-formed nonexistent
  id. A typo looked like a crashed server, and the moderator saw the
  internals. A single `isUuid()` (`console/server/uuid.ts`) at every entry
  point, including two news endpoints that weren't in the ticket but have the
  same defect. Not about security: the id goes in as a filter parameter, not
  spliced into SQL, and a junk one simply finds no rows — it's about the
  response meaning what it means. Verified live on all seven endpoints: a junk
  id gives 400 without reaching the database; a well-formed nonexistent one
  still gives 404.

  Console tests are now 42 (were 38): `uuid.test.ts` checks the shape, a
  non-string and trailing junk after the uuid.

  Following the branch review — three more fixes on top.

  **Self-check 3 in `20261010100000_wrap_auth_uid_in_select.sql` failed a
  re-run**: it unwrapped the wrapper only in "after" and compared it with the
  raw "before", where on an already-wrapped policy the wrapper is present too.
  The failure was reproduced with a dry run on the live database (all 27
  policies); after the fix a re-run passes, and an `and true` slipped into one
  policy is still caught. The migration's effect didn't change — only the
  check — and it's already applied on the live database, so it wasn't
  re-applied.

  **`verify-version.sh` let through a build number of 19+ digits**: it
  overflows `[`'s integer, and that's the same usage error with code 2 and
  the same "passed". Now the length is limited before the comparison, and the
  value by the Google Play ceiling (2100000000).

  **The `:id` check is a single `router.param('id', uuidParam)` per router**
  instead of a copy in five handlers: a copy forgotten in a new endpoint would
  silently bring back the same 500. `uuid_param.integration.test.ts` brings up
  the router on an ephemeral port and fails if `.param` is removed (45 tests
  now).

- Second squash of the migration history (0.18.14 — the number was filled in
  at the bump before the PR). The first baseline and the 27 migrations on top
  of it (`20260826000000`…`20261010100000`) are replaced by a single
  `20261018000000_baseline_schema.sql`; the files themselves are in the tag
  `pre-baseline-migrations-2`, next to the first one. As last time, the
  contents were derived from the live schema (pg_catalog), not from the
  migrations.

  Verified mechanically, not by reading. The whole history was replayed on a
  clean PostgreSQL emulating the Supabase platform, and by catalog
  fingerprint (600 facts: columns and their order, constraints, indexes,
  function bodies and privileges, triggers, `public`/`storage`/`realtime`
  policies, grants, default privileges, the realtime publication, the bucket,
  cron) it matched production — only the platform differs
  (`rls_auto_enable()`, its two extensions, grants on storage/realtime
  tables). The baseline on the same kind of database gives the same
  fingerprint, the same `pg_dump --schema-only` and the same output of the
  behavioral run under `authenticated` and `anon`. On the live project only
  `supabase_migrations.schema_migrations` changes — 28 rows become one; the
  schema and data aren't touched. The procedure is written up in
  "History squash" (docs/operations.md).

  The baseline's control block got stricter: four invariants from the
  fourteenth audit were added to the three existing checks — a function
  accessible to `anon`; a trigger function open to `authenticated`; a
  function from a policy expression without an `authenticated` grant; a
  default EXECUTE for PUBLIC.

  Found along the way and deliberately not fixed — the baseline must match
  production: `users.write_banned_until` is visible to everyone RLS shows
  the profile to. SELECT for `authenticated` is granted on the whole `users`
  table, while 20260913100000 assumed it was per-column and wrote that the
  column is "seen by no one but the server". To be closed by a separate
  migration.

- The ban date is no longer visible to those who can see the profile
  (0.18.15, IMM-541). `users.write_banned_until` was readable by everyone RLS
  shows the `users` row to — the person themselves, Connections, fellow room
  members, commenters, and everyone for the system account: SELECT for
  `authenticated` is table-wide, not per-column as 20260913100000 assumed. A
  per-column grant would have broken the `select=*` the client loads the
  profile with, in every released version, so the column was moved into
  `user_moderation` — RLS enabled, no policies or grants for the client
  (`20261019100000`). `is_write_banned()` and `reject_write_when_banned()`
  read the date from there; the console bans with an upsert and lifts the
  ban with an UPDATE. The app didn't change. On the live database the hole
  was reproduced before applying; probes before and after — a fellow room
  member sees the profile but not the ban; the banned user gets `AMB01`; after
  the ban is lifted they can write again.

- The client no longer holds privileges on the `room_members.seq` sequence
  (0.18.15, IMM-542). `authenticated` had `rwU` on `room_members_seq_seq`,
  including `setval` on the counter `room_owner_id()` uses to decide who owns
  a room. It was unreachable through PostgREST, but the grant served no
  purpose and came from the default privileges of `postgres`, which the
  baseline revoked only from `anon`. Both are revoked — the grant itself and
  the default for future sequences (`20261019110000`); the migration itself
  checks that no sequence in `public` is open to `anon`/`authenticated`.
  Probed on the live database: direct `nextval`/`setval` are rejected,
  `create_room()`, `add_room_member()` and ownership transfer via
  `leave_room()` work.

- The Connections list stays private — a decision, not a gap (0.18.15,
  IMM-216). The open question "can others see who you're connected with" is
  closed: no, and we won't build a visibility setting. That's already how it
  works — the `connections` policy returns only your own rows, under a
  connection's post you see only comments from your own Connections, and a
  non-connection's profile isn't visible. Recorded in "Visibility rule" in
  `docs/data-model.md`, together with the only remaining signal (room
  members) and a rule for new screens.

- Editing a sent message in a room chat (0.18.15, IMM-208): your own, text
  and attachments, for 48 hours after sending. The only path is
  `edit_own_room_message(id, text, media)` (`20261019120000`): an UPDATE grant
  would have exposed `created_at`, which unread counts are based on. New
  column `room_messages.edited_at`; an edit without changes isn't an edit.
  Someone else's, nonexistent and hidden by moderation — one PT404; a deleted
  placeholder — PT422; the window has expired — a dedicated `AME01` (counted
  from `created_at`, not from the previous edit). The attachments' shape and
  non-emptiness are held by row CHECKs; the ban — by a per-column trigger on
  `text, media` with the condition `deleted_at is null`: you can't edit while
  banned, but you can delete your own. The function returns the paths of
  removed attachments; the client deletes the objects after the row.

  In the app: "Edit" in your own message's menu while the window is open;
  the input field switches to edit mode — the text, the attached attachments
  (each can be removed) and new ones, while a draft in progress is set aside
  and comes back afterwards. An edited message gets an "edited" label next to
  the time. A Realtime update no longer loses the author's name and the
  quote, and the quote in a reply takes the original from the loaded list
  before the embed — and so shows its edited text. Eleven probes on the live
  database (before and after applying), fourteen new tests, 372 in total.
