# Amicus interface

The visual subject is a small circle of people who know each other. People and
their messages carry the interface; controls stay quiet around them.

## Tokens

| Role | Light | Dark |
| --- | --- | --- |
| Background, cool air | `#F3F7F8` | `#112B30` |
| Content surface | `#FFFFFF` | `#19363B` |
| Text, deep water | `#18363A` | `#E5F1F2` |
| Action, teal | `#146B68` | `#8DD5CB` |
| Selected surface, sea glass | `#DCEFED` | `#28504F` |
| Favorite, amber | `#986019` | `#E9BB79` |

Sofia Sans, bundled locally with its OFL license, is used throughout. Full-width
semibold headings distinguish Amicus from Framebook's condensed film typography.
Body text has a 1.45 line height; metadata uses the same family at a quieter size.

## Layout

Everything reads from the left. Reading and forms have a maximum width of 720
logical pixels (480 for authentication); mobile content keeps a 16–24 pixel
gutter. Profiles make their avatar the focal point. Posts are flat white sheets
with generous reading space, rather than elevated dashboard tiles.

```text
Amicus                          Settings
  author                     menu
  date
  text / photo
  reactions                  replies

  feed   write   rooms   people   me
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

Settings follow Framebook's icon-led rows and adaptive dropdown choices. Theme
offers System default, Light and Dark. Local preferences remain available when
notification preferences cannot be fetched. Notification and account behavior
remain specific to Amicus.

## Review against the brief

The initial idea of rounded cards around every section was removed: it hid the
people behind repeated containers. Only posts need a separate reading surface.
The existing launcher's foreground anchors the header and welcome screen, on a
transparent surface: white in the dark theme, primary teal in the light theme.
Circles belong to avatars and the nodes in that artwork; forms and navigation
use quieter rounded rectangles. No decorative gradients, uppercase section
labels, automatic entrance animations, or network-loaded fonts are needed.

Both themes share component shapes and spacing. The floating bar uses the
explicitly requested glass selection from Framebook, tinted with Amicus's teal
palette, and synchronized page gestures. Explicit scroll tails clear the bar,
its gaps and the system safe area; classic navigation reserves space below the
page. Both bar styles appear only on primary destinations, including composing;
secondary screens cover the shell. Controls retain accessible labels and at least
48-pixel tap targets. Narrow settings stack choices below their labels; profile
photo actions wrap below the avatar rather than breaking words in a side column.

## Interaction

The author area of a post and the full Connection row are profile links, while
menus, reactions and relationship controls remain independent targets. Settings
show cached notification preferences and refresh them in place. New posts restore
their local draft when reopened, including audience and attachment order. The
storage and navigation behavior is documented in
[client-architecture.md](client-architecture.md).
