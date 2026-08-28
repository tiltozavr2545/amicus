// Drains notification_outbox: for each unsent row, picks a random text
// variant for its `kind`, resolves the recipient's device tokens, and sends
// via FCM's HTTP v1 API. Invoked periodically by pg_cron (see migration
// 20260818200000) rather than per-row in real time — an app this size does
// not need sub-second delivery, and polling avoids the extra Vault/pg_net
// wiring a per-insert webhook trigger would need just to carry an auth header.
//
// FCM v1 has no legacy server-key auth; it needs an OAuth2 access token
// obtained by signing a JWT with the service account's private key (RS256)
// and exchanging it at Google's token endpoint. Done by hand with WebCrypto
// below rather than pulling in firebase-admin, which assumes a Node runtime
// this Deno-based edge function doesn't have.

import { createClient } from 'npm:@supabase/supabase-js@2';

const FCM_PROJECT_ID = Deno.env.get('FCM_PROJECT_ID')!;
const SERVICE_ACCOUNT = JSON.parse(Deno.env.get('FCM_SERVICE_ACCOUNT_JSON')!);

// Injected automatically for every Edge Function by the platform — not set
// as custom secrets.
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

// Set as a function secret, and stored in Vault under 'send_push_shared_secret'
// for the pg_cron job to read. Exists for exactly one purpose: proving a caller
// is that cron job. See isAuthorized().
//
// Validated at module load, not at first use, and deliberately fatal. An unset
// variable would otherwise throw a bare TypeError on `.length` inside
// isAuthorized() on every request — a total push outage that reads as a plain
// 500. An *empty* one is worse: `presented.length !== 0` is false for a caller
// sending no header at all, the compare loop never runs, and the check returns
// true. That is the fail-open case, and behind it the only remaining gate is
// `verify_jwt`, which the block below documents as satisfied by the anon key
// shipped inside the APK. Refusing to boot makes both cases loud.
const SEND_PUSH_SECRET = Deno.env.get('SEND_PUSH_SECRET') ?? '';
if (SEND_PUSH_SECRET.length < 32) {
  throw new Error(
    'SEND_PUSH_SECRET is unset or shorter than 32 characters; refusing to start. ' +
      'See migration 20260820160000 for how the value is provisioned.',
  );
}

// How many outbox rows one run claims. Kept in step with the concurrency
// below: 200 rows at 10 in flight is ~20 sequential waves, comfortably inside
// the one-minute cron interval even at FCM's slower percentiles.
const BATCH_LIMIT = 200;
const MAX_IN_FLIGHT = 10;

const APP_TITLE = 'Amicus';

