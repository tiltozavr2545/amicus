# Schema and the visibility rule

A snapshot of the current schema and its key invariants — for quick
orientation, not a substitute for reading the schema itself. For **why** things
are the way they are, start with the comment in
`supabase/migrations/20261018000000_baseline_schema.sql`, then the history
archive: numbers like `20260822170000`, scattered throughout this file, are
migration names in the `pre-baseline-migrations` tag
(`git show pre-baseline-migrations:supabase/migrations/20260822170000_*.sql`),
and numbers from `20260826000000` to `20261010100000` are in the
`pre-baseline-migrations-2` tag; then `git log`.

Tables: `users`, `connections`, `invite_links`, `posts`, `post_media`,
`profile_photos`, `reactions`, `comments`, `muted_users`, `blocked_users`,
`favorite_users`, `device_tokens`, `notification_outbox`,
`notification_preferences`, `user_activity`, `rooms`, `room_members`,
`room_messages`.

## App version and the update notification

`device_tokens.app_version`/`.app_build` is the version of the INSTALLATION,
not of the person: one user's phone and tablet can be on different versions.
They are written on every token upsert, i.e. on every app launch and every
language change (`registerDevice`), so they are always fresh. Decisions are
made only on `app_build` (versionCode, monotonic); `app_version` is for human
eyes. NULL means "older than anything known": a client that can't report its
version is by definition older than one that can. The client normalizes both
fields to the format the CHECK accepts (`shared/app_version.dart`) — otherwise
a constraint violation would bring down push-token registration itself,
silently, and every notification with it.

`device_tokens.platform`/`.os_version` (20260912100000) answer the same
question about the same installation: what it runs on. `platform` is an
enumeration (`android`, `ios`, `macos`, `windows`, `linux`, `fuchsia`, `web`),
not free text: it's the key audiences are built on, and "iOS"/"ios"/"iPhone"
in one column would turn any `group by` into a lie. `os_version` is digits and
dots only (`16`, `18.1`, `8.1.0`). The source is `device_info_plus`
(`Build.VERSION.RELEASE` on Android, `systemVersion` on iOS), and that's not a
matter of taste: on Android, `Platform.operatingSystemVersion` from `dart:io`
returns the BUILD identifier, not the OS version. On a real phone it turned
out to be `B4.1-260810-1153` on what was actually Android 16 — the number 16
isn't in the string at all, and parsing "the first number in the string" wrote
`260810` to the database. Storing the platform's raw response isn't an option
either: every platform has its own, and every reader would have to repeat the
parsing. Both fields are nullable for the same reason as `app_build`: shipped
versions don't know about them, NULL reads as "the client can't report it",
and the CHECK lets NULL through so a constraint violation doesn't bring down
token registration itself. The client normalizes — `shared/device_os.dart`,
the counterpart to `shared/app_version.dart`. Parsing the release is anchored
to the start of the string on purpose: the unanchored variant of the same
expression was exactly what produced `260810`.

`push_registration_status` (20260913120000) answers a question `device_tokens`
can't answer per device: **why** a person has no token. `registerDevice()` has
three exits that leave no row — permission denied, `getToken()` returned null,
and a failed upsert — and from the outside all three looked the same,
including the third, i.e. our own failure. There is one row per person (on
failure there is simply no installation identifier — the token is the
identifier), it is overwritten by an upsert on every launch, and the server
sets the time. The `platform`/`os_version`/`app_version`/`app_build` columns
duplicate `device_tokens` on purpose: there they only appear on SUCCESSFUL
registration, i.e. for people we already know everything about, while here
it's the only way to learn the version of someone who has no token. The
constraints are repeated verbatim so the formats don't drift apart.

The "please update" broadcast (kind `app_update`, setting
`notify_system_account`) is triggered by a human after a release — for how,
plus the list of pg_cron jobs and where the secrets live, see
[operations.md](operations.md).

## Reports and moderation

`content_reports` — what was reported and how it ended (20260913100000).
You can report a post, a comment, a room message, or a person, and only what
the reporter can SEE: the policy asks `can_report()`, the only moderation
function exposed to the outside. Calling `is_post_visible()` directly from the
policy isn't possible — the policy expression runs as the caller, and
`authenticated` deliberately doesn't have that function; hence the dispatcher.
One report per object per person (unique index); a repeat comes back as 23505
and the client reads it as "already sent". Nobody can read the table: there is
no SELECT policy at all, same as `notification_outbox`. `target_author_id` and
`target_snapshot` (500 characters) are filled in by a trigger — a report must
stay reviewable after the author has deleted what they wrote.

`hidden_at` on `posts`, `comments`, `room_messages` is reversible hiding.
Hidden content disappears for EVERYONE, including the author: otherwise one
object would have two answers to "is it visible", and the visibility rule
would stop being one rule. The condition lives in
`is_post_visible()`/`is_comment_visible()`, and from there it propagates on
its own to the comments under a post and to the storage policy for post media
(`post_media_path_visible()` goes through the same function). MESSAGE media
needed a separate fix: its branch in the storage policy was prefix-based ("the
object is in my room's folder") and knew nothing about the messages themselves
— a hidden message would have vanished from the chat while its photos stayed
reachable by direct link. The branch was rewritten from prefix to object via
`room_message_media_visible()` — the same technique as `is_room_peer_avatar()`
for avatars. In the SELECT policies of `posts`/`comments`/`room_messages` the
condition sits as a second copy deliberately: it's a literal on the row's own
column, not a restatement of the visibility rule, and the policies don't call
the rule for performance reasons.

`user_moderation.write_banned_until` is the write ban. NULL or a missing row
means "not banned", a date in the past means "the ban has ended"; there's no
need to clean it up, it doubles as history. It's a separate table rather than
a `users` column (20261019100000, IMM-541): the `grant select` on `users` is
table-wide, and before this migration the ban date was readable by anyone RLS
showed the profile to. A per-column grant instead of moving it out would have
broken the `select=*` the client loads profiles with. `user_moderation` has
neither grants for `authenticated` nor policies — only the console under
service_role and definer functions read and write it.
**The check lives in the `reject_write_when_banned()` trigger, not in INSERT
policies** — see "The write ban is enforced by a trigger" in
[../AGENTS.md](../AGENTS.md); that's also where it explains why it can't be
done otherwise. The trigger is attached to seven tables with a single body;
the row's author is taken from `NEW` via `to_jsonb` (the column is named
differently in each) and it rejects with its own SQLSTATE `AMB01` with the end
date in DETAIL, so the client can tell a ban from a policy denial and from a
network error and show the date (`shared/write_ban.dart`).

What exactly is banned, since 20260924100000: **creating a row in these seven
tables, plus two UPDATEs** — `posts.text` and `users.name`. Both are reachable
via a direct PATCH through PostgREST, and before this migration a banned user
could freely rewrite the text of any of their posts and change their name,
which is visible to all their Connections and in all their rooms. The edit
triggers are per-column (`before update of text` / `before update of name`),
and that's not an optimization: `hidden_at` isn't in the list so the console
can hide a post by an author it has itself banned, and neither is
`avatar_path`, so a banned user can delete their own photo (deletion rewrites
the column via the gallery-sync trigger, and a full BEFORE UPDATE would reject
it). For `users` the row's author is its `id`, so the `coalesce` chain in the
function body has a separate branch on `tg_table_name`: an unconditional `id`
as the fifth element would check "the ban of the user whose id equals the
post's".

What the ban does NOT cover: `rename_room()` and `set_room_avatar()`. `rooms`
has no author column at all (the owner is the lowest `seq` in `room_members`),
so the shared function body wouldn't find it, and a separate copy of the rule
is exactly the path by which "the visibility rule lived in four copies". A
room's name is visible only to its members, i.e. to a circle the banned user
already assembled themselves.

The login ban is stored not here but in GoTrue (`ban_duration`), and the schema
deliberately keeps no copy of that fact: it would drift from the real one the
first time a ban was lifted through the dashboard.

All of this is reviewed in the local console under service_role. There is no
moderator role in the DB, and no moderator RPCs either: every function in
`public` is a PostgREST endpoint, and the only consumer, which bypasses RLS
anyway, doesn't need an endpoint.

## Visibility rule

