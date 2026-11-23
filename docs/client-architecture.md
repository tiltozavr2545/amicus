# Client architecture

Decisions and behaviour of the Flutter app that the schema doesn't show: what
it's built with, what the client itself does, and why the client is the one
doing it. Kept separate from [data-model.md](data-model.md) because this isn't
schema: that file is what the database guarantees, this one is what the app
does on top of it.

Keep the boundary in mind when reading both files: **nothing here is a
guarantee.** A modified client can behave differently, and no security rule
relies on this file — they all live in RLS, see
[data-model.md](data-model.md). This is what determines convenience and
correctness of normal operation, not what protects anyone from anything.

**Why** a given server-side decision was made the way it was is still in the
comment of the corresponding migration. What appeared in which version is in
[../CHANGELOG.md](../CHANGELOG.md).

---

## Default technical choices

The list is live: it's what the project is built with now, not what it was
meant to be built with. Deviations (e.g. replacing Riverpod with something
else) should be recorded here too, so they don't silently drift from reality.

- **State management:** Riverpod
- **Navigation:** go_router
- **Backend SDK:** supabase_flutter
- **Image caching:** cached_network_image
- **DB schema versioning:** migration files in the repository (not manual edits
  in the dashboard); applied manually via the Management API, the procedure is
  in "Working conventions" in [../AGENTS.md](../AGENTS.md), the operational
  side in [operations.md](operations.md)
- **Linting/formatting:** flutter_lints + `dart format`, checked in CI from the
  first commit
- **Repository layout:** `app/` — the Flutter project (org
  `com.github.tiltozavr2545`, package name `amicus`), `supabase/` — schema and
  Edge Function, `docs/` — documentation; the full tree is in
  [../README.md](../README.md)
- **Project name:** Amicus (renamed from the working title "Круг" after
  development started — see [project-brief.md](project-brief.md))
