# Deferred features

Everything deliberately put off — not implemented yet and not planned for the
next version. Finished work doesn't belong here — the full feature history is
in [../CHANGELOG.md](../CHANGELOG.md), the original MVP plan is in
[project-brief.md](project-brief.md).

The previous edition of this list, from before the MVP was closed, lives in
[future-development.archive.md](future-development.archive.md) — for history
only; some of what it lists has been done since.

---

## GPS track upload (running/cycling routes, Strava-style)

The ability to record a run/ride route with the phone's GPS or upload a ready
track file (GPX/TCX/FIT — the formats Strava, Garmin and most sports watches
work with), and then show the route on a map in a post.

**Mechanics (draft):**
- Record the track on the device (background GPS tracking during the activity)
  or import a ready file.
- Parse the track → a series of coordinates (lat/lon/timestamp, maybe
  elevation) + aggregates (distance, duration, average speed/pace).
- Show the route on a map in the post — needs a mapping SDK (Google
  Maps / Mapbox / something OpenStreetMap-based) — each has its own free-tier
  limits and pricing; choosing one is a separate question.

**Data model (draft):**

| Entity | Key fields | Comment |
|---|---|---|
| **Route** (or Activity) | id, post_id, type (run/ride), distance_m, duration_s, started_at | Route aggregates, tied to a post |
| **RoutePoint** | route_id, seq, lat, lon, elevation_m?, recorded_at | Track points — either normalize like this, or keep the raw GPX/FIT file in Storage and parse on the fly; open question |

**Open questions:**
- Store the track as a file in Storage and parse on the fly, or normalize it
  into a points table in the DB — a trade-off between simplicity and the
  ability to query/aggregate over tracks.
- Which mapping service to use (cost, free-tier limits, availability on
  Android without extra setup).
- First iteration: only uploading a ready file, or live GPS recording during
  the activity right away?

## iOS — what's left after the TestFlight launch

The simulator and the first TestFlight build are done — see
[ios-deployment-guide.md](ios-deployment-guide.md) and
[ios-push-apns-setup.md](ios-push-apns-setup.md). Left before publishing
to the App Store:

1. Design a proper launch image (right now it just shows the app
   icon).
2. Fill in the App Store Connect listing (description, keywords,
   screenshots) — draft in
   [review/app-store-listing-draft.md](review/app-store-listing-draft.md).
3. Run a real `flutter build ios`/archive on a device, not only through
   Transporter — check for platform bugs that didn't show up on Android.
4. Once real encryption appears — remove/change
   `ITSAppUsesNonExemptEncryption` in `Info.plist` to the correct value.

## Interface work/UI polish

Beyond what's already done — the app is functional, but no more than that.

## Localizing the Amicus news account

Right now posts from the news account (new features, digests, app news) arrive
only in Russian. Separate content is needed for each locale (or at least for
English): posts sent from a single account, but with the text in the
particular user's locale.

## Deep link for email confirmation

Right now the link in the email leads to a static confirmation page on GitHub
Pages (`site_url` in `supabase/config.toml` →
`https://tiltozavr2545.github.io/amicus/`, source — the `gh-pages` branch, a
single `index.html`), because the confirmation itself is counted on the
Supabase side before the redirect. That fixes the confusing landing page (it
used to lead straight to the GitHub repository), but opening an app screen
directly would be nicer — it needs a custom URL scheme / Android App Links set
up and handling in `supabase_flutter`; a separate task.

## Web version of the app

Flutter Web or a separate React/Vue frontend.

## Connecting via NFC

As an alternative to the invite link/QR — a very distant idea, not a priority.

## Full privacy policy audit and consent integration in the UI

Right now the privacy policy is static on GitHub Pages; consent is only the
email confirmation, with no options in the UI.

## Moving from Supabase to our own server (ASP.NET Core + PostgreSQL)

