# Interface stability and resource use

Implemented for **0.19.1+78**.

Framebook techniques evaluated for Amicus on 2026-11-18. The source checkout
was Framebook `fd4d943`; relevant changes include `7cdbae9` (resource use),
`a5394d8` (resume), `c2f0c49` (scrolling) and `abfaa6c` (responsiveness).
Amicus keeps its own navigation, account isolation and Supabase data model.

## Applied techniques

| Framebook technique | Amicus application |
| --- | --- |
| Decode images for their display size | `CachedMediaImage` wraps the original disk-cached file with `ResizeImagePolicy.fit`. Feed photos, video posters and chat attachments decode within their physical display bounds. Both full-screen galleries allow fourfold zoom, capped at 4096 pixels per side, preserving aspect ratio without upscaling small sources during decoding. |
| Give full-screen photos stable geometry | Galleries occupy their final viewport and open through a fade rather than a scaling route. |
| Stop optional work outside the foreground | Videos pause on background, hidden-tab ticker changes and slide changes. A video finishing preparation after those changes is disposed without playing. Returning requires a play tap. Chat typing timers stop in the background; reconnect callbacks defer receipt/catch-up reads until resume. Incoming messages do not mark a backgrounded chat as read. |
| Restore the active editor after Android background | `KeyboardRestore` sits above navigation. It requests the keyboard after a frame only for the same mounted, focused editor whose keyboard was previously visible. |
| Separate service subscriptions from rendering | Push registration and activity tracking use `ref.listen`; loading/completion does not rebuild navigation or its content. |
| Retain expensive state across list changes | Feed rows use post IDs and a sliver index lookup, including separator/header slots. Inserting or reordering posts retains the mounted media subtree of surviving visible rows. |
| Apply presentation settings before the first frame | Startup reads SharedPreferences before `runApp`. Theme, language and navigation use saved values synchronously, preserving existing keys. Failed startup reads retain usable defaults. |
| Serialize writes and retain the last confirmed preference | Theme, language and navigation share `PreferenceWrites`. Two failed rapid selections restore the last successfully saved value. Older failures cannot replace a newer choice. |

The image ceiling is at most 64 MiB of RGBA pixels **per decoded image**,
not a cap on process memory or downloads. Originals stay in the normal disk
cache, keyed by storage path rather than a changing signature.

## Existing equivalents and applicability

Amicus already mounts tab screens on first use, preserves their navigation
state and stops hidden branches' tickers, focus and input. Navigation already
shares one transition controller and uses a gradient over an opaque surface
instead of redundant backdrop filtering. Avatar thumbnails already decode to
their painted width; avatar bytes have a grace period. Signed media URLs have
a session cache that survives chat bubble recreation. Feed refresh retains
loaded content after network failure; chat grouping is cached between changes.

Framebook's SQLite query projections, recommendation/statistics workers,
Drive merge workers, source budgets, catalog refresh and poster-colour LRU
have no equivalent Amicus subsystem. Amicus fetches bounded server pages and
already requests reaction/comment aggregates together. Adding those workers
or catalog timers would introduce work without replacing an operation.
Its AAB distribution differs from Framebook's universal APK; release
packaging is unchanged.

Framebook's frozen feed-widget replacement is not copied over the mutable
social feed: relationship changes and deletions must reach it promptly.
Stable post identity retains media state while server results still apply.
It does not promise to anchor the same pixel when new posts are inserted.

## Verification and limits

Regressions cover overlapping/failed preference writes, first-read settings,
disposal and language hydration; actual image decoding and aspect ratio;
playback/preparation across background/tab/slide transitions; keyboard restore
with surviving/removed editors; background chat reads and typing; recovery of
disconnected chat history; removal of moderated messages after a refresh;
reply navigation with reduced motion; and retained feed image elements when
a new post is inserted.

The decode fixture is a 1000 x 2000 image. A 100 x 100 viewport at fourfold
zoom decodes it as 200 x 400: 320,000 RGBA bytes instead of 8,000,000,
excluding codec/cache overhead. This fixture is not a whole-app memory result.

Frame times, native video and audio behavior, the Android keyboard, and
battery use still require measurement with a profile build on physical
hardware. The checks guard individual rendering and lifecycle behaviors.

Local validation for 0.19.1 passed formatting, static analysis and **441 Flutter
tests**. Android delivery is tracked separately in the
[release workflow](operations.md#release).