// Four variants per kind so repeat notifications don't read identically.
//
// Keyed by locale first, matching the two locales device_tokens.locale is
// constrained to (see migration 20260820110000) and the app's own
// AppLocalizations.supportedLocales — everything downstream (pickText) picks
// a token's locale row before picking a kind, so an unrecognized locale can
// only come from a stale token predating that constraint, not a live one.
const TEXTS: Record<string, Record<string, string[]>> = {
  ru: {
    new_post: [
      'Новый пост от {author_name} — загляните в ленту',
      '{author_name}: в ленте новый пост',
      'У {author_name} свежий пост, не пропустите',
      'Новости от {author_name} уже в вашей ленте',
    ],
    app_update: [
      'Обновите приложение — вышла новая версия',
      'В Google Play новая версия Amicus — самое время обновиться',
      'Не пропустите обновление — обновите приложение в Google Play',
      'Новая версия ждёт в Google Play, обновите приложение',
    ],
    // Отдельный вид, а не переписанный `app_update`: обычное «вышла новая
    // версия» уходит на каждую заметную выкладку, и если сделать его
    // настойчивым, настойчивость перестанет что-либо значить к третьему разу.
    // Этот — для выкладок, без которых старый клиент показывает не то.
    app_update_important: [
      'Важное обновление Amicus — обновитесь в Google Play',
      'Обязательно обновитесь: на старой версии часть нового работает не так',
      'Важно: вышла новая версия Amicus, обновите приложение в Google Play',
      'Не откладывайте обновление Amicus — эта версия правда важная',
    ],
    inactive_week: [
      'Заскучали без вас — напишите что-нибудь новое',
      'Неделя без постов! Ваши знакомые ждут новостей',
      'Как прошла неделя? Расскажите в новом посте',
      'Тишина в вашей ленте уже неделю — самое время написать пост',
    ],
    digest: [
      'В ленте уже {count} новых постов — загляните, что пропустили',
      '{count} новых постов ждут вас в ленте',
      'Пока вас не было, знакомые опубликовали {count} постов',
      'Лента обновилась: {count} новых постов от знакомых',
    ],
    post_comment: [
      '{author_name} прокомментировал(а) ваш пост',
      'Новый комментарий от {author_name} под вашим постом',
      '{author_name} оставил(а) комментарий к вашему посту',
      'Ваш пост прокомментировал(а) {author_name}',
    ],
    comment_reply: [
      '{author_name} ответил(а) на ваш комментарий',
      'Новый ответ от {author_name} на ваш комментарий',
      '{author_name} прокомментировал(а) в ответ вам',
      'Вам ответил(а) {author_name}',
    ],
    // Названия комнаты в тексте нет намеренно: оно у каждого своё (у комнаты
    // без названия — перечисление остальных участников), собирает его клиент,
    // и вторая копия этого правила разошлась бы с первой при первом же
    // переименовании. В payload при этом едет room_id — под будущий deep link.
    room_message: [
      'Новое сообщение от {author_name}',
      '{author_name} написал(а) в комнате',
      'Вам пишут в комнате: {author_name}',
      'В комнате новое сообщение от {author_name}',
    ],
  },
  en: {
    new_post: [
      'New post from {author_name} — check out the feed',
      '{author_name} just posted something new',
      '{author_name} has a fresh post, don’t miss it',
      'News from {author_name} is in your feed',
    ],
    app_update: [
      'Update the app — a new version is out',
      'A new version just landed on Google Play — update now',
      'Don’t miss the update — update the app via Google Play',
      'A new version is waiting on Google Play, go update',
    ],
    app_update_important: [
      'Important Amicus update — please update in Google Play',
      'Please update: on the old version some new things behave wrongly',
      'Important: a new version of Amicus is out, update in Google Play',
      'Don’t put this update off — this one really matters',
    ],
    inactive_week: [
      'We’ve missed you — write something new',
      'A week without a post! Your connections are waiting to hear from you',
      'How was your week? Tell us in a new post',
      'It’s been quiet in your feed for a week — good time to post',
    ],
    digest: [
      '{count} new posts are waiting in your feed',
      '{count} new posts you might have missed',
      'While you were away, your connections posted {count} times',
      'Your feed updated: {count} new posts from connections',
    ],
    post_comment: [
      '{author_name} commented on your post',
      'New comment from {author_name} on your post',
      '{author_name} left a comment on your post',
      'Your post got a comment from {author_name}',
    ],
    comment_reply: [
      '{author_name} replied to your comment',
      'New reply from {author_name} to your comment',
      '{author_name} replied to you',
      '{author_name} answered your comment',
    ],
    room_message: [
      'New message from {author_name}',
      '{author_name} wrote in a room',
      '{author_name} sent a message in a room',
      'A room has a new message from {author_name}',
    ],
  },
};

// Returns null for a kind this function has no copy for. The outbox's own
// CHECK constraint keeps that unreachable today, but the two live outside each
// other: adding a kind to the constraint without adding it here used to index
// `undefined[…]` and throw from *outside* sendToToken's try, taking the whole
// drain down over one unrecognized row. A null lets the caller skip that row
// and keep going.
function pickText(
  locale: string,
  kind: string,
  payload: Record<string, unknown>,
): string | null {
  const variants = (TEXTS[locale] ?? TEXTS.ru)[kind];
  if (!variants || variants.length === 0) return null;
  const template = variants[Math.floor(Math.random() * variants.length)];
  return template.replace(/\{(\w+)\}/g, (_, key) => String(payload[key] ?? ''));
}