**One visibility rule for the whole project** — `is_author_visible(uuid)`:
myself, the Amicus system account (`is_system_account()`, the only hardcoded
exception — 20260818150000; the literal itself lives in
`system_account_ids()`, which 20260821160000 introduced for the client so the
feed wouldn't carry a copy of that id in the APK, and 20260822220000 also made
the single source on the server: `is_system_account()` now asks it rather than
its own second literal), or a Connection with no block in either direction.
It's consulted by the SELECT policy on `posts`, `reaction_summary()`, both
`comments` policies (via `is_author_of_comment_visible()` — it returns a
strict boolean, not NULL, otherwise `null`/`false` would be distinguishable
from the outside and act as an oracle for row existence, 20260821130000) and
the storage policy for post photos.
**Change it only in this function.** The rule used to be duplicated in four
copies, two of which fell behind on mute/block and became holes — see 0.11.0
in [../CHANGELOG.md](../CHANGELOG.md); the same thing happened a third time
with the mute and connection halves of the rule in separate places — see
0.13.2 there.

**Mute no longer takes part in this rule** (20260829130000). Before that, the
condition read "a Connection I haven't muted and with no block", and mute hid
the person COMPLETELY — including their own profile: you tap a connection's
avatar and an empty page opens, which reads as "they have no posts" or "they
blocked me". It lied because of my own personal setting, which they don't know
about and didn't make.

Now **mute means exactly two things: not in the general feed and no pushes**,
while a block remains a wall and the only privacy boundary. They had to be
separated because RLS doesn't know about screens: the feed and the profile are
one and the same `select from posts`, the only difference being the client's
`.eq('author_id', …)`. So either the rule stops asking about mute, or the
profile gets a second copy of the rule — and that's exactly the mistake the
rule was consolidated into one function to avoid. So "what's not in the feed"
moved into the feed query itself — how exactly is in
[client-architecture.md](client-architecture.md).

A consequence to keep in mind: **mute is not a privacy boundary and must not be
treated as one** — the client enforces it, and a modified client may not apply
it. Nothing private is exposed by this: the muted person is still a
Connection, whose `users` row and avatar the policies have always shown
(`is_connected_to_caller()` never asks about mute). A block is entirely
server-side and works both ways.

`has_muted()` is still alive and remains in exactly two places, both about
notifications: `enqueue_post_notifications()` (the favorites branch and the
digest count) and `enqueue_comment_notifications()`. Muting someone and still
getting their pushes would make no sense.

The rule's building blocks are three small predicates, each reused rather than
rewritten inline:
- `is_blocked_pair(a, b)` — a block in either direction.
- `has_muted(muter, muted)` — directional; unlike a block, not symmetric;
  since 20260829130000 only notifications ask it.
- `are_connected(a, b)` — whether there's a Connection.

All three are `security definer`, but **not granted** to `authenticated`
directly (except via another `security definer` function): both arguments are
arbitrary, so a direct grant would answer someone else's question "are these
two muted/blocked/connected to each other" — which is exactly how
`is_blocked_pair` was a hole before 0.11.0. For the only place where such a
check is needed in a raw RLS policy (`users`, "visible to self, Connections,
the system account and one's own commenters"), there's a one-directional
wrapper `is_connected_to_caller(other)` — one argument, always compared
against `auth.uid()` internally, so it's safe to grant.

`is_author_visible()` itself is **not** granted to `authenticated` either
(20260826120000): all its calls are inside `security definer` functions, i.e.
run as the owner, and no policy uses it — the grant served nothing and only
published a superfluous `/rpc/is_author_visible` endpoint.

In policies, the `is_author_visible`/`is_blocked_pair` family is used as
`author_id in (select visible_author_ids())`, not as a per-row call — see
"Pitfalls" in [../AGENTS.md](../AGENTS.md) (`security definer` isn't inlined by
the planner). `visible_author_ids()` itself gets the system account by
calling `system_account_ids()` directly, not by scanning `users` with a
predicate on every row (20260822250000): the branch's answer is a constant
list, and the cost shouldn't grow with the number of registered users.

**Post visibility is required on both reaction write paths, not just on
INSERT.** The UPDATE policy on `reactions` lacked this requirement until
20260822230000, and the `dislikes_disabled` guard sat on it too: the guard is
written as a subquery on `posts`, which runs with the caller's rights and is
therefore itself filtered by the `posts` policy. Post not visible — subquery
empty — the guard reads that as "no flag". And you could hide someone's post
from yourself on your own: back then mute still removed the author from the
visibility rule, so it was enough to like a post, mute the author, and switch
your own row to `dislike`. (Today the same hole can't be exploited that way —
mute has left the rule, see above — but the requirement on UPDATE is no less
mandatory for it: a post can also be hidden by a block.) The same class as the
`blocked_users` hole from 0.11.0: RLS also applies to subqueries inside a
policy.

**The Connections list is private, and that's a decision, not a gap** (IMM-216,
2026-10-19). The SELECT policy on `connections` returns only rows where you
are one of the parties, and there is no "so-and-so's connections" screen. The
visibility rule is built so that other people's connections don't leak through
indirectly either: under a connection's post you see comments only from YOUR
Connections, and a non-connection's profile isn't visible at all. The only
residual signal is a room: its members see each other and know that the owner
gathered them from their own connections (`add_room_member()` requires a
Connection). It was decided not to build a "who can see my contact list"
feature. Any new place that shows other people must be checked for whether it
reveals who a third party is connected to.

## Rooms

A room is a separate chat for the people invited to it. Introduced by
20260826180000 — back then still as a feed; 20260828100000 removed the feed,
keeping the chat ("The room stopped being a feed" below).

`rooms` / `room_members` / `room_messages`.

**A room has no `creator_id`.** The owner is the member with the lowest `seq`
(`room_owner_id()`), i.e. whoever joined earliest among those remaining. So
"the creator left — rights pass to the oldest member" happens on its own:
deleting the row in `room_members` IS the transfer of rights; there's no
separate trigger and no separate column that someone could forget to update.
`seq` is an identity, not `joined_at`: `create_room()` inserts everyone in one
transaction, where `now()` is the same for all rows, so "who came first" by
time couldn't be resolved at all. The owner renames the room, adds and removes
members; anyone can leave on their own. All four owner RPCs (`rename_room()`,
`add_room_member()`, `remove_room_member()`, `set_room_avatar()`) answer
**with the same `PT404` both for "no such room" and for "exists, but isn't
yours"** (20260905100000) — the same principle as `delete_own_comment()` and
`delete_own_room_message()`. They used to differ (`PT404` vs. `PT403`), and
`security definer` carries the question past RLS, so the response code let you
tell a live room from a made-up one by brute-forcing uuids. Both checks are
folded into one: `room_owner_id()` returns NULL for a nonexistent room, and
`is distinct from auth.uid()` is true in both cases at once. The check is
specifically `is distinct from`, not `not owns_room(...)`: with the latter,
NULL yields NULL, the branch doesn't fire at all, and without an existence
check above it the call would carry on with a nonexistent room — exactly that
trap lived in `set_room_avatar()`, masked by the order of the checks.

**A two-person room isn't a "small group" — it's a different entity.**
`is_direct`, no name at all (`rooms_direct_shape` requires `name is null`):
each side sees the other member's name, and the client assembles that name
(`roomDisplayName()`), not the database. A third person can't be added, and it
dies when either side leaves — a room for one with someone else's
conversation inside is of no use to anyone. There's exactly one pair per room:
`direct_a`/`direct_b` (ordered by `least`/`greatest`, like
`connections_ordered_pair`) under a unique partial index — denormalization for
the sake of an invariant that can't be expressed through `room_members` at
all. It also makes `create_room()` idempotent for a direct room: a repeated
call returns the existing one. A group room without a name is called by
listing its members — that's also computed on the client, because storing the
list would freeze it: names change, and so does membership.

A direct room does have an owner in the schema (it's just the lowest `seq`;
the schema has no "ownerless" case), but **the UI doesn't show it**: there's
nothing for the owner to do there — no adding, removing or renaming — and a
label next to one of the two names would only raise the question of why it's
there.

**The room stopped being a feed** (20260828100000). For a day and a half a
room had two halves — its own feed and its own chat — and the post visibility
rule had two branches: "a general-feed post whose author is visible" OR "the
post is in my room". The chat caught on; the second branch remained something
every new post-related feature has to remember, and they don't always —
20260826190000 closed exactly such a finding a day after it was applied. So
room posts were deleted, `post_rooms` and `posts.in_general_feed` were dropped,
the visibility rule was folded back into a single branch, and post targeting
returned as a visibility setting on the post itself rather than a room — "Who
can see a post" below (20260829100000).

