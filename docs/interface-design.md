# Amicus interface

Amicus is a personal album and a conversation with people the reader knows.
Photographs, names and messages carry the identity. Color marks an action or a
state rather than covering the entire interface.

This is the 0.19.1 interface. Resource and lifecycle behavior is
documented in [performance.md](performance.md).

## Tokens

| Role | Light | Dark |
| --- | --- | --- |
| Background, album page | `#F5F5F7` | `#1B1B1F` |
| Content surface | `#FFFFFF` | `#242429` |
| Text, graphite | `#25252B` | `#EFEFF3` |
| Supporting text | `#666670` | `#B9B8C2` |
| Action, berry | `#6354A5` | `#C3B6F2` |
| Favorite, amber | `#88651E` | `#D9BB79` |

Backgrounds, avatars, navigation selection and chat bubbles use neutral grays.
Berry is reserved for primary actions, active icons, links and focus. Amber
identifies favorites; red identifies destructive actions and errors. A selected
reaction uses its semantic color, while unselected reactions remain neutral.
The dark theme uses graphite surfaces without a colored wash.

Sofia Sans is bundled locally with its OFL license. Semibold headings and
regular body text support both Russian and English. Body text has a 1.45 line
height; metadata uses the same family at a quieter size. Fonts never load from
the network.

## Layout

Reading and forms are left aligned, with a maximum width of 720 logical pixels
(480 for authentication). Mobile content keeps a 16–24 pixel gutter. The feed
is a continuous reading surface: entries are separated by space and
a rule, without enclosing cards. A compact brand signature sits above the feed
title. Profile photographs and names share an identity block, stacking on narrow
screens. The name is editable in place. Rooms use two-line previews, dates and a
stronger weight for unread conversations. Connections keep a compact invitation
disclosure above the people list. It
opens automatically for an empty list, and otherwise leaves room for people.
Relationship actions live in one trailing overflow menu with explicit labels.
Small, noninteractive marks beside the name identify favorite, muted and blocked
states. Profile photo tools live in a bottom sheet opened by the camera control on the avatar;
tapping the photograph itself still opens the viewer.

```text
Amicus                          Settings
Posts
  avatar  author                   menu
          date
  text / photo
  reactions                     replies

  feed   write   rooms   people   me
```

```text
Profile
  photograph         editable name
  camera / menu      save when changed
  wall
    entries
```

```text
Settings
  Notifications
    source                         switch
  Appearance
    Navigation                    choice
    Language                      choice
    Theme                         choice
  Account
    Sign out
    Delete account
  About / version
```

## Review against the brief

Replacing teal with another fully tinted palette would preserve the original
problem: too much color on every screen. Reading surfaces and supporting text
stay neutral, while photographs, names and messages carry the identity. Colorful
profile panels and avatar placeholders were removed. Own chat messages use a slightly stronger neutral surface;
alignment and bubble tails also identify the sender. The active navigation
surface is neutral glass, with color restricted to the active icon. The compose
destination uses the standard plus symbol.

Authentication pairs a horizontal brand signature with a bounded form. Post
composition uses a spacious writing sheet instead of a short outlined field.
Chat headers pair the conversation avatar with its name and presence; chat and
comment inputs sit in a separate neutral tray. Settings group related controls
on shared surfaces, with headings outside; account actions form their own group.

The circle-of-people mark stays the identifying element. Its original authored
foreground is preserved byte for byte.
`python3 scripts/generate-branding.py` packages background layers and iOS icon
sizes from that artwork (Pillow required); it does not redraw the symbol. The
launcher background is berry on Android and iOS; the in-app mark has a transparent background and follows the theme. Android keeps
its separate, heavier notification vector. Launch screens use a neutral
background. Original launch artwork is retained.

The shared theme reaches authentication, feed, comments, post creation/editing,
both profiles, galleries and gallery tools, Connections, blocked users, room
lists, room creation/details, chat, settings, reports and confirmation sheets.
Full-screen media keeps its black viewing surface. Forms, dialogs and buttons
share consistent controls, with visible focus and accessible tap targets.

## Interaction

Floating and classic navigation remain available in Settings. The floating
bar keeps synchronized page gestures and its restrained glass selection.
Reduced motion skips settling animations and jumps directly to quoted messages
in chat. Full-screen photos fade at their final
viewport size, with bounded decoding and fourfold zoom. Videos pause when their
slide/tab is hidden or the app leaves the foreground; return does not autoplay.
Secondary screens cover the shell;
scroll tails clear floating navigation and the device safe area.

Profile links include the author area of a post, the full Connection row, the
direct-chat header and the name above a room message. Menus, reactions and
relationship controls remain independent targets. Settings
show cached notification preferences and refresh them in place. Saved theme,
language and navigation are applied before the first frame; failed changes
restore the last saved choice. New posts restore
their local draft when reopened, including audience and attachment order. The
storage and navigation behavior is documented in
[client-architecture.md](client-architecture.md).

## Local previews

`AMICUS_PREVIEW_DIR=/private/tmp/amicus-preview make verify` captures interface
previews while running the existing layout checks. All people and content in
these fixtures are fictional. Layout checks cover both themes at 320, 390 and
800 logical pixels with enlarged Russian text, narrow authentication forms,
keyboard clearance and secondary navigation. Send icons must maintain a contrast
ratio of at least 4.5 against the filled button in both themes.
