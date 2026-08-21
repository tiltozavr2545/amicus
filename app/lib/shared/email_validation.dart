import '../l10n/app_localizations.dart';

/// What is wrong with an address the user typed, or null when nothing is.
enum EmailProblem {
  empty,

  /// Doesn't parse as an address at all — a missing `@`, a domain with no dot,
  /// stray spaces.
  malformed,

  /// Parses fine, but the domain is reserved by the RFCs precisely so that it
  /// can never exist. Mail to it cannot be delivered by anyone, ever.
  undeliverableDomain,
}

/// Domains that are guaranteed never to receive mail.
///
/// RFC 2606 reserves `example.com/.net/.org` and the `.test`, `.example`,
/// `.invalid` and `.localhost` TLDs for documentation and testing; RFC 6761
/// repeats the TLD half. This is not a spam or disposable-mail blocklist —
/// those are judgement calls about real domains, they need constant upkeep,
/// and getting one wrong locks a real person out. Everything here is
/// undeliverable by specification, so refusing it costs nobody anything.
const _reservedDomains = {
  'example.com',
  'example.net',
  'example.org',
  'example.edu',
  'localhost',
};

const _reservedTlds = {'test', 'example', 'invalid', 'localhost', 'local'};

/// Conservative on purpose: its job is to catch typos and obvious junk before
/// a request goes out, not to be the authority on RFC 5321. Anything it lets
/// through is still the server's call. The local part follows the characters
/// RFC 5322 allows unquoted; the domain must be dot-separated labels, which is
/// what rejects `me@localhost` and `me@gmail` while leaving plus-addressing,
/// subdomains and long TLDs alone.
final _emailPattern = RegExp(
  r"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+"
  r'@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
  r'(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$',
);

/// Checks [raw] before it is worth sending anywhere.
///
/// Client-side only, and deliberately so: it exists to give the person typing
/// an answer immediately instead of after a round trip, and to stop addresses
/// that provably cannot receive the confirmation link — a signup to one of
/// those leaves an account that can never be confirmed and never signed into,
/// which is exactly the wreckage this was written to stop creating. It is not
/// a security control; anyone can call the auth API directly, so nothing may
/// depend on this having run.
EmailProblem? validateEmail(String raw) {
  final email = raw.trim();
  if (email.isEmpty) return EmailProblem.empty;
  if (!_emailPattern.hasMatch(email)) return EmailProblem.malformed;

  // Everything after the last `@`: the pattern above already guarantees there
  // is exactly one, but the local part may legally contain characters that
  // make a naive split misleading.
  final domain = email.substring(email.lastIndexOf('@') + 1).toLowerCase();
  if (_reservedDomains.contains(domain)) {
    return EmailProblem.undeliverableDomain;
  }
  final tld = domain.substring(domain.lastIndexOf('.') + 1);
  if (_reservedTlds.contains(tld)) return EmailProblem.undeliverableDomain;

  return null;
}

/// Localized wording for [problem], same shape as [authErrorMessage] in
/// `auth_error_message.dart` — the message lives next to the rule that
/// produces it rather than being spelled out at each screen.
String emailProblemMessage(AppLocalizations l10n, EmailProblem problem) {
  return switch (problem) {
    EmailProblem.empty => l10n.emailRequiredError,
    EmailProblem.malformed => l10n.invalidEmailError,
    EmailProblem.undeliverableDomain => l10n.undeliverableEmailError,
  };
}