The branch also existed in COMMENT visibility — "the comment's author is my
roommate", `is_comment_author_room_peer()` — and that's where a landmine
turned up: its first conjunct was `post_in_my_rooms()`, dropped by the same
migration, and the body of a `security definer` function is resolved at
runtime. So reading comments would have failed with 42883 for everyone the
first branch didn't cover. A simulation caught it right after the migration
was applied; both copies of the rule (the `comments` policy and
`is_comment_visible()`) went back to their pre-rooms text.

**Mute and block don't apply inside a room** — a conscious decision: you
joined the same room, so you see each other. The only thing a block still does
is prevent ASSEMBLING a room with the person it's against (`create_room()`,
`add_room_member()`); it doesn't touch an existing room.

Hence a consequence that's easy to miss: room members don't have to be
Connections **of each other** — the owner gathered them from THEIR OWN
connections. So room membership alone isn't enough to see even the other
person's name, and `shares_room_with_caller()` is asked in two places: the
`users` policy (otherwise a chat message would have no author name) and the
avatar storage policy (otherwise an empty circle). In the second place — not
directly, but via `is_room_peer_avatar()`, which narrows the answer down to a
single object; why is covered in "Storage" below.

Post photos are a trace rooms left behind (20260826190000). The object path —
`posts/<author_id>/…` — knows only the AUTHOR, and before rooms that was
enough: all of an author's posts lived in the general feed, so "the author is
visible" meant "their files are visible too". With room feeds that stopped
being true, and a connection of the author who wasn't invited to the room
could open the photo file of a post addressed only to the room (while not
seeing the `post_media` row or the post itself). Since then the storage policy
goes from the path to the POST (`post_media_path_visible()` →
`is_post_visible()`), not to the author, and it stays that way: one copy of the
rule is better than two, even after the branch it was introduced for is gone.
The author's own branch (`foldername[2] = auth.uid()`) remains first and
deliberately doesn't require a `post_media` row: the client uploads files
BEFORE the post exists, and without it the author couldn't open what they just
uploaded.

### Room avatar

`rooms.avatar_path` + the `rooms/<room_id>/…` prefix in the `media` bucket
(20260826210000). Group rooms only: a direct room is the other member, and its
avatar is theirs.

The difference from `avatars/<user_id>/…` and `posts/<author_id>/…` is that
the second folder here isn't a user but a room, so the permission is computed
not by comparing with `auth.uid()` but by asking "do I own this room" —
`owns_room()`. It's a one-directional wrapper over `room_owner_id()` for
exactly the same reason `are_connected()` has `is_connected_to_caller()`:
`room_owner_id()` itself answers about ANY room and is therefore not granted to
the client, while the wrapper answers about the caller and is safe to grant
(without the grant it couldn't be called from the storage policy).

The CHECK on the column holds both invariants at once: a direct room has no
avatar at all, and the path always lies under ITS OWN room's prefix. The
second isn't decoration: without it the owner of one room could write a path
to another room's file, and a member's client would dutifully go download it.

In the UI, a group room without its own picture shows a neutral icon, **not
the avatar of one of its members**: a borrowed face reads as "this is that
person" — the row looks like them, and tapping it used to open their profile —
even though they were picked only because they joined before the others. A
member's face stays with the two-person room, where it effectively is the room.

The path is written by the `set_room_avatar()` RPC, not an UPDATE policy: a
policy can't restrict WHICH columns change, and along with the avatar it would
open up `is_direct` and the `direct_a`/`direct_b` pair, which direct-room
uniqueness rests on. The RPC returns the orphaned path — the client deletes the
object after writing the row, as everywhere else: the "rows first, then
objects" rule and its reason are in
[client-architecture.md](client-architecture.md); the client enforces it.

### Room chat

`room_messages` + `room_members.last_read_at` (20260826200000).

There's no separate visibility rule for a message: a message is visible to
whoever is in the room — `room_id in (select my_room_ids())`, and that's it.
Neither mute nor block narrows it, and that's the only sensible option: holes
in a conversation read worse than the presence of an unpleasant person.

**Deletion is a tombstone (`deleted_at` + empty text), not a `delete`.** The
reason isn't only that comments work the same way: a realtime subscription
delivers DELETE without the row's contents (replica identity default — key
only), so there's nothing to check RLS against, while UPDATE arrives as the
whole row and is filtered by the policy like a normal read. Blanking a row via
UPDATE is the same as removing it, just without the blind spot. The table has
no UPDATE or DELETE policies at all: the only path is
`delete_own_room_message()`, where the tombstone is set atomically together
with clearing the text (an UPDATE policy can't restrict WHICH columns change,
and would open up editing your whole row, including `created_at`, which unread
counts are based on).

**Unread state lives on the member row** (`last_read_at`), not in a separate
table: that would repeat `(room_id, user_id)` one-for-one. `default now()` — a
new member doesn't inherit the entire conversation as unread. Your own messages
are never counted as unread.

