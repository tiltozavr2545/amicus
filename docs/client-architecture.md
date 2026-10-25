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
- **Flutter version:** pinned to 3.32.8 (SDK in `~/development/flutter`) —
  nothing newer while the dev machine is on macOS 12; the full list of
  environment constraints is in [../AGENTS.md](../AGENTS.md)
- **Supabase API keys:** the new format is used (Publishable/Secret instead of
  legacy anon/service_role) — `SUPABASE_ANON_KEY` holds the Publishable key
  (`sb_publishable_…`); the Secret key is not used anywhere in client code

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

The server half — a private Realtime channel and two policies on
`realtime.messages` — is described in "["Typing…" and "online"](data-model.md)"
in data-model.md. The client half is this.

The client announces itself with `track({user_id, typing})` and clears the
flag in three ways: by sending, by leaving the screen, and by a 4-second timer
after the last keystroke. The last one exists exactly for the case when the
first two didn't happen — a draft abandoned mid-word shouldn't leave a lie on
someone else's screen.

**The announcement is repeated on every join, and its content is asked of the
screen.** Both conditions appeared after "typing…" turned out to show up only
every other time, and each closes its own half:

- *On every join.* Presence is a consequence not of subscribing but of
  `track()`. The socket drops when the app is backgrounded (`supabase_flutter`
  itself does this on `paused` and reconnects on `resumed`), and a recreated
  channel carries nothing over: until the client announces itself again, it
  isn't in the room, however long the screen has been open.
- *Asked, not assumed.* Previously a hardcoded `typing: false` was tracked on
  join. An announcement made before the channel came up isn't lost but
  **buffered** and sent on join — by a hook the channel registers in its own
  constructor, i.e. before our callback. So "typing" raised while joining
  arrived first and was immediately overwritten by the lie that followed it,
  and by then the screen already considered the announcement made and didn't
  repeat it on any later keystroke: the other person didn't see the indicator
  for the whole draft. Only the screen knows what's actually in the input
  field — so it's the one asked.

The flip side of the same rule: when the channel stops being up (error,
timeout, close), the screen receives two empty sets and removes the line.
Presence is a statement about "right now", and a list left over from a channel
that no longer exists is a lie that outlived the only thing that made it true.

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

The fix is re-reading the newest page, and whether it can be stitched on is
decided by its overlap with what's already loaded:

- **there is an overlap** — nothing was lost between the page and the list,
  new messages are appended on top, the rest are replaced in place (which is
  what brings in the placeholders of deleted ones);
- **there is no overlap** — a full page came back, and there may be more
  between it and the list; stitching it on would leave a hole in the middle of
  the conversation. The list restarts from this page: a lost scroll position
  is an inconvenience, a conversation with a silent gap is a lie.

There are two triggers, and the first is more precise: **channel
resubscription** (the request is sent after the subscription is live again —
the reverse order would leave a second gap between the request and the join)
and **the app returning from the background** as a safety net in case the
socket never comes back.

## Signed URLs outlive the widget

The `media` bucket is private, so no image is shown until its path is signed,
and signing is a network request. The asynchrony was the problem: a widget
that signs its paths in `initState` shows a spinner until the response — and
does so again every time its `State` is recreated.

In chat this happens all the time. The list inserts a new message at index 0,
all indices below shift, and `ScrollablePositionedList` builds through a
`SliverChildBuilderDelegate` that the package doesn't let you pass a
`findChildIndexCallback` to — so the element in a slot simply gets the *next*
message. The attachments key inside doesn't match, the `State` is dropped, and
a photo that has been on screen for ten minutes flickers a spinner and gets
signed again — once per visible bubble, for every message sent or received.

The cache (`lib/shared/signed_url_cache.dart`) fixes this at the root instead
of fighting the list: the recreated `State` asks **synchronously**, before the
first frame, and gets the same URL it had a second ago; `CachedNetworkImage`
draws from its disk cache (keyed by the bucket path, not the query string), and
there's neither a flicker nor a request. In memory only and for the lifetime of
the process: these are URLs to objects RLS showed to **this** account, so
`clear()` is called on them on sign-out along with the rest of its state.

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
