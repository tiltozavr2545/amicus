# iOS Push Notifications — APNs Key Setup (Firebase Cloud Messaging)

## Context

Amicus already has iOS push notifications wired on the app side:
- `Runner.entitlements` has `aps-environment` set.
- `GoogleService-Info.plist` is present and registered in the Xcode project.
- Bundle ID: `com.github.tiltozavr2545.amicus`
- Firebase project ID: `amicus-a60c1`

This is the **same Firebase project already used for Android push**. We are
just adding the iOS side of Cloud Messaging to it — no new project needed.

What's still missing: Firebase needs an **APNs Authentication Key** to be
able to actually deliver push notifications to iOS devices. Without it,
`Firebase.initializeApp()` succeeds and the app can *register* for push, but
no notification will ever arrive — not even in TestFlight or on a real
device.

## What you need to do

### 1. Get the APNs key details from Madrus

The APNs Auth Key has already been generated (Apple only allows downloading
the `.p8` file once, so Madrus did this himself). Ask him for the `.p8` file
directly (AirDrop, secure file share, etc. — never over chat/email in plain
text), plus these two IDs:

- **Key Name**: `Amicus APNs Key`
- **Key ID**: `UUXUV8VJX6`
- **Team ID**: `8APG7DF2J3`
- **Environment**: Production (this key is scoped to Production only — it
  cannot be used for Sandbox/debug builds, and this scope can't be changed
  after the fact)
- **Key Restriction**: Team Scoped (All Topics) — covers all apps under this
  Apple Developer team, not just Amicus

### 2. Upload it into Firebase Cloud Messaging

1. Go to [Firebase Console](https://console.firebase.google.com/) → open
   project **`amicus-a60c1`**.
2. Click the gear icon → **Project settings**.
3. Go to the **Cloud Messaging** tab.
4. Scroll to the **Apple app configuration** section. You should see the iOS
   app `com.github.tiltozavr2545.amicus` listed there (it appears once someone
   has added the iOS app to the Firebase project via `GoogleService-Info.plist`
   — this is already done).
5. Under **APNs Authentication Key**, click **Upload**.
6. Select the `.p8` file, enter the **Key ID** and **Team ID** Madrus gave
   you.
7. Save.

### 3. Verify

- The Cloud Messaging tab should now show the key as configured (no more
  "upload a key" prompt for the iOS app).
- Real push delivery can only be verified on a **physical iOS device** (or
  via TestFlight) — the iOS Simulator cannot receive real push notifications
  at all, regardless of this setup. That's expected and not a bug.

## Notes

- One APNs key can cover **all** iOS apps under the same Apple Developer
  team, so this step should not need to be repeated for future iOS apps on
  the same team.
- Don't need to touch anything on the Android side — this is purely
  additive for iOS.
- If you don't already have **Editor** (or higher) access on the
  `amicus-a60c1` Firebase project, ask Madrus to grant it, or have him do
  the upload himself with your `.p8` file details.