**Per-message read/delivered uses the same technique** (20260827100000).
Next to `last_read_at` there's `last_delivered_at`, a second marker on the same
`room_members` row; here too there's no separate table for a specific
message's status — the client does the comparison: a message has been read by
a member if their `last_read_at` is no earlier than the message's `created_at`
(likewise for delivery). Checkmarks are drawn only on YOUR OWN messages (others
reading yours isn't the same thing as you reading theirs), and in a group room
as an aggregate "read N/M" across all the "other" members rather than an icon:
an icon can't say "3 of 5".

"Delivered" in this app doesn't mean "reached the device" — there are no push
delivery receipts here, and adding them for one checkmark isn't worth it. The
meaning is weaker: `mark_rooms_delivered()` advances `last_delivered_at` in all
of the caller's rooms at once and is called on every load of the room list
(`my_rooms()`) — the very fact that the client successfully synced the list is
the only "delivered" signal this app has without its own push-acknowledgment
infrastructure. Reading still advances both markers at once
(`mark_room_read()`) — something read can't be undelivered.

But only in rooms where there's something to deliver (20260923100000): where
there isn't a single live message from someone else newer than the marker, the
row isn't rewritten. Advancing it there is unobservable anyway — a message
older than the marker counts as delivered no matter how much further you move
it — but it was expensive: the `room_members` row is published to realtime (see
below), so every rewritten row woke up all members of that room. An
unconditional UPDATE across all rooms on every list load turned into a fan-out
broadcast, and the more shared rooms people had, the more a single message
cost — mutually, since other people's loads woke us up in exactly the same way.

`room_members` was added to the realtime publication as the second (after
`room_messages`) use of this mechanism in the project — with the same SELECT
policy as a normal read, so the sender's checkmark can flip while they're
still looking at the screen, and someone else's room still can't leak past RLS.

**Realtime** — its first use in the project: `room_messages` was added to the
`supabase_realtime` publication. Postgres Changes checks the subscriber's
SELECT policy for every row, so other people's rooms won't leak through the
subscription — the rule is the same as for a normal read.

`my_rooms()` was recreated for the chat (drop + create: `create or replace`
isn't allowed to change OUT columns) and now also returns the last message and
the unread count — the room list is also the chat list.

### Replying to a message

`room_messages.reply_to_id` is a nullable self-reference to `room_messages(id)`
(20260911100000), `on delete set null`: message rows are never physically
deleted (see the tombstone above), so this branch doesn't fire in practice, but
a reply will survive the original disappearing if that rule ever changes.
There's no reverse index ("which messages reply to this one") — a quote is
always resolved by id, and the client never searches in the reverse direction.

The INSERT policy checks not only `room_id IN my_room_ids()` (already there),
but also that `reply_to_id`, if set, points to a message FROM THE SAME room —
otherwise you could quote another room by a guessed uuid. This check goes
through the `security definer` function `room_message_in_room()`, not a bare
`EXISTS` right in the policy: a subquery on `room_messages` inside its own
policy broke the insert of ANY message with `42P17 infinite recursion` on the
first apply — "A subquery against the table's OWN self" in
[AGENTS.md](../AGENTS.md).

The client resolves the quote differently depending on where the row came
from: `fetchMessages`/`sendMessage` ask PostgREST for an embed
(`reply_to:reply_to_id(...)` — the bare FK column, without a table name:
PostgREST doesn't resolve a self-reference through the usual form
`room_messages!reply_to_id`, see above) and get a ready preview right in the
response, while Postgres Changes delivers only the raw `reply_to_id` column
without a join (Realtime can't embed) — then the screen looks for the original
in the already-loaded message list itself, and if it doesn't find it (the page
containing it hasn't been loaded yet), it draws "Original message unavailable"
instead of a blank or a crash.

### Media in a message

`room_messages.media` is a jsonb array of up to 10 elements (20260828120000).
**The only place in the project where media is stored as a column rather than
as rows**, and that's not sloppiness but three separate answers to "why is it
different for posts":

- **Realtime delivers a ROW.** The subscriber receives `room_messages` and
  nothing else. Rows of a second table would arrive in a separate query, which
  the subscription doesn't have — and a bubble with a photo would show up empty
  for everyone else until they reopened the screen.
- **The CHECK can finally be expressed.** "Empty isn't allowed: either text or
  attachments" is a condition on ONE row if the media is in that same row. For
  posts the same rule had to be checked procedurally inside
  `create_post_with_media()` (20260823120000) precisely because `post_media`
  rows arrive separately and the CHECK can't see them.
- **No reverse path from file to row is needed.** For posts, the storage policy
  goes from the path to the `post_media` row and on to the post
  (`post_media_path_visible()`), because post visibility is computed. For a
  message, visibility is room membership, and the room is written in the path
  itself. The `storage_path` indexes the post table exists for aren't needed
  here at all.

The array's shape is enforced by a CHECK via `room_message_media_ok(room_id,
author_id, media)` — a CHECK itself can contain neither a subquery nor
`jsonb_array_elements`, but an immutable function can. It also checks the PATH
of every element, and checks it on the row rather than in the INSERT policy:
the policy constrains the caller, the CHECK constrains the row itself, and the
rule will outlive a future `security definer` function that starts writing
messages bypassing the policy. It's the only function in the project granted
to `authenticated` not to be called from the client but because a CHECK is
evaluated with the writer's rights; that's safe because it touches no table and,
as an endpoint, only answers the question "is this json well-formed".

Since 20260829110000 it also enforces SIZE: no more than 400 characters per
path and no more than 8000 bytes for the whole column. Before that, `media` was
the only client-writable column in the schema without a ceiling (`posts.text`,
`comments.text`, `room_messages.text` — 5000 each, `users.name` and
`rooms.name` — 100) and the only one that goes out not in response to a
request but on its own: `room_messages` is in the realtime publication, and the
subscriber receives the ROW. Ten paths, each starting with a legitimate prefix
and continuing with a megabyte of padding, were broadcast to the whole room in
a single send and could be repeated at will. The numbers have a twofold margin
over the honest maximum: the longest legitimate path is 161 characters (168
for a poster), and ten elements with all fields come to about 3970 bytes.

Sending remains a plain `insert` — no RPC was needed, there's nothing to insert
but one row — while `delete_own_room_message()` now also removes attachments,
returning the orphaned paths: the client deletes the objects AFTER writing the
row (`deleteRowsThenObjects`), as everywhere else.

### Editing a message

You can edit your own message for 48 hours after sending — both text and
attachments (20261019120000, IMM-208). There's one path —
`edit_own_room_message(id, text, media)`, not an UPDATE grant: a policy can't
restrict columns and would open up `created_at`, which unread counts and
checkmarks are based on — the same reason deletion is an RPC. The edit reaches
everyone else as a regular realtime UPDATE, as the whole row.

- **`room_messages.edited_at`** is set only by the RPC; the client draws
  "edited" from it. Previous versions aren't stored. An edit with no changes
  isn't an edit: an empty response, `edited_at` doesn't move.
- **The window is counted from `created_at`**, not from the previous edit,
  otherwise editing once every two days would keep it open forever. Rejection
  is its own SQLSTATE `AME01`, so the client can say "time's up" rather than
  "something went wrong".
- **Responses** are the same as for deletion: "doesn't exist", "someone else's"
  and "hidden by moderation" are all one PT404; the author can see the
  tombstone of a deleted message, and for that it's PT422.
- **Attachment shape and non-emptiness are enforced by the row's own CHECKs**,
  which fire on UPDATE just as on insert — there's no second copy of the rules
  in the function. Removing everything from a message is a deletion, not an
  edit.
- **Attachments**: the client uploads new files before the call, under the
  same `messages/<room>/<author>/` prefix; the function returns the paths the
  edit removed, and the objects go after the row (`deleteRowsThenObjects`).
  An upload that never reached the RPC is orphans for `reap_orphaned_media()`.
- **Ban**: an edit is also a write, so `room_messages` has a per-column
  `before update of text, media` with `reject_write_when_banned()`. With the
  condition `when (new.deleted_at is null)`: deletion rewrites the same
  columns, and you're allowed to delete your own content while banned.
- **The quote in a reply** takes the original from the loaded list first and
  only then from the embed: the embed is a snapshot at load time and would keep
  quoting words the author has already edited.

### "Typing…" and "online"

Neither a table nor a column (20260828130000): both live exactly as long as
the screen is open, and a value that goes stale a second after being written
has nowhere to be stored — Realtime presence keeps it in memory and
distributes it to subscribers itself. Hence the feature's boundary: "online"
here means "in this chat right now", not "has opened the app", and "last seen
at 12:40" can't be done this way — that needs a `last_seen_at` column and a
separate conversation about privacy.

**The channel is private, and that's the main point.** A regular Realtime
channel is open to anyone who knows its name: presence and broadcast, unlike
Postgres Changes, check RLS on nothing — they don't read anything from tables
either. A private one does check: subscribing and sending go through
`realtime.messages`, which has RLS enabled but, until now, not a single
policy, i.e. private channels were forbidden entirely. Now there are two, and
both ask the same thing: `is_my_room_topic('room:<uuid>')`. The regex before
the type cast there isn't decoration — the topic arrives as a string from the
client, and `'room:мусор'::uuid` would be not "false" but an error inside the
policy; `case` also provides an evaluation order you can rely on, unlike `and`.

Postgres Changes channels (`room_messages:…`, `room_members_receipts:…`)
remain public and aren't affected by these policies: they have their own
check, per row, by the same SELECT policy of the table.

How the client announces itself and when it clears the flag is in
[client-architecture.md](client-architecture.md), in the section on presence.

### Room notifications

One kind (`room_message`) and one setting (`notify_room_messages`).
There used to be two — the second notified about a post in a room — and they
went away together with room feeds (20260828100000): a setting that turns
nothing off is worse than a missing one, because it's visible.

Three safeguards without which a chat turns into noise:
- **the room is muted personally by this person** —
  `room_members.notifications_muted` (20260828110000), a third marker on the
  same row and for the same reason as the first two: the "person ↔ room"
  relationship is already described by that row, and a separate table would
  repeat its key. The global setting answers "do I want chat pushes at all",
  the flag — "do I want them from THIS chat". Mute is about pushes and only
  that: unread counts are still computed and the badge on the list row stays,
  because muting a room and no longer reading it aren't the same thing. The
  flag is written by `set_room_muted()`, not an UPDATE policy: a policy can't
  restrict WHICH columns change, and would open up `last_read_at` and
  `last_delivered_at` — the very ones unread counts and checkmarks are based
  on (`room_members` has no UPDATE grant at all). **The flag is NOT hidden from
  the room's other members, though**, and the doc comment in
  `rooms_repository.dart` claimed the opposite until 20260924100000.
  `room_members` is readable by every member of the room (the same policy the
  room list uses to get names and avatars), and the SELECT grant there is
  table-wide — so a fellow member who queries this column will get it. The app
  doesn't query it (`fetchMemberReceipts` selects three columns, and this isn't
  one of them), but "nobody looks" and "nobody can" are different claims. The
  fix is: `revoke select on room_members` and a per-column
  `grant select (room_id, user_id, joined_at, last_read_at,
  last_delivered_at, seq)`; `my_rooms()` won't suffer, since it's `security
  definer` and runs with the owner's rights. Deliberately not done in
  20260924100000: `room_members` is in the realtime publication that carries
  the "delivered/read" checkmarks, and how realtime behaves with per-column
  grants can only be verified with a live client — breaking working
  checkmarks over this without such a check isn't worth it;
- **the person is in this chat right now** — the screen marks every incoming
  message as read, so a fresh `last_read_at` (less than a minute old) means
  "reading right now", and no push is queued;
- **the queue collapses** — until the previous notification from this room
  has gone out, a second one isn't created; otherwise a chat that comes alive
  turns into a queue of forty identical pushes arriving all at once.

The room name is deliberately absent from the push text: it's different for
each person (for a room without a name — a list of the other members), the
client assembles it, and a second copy of that rule on the server would drift
from the first at the very first rename. The payload carries `room_id` — that's
what opens the chat on tap.

### Tapping a push

The schema has nothing to do with it: `send-push` puts into `data` the same ids
that are already in the queue row's payload, while where each kind leads and
who handles the tap is app behavior — see "Tapping a push" in
[client-architecture.md](client-architecture.md).

## Who can see a post

`posts.visibility` is `'connections'` (all connections) or `'favorites'`
(only the author's favorites). Introduced by 20260829100000, replacing
addressing posts to rooms, which was removed a day earlier.

The difference between the two is the whole point of the swap: a room is a
GROUP, a separate place with its own membership and its own feed, while
visibility is a property of THE POST ITSELF. The former needed a second table,
a second feed and a second branch of the rule living a life of its own; the
latter needs a column on the post row, visible right where everything else
about the post is.

**The "favorites only" audience is the AUTHOR's favorites list**
(`favorite_users` where `user_id` = the author). There is no separate "close
friends" table: the list already exists, it already means "these people are
closer to me than the rest", and a second, identical collection next to it
would force everyone to remember which one is for what. A side effect worth
saying out loud: until now favorites were PURELY PERSONAL — "I want a push
about their posts"; the other side didn't know about it and didn't depend on
it. Now it is also an audience, and that changes not only post visibility but
the privacy of the list itself. 20260829100000 claimed that "you still can't
find out that you are in someone's favorites"; **that stopped being true at
the very same moment**, and it's better to say so plainly than to repeat a
dropped invariant. `authors_who_favorited_me()` is granted to `authenticated`
and has to be (see below), and with no arguments it lists everyone who has
added the caller. So anyone can find out whose favorites they are in — only
about themselves, but as a complete list.

So the invariant reads: **someone else's favorites list is closed; your own
"who added me" is open to you**. `favorite_users` rows are still visible only
to their owner, the "Favourites only" badge is drawn only for the post's
author, and nobody can ask "does X have Y in favorites". This is the price of
the audience, not an oversight: as long as someone else's list decides what a
person sees, there is no way to hide from them the fact of being on it.

The twelfth audit (20260829110000) closed the other half of the same story:
`is_favorited_by()` was granted to `authenticated` as a dead grant and
answered "does p_author have me in favorites" for ANY p_author. It was
superfluous because its only caller is `is_post_visible()`, itself
`security definer` and granted to nobody, so inside it the call runs with the
owner's rights. Same class as the dead grant on `is_author_visible()`
(20260826120000), but unlike that one, not harmless.

The rule is two-branched again and again written **in two places and only
two** — the `posts` SELECT policy (inline) and `is_post_visible()`, which is
asked by `is_comment_visible()`, `reaction_summary()` and
`post_media_path_visible()`. Both have to be changed. Everything else — media,
comments, reactions, files in Storage — goes through a nested
`exists (select 1 from posts …)` and picks up the new rule automatically.

There are also two favorites predicates, the same duo as
`visible_author_ids()`/`is_author_visible()`: the set
`authors_who_favorited_me()` for the policy (an uncorrelated `IN (SELECT …)`
is hashed once) and the scalar `is_favorited_by()` for per-row callers.
Both are `security definer` for the same reason `is_blocked_pair()` became one
in 0.9.0: RLS on `favorite_users` only lets you reach your own rows, so a
subquery against SOMEONE ELSE's favorites inside the policy would filter down
to nothing — and a "favorites only" post would be visible to nobody,
including the favorites themselves.

Their grants are DIFFERENT, and that's not duo symmetry but a difference in
who calls them. `authors_who_favorited_me()` is granted to `authenticated`
because it sits in the `posts` SELECT policy, and the policy is evaluated with
the reader's rights: revoking the grant means turning the feed off for
everyone. `is_favorited_by()` is granted to nobody — its only caller is itself
`security definer` and runs as the owner (20260829110000). The rule "every
argument is about the caller themselves" was formally satisfied here and would
have let both through; what tells them apart is whether the function has a
caller that needs the grant at all.

**The author always sees their own post** — and that's a separate line in
both copies of the rule, not a consequence of the first branch. A simulation
right after rollout caught it: the author saw four of their five posts,
because they would only pass the second branch by having themselves in
favorites.

Notifications are computed by the same rule, and the lists here are
DIFFERENT: the "new post" push goes to those who added the AUTHOR, while the
post is visible to those the author added. Without an explicit condition in
`enqueue_post_notifications()` the push would go to someone who won't be shown
the post; for the same reason the digest counts only what's visible — luring
someone into the feed with a count of posts they won't find there is worse
than not luring them at all.

The column is written only by `create_post_with_media()` and
`update_post_with_media()`; there are no INSERT or UPDATE grants on it. On
edit the default is `null` ("leave as is"), not `'connections'`: a client that
doesn't know about visibility edits the caption of a "favorites only" post —
and must not expose it to everyone through that edit.

**A publish retry that narrows the audience withdraws its pushes**
(20260905100000). `enqueue_post_notifications()` is AFTER INSERT, and only
INSERT, while the `on conflict` branch in `create_post_with_media()` is an
UPDATE. So an "all connections" publish that committed after `.timeout()`
stopped waiting for it manages to fan out `new_post` to everyone who has the
author in favorites; meanwhile the composer stays open with a live token and
an editable toggle, and the next tap — now with "favorites only" — changed the
column without touching the queue. The "Petya has a new post" push reached
someone who won't be shown the post: exactly the leak the visibility condition
in the trigger itself was introduced to prevent. Now a retry that leaves the
post "favorites only" deletes from `notification_outbox` the not-yet-sent
`new_post` entries about THIS post for everyone not in the author's
favorites — that is, it brings the queue to what the trigger would have done
had it known the final audience.

It has three limits, named out loud: what's already sent
(`sent_at is not null`) is left alone — a push can't be recalled; `digest` is
not touched at all — it doesn't name the post but counts posts, so a narrowed
audience makes its number one too high, and that's an inaccuracy, not a leak;
the reverse move (a retry that WIDENS the audience) adds no notifications —
one publish, one push, and a missed push is cheaper than an extra one.

## Connection requests

`connection_requests` (20260828140000) is the second way to make a Connection
and the first one that doesn't require meeting in person. The first way, the
invite code (`activate_invite_link()`), remains the main one: a connection in
this app is about people you know personally.

**A request can be sent ONLY to someone you share a room with.** It's a narrow
door, and that's the whole idea: a room is assembled by its owner from THEIR
connections, its members don't have to be each other's connections, and people
already sitting in the same chat had no way to exchange a code until now. No
directory, no people search and no way to message a stranger appears from
this — the condition is checked server-side by `shares_room_with_caller()`.

**The pair is ordered, unlike `connections`**: a request has a direction, and
who asked whom is an essential part of it. Uniqueness is on
`(requester_id, recipient_id)` — that is, **one request per DIRECTION, ever,
in any status**, not one per pair: a decline is final for the declined
direction, because the ability to ask again turns a decline into a
negotiation, but someone who changed their mind sends THEIR own request in the
opposite direction, and the same index lets it through — that's their own
decision, not a repeated ask.

The wording "one per pair" also appeared in the header of 20260828140000,
where it referred to "a second, symmetric index below". There is no such index
and there must not be: it would forbid exactly the reverse move that the very
next paragraph there calls legitimate. The correct reading is directional, and
it matches what is in the schema. The migration header was retroactively
brought in line with it (20260905100000, the thirteenth audit): only the
comment text was edited, the DDL there didn't change — the directional index
had been in the schema from the start.

A counter-request isn't created but accepted: two people who asked each other
both agree, and making one of them also press "Accept" would be ceremony for
ceremony's sake (`request_connection()` returns `connected` in this case).

A block and the absence of a shared room answer with the same PT403:
distinguishing them would answer the question "did they block me?", which a
block must hide. The block is also checked on ANSWERING — it could have
appeared after the request was sent.

A decline doesn't produce a notification: telling someone "you were declined"
turns a quiet decline into an event. The sender will see it themselves — the
"Ask to connect" button won't come back for them. This is held on the client,
and it wasn't always: the screen read only requests with status `pending`, so
a declined one disappeared from the list along with the silence, the button
came back — and answered PT409 forever, because the index will never allow a
second row in the same direction. The client now fetches ITS OWN requests in
any status (`fetchRequests()`), and "the button won't come back" describes the
code, not an intention. Both kinds (`connection_request`,
`connection_accepted`) have no opt-out setting, the only such ones besides
`app_update`: a request is addressed personally and arrives once every few
months, and "I will never find out again that someone asked me" is not a
choice worth offering.

## Comments

Nesting is **exactly one level**. `parent_comment_id` is the thread root,
`reply_to_id` the addressee (only for the "In reply to" label), `deleted_at`
the placeholder. Deletion goes through the `delete_own_comment()` RPC: with
replies — a placeholder, without — a real delete; the server decides. There
are deliberately no DELETE or UPDATE policies on `comments`: editing comments
isn't a feature, and a direct DELETE would take OTHER people's replies with it
via `on delete cascade` (which is why 20260725120000 dropped the DELETE policy
introduced by 20260710113710). Since 20260825100000 the DELETE grant itself is
revoked too: without a policy it opened nothing anyway, but it survived the
policy's removal and was waiting for someone to bring a policy back. "No such
comment" and "exists, but someone else's" answer with the same `PT404` —
distinguishing them would answer "is the row alive" about something RLS must
hide entirely (20260822140000).

`comments.text` is at most 5000 (`comments_text_length`, 20260716120000) and
non-empty after `btrim` unless the row is a placeholder
(`comments_text_not_blank`, 20260824110000). The condition is a disjunction on
`deleted_at` rather than plain `btrim(text) <> ''` because
`delete_own_comment()` makes the placeholder precisely an empty string — there
it isn't junk but the very value "there is no text anymore". There was no
lower bound at all until it was introduced for `posts.text` and `users.name`
(20260822200000): an empty comment got through, was rendered as an empty line
for everyone who could see the post, was counted in `comment_summary()` and
sent the author a push along the way.

The structural reply rules (`enforce_comment_reply_rules()`) live in a
`security definer` BEFORE INSERT trigger, and such triggers fire **before**
the policy's `WITH CHECK`. So the trigger stays silent about everything the
caller isn't allowed to see: not visible — `return new`, and the policy does
the refusing, with the same 42501 for "no row", "someone else's row" and
"placeholder row". Visibility of both sides (`parent_comment_id`,
`reply_to_id`) is checked by `is_comment_visible()` — the only case where the
`comments` SELECT policy condition is duplicated on purpose: the function
can't be substituted into the policy itself, `security definer` isn't inlined
and a per-row call on the feed is the regression from 20260726180000. Both
have to be changed (20260822140000).

## Post media

Up to 20 photos/videos per post — `post_media(post_id, position, media_type,
storage_path, poster_path)`, one row per item. `position` is only the display
order in the feed carousel, not a dense sequence (on edit the client rewrites
the positions of the remaining rows all at once). Visibility is inherited from
the visibility of the post itself, and inherited literally: the policy is
`exists (select 1 from posts p where p.id = post_media.post_id)`, and RLS
applies to the subquery inside a policy too, so "a `posts` row was found"
literally means "the post is visible". `post_media` has had no copy of the
rule of its own since 20260826180000 — before that there was a join to
`visible_author_ids()` here, i.e. a fourth copy, and it would have known
neither about the room branch back then nor about `visibility` now. **There is
no UPDATE policy on `post_media`**: replacing a file and reordering are always
delete+insert of rows, never an in-place update (on reorder the storage object
isn't touched; the row with the same `storage_path` is simply recreated with a
new `id`/`position`). Both halves are done by
`set_post_media(post_id, items)` — **in one transaction** — and it returns the
paths nothing references anymore, so that the client deletes the objects only
AFTER the rows have been rewritten (20260820150000). As two PostgREST requests
this was two transactions, and a drop between them left the post with no
media at all. The client doesn't call it directly but through
`update_post_with_media(post_id, text, items)` (20260824120000), which adds the
post caption to the same call — see below on "neither text nor media".
`set_post_media()` itself **has not been granted to `authenticated` since
20260905100000** and lives only as the internals of its wrapper:
`update_post_with_media()` calls it from inside `security definer`, with the
owner's rights, where no grant is needed. The grant was kept for build 41 ("it
can be removed once `min(app_build)` passes 42"), but the condition was met
from the other side — 20260828100000 dropped `posts.in_general_feed` and
changed the signature of `create_post_with_media()`, i.e. it switched off the
feed and publishing for all builds 46 and below. The grant wasn't harmless in
the meantime: `set_post_media()` doesn't check "neither text nor media" and
can't (it only sees the media — see below), so `/rpc/set_post_media` with an
empty `items` on one's own captionless post left an empty post alive in the
feed of all connections until the next `purge_empty_posts()`. Since
20260826120000 its final INSERT swallows duplicates with
`on conflict (post_id, storage_path) do nothing` — just like its counterpart
`create_post_with_media()`: two functions writing to one table on the same key
behaved differently, and the same path arriving in `items` twice was silently
dropped on publish but failed with a raw 23505 on edit. Together with
`on conflict` the `#variable_conflict use_column` directive was added there,
and it is mandatory: `returns table (storage_path text)` creates an OUT
parameter with that name, and the conflict target must be a bare column
name — it can't be qualified syntactically, and unqualified it collides with
the variable and fails with 42702.
The limit of 20 is the backstop trigger `enforce_post_media_limit()`
(`BEFORE INSERT`); the main gate is the client.

The path prefix is checked by **both** write paths, and these are two
different checks of one condition. `security definer` carries
`set_post_media()` past the INSERT policy, so it checks by itself and throws
`PT422` (20260822170000); a direct INSERT (which `createPost` does) is checked
by the INSERT policy and answers 42501 (20260822180000). The condition is the
same: `storage_path`/`poster_path` must start with `posts/<auth.uid()>/`,
exactly as in the storage INSERT policy. While this lived only in the RPC, a
direct INSERT could attach a row with someone else's path to one's own post —
this doesn't expose the bytes to another viewer (they sign the object
themselves, and the storage policy matches the second segment against their
own `visible_author_ids()`), but authorship was spoofed.

`posts.text` is either NULL or non-empty after `btrim`
(`posts_text_not_blank`, 20260822200000).

Publishing a post together with its media is **one transaction**, via
`create_post_with_media(client_token, text, items)` (20260823120000). Before,
it was three PostgREST requests in a row (insert the post, read the `id`,
insert the media), i.e. three transactions: a drop after the first one
published the post with text and no photos — live in the feed of all
connections, with the push already sent — while the composer showed "Failed to
publish". Same shape and same cure as `set_post_media()` (20260820150000) on
the edit path; back then it didn't touch the create path. The arbitration is
the same as before — `on conflict (author_id, client_token)` — but the
conflict branch is no longer `do nothing`: it **brings the post to the state
sent** (20260824100000). One `client_token` is one publish, whose content is
determined by the last call with that token.

Since a retry can REMOVE media, it can leave an object in the bucket with no
row referencing it. So `create_post_with_media()` returns
`table (storage_path text)` — the paths orphaned by its own overwrite — and the
client runs the cleanup through `deleteRowsThenObjects` (20260825110000),
exactly as on the edit path. `reap_orphaned_media()` is the last line of
defence here, not the first: it collects objects older than a day, a hundred
per run, which is not the tool for a 100 MB clip removed from a draft a second
ago.

This isn't decoration; it's what lets the composer mint the token once per
session. While a retry was a no-op, the token had to be tied to the content
(otherwise an edit after a failure would silently not apply) — which meant
that after a publish that "failed" on timeout and committed anyway, an edit to
the draft went out under a NEW token and published a second post with a
second push.

For the same reason "neither text nor media" is checked synchronously on
**both** write paths (`PT422`), not just by a cron: `create_post_with_media()`
on publish and `update_post_with_media()` on edit. Before, this couldn't be
expressed as a CHECK: at the moment the post was inserted, the media rows
didn't exist yet, and the check would reject a legitimate photos-only post.
The check can't be put into `set_post_media()` itself either: it only sees the
media, and by the time it's called the text is either already new or still
old — depending on the order in which the client sends the two commands, and
the "text first" order only appeared in build 42. The `purge-empty-posts` cron
stays and is needed, but now for one reason out of two: the grant on
`set_post_media()` is revoked (20260905100000, see above), but the grants for
direct INSERT into `posts`/`post_media` are not. A post with no text and no
media can still arrive that way, bypassing both RPCs, which is why the cron
stays. It can only be removed once direct INSERT goes away.

`posts.text` itself is edited through a narrow UPDATE policy (`grant update
(text)`, 20260819210000) — the only `posts` column available for UPDATE;
`author_id`/`created_at`/`id`/`client_token` are unreachable this way.

`poster_path` is for video only: a JPEG of the first frame, generated on the
client when the file is picked.

## Profile photos

Up to 80 photos per user — `profile_photos(user_id, position, storage_path)`,
one row per photo, the same non-dense `position` and delete+insert reorder as
`post_media`, and likewise in one transaction — via
`reorder_profile_photos(photo_ids)`, which must be given the **whole** gallery
(positions are rewritten to a dense 0..N-1; a partial permutation would
collide with untouched rows; a mismatch is `PT422`). The check compares
lengths, and until 20260826120000 that fell short in exactly one case: an
array with duplicates. For a gallery `{a, b}` the set `[a, a]` yields two rows
on the join, the lengths match, `PT422` doesn't fire, `delete` removes both
photos — and then the INSERT fails with a raw 23505 on
`profile_photos_user_storage_path_key`. The data was rolled back, but instead
of a clear "the set doesn't match your gallery" the person got a generic
error. Duplicates are now cut off by a separate `count(distinct)` check before
the table is read: they can't be counted via `array_length`, since the length
is exactly what matches. Appending goes through
`append_profile_photos(items)` (20260824130000) — and `position` there is
handed out by the server, from the same transaction the rows land in.
Computing it on the client was impossible for the same reason reordering with
two requests was: the screen computed it from the cached list, and that list
lags exactly when the previous attempt committed after "Failed to add
photos" — and the new rows aimed at occupied positions. An `upsert` can't
paper over this: its arbiter is `(user_id, storage_path)`, and new files have
their own paths, so a conflict on `position` isn't absorbed but brings down
the whole batch. Direct INSERT stays granted — the Play builds use it.
Visibility is **self, a Connection or the system account, ignoring
mute/block**, not `is_author_visible()`: a block must not hide the avatar on
the "Blocked" screen, which is where blocks are lifted.
This used to be exactly the same rule as for the avatar itself in Storage;
since 20260905100000 they differ by one branch — storage gained the room
peer, who can see the avatar and only the avatar, while still not seeing the
gallery rows. Why it's done this way rather than by prefix — see "Storage"
below.

The system account branch arrived here later than the rest (20260823130000):
the "visible to everyone" exception was introduced in four steps, and it
reached neither `profile_photos` nor the avatar storage policy — and the
system account is nobody's Connection, so both answered "no" to literally
everyone. This shows on the theme-toggle easter egg: it opens the Amicus
profile, which draws the avatar and, on tap, the gallery. `users.avatar_path`
remains the only field the rest of the client reads (feed, connections list,
`friend_profile_screen`) — instead of rewriting those places for the gallery,
the `sync_avatar_path_from_profile_photos()` trigger keeps it in sync with the
lowest-`position` photo on every `profile_photos` mutation. It is
`security definer` — not to access other people's rows, but because after
20260822210000 `authenticated` has no right to write `users.avatar_path` at
all, and someone has to write it. It can't touch someone else's row:
`new/old.user_id` comes from `profile_photos`, where RLS has already pinned it
to `auth.uid()`.
`storage_path` must start with `avatars/<auth.uid()>/` — same as
`post_media`, and for the same reason (20260822180000). The limit of 80 is the
backstop trigger `enforce_profile_photos_limit()`, the same pattern as
`post_media`. Migration `20260819240000_add_profile_photos.sql`.

## Server-owned columns

`anon` has no table privileges left at all (20260818140000, 20260821120000),
and `authenticated` has had `TRUNCATE`, `TRIGGER` and `REFERENCES` revoked —
both on the tables themselves and in default privileges, so the next table
created doesn't get them back (20260822240000). The main one of the three is
`TRUNCATE`: **RLS doesn't apply to it at all** — policies filter rows, and it
isn't a row-level operation. Before the fix, a user whose policies showed them
3 rows of `reactions` wiped all 56.

The "grant ↔ policy" correspondence is verified by a check block right in the
migration: if `authenticated` retains a write privilege with no policy under
it, the rollout fails. The block from 20260824140000 checked against
`information_schema.column_privileges` — the right source for INSERT and
UPDATE, which can be per-column, and blind to DELETE: that's a table-level
privilege and never shows up in `column_privileges`. The entire command
slipped past a check written precisely against this. Behind it stood four dead
grants — `comments`, `connections`, `invite_links`, `users` — revoked in
20260825100000; the same migration extended the block with
`role_table_grants`, and it now covers all three commands.

The client write grant is narrowed by column on **every** table the client
writes to at all. For `users` that's `update (name)` and no INSERT whatsoever
(the row is created by the `handle_new_user()` trigger) — `dislikes_disabled`,
`created_at` and `avatar_path` are server-owned, even though the RLS policy
only says "is this my row" (20260820140000, 20260822210000). `avatar_path`
joined the list later than the rest: its grant was left over from the
pre-gallery version, the client only reads it and a trigger writes it, so the
live grant allowed exactly one thing — putting someone else's path into your
own avatar. `name` is limited to 100 characters and must be non-empty after
`btrim` (`users_name_not_blank`, 20260822200000): the `'Без имени'` ("No
name") fallback exists only in `handle_new_user()`, i.e. at sign-up, and
doesn't extend to UPDATE.

Pinned in the `posts`/`comments` INSERT policies: `created_at = now()`,
`deleted_at is null`. `id` on `posts`/`comments`/`reactions` isn't granted for
INSERT at all (the client never picks it) — otherwise a conflict on `id` with
someone else's hidden row answers "is it alive" (an existence oracle,
0.13.1/0.13.2).

`reactions` — the same, but on UPDATE: the column can't be closed with the
same grant (the client's upsert without `onConflict` sends `post_id`/`user_id`
in SET on every call, not just `type` — narrowing the grant would break
legitimately switching a reaction). Instead of a grant there's a BEFORE UPDATE
trigger `pin_reaction_identity()`: it silently reverts `id`/`post_id`/
`user_id`/`created_at` to their old values on any attempt to change them, and
leaves `type` alone. Migration `20260819150000`.

`device_tokens` — the same technique for the same reason (the upsert sends all
payload columns in SET, including `user_id`/`fcm_token`, so a column grant on
UPDATE would break push registration): the BEFORE UPDATE trigger
`pin_device_token_timestamps()` reverts `created_at` to its old value and sets
`updated_at = now()`. Since 20260826120000 it also puts back the
`(user_id, fcm_token)` pair itself — the primary key, which an UPDATE must not
move: the grant covers the whole table, the policy checks only `user_id`, and
without the pin a row could be switched to someone else's `fcm_token`,
diverting pushes to someone else's device without violating a single policy.
On the legitimate path this is a no-op; the upsert conflicts on exactly this
pair. The second half matters more than the first — before it, `updated_at`
wasn't updated at all: `default now()` fires only on insert, and the upsert
payload doesn't include that column, so the column equalled `created_at` on
every row and lied about when the device was last online. Migration
`20260822130000`.

No more than 20 rows per user; extra ones are **evicted** rather than rejected
with an error: registration is fire-and-forget and has no screen behind it
(`enforce_device_token_limit()`, 20260821180000). The least recent by
`updated_at` is evicted — `created_at` won't do, since
`pin_device_token_timestamps()` deliberately keeps it equal to the date of the
FIRST registration, and sorting by it would throw out a year-old working phone
before a three-month-old dead token (20260822160000).

**One device, one account.** An FCM token is issued to an app installation,
not to a person, and you can't be signed in to two accounts at once here, so a
row with this `fcm_token` under a different `user_id` is always a leftover
from the device's previous owner. Only `unregisterDevice()` on sign-out
removed it, and that is best-effort and wrapped in an empty catch: signing out
without network — or a rotation that has already happened, so `getToken()`
returns a different string from the one registered — left it forever, and the
next account on the same phone received someone else's notifications, with
commenter names and digests. Nothing fixed this on its own: `send-push` only
deletes a token on an FCM `UNREGISTERED` response, and the token is alive; the
client can't retry the removal — after sign-out there's no session anymore,
and the policy only lets you reach your own rows. Since 20260826120000 the row
is claimed by whoever registers last: the BEFORE INSERT trigger
`claim_device_token()` (`security definer` — the row is someone else's)
deletes all rows with this token under other users. An invariant that holds
only if the departing client manages to reach the network is not an
invariant.

## Invite links

`connections.method` records how the connection was made: `invite_link` (the
only way the app makes one), `manual` (rows inserted by hand via the
Management API — test data) and `qr_code`. The last one is **groundwork for a
future feature**, not a working path: there is no QR scanning in the app
(see [future-development.md](future-development.md)),
`activate_invite_link()` always sets `invite_link`, and not a single live row
with `qr_code` came through the app. Manual inserts used to be labelled with
exactly that value — i.e. they looked as if they had come through a
nonexistent path — so 20260826130000 introduced a separate `manual` value,
moved the existing such rows to it and left `qr_code` free until the feature
itself appears.

`activate_invite_link()` throws stable SQLSTATEs — `PT404` (not found),
`PT409` (used), `PT422` (your own); the client maps them to ARB strings and
never shows `e.message`.

The code is `encode(gen_random_bytes(16), 'hex')`, 32 characters and 128 bits
(20260823140000). Before that it was 5 bytes, i.e. 40 bits: too little for a
bearer credential that never expires and opens the feed, profile and
gallery — brute-forcing runs against the whole pool of unclaimed codes at once,
and `activate_invite_link()` doesn't slow it down in any way. Existing codes
weren't rewritten: used ones are dead, and a live one is revoked with the
"Create new code" button.

Issuing a code is two different functions, and that isn't duplication.
`create_invite_link()` is idempotent: if there's an unused code, it returns
**that one**, which is what a retry needs. It's idempotent against itself too:
read-then-insert without a lock lost the race between two simultaneous calls
from the same owner — exactly the post-timeout retry the function was written
for, because `.timeout()` stops waiting without cancelling the request — and
the second call failed with a raw 23505 on
`invite_links_one_active_per_owner`, even though the code had been issued.
Since 20260826120000 the insert goes through
`on conflict (owner_id) where not is_used do nothing` (the predicate is
mandatory: the index is partial), and `row_count` after it tells "I inserted"
from "someone else got there first" — in the latter case their code is
returned. `rotate_invite_link()` (20260822150000) deletes the owner's unused
rows and mints a new one — the only way to revoke a code sent to the wrong
person: the code is a bearer one, whoever activates it becomes the Connection,
and `invite_links_one_active_per_owner` doesn't allow a second active row.
Deletion rather than `is_used = true`, so that a revoked code reads as `PT404`
("no such code") and not `PT409` ("already used") — the latter would be
untrue. The client calls rotation only from the "code is already on screen"
branch and only after confirmation.

A code is burned only when it actually created a connection. The insert goes
through `on conflict (user_a_id, user_b_id) do nothing`, while
`is_used = true` used to be set right after unconditionally — that is,
presenting the code by someone already connected to its owner burned the code
for nothing (20260825120000 checks the insert's `row_count`). It's easy to get
there: `.timeout()` stops waiting without cancelling the request, so tapping
"Activate" again after an "error" is normal human behaviour. The different
outcomes are deliberately not distinguished externally: "you are now
connected with X" is true in both, while a separate code would answer the
presenter's question about someone else's connection graph.

## Storage

The `media` bucket is created by a migration (20260822260000), not just by hand
in the dashboard: before it, the bucket was configured via
`update … where id = 'media'`, so on a clean project both such `update`s found
nothing and silently passed. The same migration turns `public = false` from an
initial value into an invariant — all the SELECT policies below rest on it
(there's deliberately no number here: there got more of them with rooms and
there will be more again), and a public bucket cancels them all at once.

The bucket is private, signed URLs live 24 h, the object limit is 100 MiB,
`allowed_mime_types` is five image types and six video types, matching exactly
`videoExtensions`/`imageExtensions` in `shared/media_extensions.dart`
(storage_client takes the content-type from the extension
in the object name, not from the content; 20260820130000). That's exactly why
both lists exist on the client: a format not in `allowed_mime_types` is
rejected at upload by file name and will be rejected on every retry, so both
pickers filter it out themselves, with a clear message.

Both — but not from the start. For images the gate was introduced together
with this file (before it `.gif` fell into the generic "Failed to publish"),
while for video it appeared later, even though this paragraph claimed
otherwise: `videoExtensions` was used only in `_looksLikeVideo()` — as a
"video or image" classifier when the picker didn't report a mime — and wasn't
a gate. So an `.avi` made it to the bucket and bounced off it forever, and a
clip with no extension in its name got the default `jpg` from
`fileExtension()`, passed as `image/jpeg` and stayed in the feed as a slide
with `media_type = 'video'` that plays nothing.

`posts/<uid>/…` — by the visibility of THE POST ITSELF, not its author
(`post_media_path_visible()` → `is_post_visible()`, 20260826190000). It used
to be "by `is_author_visible`", and that was the same thing exactly until the
author got posts that not all of their connections could see (room feeds;
20260828100000 removed them, but the rule stayed — one copy is better than
two). See "Room avatar" above for the same trap from the other side.
The author's own branch (`foldername[2] = auth.uid()`) comes first and doesn't
require a row in `post_media`: the client uploads files before the post exists.
The path itself is `posts/<author_id>/<post_client_token>/<media_client_token>.<ext>`;
the first two segments haven't changed since the single-photo version, so the
policies matching on `(storage.foldername(name))[1..2]` didn't need touching
when moving to multiple media. Each file is its own object under its own
`media_client_token`; the video poster sits next to it as
`<media_client_token>_poster.jpg`.

`avatars/<uid>/…` — to self, Connections and the system account
(20260823130000) **by the whole prefix**, and to a room peer (20260826180000)
**only one object: the current `users.avatar_path`** (`is_room_peer_avatar()`,
20260905100000). **A block narrows none of this**: a blocked user stays in the
connections list and on the "Blocked" screen, where blocks are lifted, and both
screens draw the avatar.

The difference between "prefix" and "object" here isn't tidiness but a fixed
hole. Profile photos (`profile_photos`) are the same kind of objects under the
same prefix and didn't need a storage policy of their own — and while there
were three branches, that added up: for both self and a Connection, RLS on
`profile_photos` shows the whole gallery, so the prefix form was exactly equal
to it. The room branch broke that equality: gallery rows aren't visible to a
room peer at all, but the objects were, including the ones that aren't the
avatar. `storage.list('avatars/<uid>')` goes through the same SELECT policy,
so it listed all of up to 80 photos to a room peer, each of which then just
had to be signed and downloaded. A room was meant as "you see each other's
names and faces", not as access to someone else's album. Exactly the same
mistake — prefix instead of object — had already been fixed by
20260826190000 for `posts/` (see the paragraph above); in `avatars/` it lasted
longer because before rooms it was invisible.

`rooms/<room_id>/…` — the room avatar: members read it, the owner writes and
deletes it. The only prefix where the second folder isn't a user but a room,
so the right is computed via `owns_room()` rather than by comparing with
`auth.uid()`.

`messages/<room_id>/<author_id>/<send token>/<file token>.<ext>` — message
media (20260828120000): any room member reads, a member writes into their own
folder, **the author deletes — even after leaving the room**
(20260829120000). For SELECT and INSERT the first two folders are the
permission itself: the room answers "who can see it", the author answers "who
may write"; the second condition isn't a formality — without it a member could
put a file into someone else's folder inside a shared room, and the CHECK on
the row would reject only THEIR OWN row, while the object would stay. For
DELETE, though, membership was superfluous and harmful: no one else's bytes
can be reached through the third path segment regardless of membership, but
one's own files became inaccessible exactly where they need to be cleaned
up — on account deletion (`delete_own_account()` cascades away `room_members`
before the client gets to the bucket) and for an author who deleted their
message after leaving the room (`delete_own_room_message()` doesn't require
membership even now).

Objects that no row references are swept out by `reap-orphaned-media`
(20260823110000) — the row limits "20 media per post" and "80 photos" count
tables and don't look into the bucket, and uploading happens BEFORE rows are
inserted, so every abandoned draft leaves behind whatever it managed to
upload. The reaper has three branches, one per form of the question "does
anything still reference this file":
`posts/` and `avatars/` ask the `post_media`/`profile_photos` rows,
`messages/` (20260828120000) the jsonb inside `room_messages`, `rooms/`
(20260829110000) the `rooms.avatar_path` column. The last one was added last,
and for good reason: a deleted room's avatar wasn't merely uncollected but
UNREACHABLE — both of its storage policies compute the right via
`owns_room()`, i.e. via a row in `room_members`, which an empty room no longer
has, so the object could be neither read, nor deleted, nor found. The one-day
threshold is shared and protects a fresh upload whose row will appear a second
later. The schedule, the per-run limit and how to see what the job is about to
delete are in [operations.md](operations.md).

No prefix has an UPDATE policy (20260822210000): `posts/…` never had one,
`avatars/…` had one lying unused since 20260707222025 and it was dropped —
replacing a file here is always a new object under a fresh client-minted path
plus a delete of the old one, which is why `uploadTolerant` deliberately
doesn't set `upsert`.
