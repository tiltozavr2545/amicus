import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/auth/auth_providers.dart';
import 'features/auth/sign_in_screen.dart';
import 'features/auth/sign_up_screen.dart';
import 'features/connections/connections_screen.dart';
import 'features/feed/feed_screen.dart';
import 'features/profile/profile_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final authChanges = ref.watch(supabaseClientProvider).auth.onAuthStateChange;

  return GoRouter(
    initialLocation: '/',
    refreshListenable: _GoRouterRefreshStream(authChanges),
    redirect: (context, state) {
      // Read the session straight off the SDK client rather than through
      // currentUserIdProvider: that provider only recomputes once Riverpod's
      // own subscription to authStateChangesProvider fires, which can lose
      // a race against this callback (triggered by our own separate
      // subscription in _GoRouterRefreshStream below) and read a stale
      // cached value.
      final loggedIn =
          ref.read(supabaseClientProvider).auth.currentSession != null;
      return computeRedirect(
        loggedIn: loggedIn,
        location: state.matchedLocation,
      );
    },
    routes: [
      GoRoute(path: '/', builder: (context, state) => const FeedScreen()),
      GoRoute(
        path: '/profile',
        builder: (context, state) => const ProfileScreen(),
      ),
      GoRoute(
        path: '/connections',
        builder: (context, state) => const ConnectionsScreen(),
      ),
      GoRoute(
        path: '/sign-in',
        builder: (context, state) => const SignInScreen(),
      ),
      GoRoute(
        path: '/sign-up',
        builder: (context, state) => const SignUpScreen(),
      ),
    ],
  );
});

/// Where `redirect` should send the user, or `null` to stay put. A pure
/// function so the decision table can be unit tested without a router,
/// Supabase client, or BuildContext.
String? computeRedirect({required bool loggedIn, required String location}) {
  final onAuthScreen = location == '/sign-in' || location == '/sign-up';
  if (!loggedIn && !onAuthScreen) return '/sign-in';
  if (loggedIn && onAuthScreen) return '/';
  return null;
}

/// Bridges a Stream to Listenable so GoRouter can re-evaluate `redirect`
/// whenever the auth state changes.
class _GoRouterRefreshStream extends ChangeNotifier {
  _GoRouterRefreshStream(Stream<dynamic> stream) {
    _subscription = stream.asBroadcastStream().listen((_) => notifyListeners());
  }

  late final StreamSubscription<dynamic> _subscription;

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
