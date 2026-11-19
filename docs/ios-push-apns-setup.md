# iOS Push Notifications — APNs Key Setup (Firebase Cloud Messaging)

**Previously configured and tested.** The APNs key and successful delivery
were recorded during the iOS rollout; this is not a fresh check of Firebase
or a guarantee of current delivery. The document is kept for checking that
the key is still in place, and repeating the upload if it ever has to be done
again (the key is revoked, someone deletes it from Firebase, or a new Firebase
project appears).

What it covers is the one step that connects Amicus's existing push code to
Apple. Everything else — the entitlement, the Firebase registration, the
outbox and the Edge Function — is described elsewhere: see
[operations.md](operations.md) for the sending side and
[ios-deployment-guide.md](ios-deployment-guide.md) for the build. Written as a
runbook rather than as design notes. Keep current credentials outside it.

## Context

Amicus already has iOS push notifications wired on the app side:
- `Runner.entitlements` has `aps-environment` set.
- The Xcode project registers `GoogleService-Info.plist` as a resource.
  Restore the gitignored file from the Firebase configuration before building.
- Bundle ID: `com.github.tiltozavr2545.amicus`
- Firebase project ID: `amicus-a60c1`

This is the **same Firebase project already used for Android push**. We are
just adding the iOS side of Cloud Messaging to it — no new project needed.

The piece this document is about: Firebase needs an **APNs Authentication
Key** before it can actually deliver anything to iOS devices. Without one,
`Firebase.initializeApp()` succeeds and the app still *registers* for push —
a token appears in `device_tokens` exactly as on Android — but no notification
ever arrives, not in TestFlight and not on a real device. Nothing fails
loudly, which is why the section below exists: a working registration is not
evidence of a working key, and the two are easy to confuse.

## Checking that the key is in place

Two ways to confirm it, useful when push stops arriving on iOS and you need to
rule this out — or before repeating the upload for a rotated key.

**The authoritative check, in Firebase.** [Firebase
Console](https://console.firebase.google.com/) → project **`amicus-a60c1`** →
gear icon → **Project settings** → **Cloud Messaging** tab → **Apple app
configuration**. Under the iOS app `com.github.tiltozavr2545.amicus`:

- a key is in place if the **APNs Authentication Key** row lists a Key ID
  with a delete/replace control next to it;
- it is missing if that row shows an **Upload** button and nothing else.

**The functional check, from the database.** Useful when you cannot get into
the Firebase console, or want to confirm that delivery actually works rather
than that a key merely exists. Queue one notification to yourself through the
Management API (`POST /v1/projects/<ref>/database/query`, see "Working
conventions" in [../AGENTS.md](../AGENTS.md)):

```sql
-- Any kind works; `app_update` is the one whose text needs no payload fields.
-- This does send a real "update the app" push to your own devices.
insert into public.notification_outbox (user_id, kind, payload)
select u.id, 'app_update', '{"build": 1, "version": "apns-check"}'::jsonb
  from auth.users u
 where u.email = 'your@email.here';
```

The `drain-notification-outbox` cron picks it up within a minute and calls the
Edge Function through `pg_net`, which keeps the response. Read it:

```sql
select status_code, content::text, created
  from net._http_response
 order by created desc
 limit 3;
```

- `sent` counts requests accepted by FCM during the run. Confirm the specific
  notification arrived on the iPhone.
- With the updated sender, HTTP 502 and `errors` indicate delivery errors.
  A `pending` row can be retried and a terminal failure records
  `failed_at` with `last_delivery_error` in `notification_outbox`. Check
  Firebase and the APNs key configuration when diagnosing an iOS-only error.
- A completed row can also represent a recipient with no active registration.
  Match the queue result to the iPhone's registration and actual delivery.

Two caveats. `sent` counts all of that user's devices, so run this on an
account whose only registered device is the iPhone — otherwise an Android
phone in the same account makes `sent` non-zero regardless. And
`net._http_response` is pruned after a few hours, so read it soon after.

A `device_tokens` row verifies registration. A successful physical-device
or TestFlight smoke test verifies the Production APNs path. Supported
simulators use APNs Sandbox. See
[the iOS guide](ios-deployment-guide.md#3-device-and-simulator-verification).

## Doing the upload again

The steps as they were performed the first time. Needed only if the key is
gone or replaced — nothing here has to be repeated for an ordinary release.

### 1. Get the existing APNs key details from the team administrator

The APNs Auth Key was generated during setup. Obtain its existing `.p8` file
from the team administrator
directly (AirDrop, secure file share, etc. — never over chat/email in plain
text), plus the details below — Firebase asks for the Key ID and the Team ID,
the rest is context:

- **Key Name**: `Amicus APNs Key`
- **Key ID**: obtain from the private key record
- **Team ID**: use the current Apple Developer team
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
6. Select the `.p8` file, enter the **Key ID** and **Team ID** the administrator gave
   you.
7. Save.

### 3. Verify

Both checks from "Checking that the key is in place" above, in that order: the
Cloud Messaging tab should stop offering an **Upload** button and start
listing the Key ID, and the queued-notification check should come back
`"sent":1` with the push actually arriving on a **physical iOS device** or
through TestFlight. A simulator Sandbox test does not verify this Production
configuration.

## Notes

- One APNs key can cover **all** iOS apps under the same Apple Developer
  team, so this step should not need to be repeated for future iOS apps on
  the same team.
- Don't need to touch anything on the Android side — this is purely
  additive for iOS.
- If you don't already have **Editor** (or higher) access on the
  `amicus-a60c1` Firebase project, ask its administrator to grant it, or have them do
  the upload with the existing private key details.