function base64url(bytes: ArrayBuffer | Uint8Array): string {
  const arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let binary = '';
  for (const b of arr) binary += String.fromCharCode(b);
  return btoa(binary).replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
}

let cachedToken: { value: string; expiresAt: number } | null = null;

async function getAccessToken(): Promise<string> {
  if (cachedToken && cachedToken.expiresAt > Date.now() + 30_000) {
    return cachedToken.value;
  }

  const now = Math.floor(Date.now() / 1000);
  const header = { alg: 'RS256', typ: 'JWT' };
  const claims = {
    iss: SERVICE_ACCOUNT.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  };
  const unsigned = `${base64url(new TextEncoder().encode(JSON.stringify(header)))}.${
    base64url(new TextEncoder().encode(JSON.stringify(claims)))
  }`;

  const pem = SERVICE_ACCOUNT.private_key
    .replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '')
    .replace(/\s+/g, '');
  const keyBytes = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));

  const cryptoKey = await crypto.subtle.importKey(
    'pkcs8',
    keyBytes,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    cryptoKey,
    new TextEncoder().encode(unsigned),
  );
  const jwt = `${unsigned}.${base64url(signature)}`;

  const resp = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  });
  if (!resp.ok) {
    throw new Error(`Google token exchange failed: ${resp.status} ${await resp.text()}`);
  }
  const json = await resp.json();
  cachedToken = { value: json.access_token, expiresAt: Date.now() + json.expires_in * 1000 };
  return cachedToken.value;
}

// Only the pg_cron job in migration 20260818200000 is meant to call this.
//
// The platform's own `verify_jwt` gate is satisfied by *any* project JWT —
// including the anon key, which ships inside the APK
// (--dart-define=SUPABASE_ANON_KEY) and is therefore public by construction.
// Without a check of its own, anyone who unpacked the app could drain the
// outbox on demand: every call burns a Google token exchange plus one FCM
// request per recipient device, and stamps `sent_at` on every row it touched
// whether or not delivery worked, so the notifications it fails to deliver are
// simply lost (this is best-effort push, there is no retry queue).
//
// The proof of identity is a dedicated shared secret in its own header, *not*
// the bearer token. Two reasons, one of which was learned the hard way:
//
//   1. The bearer has to stay a valid JWT regardless, because that is what the
//      `verify_jwt` gate in front of this function checks. It is not ours to
//      repurpose.
//   2. Comparing the bearer against `SUPABASE_SERVICE_ROLE_KEY` looks like it
//      should work and does not. This project has two generations of API keys
//      live at once (legacy JWTs and the newer `sb_secret_…` form), the cron
//      job sends the legacy service-role JWT it reads from Vault, and the value
//      the platform injects into this env var is neither the same format nor
//      the same length. Every legitimate call came back 401. A secret that
//      exists only for this handshake cannot drift that way.
//
// Compared with a fixed-time loop rather than `===`: a short-circuiting compare
// leaks the length of the matching prefix to a caller who can time it, which is
// exactly how a secret this shape gets guessed byte by byte.
// Compared as SHA-256 digests rather than raw strings. A fixed-time loop over
// the raw values still has to bail out early when the lengths differ, and that
// early return is itself an oracle: one request per candidate length recovers
// how long the secret is before any guessing of bytes begins. Digests are
// always 32 bytes, so the compare below is unconditional and the length of the
// presented header tells an attacker nothing.
async function sha256(value: string): Promise<Uint8Array> {
  return new Uint8Array(
    await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)),
  );
}

const SECRET_DIGEST = await sha256(SEND_PUSH_SECRET);

async function isAuthorized(req: Request): Promise<boolean> {
  const presented = await sha256(req.headers.get('x-send-push-secret') ?? '');
  let diff = 0;
  for (let i = 0; i < SECRET_DIGEST.length; i++) {
    diff |= presented[i] ^ SECRET_DIGEST[i];
  }
  return diff === 0;
}

