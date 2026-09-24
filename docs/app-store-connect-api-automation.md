# App Store Connect API Automation

Triggers an Xcode Cloud build directly via the App Store Connect REST API, instead of clicking **Start Build** in the web UI. Useful when a build needs to be kicked off from a script, from CI, or by an agent that has no way to sign in through a browser (App Store Connect sign-in normally requires an Apple ID plus 2FA, which no headless credential can complete unattended).

This is a first-party, documented Apple capability — not a workaround. See [Apple's Xcode Cloud Workflows and Builds reference](https://developer.apple.com/documentation/appstoreconnectapi/xcode-cloud-workflows-and-builds).

## Prerequisites

- Admin, App Manager, or Developer role in App Store Connect (needed to generate an API key).
- An existing Xcode Cloud workflow already configured — see [xcode-cloud-setup.md](xcode-cloud-setup.md). This doc only covers *triggering* a build on a workflow that already works; it assumes step 3 there (workflow creation) is done.

## 1. Generate an API key

App Store Connect → **Users and Access** → **Integrations** tab → **Keys** (this is a different key type from the In-App Purchase or App Store Server API keys — make sure you're on the right sub-tab):

1. Click **Generate API Key** (or the **+** button).
2. Give it a name (e.g. `amicus-xcode-cloud-trigger`) and pick a role — **Developer** is enough to read/start Xcode Cloud builds; it doesn't need Admin.
3. Download the `.p8` private key file **immediately** — App Store Connect shows it exactly once and cannot regenerate it. Store it somewhere safe, outside the repo, never committed.
4. Note down the two IDs shown next to the key in the list:
   - **Key ID** (short, e.g. `D383SF739`)
   - **Issuer ID** (a UUID, shown once at the top of the Keys page, shared by all keys on the team)

These three things (Key ID, Issuer ID, the `.p8` file's contents) are together the credential. Treat the `.p8` file exactly like a private SSH key or a database password — store it read-protected, never paste its contents into chat, a commit, or a log.

## 2. Find the Xcode Cloud workflow ID

App Store Connect → your app → **Settings** → **Xcode Cloud** → select the workflow you want to trigger (the one built in [xcode-cloud-setup.md](xcode-cloud-setup.md) step 3). The workflow ID is the last UUID segment in the page's URL:

```
https://appstoreconnect.apple.com/teams/{team-id}/apps/{app-id}/ci/workflows/{workflow-id}
```

Note it down alongside the key details — it doesn't change unless the workflow itself is deleted and recreated.

## 3. Sign a JWT for each request

Every App Store Connect API call needs a fresh JSON Web Token, signed with the `.p8` key, valid for at most 20 minutes. The claims:

```json
{
  "iss": "<issuer-id-uuid>",
  "exp": "<now + up to 1200 seconds, as a unix timestamp>",
  "aud": "appstoreconnect-v1"
}
```

Signed with algorithm `ES256`, header includes `kid: <key-id>`.

A minimal Python signer (needs `pyjwt` and `cryptography`):

```python
import time
import jwt  # pip install pyjwt cryptography

def make_token(issuer_id: str, key_id: str, private_key_path: str) -> str:
    with open(private_key_path) as f:
        private_key = f.read()
    payload = {
        "iss": issuer_id,
        "exp": int(time.time()) + 1200,
        "aud": "appstoreconnect-v1",
    }
    return jwt.encode(payload, private_key, algorithm="ES256", headers={"kid": key_id})
```

Never write the issuer ID, key ID, or the `.p8` file's contents directly into a script committed to the repo — read them from environment variables or a local file outside version control at call time.

## 4. Start a build

```bash
curl -s -X POST "https://api.appstoreconnect.apple.com/v1/ciBuildRuns" \
  -H "Authorization: Bearer ***" \
  -H "Content-Type: application/json" \
  -d '{
    "data": {
      "type": "ciBuildRuns",
      "relationships": {
        "workflow": {
          "data": { "type": "ciWorkflows", "id": "<workflow-id>" }
        }
      }
    }
  }'
```

A successful response returns `201` with the new build run's `id` and `number`. Poll `GET /v1/ciBuildRuns/{id}` (or the workflow's build list) to watch it progress through `PENDING` → `RUNNING` → `COMPLETE`.

**Not yet independently verified against this project**: whether `ciBuildRuns` requires an explicit `sourceBranchOrTag`/git-reference relationship in the request body to pick a non-default branch, or whether it always builds whatever the workflow's own start condition currently points at. Confirm against Apple's OpenAPI spec (or a client library, see below) before the first real trigger, and update this doc with the confirmed behavior once verified.

## 5. Existing tooling (don't hand-roll if this covers the need)

- **fastlane** — the `app_store_connect_api_key` action generates the JWT from the same three credentials and is already the standard way most Flutter/iOS pipelines authenticate to App Store Connect. See [fastlane's App Store Connect API docs](https://docs.fastlane.tools/app-store-connect-api).
- **GitHub Actions** — [`yorifuji/actions-xcode-cloud-dispatcher`](https://github.com/marketplace/actions/xcode-cloud-dispatcher) wraps steps 3–4 above as a reusable action, useful if this project ever wants Xcode Cloud triggered automatically from a GitHub Actions workflow (e.g. on every push to `develop`) rather than on demand.

## Credential storage

The `.p8` file, Key ID, and Issuer ID are a standing secret, same category as the Supabase Management API token or `SUPABASE_SERVICE_ROLE_KEY` — never committed, never displayed in full, never piped through a tool call that could echo it into a transcript. Whoever runs the trigger script supplies the path/values themselves (e.g. via a `read -s`-style local prompt or a gitignored env file), the same convention already used for Management API tokens elsewhere in this project (see AGENTS.md).

## Revoking a key

If a key is ever suspected compromised: App Store Connect → Users and Access → Integrations → Keys → select the key → **Revoke**. Takes effect immediately; any script relying on it starts failing auth until a new key is generated and steps 1–2 are redone with the new IDs.
