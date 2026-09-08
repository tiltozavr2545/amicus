# Xcode Cloud Setup

Builds and archives the iOS app on Apple's own managed macOS/Xcode images,
instead of the local M4 MacBook Pro used for iOS development. This matters
whenever that machine's macOS is a beta: a beta host OS gets stamped into
every locally-built archive (`BuildMachineOSBuild` in `Info.plist`), and App
Store Connect rejects that at validation time (`ITMS-90111: Unsupported SDK
or Xcode version`) even when Xcode.app itself is a stable, up-to-date
release. Xcode Cloud sidesteps this entirely by building on Apple-maintained
stable images, regardless of what the local Mac is running.

This is a Flutter project, so Xcode Cloud's native `xcodebuild archive` step
knows nothing about Flutter or CocoaPods on its own — `app/ios/ci_scripts/ci_post_clone.sh`
does everything `flutter build ios` normally does locally before that step
runs.

## Prerequisites

- Admin or App Manager role on the Apple Developer team (needed to grant
  Xcode Cloud access to the GitHub repo and to configure workflows).
- The GitHub repo (`tiltozavr2545/amicus`) reachable from an account with
  admin rights on it, to install Apple's GitHub App during the connection
  step.

## 1. Connect the repository

Open `app/ios/Runner.xcworkspace` in Xcode (not the `.xcodeproj`). On a
machine whose macOS is itself a beta, the stable `Xcode.app` may refuse to
launch at all ("This version of Xcode isn't supported in this version of
macOS") — use the matching-generation `Xcode-beta.app` instead just for this
one-time setup. That's safe: workflow creation only talks to App Store
Connect/GitHub, it doesn't build anything locally, so it has no bearing on
which toolchain later produces the actual archive.

In Xcode 26+, workflow creation is **not** under the Product menu — it moved
to the Report Navigator:

1. `⌘9` (Report Navigator) → **Cloud** tab → **Get Started…**.
2. Confirm your Apple ID is already listed under **Settings → Accounts**
   (add it there first if not — Xcode Cloud only appears once a signed-in
   account is tied to an active team).
3. **Select Product**: pick the entry named after the App Store Connect app
   display name (**"Amicus"**), not the internal Xcode scheme name — the
   picker lists it alongside every CocoaPods sub-target (`FBLPromises`,
   `FirebaseCore`, etc.), which are not what you want.
4. Grant access to the `tiltozavr2545/amicus` GitHub repository when
   prompted — this installs Apple's GitHub App and needs admin rights on
   that GitHub account/org.

## 2. `ci_scripts/ci_post_clone.sh`

Already committed at `app/ios/ci_scripts/ci_post_clone.sh` — Xcode Cloud
picks it up automatically because it sits next to `Runner.xcworkspace`. It:

1. Installs Flutter 3.32.8 (pinned to match `app/pubspec.yaml`'s SDK
   constraint) into the build VM.
2. Reconstitutes `GoogleService-Info.plist` and `.env` from Environment
   Variables (see step 4) — both are gitignored, so Xcode Cloud's clone
   never has them.
3. Runs `flutter build ios --release --no-codesign --dart-define-from-file=.env`
   — the same command `make build-ios` runs locally, minus real signing.
   This bakes `DART_DEFINES` into `ios/Flutter/Generated.xcconfig` and builds
   `Flutter.framework`/`App.framework`, which Xcode Cloud's own archive step
   then picks up automatically through the project's existing xcconfig
   include chain.

Nothing here needs editing to get a first build working — only bump the
Flutter version pin if `AGENTS.md`'s SDK pin ever changes.

## 3. Create the workflow

App Store Connect → Xcode Cloud → your app → **Workflows** → **+**:

- **Start Condition**: branch changes on `main` (or trigger manually — see
  step 5).
- **Environment**: pin a specific stable Xcode version explicitly (don't
  leave it on a "latest" setting that could shift under you) — match
  whatever `xcodebuild -version` reports as current stable when you set this
  up.
- **Actions**: **Archive** → scheme `Runner`.
- **Post-Actions** (optional but convenient): **TestFlight (Internal
  Testing)** so a successful build auto-attaches to your existing internal
  test group instead of requiring a manual App Store Connect step.

## 4. Environment Variables

Same workflow → **Environment Variables** tab → add:

| Name | Value | Secret? |
|---|---|---|
| `SUPABASE_URL` | from `app/.env` | no |
| `SUPABASE_ANON_KEY` | from `app/.env` | yes |
| `GOOGLE_SERVICE_INFO_PLIST_BASE64` | `base64 -i app/ios/Runner/GoogleService-Info.plist \| pbcopy`, then paste | yes |

## 5. Trigger and verify a build

Push to the start-condition branch, or use **Start Build** in App Store
Connect to trigger one on demand without waiting for a push. Watch the build
log for the `ci_post_clone.sh` output first — a failure there (missing env
var, Flutter clone failing) shows up before the archive step even starts.

Once it succeeds and reaches **Ready to Submit** under TestFlight (or gets
auto-attached, if step 3's post-action is configured), the resulting build
was made on Apple's own stable image — no `BuildMachineOSBuild` beta stamp,
so it should clear the `ITMS-90111` check that rejected locally-built
binaries.

## Build number override

Xcode's `VERSIONING_SYSTEM` build setting, when set to `apple-generic`,
stamps the built app's `CFBundleVersion` from `CURRENT_PROJECT_VERSION` at
build time — overriding whatever `Info.plist` actually specifies
(`$(FLUTTER_BUILD_NUMBER)`, driven by `pubspec.yaml`), regardless of what
any pre-build script computes. Xcode Cloud's own "automatic build
numbering" relies on this being enabled, and it was silently replacing
`pubspec.yaml`'s build number with its own internal counter (App Store
Connect showed build `4`/`5`/`6` instead of the `57`/`58` actually in
`pubspec.yaml`).

Fixed by turning it off for the `Runner` target, across all three build
configurations (Debug/Profile/Release): Xcode → select the `Runner`
project → `Runner` target → **Build Settings** → **Versioning** →
**Versioning System** → **None**. With it off, `pubspec.yaml`'s build
number is the real source of truth again on both local and Xcode Cloud
builds — no workarounds needed in `ci_post_clone.sh`.

## 6. Submit it

From here, follow [ios-deployment-guide.md](ios-deployment-guide.md#9-get-it-into-testflight)
steps 8–9 as usual (attach to a test group, or select the build on the App
Store version page and resubmit for review) — Xcode Cloud only replaces how
the binary gets built, not anything downstream of that.
