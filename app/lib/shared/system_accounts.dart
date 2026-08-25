import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/auth/auth_providers.dart';
import 'network_timeout.dart';

/// The Amicus system news account's id — the one hardcoded exception in
/// `is_system_account()` (see migration 20260818150000).
///
/// Only ever the offline fallback for [SystemAccounts.ids]. Anything that
/// reads it directly is a second copy of a rule the server owns, which is
/// exactly what migration 20260821160000 set out to remove.
const systemAccountId = 'e5110c16-91e7-44ca-8075-348bca3efedd';

/// Which accounts the server considers system accounts, asked of the server
/// rather than compiled in.
///
/// One holder for the whole app rather than a private cache inside
/// [FeedRepository], which is where this lived first. The feed asked the
/// server (`system_account_ids()`, 20260821160000) while the theme switch's
/// easter egg went on using the compiled-in literal — so the rule had two
/// copies again, and the copy nobody looked at would have broken silently the
/// first time the account was rotated: `fetchProfile` on a retired uuid throws
/// on `.single()`, and that throw is swallowed by design.
///
/// Cached for the instance's lifetime: the answer changes about as often as a
/// migration is written.
class SystemAccounts {
  SystemAccounts(this._client);

  final SupabaseClient _client;

  List<String>? _cached;

  /// The lookup currently in flight, shared by everyone who asks while it
  /// runs. [FeedRepository.fetchPage] asks on *every* page, and pagination
  /// routinely has more than one page going at once, so without this each of
  /// them opened its own round trip for the same constant.
  Future<List<String>>? _inFlight;

  /// When the last attempt gave up, or null if the last one succeeded (or
  /// none has run yet). See [_retryAfterFailure].
  DateTime? _failedAt;

  /// How long a failed lookup is taken at its word before it is worth asking
  /// again.
  ///
  /// The failure needs remembering for the same reason the success does, and
  /// the old code remembered only the success. `fetchPage` awaits this
  /// *before* it can even issue the posts query, so with no connection the
  /// feed paid a full [networkTimeout] here and then another one on the query
  /// itself — about 24 s before "failed to load" and the cached page
  /// appeared, and the same 24 s again on every pull-to-refresh and every
  /// page of pagination, because nothing recorded that the lookup had just
  /// failed.
  ///
  /// A minute rather than the rest of the session: the fallback below is
  /// today's right answer, but it is compiled in, and a session that happened
  /// to start offline must not keep using it after the account is rotated.
  static const _retryAfterFailure = Duration(minutes: 1);

  /// The server's list, or `[systemAccountId]` if the lookup failed.
  ///
  /// Falling back rather than throwing is deliberate — a feed must not fail to
  /// load because this lookup did, and today's known answer is strictly better
  /// than filtering nothing. An *empty* list, on the other hand, is a real
  /// answer ("there are no system accounts") and is cached and returned as
  /// such; callers must handle it rather than assuming at least one element.
  Future<List<String>> ids() async {
    final cached = _cached;
    if (cached != null) return cached;

    final failedAt = _failedAt;
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < _retryAfterFailure) {
      return const [systemAccountId];
    }

    return _inFlight ??= _fetch();
  }

  Future<List<String>> _fetch() async {
    try {
      final rows = await _client
          .rpc('system_account_ids')
          .timeout(networkTimeout);
      _failedAt = null;
      return _cached = (rows as List<dynamic>).cast<String>();
    } catch (_) {
      _failedAt = DateTime.now();
      return const [systemAccountId];
    } finally {
      _inFlight = null;
    }
  }
}

final systemAccountsProvider = Provider<SystemAccounts>((ref) {
  return SystemAccounts(ref.watch(supabaseClientProvider));
});
