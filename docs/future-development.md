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

## iOS release validation

Before distributing the current candidate through TestFlight, verify its
launcher icon, profile layout, keyboard, media playback, chat reconnect and push
behavior on a physical iOS device using the [iOS build guide](ios-deployment-guide.md). Use
the [Xcode Cloud pin](xcode-cloud-setup.md) for the UIScene runner.

Store listing copy and iPhone/iPad screenshots still need review against the
build being submitted; see [the listing draft](review/app-store-listing-draft.md).
Check the actual submission status in App Store Connect. Repository files
cannot establish whether a build has been approved or published.

A separate custom launch composition remains an optional design task. Revisit
export compliance if the app's encryption behavior changes; the existing
`ITSAppUsesNonExemptEncryption=false` describes the current implementation.

## Interface verification and documentation

- Verify the updated notification silhouette on a Samsung One UI device. The
  notification resource builds successfully, but Samsung rendering has not yet
  been checked on hardware.
- Measure scrolling, image memory, video suspension and battery use on a
  physical device in profile mode. Automated regressions establish avoided
  work, not a measured battery-life improvement; see [performance.md](performance.md).

The current design and client behavior are recorded in
[interface-design.md](interface-design.md) and
[client-architecture.md](client-architecture.md); completed changes belong in
[../CHANGELOG.md](../CHANGELOG.md).

## Localizing the Amicus news account

Right now posts from the news account (new features, digests, app news) arrive
only in Russian. Separate content is needed for each locale (or at least for
English): posts sent from a single account, but with the text in the
particular user's locale.

## Deep link for email confirmation

Confirmation currently opens the GitHub Pages landing page configured by
`auth.site_url` in `supabase/config.toml`. Its source is
`docs/gh-pages/email-confirmed.html`; `sync-gh-pages.yml` deploys it as
`index.html` on the `gh-pages` branch. Password recovery uses the separate
`reset-password.html` redirect. Edit the source pages, never the deployment
branch directly.

Returning to a native app screen after confirmation remains deferred. It needs
an agreed URL scheme/App Links/Universal Links flow and client handling.

## Web version of the app

Flutter Web or a separate React/Vue frontend.

## Connecting via NFC

As an alternative to the invite link/QR — a very distant idea, not a priority.

## Full privacy policy audit and consent integration in the UI

The privacy policy and terms are static GitHub Pages documents. Sign-up has
no dedicated consent control or persisted consent record; email verification
is a separate authentication step. Any future consent flow needs its own
product requirements rather than being inferred from email confirmation.

## Moving from Supabase to our own server (ASP.NET Core + PostgreSQL)

Not a hypothesis but a settled matter: sooner or later the whole database will
move from Supabase to my own personal server — just not now; it's overkill
until it's actually needed. There's experience with ASP.NET Core + PostgreSQL
(essentially the same thing done in the TransferScout lab), and the backend
can be rewritten on it. RLS policies are currently written as plain Postgres
SQL — access logic won't need porting during the migration, only the
Auth/Storage/Realtime layer.

## Pull-to-refresh on more data screens

The feed, profile post lists, Rooms and Connections support pull-to-refresh.
Extend it to other data screens where a manual reload is useful.

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
