# amicus

The Amicus Flutter app. Only the client code lives here — the full project description, setup, documentation and plans are in the repository root: [../README.md](../README.md).

Working version: **0.19.1+78 (unreleased)**. Android development and verification
use Flutter 3.32.8 on the Intel Mac; the iOS UIScene runner uses the independent
SDK pin described in the [iOS guide](../docs/ios-deployment-guide.md).

Running from this folder:

```bash
flutter pub get
flutter run --dart-define-from-file=.env
```

Client-specific references:

- [Client architecture](../docs/client-architecture.md): navigation, preferences,
  media caching and account-scoped post drafts.
- [Interface design](../docs/interface-design.md): themes, typography and layout.
- [Performance](../docs/performance.md): bounded image decoding, foreground
  work, stable media state and automated/device verification limits.
- [Documentation index](../docs/README.md): current references and history.
- `make verify` from the repository root runs dependency, formatting, analysis
  and test checks.
