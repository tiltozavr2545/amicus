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

## Known quirk: the build number won't match pubspec.yaml

Xcode Cloud's archive/upload pipeline silently rewrites `CFBundleVersion`
with its own internal `$CI_BUILD_NUMBER` counter, regardless of what
`pubspec.yaml`/`Generated.xcconfig` say. Confirmed by testing two different
ways to force it (letting pubspec drive it, and passing `--build-number`
explicitly with a safe offset) — both were overridden anyway. There's no UI
toggle for this in either App Store Connect's web workflow editor or
Xcode's target Identity tab (both checked, neither has one).

This only affects the **iOS binary Xcode Cloud produces** — `pubspec.yaml`'s
build number is still the real source of truth for Android releases and any
local iOS fallback build (`make release-ios`), and the marketing version
(`0.18.6`) still flows through correctly; only the build-number component
diverges. Keep bumping it in `pubspec.yaml` as usual for Android's sake.

Practical risk: `$CI_BUILD_NUMBER` starts low and only grows as fast as this
workflow gets triggered — it would need dozens more runs to reach the range
of pre-Xcode-Cloud local build numbers (up to 57 as of this writing) and
risk a collision (App Store Connect build numbers must be unique and
increasing across the app's entire history, forever — "Expired" status
doesn't free a number back up). If that becomes an actual concern, look for
a real Xcode Cloud setting to disable automatic versioning rather than
trying to out-compute it from `ci_post_clone.sh` again.

## 6. Submit it

From here, follow [ios-deployment-guide.md](ios-deployment-guide.md#9-get-it-into-testflight)
steps 8–9 as usual (attach to a test group, or select the build on the App
Store version page and resubmit for review) — Xcode Cloud only replaces how
the binary gets built, not anything downstream of that.
