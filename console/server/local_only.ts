import type { NextFunction, Request, Response } from 'express';

/// Хостнеймы, под которыми консоль сама себя зовёт. Порт не проверяется
/// намеренно: браузер работает с Vite на 5173, а тот проксирует в API на 5174,
/// **сохраняя исходный `Host`** (`changeOrigin: false` в vite.config.ts). То
/// есть сюда законно приходит и `127.0.0.1:5173`, и `127.0.0.1:5174`, и
/// `localhost:*`. Значение имеет именно хостнейм: чужое доменное имя в `Host`
/// — это и есть подпись DNS rebinding.
const LOOPBACK_HOSTS = new Set(['127.0.0.1', 'localhost', '::1', '[::1]']);

/// Origin'ы, из которых консоли позволено ходить в своё же API. Любой другой —
/// это страница, открытая в том же браузере, а не консоль.
function isLoopbackOrigin(origin: string): boolean {
  // `null` шлёт, например, страница с `data:`/`file:` — это не консоль.
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

/// Пускать ли этот запрос в локальное API.
///
/// Почему проверка нужна, хотя `listen()` и так слушает только петлю: петля
/// закрывает сеть, но не браузер разработчика. Две атаки проходят мимо
/// биндинга целиком, и обе требуют только того, чтобы человек открыл вкладку:
///
///   * **DNS rebinding.** Чужой домен отвечает A-записью `127.0.0.1`. Тогда
///     для браузера страница и API — ОДИН origin, никакого CORS не возникает,
///     и скрипт со страницы читает ответы консоли как свои. Это и есть путь к
///     базе целиком: консоль ходит service_role-ключом, мимо RLS. Отличает
///     такой запрос ровно одно — в `Host` стоит домен атакующего, а не
///     `127.0.0.1`. Поэтому проверка `Host` здесь главная.
///
///   * **Cross-origin запись.** Ответ браузер не покажет, но сам запрос
///     уйдёт, а запись этим и опасна: `POST /api/moderation/ban` побочный
///     эффект произведёт. `express.json()` разбирает только
///     `application/json`, а он требует preflight, и на него никто не
///     отвечает — но полагаться на это значит полагаться на то, что список
///     «простых» Content-Type никогда не поменяется и что ни один обработчик
///     не начнёт читать параметры из URL. Проверка `Origin` делает отказ
///     явным.
///
/// Третий признак — `Sec-Fetch-Site`. Его ставит сам браузер, подделать со
/// страницы нельзя (это forbidden header), и для запроса из консоли он всегда
/// `same-origin`. Он не заменяет две проверки выше (у curl его нет вовсе), но
/// ловит случай, где `Origin` почему-то не приехал.
///
/// Пустая функция от строк, а не middleware: у неё есть таблица случаев, и
/// таблицу надо проверять тестом, а не глазами.
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
  // `none` — адрес набрали руками или открыли из закладки; `same-origin` —
  // сама консоль. `same-site` и `cross-site` для петли означают чужую
  // страницу.
  if (site && site !== 'same-origin' && site !== 'none') {
    return { ok: false, reason: `Sec-Fetch-Site: ${site}` };
  }

  const remote = headers.remoteAddress;
  // Лишний рубеж на случай, если биндинг когда-нибудь расширят: `::ffff:` —
  // это IPv4-адрес в IPv6-сокете, так его отдаёт Node.
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
  // Логируется, потому что сработавшая проверка — это не опечатка в URL, а
  // либо перенастроенный запуск, либо вкладка, которая только что попыталась
  // сходить в базу проекта.
  console.warn('[api] отказ локальной проверки:', verdict.reason);
  res
    .status(403)
    .json({ error: 'Консоль принимает запросы только с этой машины' });
}
