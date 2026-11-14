import type { NextFunction, Request, Response } from 'express';

/// Hostnames the console calls itself by. The port is deliberately not
/// checked: the browser talks to Vite on 5173, which proxies to the API on
/// 5174 **preserving the original `Host`** (`changeOrigin: false` in
/// vite.config.ts). So `127.0.0.1:5173`, `127.0.0.1:5174` and `localhost:*`
/// all legitimately arrive here. What matters is the hostname: a foreign
/// domain name in `Host` is the signature of DNS rebinding.
const LOOPBACK_HOSTS = new Set(['127.0.0.1', 'localhost', '::1', '[::1]']);

/// Origins the console is allowed to call its own API from. Any other one
/// is a page open in the same browser, not the console.
function isLoopbackOrigin(origin: string): boolean {
  // `null` is sent by, for example, a `data:`/`file:` page — not the console.
  if (origin === 'null') return false;
  let url: URL;
  try {
    url = new URL(origin);
  } catch {
    return false;
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return false;
  return LOOPBACK_HOSTS.has(url.hostname);
}

function hostnameOf(host: string): string | null {
  // `[::1]:5174` -> `[::1]`, `127.0.0.1:5174` -> `127.0.0.1`.
  if (host.startsWith('[')) {
    const end = host.indexOf(']');
    return end === -1 ? null : host.slice(0, end + 1);
  }
  const trimmed = host.split(':')[0];
  return trimmed === '' ? null : trimmed;
}

export type GuardVerdict = { ok: true } | { ok: false; reason: string };

/// Whether to let this request into the local API.
///
/// Why the check is needed even though `listen()` only listens on loopback:
/// loopback closes off the network, but not the developer's browser. Two
/// attacks bypass the binding entirely, and both only require a person to
/// open a tab:
///
///   * **DNS rebinding.** A foreign domain answers with an A record of
///     `127.0.0.1`. Then, to the browser, the page and the API are ONE origin,
///     no CORS arises, and the page's script reads the console's responses as
///     its own. This is the path to the whole database: the console uses the
///     service_role key, bypassing RLS. Exactly one thing tells such a request
///     apart: `Host` holds the attacker's domain, not `127.0.0.1`. That is why
///     the `Host` check is the main one here.
///
///   * **Cross-origin writes.** The browser won't show the response, but the
///     request itself goes out, and that is what makes writes dangerous:
///     `POST /api/moderation/ban` will produce its side effect.
///     `express.json()` only parses `application/json`, which requires a
///     preflight that nobody answers — but relying on that means relying on
///     the list of "simple" Content-Types never changing and on no handler
///     ever starting to read parameters from the URL. The `Origin` check makes
///     the rejection explicit.
///
/// The third signal is `Sec-Fetch-Site`. The browser sets it itself, a page
/// can't forge it (it is a forbidden header), and for a request from the
/// console it is always `same-origin`. It doesn't replace the two checks above
/// (curl doesn't send it at all), but it catches the case where `Origin` for
/// some reason didn't arrive.
///
/// A pure function of strings, not middleware: it has a table of cases, and
/// the table should be verified by a test, not by eye.
export function guardLocalRequest(headers: {
  host?: string;
  origin?: string;
  secFetchSite?: string;
  remoteAddress?: string;
}): GuardVerdict {
  const host = headers.host?.trim();
  if (!host) {
    return { ok: false, reason: 'запрос без Host' };
  }
  const hostname = hostnameOf(host);
  if (hostname === null || !LOOPBACK_HOSTS.has(hostname)) {
    return { ok: false, reason: `Host не петлевой: ${host}` };
  }

  const origin = headers.origin?.trim();
  if (origin && !isLoopbackOrigin(origin)) {
    return { ok: false, reason: `Origin не петлевой: ${origin}` };
  }

  const site = headers.secFetchSite?.trim();
  // `none` — the address was typed by hand or opened from a bookmark;
  // `same-origin` — the console itself. `same-site` and `cross-site` on
  // loopback mean a foreign page.
  if (site && site !== 'same-origin' && site !== 'none') {
    return { ok: false, reason: `Sec-Fetch-Site: ${site}` };
  }

  const remote = headers.remoteAddress;
  // An extra line of defence in case the binding is ever widened: `::ffff:`
  // is an IPv4 address on an IPv6 socket, which is how Node reports it.
  if (remote !== undefined) {
    const plain = remote.startsWith('::ffff:') ? remote.slice(7) : remote;
    if (plain !== '127.0.0.1' && plain !== '::1') {
      return { ok: false, reason: `адрес не петлевой: ${remote}` };
    }
  }

  return { ok: true };
}

export function localOnly(req: Request, res: Response, next: NextFunction) {
  const verdict = guardLocalRequest({
    host: req.headers.host,
    origin:
      typeof req.headers.origin === 'string' ? req.headers.origin : undefined,
    secFetchSite:
      typeof req.headers['sec-fetch-site'] === 'string'
        ? req.headers['sec-fetch-site']
        : undefined,
    remoteAddress: req.socket.remoteAddress ?? undefined,
  });
  if (verdict.ok) {
    next();
    return;
  }
  // Logged because a tripped check is not a typo in a URL, but either a
  // reconfigured launch or a tab that just tried to reach the project's
  // database.
  console.warn('[api] отказ локальной проверки:', verdict.reason);
  res
    .status(403)
    .json({ error: 'Консоль принимает запросы только с этой машины' });
}
