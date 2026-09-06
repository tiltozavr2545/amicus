import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The provider container behind [context], captured so it can still be used
/// **after** an `await`.
///
/// The rule this encodes, stated once here instead of seven times:
/// **`ref` dies with its widget; the refresh it triggers must not.**
///
/// `WidgetRef` is not a long-lived handle — it is backed by the element's
/// `BuildContext`, and every one of its methods starts with a check that
/// throws outright once the widget is gone:
///
/// ```
/// StateError: Using "ref" when a widget is about to or has been unmounted
/// is unsafe.
/// ```
///
/// That is a real `throw` in release builds, not a debug assert. So the
/// ordinary shape
///
/// ```dart
/// await repository.doTheThing();
/// ref.invalidate(someProvider);   // <-- throws if the screen was popped
/// if (!mounted) return;
/// ```
///
/// is broken in exactly the case it exists for: the user taps, the request is
/// slow, they leave the screen, the request lands. The throw is then caught by
/// the method's own `catch`, which returns on `!mounted` — so nothing is
/// reported and the *refresh silently never happens*. Every list that was
/// supposed to reload keeps showing the state from before the tap, and its
/// buttons keep offering an action the server has already performed.
///
/// Moving the `mounted` check above the `ref` calls does not fix it either:
/// that trades a swallowed throw for a deliberately skipped refresh, and the
/// stale lists are the *point* — they belong to other screens (the shell's
/// IndexedStack keeps the feed, rooms and connections tabs alive behind
/// whatever is on top), which are still there after this one is gone.
///
/// The container, unlike the ref, belongs to the root `ProviderScope` and
/// lives as long as the app. Capture it **before** the `await` — reading it
/// needs the context too — and the refresh survives the screen:
///
/// ```dart
/// final refresh = refreshAfterAwait(context);
/// await repository.doTheThing();
/// refresh.invalidate(someProvider);
/// if (!mounted) return;
/// // …only now touch context / setState
/// ```
///
/// `listen: false` because this is a one-shot lookup, not a dependency: the
/// caller is not rebuilding on anything here.
ProviderContainer refreshAfterAwait(BuildContext context) =>
    ProviderScope.containerOf(context, listen: false);