// Only one FCM error means "this registration is dead": UNREGISTERED. It is
// read off the error body, never off the HTTP status.
//
// Status alone is not enough, and getting that wrong is destructive. FCM v1
// answers 404 for an unregistered token *and* for a project resource the
// service account cannot reach, and 400 INVALID_ARGUMENT for a malformed
// *message* as much as a malformed token. Treating the status as the verdict
// meant that pointing FCM_PROJECT_ID at the wrong project made every token in
// the batch look dead at once — and the prune below would then delete every
// device registration it had just "diagnosed". A misconfiguration that should
// cost one failed run instead wiped push for everyone until each user happened
// to reopen the app.
//
// A bare `error.status === 'NOT_FOUND'` is NOT enough and is not accepted
// here: that is exactly what a 404 for the wrong project also says. Only the
// explicit UNREGISTERED marker counts — as `error.status`, or as an
// `errorCode` inside `error.details[]`, which is where FCM v1 actually puts
// it. Erring this way costs a dead row lingering until the next real answer;
// erring the other way costs every registration in the batch.
//
// SENDER_ID_MISMATCH is deliberately not pruned either: the token is valid, it
// simply belongs to a different Firebase sender, which is a configuration
// problem on our side, not a dead device.
function isDeadTokenError(status: number, errorBody: unknown): boolean {
  if (status !== 404 && status !== 400) return false;
  const detail = (errorBody as { error?: { status?: string; details?: unknown[] } })?.error;
  if (detail?.status === 'UNREGISTERED') return true;
  for (const d of detail?.details ?? []) {
    if ((d as { errorCode?: string })?.errorCode === 'UNREGISTERED') return true;
  }
  return false;
}

// The access token is now obtained once per run by the caller and passed in,
// rather than fetched inside this try. A revoked or rotated service-account key
// made every single call here return 'error' while the drain went on stamping
// `sent_at` and answering 200 — silent, total, permanent push loss that looked
// healthy from every side. Hoisting it turns that same failure into one 500
// with the claim released, so nothing is consumed and the next run retries.
async function sendToToken(
  accessToken: string,
  token: string,
  body: string,
): Promise<'ok' | 'stale' | 'error'> {
  try {
    const resp = await fetch(
      `https://fcm.googleapis.com/v1/projects/${FCM_PROJECT_ID}/messages:send`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${accessToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          message: { token, notification: { title: APP_TITLE, body } },
        }),
      },
    );
    if (resp.ok) return 'ok';
    const errorBody = await resp.json().catch(() => null);
    return isDeadTokenError(resp.status, errorBody) ? 'stale' : 'error';
  } catch (_) {
    return 'error';
  }
}

// Runs `worker` over `items` with at most `limit` in flight. The sends are
// mutually independent and nothing depends on their order, so the previous
// strictly sequential loop was pure wall-clock: 200 rows × ~2 devices × ~400 ms
// ≈ 160 s, which is how one run came to overlap the next two cron ticks.
async function forEachLimited<T>(
  items: T[],
  limit: number,
  worker: (item: T) => Promise<void>,
): Promise<void> {
  let cursor = 0;
  const runners = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (cursor < items.length) {
      const item = items[cursor++];
      await worker(item);
    }
  });
  await Promise.all(runners);
}