Not a hypothesis but a settled matter: sooner or later the whole database will
move from Supabase to my own personal server — just not now; it's overkill
until it's actually needed. There's experience with ASP.NET Core + PostgreSQL
(essentially the same thing done in the TransferScout lab), and the backend
can be rewritten on it. RLS policies are currently written as plain Postgres
SQL — access logic won't need porting during the migration, only the
Auth/Storage/Realtime layer.

## Chat jumps when a message arrives while reading history

Deliberately deferred in 0.18.10, along with the rest of the batch of chat
fixes (see [../CHANGELOG.md](../CHANGELOG.md)). `ScrollablePositionedList`
anchors by **index**, and inserting at the start of the list shifts every
index below by one — by two if the message opens a new calendar day and a
divider is added for it. So for someone who has scrolled up and is reading,
the conversation slides away under their finger by the height of a message.

The compensation arithmetic is trivial (the shift equals the growth of the
item list, because items are only ever prepended), but it can only be applied
with `jumpTo` in a post-frame callback — and that cancels momentum if the
message arrives mid-fling. The package doesn't let you tell whether "a finger
is on the screen right now": it doesn't expose its own `ScrollController`. So
in the worst case the cure is worse than the disease, and an automated test
can't catch the difference — it would have to be checked by hand on a device.

A possible path, if taken on: see whether a newer version of the package
exposes `findChildIndexCallback` or the controller itself — then this gets
solved together with bubbles recreating their `State` (see "Pitfalls" in
[../AGENTS.md](../AGENTS.md)).

## Instant display of a new avatar in the profile

When a new avatar is uploaded it should immediately become the current one
(first), so that it shows in the profile right after upload, without any
extra action from the user.

## Pull-to-refresh on every screen of the app

The ability to refresh a screen with a swipe — currently not available
everywhere.

---

## Ideas for later

Unlikely to get done — written down so there's something to come back to if
needed.

- **QR scanning as a second way to connect** — in addition to
  invite links

- **Integration with existing social networks (Instagram, TikTok, etc.)** —
  the ability to link an account, move posts (with photos/videos) to your
  own wall in Amicus, as a one-off sync or a periodic background one.
  Syncing friends to the wall as an option (who from your Insta follows ends
  up in Connections or in a separate list). Addresses the main objection to
  quitting social networks: friends' content stays, but in a circle closed to
  everyone else

- **Post view counter** — the task is worded "peculiarly" (in the author's
  words) — if it ever gets picked up, before implementing it you need to
  clarify exactly how a view is counted (when the card is shown in the feed /
  when fully expanded / unique users only / what about repeat views,
  etc.), not make it up on your own

- **Push notifications about reactions to your own posts** — a separate piece
  of the same push-notification idea from what's already implemented
  (posts, comments/replies); its own `kind` in `notification_outbox`, a
  trigger on `reactions` instead of `posts`/`comments`

- **Video messages ("circles", like in Telegram)** — round video messages
  recorded with the camera right in the app — as an alternative/addition to a
  photo in a post or comment.

  **Mechanics (draft):**
  - Record with the device camera (usually the front one), with a duration
    limit (e.g. 60 sec, like in Telegram).
  - The round mask is more likely a client-side rendering (`ClipPath`/overlay)
    than re-encoding the video file itself into a round shape.
  - Storage — Storage (the same bucket as photos, or a separate one),
    visibility under the same privacy rules that already apply to
    photos/avatars (Connections-only).

  **Open questions:**
  - A separate attachment type for posts, or only for comments (or
    both)?
  - Size/duration limit, and whether client-side re-encoding/compression is
    needed before upload.
  - Autoplay in the feed (with or without sound) — a UX question, to be
    decided separately.



---

## Open questions

No need to answer them right now — this is a checklist for later, when you
get to the corresponding feature:

- Should it be possible to break a Connection (roughly, "remove from
  connections")?

It was decided to keep the contact list private — see "Visibility rule" in
[data-model.md](data-model.md).
