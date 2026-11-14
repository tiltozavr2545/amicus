# amicus

The Amicus Flutter app. Only the client code lives here — the full project description, setup, documentation and plans are in the repository root: [../README.md](../README.md).

Running from this folder:

```bash
flutter pub get
flutter run --dart-define-from-file=.env
```

Client-specific references:

- [Client architecture](../docs/client-architecture.md): navigation, preferences,
  media caching and account-scoped post drafts.
- [Interface design](../docs/interface-design.md): themes, typography and layout.
- `make verify` from the repository root runs dependency, formatting, analysis
  and test checks.