- **Repository:** [github.com/tiltozavr2545/amicus](https://github.com/tiltozavr2545/amicus)
  (public)
- **Flutter version:** Android/local verification is pinned to 3.32.8
  (`~/development/flutter`) on the Intel macOS 12 machine. Xcode Cloud uses
  its independent 3.47.5 pin for the committed UIScene-based iOS runner; see
  [xcode-cloud-setup.md](xcode-cloud-setup.md). Do not upgrade the Intel SDK.
- **Supabase API keys:** the new format is used (Publishable/Secret instead of
  legacy anon/service_role) — `SUPABASE_ANON_KEY` holds the Publishable key
  (`sb_publishable_…`); the Secret key is not used anywhere in client code

## Interface and local preferences

Current rendering, media-memory and foreground-work rules, their Framebook
origin and validation limits are recorded in [performance.md](performance.md).

`lib/theme/amicus_theme.dart` defines both themes, bundled Sofia Sans typography
and shared controls. The palette and layout rationale live in
[interface-design.md](interface-design.md). `ContentWidth` bounds reading and
form widths on tablets; authentication forms scroll above the keyboard.

The header and welcome screen use the launcher's foreground without its colored
background or adaptive-icon padding. The artwork is white in the dark theme and
tinted with the primary berry in the light theme. Android notifications use a
separate 24 dp vector with stronger lines and nodes for small display sizes.
Its appearance on Samsung One UI still needs device verification.

In a direct chat, tapping the header opens the other person's profile and
message bubbles omit author names. Group headers open room details, while
member names above incoming messages link to their profiles. Each link takes
the space of its text, allowing short bubbles to wrap their content.
Profile and room-detail routes open above the chat and preserve its draft.
Profile data continues to use its existing visibility rules.

Presence means the other person is viewing this chat in the foreground.
Typing takes priority over online and expires after four seconds without a
text change. The header reserves the same status line height in all states.

### Navigation and profiles

The bottom bar appears only on the four primary tabs and the new-post compose
destination. Secondary screens use the root navigator above the shell: comments,
chats, Connection profiles, room creation/details, blocked users, post editing,
photo viewers and photo ordering/deletion do not display either bar style.
Returning restores the underlying tab and its state. Creating a room replaces
the creation screen with its chat, so Back returns to the room list.

The author block in a post (avatar, name and date) and the full Connection row
open that person's profile. Post menus and trailing relationship controls keep
their separate actions. Feed queries join the author's `avatar_path`; post copies
and the per-viewer feed cache preserve it. Cards share `avatarBytesProvider` with
profiles and Connections, so posts by one author reuse a download. Initials are
the fallback while a photograph is unavailable. `ConnectionName` shares private
favorite/mute/block indicators between author headers and Connections. The
`connectionsByIdProvider` lookup reuses `friendsProvider`, so relationship changes
update visible badges without fetching posts again; a missing relationship
snapshot leaves the name visible without badges.
Pulling down in Connections reloads both the relationship list and incoming
requests, including when the list is empty.

Both the own-profile tab and Connection routes use `ProfilePage` for the
app bar, avatar and gallery viewer, identity layout and author-scoped posts.
The owner supplies the photo menu and the name and Settings actions. A
Connection route supplies the report action and gets Back from the navigator.

Floating navigation synchronizes its neutral glass selection and pages through one
animation controller. Dragging the bar or swiping a primary page changes tabs;
cancelling returns to the starting tab. Reduced motion skips settling animations.
`BottomNavigationInset` clears the full floating bar, its gaps and the system
safe area at scroll tails and below the room creation action. Classic navigation
reserves layout space instead. The composer uses a temporary slot; its local
snapshot survives the widget being disposed (see "Post drafts" below).

### Settings

Settings follow Framebook's icon-led rows and adaptive dropdown pattern; the
remaining visual design belongs to Amicus. SharedPreferences stores language,
System default / Light / Dark theme, and floating/classic navigation. The theme
selector lives only in Settings, preserves previous light/dark preferences and
can restore following device brightness. Its six-change system-account shortcut
is retained.

Startup supplies saved presentation preferences before the first frame.
Writes serialize per preference and failed changes return to the last
successfully saved value. The language key remains `app_locale`; no migration
of existing preferences is required.

Notification preferences remain server-backed. A per-account local snapshot
appears while the server refresh runs, without a loading indicator. The first
visit without a snapshot shows the standard defaults. A later server response
updates untouched switches in place. Each write sends a single flag, so opening
Settings on a slow connection or changing another flag on a different device
preserves the other values. A switch stays disabled while its write is pending.
Failed writes revert that switch and show an error.
Loading failures leave the switches and other settings available, with a retry
action. Account actions still require confirmation.

### Interface verification

`test/interface_layout_test.dart` checks narrow/tablet widths, Russian text,
both themes, gestures and cancellation, secondary-screen navigation, scroll tails
and keyboard clearance. Optional previews use synthetic content:

```bash
cd app
flutter test test/interface_layout_test.dart \
  --dart-define=AMICUS_PREVIEW_DIR=/private/tmp/amicus-previews
```

## Post drafts

A new post has one local draft per account in application-support storage. Text
is debounced for 250 ms, with an immediate flush on leaving the screen or
backgrounding the app. Attachment changes are saved immediately. Images and
videos are copied out of picker temporary storage; order, audience, media tokens
and the submission idempotency token are restored with the text. A successful
publication clears the draft; failed publication retains it. Editing a published
post does not replace the new-post draft. Account deletion removes that account's
draft; sign-out retains it for the same account, with separate storage for others.

The storage implementation is `lib/features/feed/post_draft_store.dart`. Writes
are serialized; media are staged before metadata is replaced. Removing an
attachment removes its private draft copy, and an empty draft removes its folder.
Drafts stay on this device and are not synchronized or uploaded until publishing.
Storage and widget tests cover restoration, file retention, account isolation,
write ordering, leaving the composer, retry-token reuse and successful cleanup.

## Rows first, then objects

A rule that `data-model.md` refers to by name
(`deleteRowsThenObjects`, `lib/shared/delete_order.dart`), but it lives here
because the client is what enforces it: **a row pointing at a deleted object is
breakage everyone sees; an object nothing points at is bytes nobody sees.** So
of the two halves of a deletion, the one that removes the reference must go
first.

The second, object half is always best-effort: once the rows are committed,
the operation has succeeded from any observer's point of view, and reporting a
failed cleanup as a failed deletion would be a lie that invites retrying
something already done. An error in the first half, on the contrary, is
rethrown, and the second half never runs.

The order was wrong in all three places that existed at the time, and each
broke in its own way: deleting a post left a broken image in the feed of all
the author's connections, deleting a profile photo left `users.avatar_path`
pointing at a nonexistent file (the avatar vanished everywhere at once), and
deleting an account managed to destroy every photo — and then failed, leaving a
live account without a single one of them. Today the helper covers
all seven places where a deletion touches both sides: publishing and editing a
post (a retry with the same token may remove media), deleting a post, the
profile photo, the account, the room avatar, and message attachments.

The last line of defence, not the first, is `reap_orphaned_media()`: it takes
objects older than a day and a hundred per run, which is not the tool for a
hundred-megabyte clip removed from a draft a second ago (see "Scheduled jobs"
in [operations.md](operations.md)).

## A refresh that outlives its screen

`ref` is not a long-lived handle: it's tied to the element's `BuildContext`,
and every one of its methods starts with a check that, after unmounting,
**throws** (`StateError: Using "ref" when a widget is about to or has been
unmounted is unsafe`) — in release builds too, not just debug. So the familiar
shape "`await`, then `ref.invalidate(...)`, then `if (!mounted)
return`" is broken in exactly the case it was written for: the person taps,
the request is slow, they leave the screen, the request completes. The throw is
caught by the method's own `catch`, which exits on `!mounted`, and **the
refresh silently doesn't happen** — lists that should have been re-read show
the state from before the tap, and their buttons offer an action the server
has already performed.

Moving the `mounted` check above `ref` is not a fix: it trades a swallowed
throw for a deliberately skipped refresh, and stale lists are the whole
problem. They belong to OTHER screens: the feed, rooms and connections tabs
live in the shell's `IndexedStack` and stay mounted under whatever is on top.

There's one rule: **capture the container BEFORE the `await`** —
`refreshAfterAwait(context)` (`lib/shared/refresh_after_await.dart`),
a thin wrapper over `ProviderScope.containerOf(context, listen: false)`.
The container belongs to the root `ProviderScope` and lives as long as the
app. Every place where a refresh followed an `await` is done this way:
`_run()` and `_askToConnect()` on the room screen, `_run()` and the reply to a
connection request on the connections screen, unblocking, saving the name in
the profile, and creating a room.

The chat screen captures the container with the same helper, but for a related
reason: it needs to refresh the room list **on exit**, and by then there's
neither a `ref` nor a context to get one from. The refresh itself is also
deferred by a frame — Riverpod refuses to modify a provider from any widget
lifecycle method, `deactivate()` and `dispose()` included.

## Tapping a push

`send-push` also puts `data` into the FCM message: `kind` plus whichever ids
were found in the queue row's payload (`room_id`, `post_id`, `comment_id`,
`author_id`). Before that the ids only reached the Edge Function, and the
device got just the `notification`, so a tap opened the app on whatever screen
it had been left on, and you had to find what the push was about yourself.

Where each kind leads is decided by a single pure function on the client
(`pushTargetFrom()`), and its table is complete: `room_message` → room chat,
`post_comment`/`comment_reply` → the post's comments, `new_post`/`digest`/
`inactive_week` → feed, `app_update`/`app_update_important` and any unknown
kind → nowhere (the app is already open anyway, and updating doesn't happen
inside it). A kind whose id didn't arrive also leads nowhere: an empty screen
is worse than no screen.
Tapping a feed notification scrolls the main feed to the top and fetches a
fresh first page, even when the tab is already open.

The tap is handled by the app shell — the only widget that's always mounted
while there's a session. This matters for a cold start: the tap arrives before
the screen it's addressed to exists, and `getInitialMessage()` is queried
exactly once (the provider is not autoDispose — recreating it would reopen the
same screen).

Putting `data` into the message happens in the Edge Function, and that is
deployed separately from the app: without `supabase functions deploy
send-push` a tap will keep just opening the app, even if the client already
knows how to do more. See "Release" in [operations.md](operations.md).

## Presence and "typing…"

The server uses a private Realtime channel and two policies on
`realtime.messages`. See [the presence data model](data-model.md#typing-and-online).

The client announces itself with `track({user_id, typing})` while the chat is
visible. Backgrounding or covering the chat with an opaque route withdraws
presence and cancels typing. Sending, starting an edit and a four-second
input timeout clear typing. Moving the caret or restoring a stashed draft
leaves typing idle.

Every channel join reads the current typing state from the composer.
Announcements wait for a joined socket, and a failed acknowledgement is
retried while that connection and the desired state are current. The header
uses complete Presence sync snapshots. A channel error, timeout or close
clears the displayed state.

## Realtime doesn't replay what was missed

Postgres Changes is a stream, not a log: a subscriber receives what happened
while it was subscribed, and nothing else. And the socket drops every time the
app goes to the background — `supabase_flutter` itself does this. So a gap in
the conversation is not an edge case but what happens on every switch between
apps.

Nobody noticed this before: the chat screen could only load **older**
messages (a `before` cursor), so anything said while the app was in the
background never showed up in an open chat — until it was closed and reopened.
Deletions were lost the same way: removing a message arrives not as an insert
but as an update of an existing row, and nothing delivered that either.

The chat reloads the newest page when PostgreSQL confirms the live
subscription, including the first connection. Returning to the foreground
also requests a snapshot. If a snapshot is in flight when the subscription
becomes ready, a follow-up covers the interval. The same readiness signal
refreshes delivery and read receipts.

Only overlap with an earlier HTTP page establishes continuity. A live insert
on the far side of a gap leaves the latest page disconnected and older
pagination restarts at its boundary. The latest snapshot removes rows no
longer visible in its range, and retained older messages are rechecked by ID
through the same RLS policy. The client keeps newer Realtime revisions while
refreshing embedded quotes from HTTP.

The chat's reversed viewport keeps its origin on a message. Newer rows grow
on one side of the origin, with older history on the other. Incoming messages
and date labels keep the reading position and scroll momentum. The viewport
follows new rows when resting at the newest edge. A reply scrolls to a laid-out
original, or reanchors the viewport directly at a distant original.

## Confirming a room send

A draft gets a `client_token` on its first send. A retry reuses it as long as
the text, reply and attachments still match. The composer accepts confirmation
from either the insert response or a saved row with that token and author.
This handles a successful insert whose HTTP response is lost.

## Signed URLs outlive the widget

The `media` bucket is private, so no image is shown until its path is signed,
and signing is a network request. The asynchrony was the problem: a widget
that signs its paths in `initState` shows a spinner until the response — and
does so again every time its `State` is recreated.

The chat preserves keyed rows as new messages arrive. Rows can still be
recreated when they leave the viewport or the chat opens at a distant quote.
The cache (`lib/shared/signed_url_cache.dart`) gives a recreated row the same
signed URL before the first frame. `CachedNetworkImage` uses the bucket path
as its disk cache key. Signed URLs live in memory and are cleared on sign-out
because their access was granted to the current account.

## Mute as a feed filter

The only visibility rule enforced by the app rather than the database — and
that's why it's here and not in [data-model.md](data-model.md).

Since 20260829130000 mute plays no part in RLS at all: a muted person stays a
regular Connection, their profile opens and their posts are visible there.
Hiding them from the **general feed** is the job of the feed query itself:
`ConnectionsRepository.fetchMutedIds()` returns the list, and
`FeedRepository.fetchPage()` mixes it into the same `not.in.(…)` that already
filters out the system account.

The list is read once per load cycle, not per page: all pages hide the same
people, and the answer can't change mid-scroll. It's re-read by `_refresh()` —
and mute/unmute triggers exactly `feedRefreshTickProvider`, i.e. a refresh. On
a profile (`authorId` set) the query isn't made at all: there's nothing to
filter there, that's the whole point.

A failed read drops the page into the usual "couldn't load" with a fallback to
the cache, rather than substituting an empty set: quietly showing a feed full
of people you asked not to see is worse than an honest error.

Why this isn't a hole is in "Visibility rule" in [data-model.md](data-model.md):
a muted person remains a Connection whose `users` row and avatar the policies
have always shown. The privacy boundary was and remains blocking, and it lives
entirely on the server.
