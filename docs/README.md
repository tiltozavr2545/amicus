# Amicus documentation

The current release version is **0.19.1+78**. See the
[changelog](../CHANGELOG.md#0191) for the changes and
[operations](operations.md#release) for the separate Play, GitHub APK,
TestFlight, and backend delivery steps.

## Current references

| Topic | Primary document |
| --- | --- |
| Product, features, local startup | [Project README](../README.md) |
| Schema, grants, visibility, storage | [Data model](data-model.md) |
| Client behavior, navigation, drafts, chat | [Client architecture](client-architecture.md) |
| Visual tokens and interactions | [Interface design](interface-design.md) |
| Rendering, foreground work, image memory and validation limits | [Performance](performance.md) |
| Jobs, secrets, migrations, Android delivery | [Operations](operations.md) |
| Local administration and console verification | [Console README](../console/README.md) |
| iOS build, signing and TestFlight | [iOS deployment](ios-deployment-guide.md) |
| Stable remote iOS builds | [Xcode Cloud](xcode-cloud-setup.md) |
| Starting a Cloud build through the API | [App Store Connect API](app-store-connect-api-automation.md) |
| Apple push setup and diagnostics | [APNs](ios-push-apns-setup.md) |
| Store copy awaiting review | [App Store listing draft](review/app-store-listing-draft.md) |
| Outstanding work and open questions | [Future development](future-development.md) |

[GitHub Pages sources](gh-pages/) contain the privacy policy, terms, email
confirmation and password-reset pages. A push to `main` changing these files
deploys them through `sync-gh-pages.yml`; editing local files does not publish.

## History and maintenance

[Project brief](project-brief.md), [MVP implementation plan](implementation-plan.md)
and [former backlog](future-development.archive.md) describe historical states.
Do not read their Android-only scope or old schema sketches as current behavior.
Older migration bodies live in the archive tags documented in
[operations](operations.md#migrations).

Update the primary reference when behavior changes, keep completed work in the
changelog and unresolved work in future development. Record device checks
separately from automated tests; passing tests do not establish store approval,
deployed schema equality or measured battery savings. Repository text is English;
actual Russian localization remains Russian. Environment and agent conventions
belong in [AGENTS.md](../AGENTS.md).
