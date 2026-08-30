# iOS Deployment Guide — Simulator to TestFlight

How Amicus got from "no iOS build" to a working TestFlight install, and how
to repeat it for future releases. Written after doing this the first time
end-to-end on macOS with Xcode.

## Prerequisites

- **Xcode stable, not beta.** `xcode-select -p` must point at
  `/Applications/Xcode.app/Contents/Developer`, not `Xcode-beta.app`. Beta
  Xcode + beta iOS Simulator crashes on launch (`Runner quit unexpectedly`)
  and CocoaPods deployment-target checks fail against it. Switch with:
  ```bash
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  ```
- **Apple Developer account** with Admin/Account Holder role on the team
  (needed to generate Distribution certificates for App Store builds).
- **`GoogleService-Info.plist`** for the iOS app in the same Firebase project
  backing Android push (bundle ID `com.github.tiltozavr2545.amicus`,
  project `amicus-a60c1`). This file is gitignored — get it from whoever
  administers the Firebase project, or add the iOS app yourself in
  Firebase Console → Project Settings → Add app → iOS.

## 1. Wire GoogleService-Info.plist into Xcode

Dropping the file into `ios/Runner/` is not enough — Xcode only bundles
files that are registered in `project.pbxproj`. It needs entries in three
sections:

1. `PBXBuildFile` — a build-file record referencing the file.
2. `PBXFileReference` — the file itself, `lastKnownFileType = text.plist.xml`.
3. `PBXGroup` (the `Runner` group) — so it shows up in Xcode's file tree.
4. `PBXResourcesBuildPhase` (the `Resources` build phase `files` array) —
   so it's actually copied into the app bundle at build time.

After editing, verify with `plutil -lint ios/Runner.xcodeproj/project.pbxproj`
(should print `OK`), then `pod install` from `ios/`.

## 2. Fix the Podfile deployment target

Some third-party pods (nanopb, older Firebase transitive deps, etc.) declare
ancient `IPHONEOS_DEPLOYMENT_TARGET` values (9.0, 12.0) that modern Xcode
(26+) rejects outright with "Target Integrity" errors during build. Force a
floor in the `post_install` hook of `ios/Podfile`:

```ruby
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    target.build_configurations.each do |config|
      if config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'].to_f < 15.0
        config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
      end
    end
  end
end
```

Then `rm -rf ios/Pods ios/Podfile.lock && pod install` for a clean rebuild.

## 3. Run on Simulator

```bash
cd app
xcrun simctl list devices available   # pick an iOS 26.x device, not 27.0 beta
xcrun simctl boot "<device-udid>"
open -a Simulator
flutter run --dart-define-from-file=.env -d "<device-udid>"
```

### Known Simulator quirks (not app bugs)