Deno.serve(async (req) => {
  if (!(await isAuthorized(req))) {
    return new Response(JSON.stringify({ error: 'unauthorized' }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // Claims the rows instead of merely reading them: see migration
  // 20260821150000. `for update skip locked` inside that function means a run
  // that overlaps another (the cron fires every minute and does not wait for
  // the previous call) picks up different rows rather than re-sending the same
  // ones.
  const { data: rows, error } = await supabase.rpc('claim_notification_outbox', {
    p_limit: BATCH_LIMIT,
  });

  if (error) {
    return new Response(JSON.stringify({ error: error.message }), { status: 500 });
  }
  if (!rows || rows.length === 0) {
    return new Response(JSON.stringify({ processed: 0, sent: 0 }), { status: 200 });
  }

  // Releases this run's claim so the rows are picked up again immediately
  // rather than waiting out the five-minute reclaim window.
  const releaseClaim = async () => {
    await supabase
      .from('notification_outbox')
      .update({ claimed_at: null })
      .in('id', rows.map((r: { id: string }) => r.id));
  };

  const userIds = [...new Set(rows.map((r: { user_id: string }) => r.user_id))];
  const { data: tokenRows, error: tokenError } = await supabase
    .from('device_tokens')
    .select('user_id, fcm_token, locale')
    .in('user_id', userIds);
  if (tokenError) {
    await releaseClaim();
    return new Response(JSON.stringify({ error: tokenError.message }), { status: 500 });
  }

  const tokensByUser = new Map<string, { token: string; locale: string }[]>();
  for (const t of tokenRows ?? []) {
    const list = tokensByUser.get(t.user_id) ?? [];
    list.push({ token: t.fcm_token, locale: t.locale });
    tokensByUser.set(t.user_id, list);
  }

  // Once per run, before anything is consumed. A failure here is a project-wide
  // problem (revoked key, Google unreachable), not a per-message one, so the
  // claim goes back and the batch is left untouched for the next tick.
  let accessToken: string;
  try {
    accessToken = await getAccessToken();
  } catch (e) {
    await releaseClaim();
    return new Response(
      JSON.stringify({ error: `token exchange failed: ${e instanceof Error ? e.message : e}` }),
      { status: 500, headers: { 'Content-Type': 'application/json' } },
    );
  }

  // Flattened to (row, device) pairs so the concurrency limiter sees every
  // independent send at once instead of one recipient at a time.
  type Delivery = { userId: string; token: string; body: string };
  const deliveries: Delivery[] = [];
  const skippedKinds = new Set<string>();
  const doneIds: string[] = [];

  for (const row of rows as {
    id: string;
    user_id: string;
    kind: string;
    payload: Record<string, unknown> | null;
  }[]) {
    // Every claimed row is consumed, including one with no devices and one
    // whose kind has no copy — leaving either unstamped would make the drain
    // re-pick it forever.
    doneIds.push(row.id);
    for (const { token, locale } of tokensByUser.get(row.user_id) ?? []) {
      const body = pickText(locale, row.kind, row.payload ?? {});
      if (body === null) {
        skippedKinds.add(row.kind);
        continue;
      }
      deliveries.push({ userId: row.user_id, token, body });
    }
  }

  let sentCount = 0;
  // Keyed by user as well as token: two accounts signed in on one device hold
  // two rows carrying the same token string, and a prune matching the token
  // alone would take the other account's registration down with it.
  const staleTokens = new Set<string>();

  await forEachLimited(deliveries, MAX_IN_FLIGHT, async (d) => {
    const result = await sendToToken(accessToken, d.token, d.body);
    if (result === 'ok') sentCount++;
    if (result === 'stale') staleTokens.add(`${d.userId} ${d.token}`);
  });

  // Stamping is what actually consumes the batch, so its failure is reported
  // rather than swallowed: the rows keep their claim, the five-minute window
  // hands them back, and the 500 says why. Silently returning 200 here is how
  // a broken stamp turned into the whole batch being sent a second time.
  const { error: stampError } = await supabase
    .from('notification_outbox')
    .update({ sent_at: new Date().toISOString() })
    .in('id', doneIds);
  if (stampError) {
    return new Response(
      JSON.stringify({ error: `failed to mark rows sent: ${stampError.message}`, sent: sentCount }),
      { status: 500, headers: { 'Content-Type': 'application/json' } },
    );
  }

  for (const pair of staleTokens) {
    const [userId, token] = pair.split(' ');
    await supabase.from('device_tokens').delete().eq('user_id', userId).eq('fcm_token', token);
  }

  return new Response(
    JSON.stringify({
      processed: rows.length,
      sent: sentCount,
      pruned: staleTokens.size,
      ...(skippedKinds.size > 0 ? { skipped_kinds: [...skippedKinds] } : {}),
    }),
    { status: 200, headers: { 'Content-Type': 'application/json' } },
  );
});
