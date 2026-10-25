# Archive: deferred features as of the MVP

**This document is historical.** A snapshot of [future-development.md](future-development.md)
from the time the MVP wasn't closed yet — kept to show what was planned before
the MVP and what this list looked like before it was rewritten.
The live list of deferred work is in [future-development.md](future-development.md), and
this file has already drifted from it: some of what's listed below was done long ago.

Done since then, although listed below as deferred: the Amicus news account,
your own wall (one person's posts), timeouts on network calls,
the server-side comment counter (`comment_summary()`), the `media` bucket being
private (now also pinned by a migration). What appeared in which version — see
[../CHANGELOG.md](../CHANGELOG.md).

Nothing needs to be checked against it; nothing links to it except the live
`future-development.md` and the index in [../README.md](../README.md).

---

Everything deliberately deferred past the MVP (0.1) so as not to drown at the start. See the main plan in [project-brief.md](project-brief.md).

It's worth coming back to this list only after the MVP works end to end (Stage 5 of the roadmap is done).

---

## Rooms

Private sub-spaces inside the shared circle — originally part of the overall project idea, but moved out of the MVP so as not to grow the scope of the first version.

**Mechanics:**
- Any user can create a room.
- A room is populated only by those its creator added (from among their Connections).
- A room has its own isolated feed — posts marked "only for this room" don't get into the shared feed and aren't visible outside the room.
- A post can be published: (a) to the shared feed, (b) to one or several rooms at once.

**Data model (draft):**

| Entity | Key fields | Comment |
|---|---|---|
| **Room** | id, name, creator_id, created_at | The room |
| **RoomMember** | room_id, user_id, joined_at | Who is in the room (many-to-many) |
| **PostTarget** | post_id, room_id (nullable) | Where the post is published: NULL = shared feed, otherwise a specific room. One post can have several rows (several rooms) |

When this feature's turn comes, the MVP's `Post` will need to be linked to `PostTarget` instead of direct visibility through Connections.

**A separate roadmap stage (after the MVP):** creating a room, adding members, the room feed, choosing where to send a post when publishing.

## Video messages ("circles", like in Telegram)

Round video messages recorded with the camera right in the app — as an alternative/addition to a photo in a post or comment.

**Mechanics (draft):**
- Record with the device camera (usually the front one), with a duration limit (e.g. 60 sec, like in Telegram).
- The round mask is more likely a client-side rendering (`ClipPath`/overlay) than re-encoding the video file itself into a round shape.
- Storage — Storage (the same bucket as photos, or a separate one), visibility under the same privacy rules that already apply to photos/avatars (Connections-only, see 0.4.0/0.5.0 in CHANGELOG.md).

**Open questions:**
- A separate attachment type for posts, or only for comments (or both)?
- Size/duration limit, and whether client-side re-encoding/compression is needed before upload.
- Autoplay in the feed (with or without sound) — a UX question, to be decided separately.

## GPS track upload (running/cycling routes, Strava-style)

The ability to record a run/ride route with the phone's GPS or upload a ready track file (GPX/TCX/FIT — the formats Strava, Garmin and most sports watches work with), and then show the route on a map in a post.

**Mechanics (draft):**
- Record the track on the device (background GPS tracking during the activity) or import a ready file.
- Parse the track → a series of coordinates (lat/lon/timestamp, maybe elevation) + aggregates (distance, duration, average speed/pace).
- Show the route on a map in the post — needs a mapping SDK (Google Maps / Mapbox / something OpenStreetMap-based) — each has its own free-tier limits and pricing; choosing one is a separate question.

**Data model (draft):**

| Entity | Key fields | Comment |
|---|---|---|
| **Route** (or Activity) | id, post_id, type (run/ride), distance_m, duration_s, started_at | Route aggregates, tied to a post |
| **RoutePoint** | route_id, seq, lat, lon, elevation_m?, recorded_at | Track points — either normalize like this, or keep the raw GPX/FIT file in Storage and parse on the fly; open question |

**Open questions:**
- Store the track as a file in Storage and parse on the fly, or normalize it into a points table in the DB — a trade-off between simplicity and the ability to query/aggregate over tracks.
- Which mapping service to use (cost, free-tier limits, availability on Android without extra setup).
- First iteration: only uploading a ready file, or live GPS recording during the activity right away?

## iOS

The MVP (0.1) is deployed on Android only (Google Play, Internal Testing track). The iOS build is deliberately deferred — originally because of the dev machine on macOS 12.7.6 (Xcode requires macOS 14+, see CLAUDE.md), now simply as a separate task after the portfolio release on Android.

When its turn comes:
1. Upgrade the dev machine to macOS 14+ (or build on another machine/CI) and install Xcode.
2. An Apple Developer account (paid, $99/year — the only point where money will be needed).
3. Run the `flutter create --platforms=ios` configuration (wired up from the start) through `flutter run`/`flutter build ios` on a real device or simulator, catch platform bugs that didn't show up on Android.
4. Xcode archive → App Store Connect → TestFlight, add myself/friends as testers.

## 1.0 — after the MVP works

- ~~Dark theme~~ — implemented out of order in 0.8.0 (a light/dark toggle in the `AppBar` of the three main tabs, follows the device's system theme by default), see CHANGELOG.md
- ~~"Forgot password" on the sign-in screen~~ — implemented out of order in 0.6.0 (a "Forgot password?" link on the sign-in screen → `auth.resetPasswordForEmail()` → an interactive `reset-password.html` on GitHub Pages, `AuthFlowType.implicit` instead of PKCE), see CHANGELOG.md
- Post view counter. The task is worded "peculiarly" (in the author's words) — before implementing it the agent must clarify with the user exactly how a view is counted (when the card is shown in the feed / when fully expanded / unique users only / what about repeat views, etc.), not make it up on its own
- ~~Several reaction types — at least like, a neutral reaction and dislike (not just like)~~ — implemented out of order in 0.3.0 (a `type` column in `reactions` + an UPDATE RLS policy for changing a reaction, three mutually exclusive reactions in the UI), see CHANGELOG.md
- ~~Nested comments (replying to a comment) — the `parent_comment_id` field in the `Comment` table is already laid into the schema for the future~~ — implemented out of order in 0.10.0 (one nesting level, `parent_comment_id`/`reply_to_id`/`deleted_at` + a depth trigger + the `delete_own_comment` RPC), see CHANGELOG.md. A correction to the struck-out item: `parent_comment_id` was in fact **not** in the schema — the field stayed only in the data-model draft in the brief and never made it into the MVP migration, so in 0.10.0 the column was added from scratch
- ~~Deleting your own posts and comments~~ — implemented out of order in 0.2.0 (DELETE RLS policies on `posts`/`comments`/post photos + UI), see CHANGELOG.md
- Deleting the whole account — the MVP currently has none of this at all (no UPDATE policy on posts/comments for editing, no account deletion screen); for now an account is deleted manually by the admin on request by email (see the privacy policy on GitHub Pages)
- Editing a post — currently it can only be deleted; the text can't be edited after publishing
- Several photos in one post — currently strictly one photo per post
- ~~"Known for N days/months"~~ — implemented out of order in 0.5.0 (a label on the "Connections" screen from the Connection's `created_at`), see CHANGELOG.md
- ~~Mute a connection without breaking the Connection~~ — implemented out of order in 0.9.0 (a `muted_users` table, hides the author's posts only from the one who muted, without breaking the Connection); a reversible mutual block was added along the way (see CHANGELOG.md and the block item in the 2.0+ section below); in 0.10.1 the same rule was extended from posts to comments — the reply thread under a hidden comment is hidden too, as are replies addressed to the hidden person
- ~~Localization (i18n) — every string in the app is currently hardcoded in Russian; fine for the portfolio and friends, but a non-Russian-speaking user will see a Russian interface with no alternative~~ — implemented out of order in 0.7.0 (English by default, Russian with a system `ru` locale), see CHANGELOG.md
- Offline mode — cache the last opened feed so the app isn't empty without a network
- Interface work/UI polish beyond what was done in Stage 5 (currently functional, but no more than that)
- QR scanning as a second way to connect (in addition to invite links)
- Push notifications
- Deep link for email confirmation: right now the link in the email leads to a static confirmation page on GitHub Pages (`site_url` in `supabase/config.toml` → `https://tiltozavr2545.github.io/amicus/`, source — the `gh-pages` branch, a single `index.html`), because the confirmation itself is counted on the Supabase side before the redirect. That fixes the confusing landing page (it used to lead straight to the GitHub repository), but opening an app screen directly would be nicer — it needs a custom URL scheme / Android App Links set up and handling in `supabase_flutter`; a separate task, not for the MVP
- ~~Our own SMTP for confirmation emails: right now Supabase's built-in email service is used, which on the free tier has a hard rate limit (a couple of emails per hour) — this has already got in the way of manual testing several times.~~ ✅ **Closed.** A regular Gmail account (`projectamicushelper@gmail.com`) is connected as the SMTP server directly in the live Supabase project (Dashboard/Management API) — `supabase/config.toml` in the repository isn't pushed to the remote automatically, so the `[auth.email.smtp]` section there is left commented out as a reference copy (in case real SMTP is ever needed locally instead of the fake Inbucket). An infrastructure change, with no migrations and no app version (not an app feature)

## Security and privacy (from the code audit)

**First audit (before 0.4.0).** A full review of the project (RLS, Storage policies, client, secrets, the whole git history) came out clean: no critical holes, no secrets in the repository or git history, the `service_role`/secret key isn't used in the client, the anon key is public by design. Strong points — `security definer` + `set search_path` on functions, `for update` against the race on invite activation, canonical pair ordering, `revoke execute … from anon`, a size limit + MIME allow-list, `enable_anonymous_sign_ins = false`, email confirmation, `additional_redirect_urls = []`. Below is what's worth tightening after the MVP.

**Second audit (review of the 0.8.1→0.10.3 branch, closed in 0.11.0).** Did not come out clean — and its lesson is a single, general one: almost everything found appeared not because of a bad policy, but because of **duplication of the visibility rule**. The rule "whose content can I see" lived in four places, mute/block from 0.9.0 didn't reach all of them, and two lagging copies turned out to be real holes. Details of each fix are in CHANGELOG.md (0.11.0); here only the outcome and what's left.

- ~~**Social graph leak through reactions.**~~ ✅ **Closed in 0.4.0.** The SELECT policy on `reactions` was broad (`using (exists (select 1 from posts p where p.id = reactions.post_id))`) — on any visible post the API exposed the `user_id` of **everyone** who reacted, and through the then-public `users` it mapped to a name. Now SELECT on `reactions` returns only your own rows (`user_id = auth.uid()`), and the public per-post counters are computed by the `security definer` function `reaction_summary(uuid[])`: it returns only numbers (like/neutral/dislike) plus the caller's own reaction, without other people's `user_id`, with an internal post-visibility check. The option proposed here was chosen — "a real shared counter with hidden identities" — rather than narrowing to connections: the counter stays a true total, but who reacted can't be found out. Migration `20260712100000_scope_profile_and_reaction_visibility.sql`.

- ~~**The whole address book is readable by any signed-in user.**~~ ✅ **Closed in 0.4.0.** `users` SELECT was `using (true)` — anyone saw the names/avatars/`id` of **everyone**. After the harden migration for comments, every name the app shows at all (post authors, comment authors, the connections list) already belongs to your Connections, so the policy could be narrowed with plain RLS without a `security definer` view: SELECT on `users` is now "your own row OR my Connection". Enumerating the whole address book through the API is no longer possible. Migration `20260712100000_scope_profile_and_reaction_visibility.sql`.

- ~~**Avatar files were readable by any signed-in user (bypassing the `users` narrowing).**~~ ✅ **Closed in 0.5.0.** The profile row in `users` was narrowed to Connections back in 0.4.0, but the avatar bytes themselves live in Storage, and its SELECT policy (`20260707222025`) only checked `bucket_id='media' AND foldername[1]='avatars'` — meaning any signed-in user could download someone else's photo at the path `avatars/{uuid}/...` knowing just the UUID (it doesn't currently leak to non-connections anywhere, but the policy is still broader than intended). Surfaced when the connections list first started pulling other people's avatars en masse. Now the storage policy mirrors the `users` rule: an avatar is visible only to yourself and your Connections (a subquery on `connections` by `foldername[2]`). Verified with an RLS test against the live DB. Migration `20260712120000_scope_avatar_storage_visibility.sql`.

- ~~**Minor hardening.** No length limit on post/comment text (neither in the UI nor in the DB) — worth adding `check (char_length(text) <= 5000)` + a character counter in the UI. And don't print the raw exception text (`$e`) in error messages ("Не удалось …: $e", i.e. "Failed to …: $e") — replace with human-readable wording so as not to expose internal details.~~ ✅ **Closed in 0.9.1.** See CHANGELOG.md.

- ~~**The visibility rule is copied four times, two copies lagged behind mute/block.**~~ ✅ **Closed in 0.11.0.** Inline in the `posts` policy, inline in `reaction_summary()`, as the function `is_comment_author_visible()`, and inline in the storage policy on post photos. 0.9.0 didn't update all of them: a blocked user got live reaction counters for posts hidden from them through `/rpc/reaction_summary`, and, knowing the path to a photo, could keep issuing themselves new signed URLs indefinitely. All four are merged into a single `is_author_visible(uuid)`; from now on the rule changes in one place. Migrations `20260726120000`, `20260726130000`. **Avatars don't need narrowing** — a block doesn't break the Connection, the blocked user stays in the connections list, and the blocker sees them on the "Blocked" screen, where the block is lifted.

- ~~**Definer helpers answered other people's questions.**~~ ✅ **Closed in 0.11.0.** Every function in an exposed schema is a PostgREST endpoint, so a grant to `authenticated` = "call it with any arguments". `is_blocked_pair(a, b)` didn't tie its arguments to `auth.uid()` and reported whether **strangers** had blocked each other; `comment_author(uuid)` returned the author of any comment, bypassing RLS. The first had its grant revoked (it's only called from inside another definer function, i.e. with the owner's privileges); the second was collapsed into the boolean `is_author_of_comment_visible(comment_id)` and dropped. Migration `20260726140000`. For the future: **for any new `security definer` function, check that every argument is either about the caller themselves, or the function isn't granted to `authenticated` directly.**

- ~~**Server-side state was client-writable.**~~ ✅ **Closed in 0.11.0.** Supabase's default grants let `authenticated` write every column, and the INSERT policies said nothing about them: a comment could be inserted already as a tombstone (`deleted_at`), and a post with a 2099 date (`created_at`), permanently occupying the top of the feed for all of the author's connections. Both columns are pinned in `with check` (`deleted_at is null`, `created_at = now()`). Migrations `20260726160000`, `20260726190000`. For the future: **every new column the server fills in must be mentioned explicitly in the INSERT policy** — the default here works in the client's favor.

- ~~**`delete_own_comment()` failed in the dangerous direction.**~~ ✅ **Closed in 0.11.0.** `if v_author <> auth.uid()` with `auth.uid()` = NULL yields NULL, the `if` doesn't fire, and the function falls through to the delete — and that's its only permission check (the DELETE policy on `comments` was dropped in 0.10.0 for its sake). Plus a race: the "are there replies" check and the hard delete ran as separate statements, and a reply committed between them got wiped by the FK cascade. Now there's an explicit guard + `is distinct from` + `for update` before the check. Migration `20260726150000`.

- ~~**Raw error text on invite activation.**~~ ✅ **Closed in 0.11.0.** The only place that survived the 0.9.1 cleanup — the message there is useful, but timeouts and constraint violations with table names arrive through the same channel. Split apart: stable SQLSTATEs (`PT404`/`PT409`/`PT422`) + text from ARB, anything unknown gets a generic message. Migration `20260726170000`.

- ~~**RLS cost grew with the whole table.**~~ ✅ **Closed in 0.11.0.** Not a hole, but found by the same review and turned out to be the biggest by the numbers. The planner doesn't inline a `security definer` function, so `using (is_author_visible(author_id))` is a call per scanned row, and for the feed visibility is decided before `LIMIT`, i.e. over the whole posts table. Measured: the feed with 2000 posts **217 ms**, now **3.5 ms** (62×); comment counters with 1000 comments **115 ms** → **5 ms** (23×). The rule depends only on the caller, so it's asked once per query via `visible_author_ids()` + a hashable `IN (SELECT ...)`. Migration `20260726180000`. For the future: **don't put a definer function of a column into `using` if it actually depends only on `auth.uid()`.**

- **Left over (noticed during manual testing of 0.11.0):** network requests have no client-side timeout. Sending a comment in airplane mode hung with a spinner for ~3.5 minutes before falling into a snackbar — the error branch is correct, but all that time the user doesn't understand what's happening, and the text in the field looks "stuck". Fixed with `.timeout(...)` on repository calls (10–15 seconds or so) with the same generic message. Doesn't affect server rejections — those arrive instantly.

- **Left over (measured, not done):** comment counters on a feed page are still computed on the client — the server returns a row for each visible comment (hundreds of rows per page, ~40 KB) just to count them. The candidate is `comment_summary(uuid[])` with `security invoker` (RLS filters by itself, no rule duplication, unlike `reaction_summary()`). Server time doesn't change, the gain is purely on the wire; deferred because it's a change to the client data path, which isn't covered by unit tests.

- **Check (operational, not code):** the `media` bucket in the Supabase dashboard must be set to **Private** — all of the Storage RLS only makes sense under that. The client assumes it (signed URLs, authorized download), but it can only be confirmed in the dashboard.

## 2.0+ — future ambitions

- Moderation, reports, blocking a connection (partially: a simple reversible block — mutual hiding of posts without breaking the Connection, without reports or moderation — is implemented in 0.9.0, see CHANGELOG.md; full moderation/reports stay here)
- Privacy settings (who sees your contact list)
- Web version
- Connecting via NFC as an alternative to the invite link/QR — a very distant idea, not a priority
- **Full privacy policy audit, rework and integration of consent checkboxes into the app** — right now the privacy policy is static on GitHub Pages; consent is only the email confirmation, with no options in the UI
- **Amicus news account** — a built-in address (e.g. `amicus@amicus.app` or a systemwide ID) that every user is automatically linked with as a Connection. Publishes announcements, updates, app features — visible to everyone in the feed, but not taking the place of real connections. Concept: when you step away from social networks, you don't lose your friends' content, but you get less noise. Amicus as a minimal source of non-private content in the feed
- **Integration with existing social networks (Instagram, TikTok, etc.)** — the ability to link an account, move posts (with photos/videos) to your own wall in Amicus, as a one-off sync or a periodic background one. Syncing friends to the wall as an option (who from your Insta follows ends up in Connections or in a separate list). Addresses the main objection to quitting social networks: friends' content stays, but in a first flavor, blocked off for everyone else
- **Your own wall (wall/profile)** — a separate tab where only your posts are visible (still deferred past the MVP; right now the feed can't be filtered by a specific person, the feature is planned for 1.0). A tab in the profile: your wall; someone else sees only your posts (if they're your Connection) or nothing at all. Differs from the feed the way IG/Telegram do — not a timeline of the whole universe, but one person's portfolio
- **Digital detox inside a social network** — the project's core value as what sets it apart from competitors: Amicus doesn't demand giving up content entirely, only the algorithm and engagement. You see posts only from connections you chose yourself, there's no discover/Explore with promotion, no likes (reactions hidden for incognito), no view counter. A possible feature: a temporary "connections only" mode (like Digital Wellbeing for a specific app), with a notification once the period ends

## Moving from Supabase to our own server

Not a hypothesis but a settled matter: sooner or later the whole database will move from Supabase to my own personal server — just not for 0.1; it's overkill at the start. You already have experience with ASP.NET Core + PostgreSQL (essentially the same thing you did in the TransferScout lab), and the backend can be rewritten on it. RLS policies are currently written as plain Postgres SQL — access logic won't need porting during the migration, only the Auth/Storage/Realtime layer.

## Questions worth settling along the way

No need to answer them right now — this is a checklist for later, when you get to the corresponding stage or functionality:

- ~~Reaction set: it's decided there will be at least like/neutral/dislike (see 1.0) — the question of the specific iconography/reaction-picker UI is open~~ — closed in 0.3.0: three mutually exclusive reactions 👍/😐/👎 (`Icons.thumb_up` / `sentiment_neutral` / `thumb_down`, the selected one is highlighted in color — green/amber/red — and filled), each with its own counter; tapping your own reaction again removes it
- ~~Comments: are replies-to-replies (threads) needed in the first version, or is a flat list fine?~~ — closed in 0.10.0: threads are needed, but exactly one level deep (like Instagram/YouTube) — a reply to a reply goes into the same thread, and who it's addressed to is shown by the "In reply to: Name" label. The depth is enforced in the DB by a trigger, not just in the UI, so the tree can't be deepened by calling the API directly
- Can a regular room member add new people, or only the creator?
- What happens to a room if its creator deletes their account?
- Should it be possible to break a Connection (roughly, "remove from connections")?
- Can others see who exactly you're connected with, or is the contact list private information? (partially came up in the audit — see the "Security and privacy" section: in 0.4.0 reading `users` and `reactions` was narrowed to "only your connections / only your own rows", but the question of contact list visibility itself remains open)
