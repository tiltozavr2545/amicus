import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/auth/auth_providers.dart';
import 'features/auth/sign_in_screen.dart';
import 'features/auth/sign_up_screen.dart';
import 'features/connections/connections_screen.dart';
import 'features/profile/profile_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final authChanges = ref.watch(supabaseClientProvider).auth.onAuthStateChange;

  return GoRouter(
    initialLocation: '/',
    refreshListenable: _GoRouterRefreshStream(authChanges),
    redirect: (context, state) {
      final loggedIn = ref.read(currentUserIdProvider) != null;
      final onAuthScreen =
          state.matchedLocation == '/sign-in' ||
          state.matchedLocation == '/sign-up';

      if (!loggedIn && !onAuthScreen) return '/sign-in';
      if (loggedIn && onAuthScreen) return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (context, state) => const ProfileScreen()),
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