- **No on-screen keyboard when tapping a text field**: Simulator's I/O menu
  → Keyboard → "Connect Hardware Keyboard" is on. Toggle off (`⌘⇧K`) to get
  the real iOS software keyboard back (needed for Cyrillic punctuation,
  emoji picker, etc. — the Mac's hardware layout doesn't match iOS's).
- **Dictation tools (e.g. Wispr Flow) don't work either way**: they inject
  text via a synthetic Cmd+V keystroke. With hardware passthrough on, only
  the bare `V` keystroke lands (garbled). With it off, Simulator no longer
  forwards host keystrokes at all, so nothing lands. Neither state supports
  keystroke-injection dictation tools in Simulator — this only works on a
  real device.
- **Push notifications never work in Simulator**, regardless of Firebase/APNs
  setup — Apple doesn't support APNs delivery to Simulator at all. Expected.

## 4. APNs key for real push delivery

See [ios-push-apns-setup.md](ios-push-apns-setup.md) — a Production-scoped
APNs Auth Key (`.p8`) generated once in Apple Developer → Certificates,
Identifiers & Profiles → Keys, uploaded into Firebase Console → Cloud
Messaging → Apple app configuration. One key covers both TestFlight and App
Store release builds (Xcode signs both with `aps-environment: production`
automatically) — it does *not* cover ad-hoc debug builds run straight from
Xcode to a device (those need Sandbox and a separate key, not required for
the TestFlight workflow below).

## 5. App icon

Generate a 1024×1024 master PNG (no alpha channel — required by Apple, no
transparency allowed on the App Store icon), then resize into every
required slot:

```bash
SRC="path/to/master-1024.png"
IOS_DEST="ios/Runner/Assets.xcassets/AppIcon.appiconset"

# iOS: 15 sizes per Contents.json (20/29/40/60/76/83.5/1024, @1x/2x/3x per idiom)
sips -z 20 20 "$SRC" --out "$IOS_DEST/Icon-App-20x20@1x.png"
# ...repeat for all sizes listed in Contents.json...
sips -z 1024 1024 "$SRC" --out "$IOS_DEST/Icon-App-1024x1024@1x.png"
```

Filenames/sizes above already match this project's `Contents.json` — no
manifest changes needed, just replace the PNG bytes. Verify with `sips -g
hasAlpha -g pixelWidth -g pixelHeight <file>` (App Store icon must show
`hasAlpha: no`, `1024x1024`).

**Android is not a simple resize** — different launchers apply their own
mask shape (circle, squircle, teardrop) to a shared foreground/background
layer pair, so a fixed inset that looks right on one launcher gets cropped
differently on another:

- **Apple (iOS)**: one flat 1024×1024 PNG, no transparency. iOS applies its
  own consistent squircle mask at render time system-wide — the icon design
  itself controls how much inset there is (this project uses 88% fill, no
  masking surprises since there's only one mask shape to design for).
- **Android — Samsung/stock launchers**: mask straight to the edge of a
  108dp canvas, roughly circular.
- **Android — Honor/MIUI-style launchers**: apply a tighter squircle mask
  and crop deeper into the canvas than Samsung does.

Because Android launchers disagree on how much they crop, Android defines
a **safe zone**: only the center 66dp of the 108dp canvas (66/108 ≈ 61%) is
guaranteed visible on every launcher. Content placed outside that zone gets
cropped inconsistently — an 88%-fill foreground (right for iOS) rendered
edge-to-edge with no margin on Honor's tighter squircle, because 88% is well
outside the 61% safe zone. Android's foreground must be scaled to the 61%
safe zone specifically, not to iOS's 88%:

```
android/app/src/main/res/
  mipmap-anydpi-v26/
    ic_launcher.xml         # references the 3 layers below
    ic_launcher_round.xml   # same layers, round-icon variant
  mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/
    ic_launcher_foreground.png   # graphic only, transparent bg, scaled to
                                  # the 66/108 (~61%) safe-zone ratio
    ic_launcher_background.png   # full gradient, no transparency
    ic_launcher_monochrome.png   # foreground silhouette, for Android 13+
                                  # themed icons
```

Regenerate all three adaptive layers together whenever the master icon
changes; a script that composites the master PNG against a transparent
61%-scaled foreground and a full-bleed background is the reliable way to do
this (see git history around the `ic_launcher_*` files for a worked
Python/Pillow example). iOS's 88% and Android's 61% are two different,
correct numbers for two different masking models — don't copy one to the
other.

Note: launch image (splash screen shown while the app loads) shows the app
icon, not a design of its own — a proper branded splash is still pending.

## 6. Export compliance (one-time per Info.plist)

If your app only uses standard HTTPS/TLS (no custom crypto), add to
`ios/Runner/Info.plist` to skip the encryption-documentation prompt on every
future upload:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

Remove this key (or set to `true`) once the app implements actual custom
encryption — a future build will then correctly prompt for the compliance
question again.

## 7. Build the signed IPA

```bash
cd app
flutter pub get
```

`ios/ExportOptions.plist` is already committed in the repo — no need to
recreate it. `signingStyle` is `automatic`, `method` is `app-store-connect`.

Then:

```bash
flutter build ipa --dart-define-from-file=.env \
  --export-options-plist=ios/ExportOptions.plist
```

With `signingStyle = automatic` and an Admin/Account Holder Apple ID signed
into Xcode, this generates a Distribution certificate and provisioning
profile automatically — no manual cert/profile creation needed. Output:
`build/ios/ipa/<app>.ipa`.

## 8. Upload to App Store Connect

Easiest path: open **Transporter.app** (Mac App Store, free, same Apple ID
as the Developer account), drag `build/ios/ipa/<app>.ipa` in, click
**Deliver**. Apple processes it (minutes to ~an hour) before it's usable.

Prerequisite: the app record must already exist in App Store Connect (Apps
→ + → New App, iOS platform, bundle ID selected from the dropdown — the
bundle ID must already be registered as an App ID in Developer Portal →
Identifiers first). If your desired app **name** collides with an existing
App Store listing (common word), you'll need a qualified name — this
project ended up as "Amicus - Circle of Trust".

## 9. Get it into TestFlight

Once the build shows **Ready to Submit** under App Store Connect → your app
→ TestFlight → iOS Builds:

1. Create an internal test group if none exists (TestFlight → Internal
   Testing → **+**).
2. Add yourself/testers by Apple ID email under that group's **Testers**
   tab.
3. Confirm the build is attached under the group's **Builds** tab.
4. If a tester isn't getting notified despite the build looking fully
   attached and compliant: open the build's detail page (click the build
   name/version under Builds), go to **Test Information**, type anything
   into **"What to Test"**, and click **Save**. This fixed a stuck "No
   Builds Available" state on the very first build to a group, but wasn't
   needed on the next build to the same, already-established group —
   testers got the update notification and could tap **Update** in
   TestFlight with no manual step here at all. Treat it as a fallback, not
   a required step per build.
5. Install **TestFlight** (Apple's app) on the test device, sign in with the
   tester's Apple ID, accept the invite, install.

Internal testers (same Apple Developer team) skip Apple's Beta App Review —
only external testers need that. Use internal testing for this whole flow.

## Notes

- None of steps 1–7 require committing/pushing — everything can be done and
  verified locally first. `GoogleService-Info.plist` and
  `android/app/google-services.json` are gitignored and never committed;
  everything else (Podfile, pbxproj, Info.plist, ExportOptions.plist, icon
  PNGs) is normal tracked content.
- Steps 8–9 (App Store Connect / TestFlight setup) are manual, one-time-ish
  clicks in Apple's web UI — not automatable from the terminal without an
  App Store Connect API key, which this project hasn't set up yet.
