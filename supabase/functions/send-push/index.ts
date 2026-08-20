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
const SEND_PUSH_SECRET = Deno.env.get('SEND_PUSH_SECRET')!;

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
      '{author_name} commented on your post',
    ],
    comment_reply: [
      '{author_name} replied to your comment',
      'New reply from {author_name} to your comment',
      '{author_name} replied to you',
      '{author_name} answered your comment',
    ],
  },
};

function pickText(
  locale: string,
  kind: string,
  payload: Record<string, unknown>,
): string {
  const variants = (TEXTS[locale] ?? TEXTS.ru)[kind];
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
function isAuthorized(req: Request): boolean {
  const presented = req.headers.get('x-send-push-secret') ?? '';
  if (presented.length !== SEND_PUSH_SECRET.length) return false;
  let diff = 0;
  for (let i = 0; i < presented.length; i++) {
    diff |= presented.charCodeAt(i) ^ SEND_PUSH_SECRET.charCodeAt(i);
  }
  return diff === 0;
}

// FCM's per-message response distinguishes a dead token (404/400 —
// unregistered or malformed) from everything else (network blip, quota,
// transient 5xx). Only the former is safe to prune; the rest just fails this
// round and the row still gets marked sent (best-effort push, not
// at-least-once — a missed nudge isn't worth a retry queue for this app).
async function sendToToken(token: string, body: string): Promise<'ok' | 'stale' | 'error'> {
  // Everything in here is per-token best-effort, including the token
  // exchange: letting a throw escape would abort the whole drain, leaving
  // `sent_at` unset on rows this run already delivered — so the next minute's
  // run sends those again. One duplicate push is worse than one dropped one.
  try {
    const accessToken = await getAccessToken();
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
    if (resp.status === 404 || resp.status === 400) return 'stale';
    return 'error';
  } catch (_) {
    return 'error';
  }
}

Deno.serve(async (req) => {
  if (!isAuthorized(req)) {
    return new Response(JSON.stringify({ error: 'unauthorized' }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  const { data: rows, error } = await supabase
    .from('notification_outbox')
    .select('id, user_id, kind, payload')
    .is('sent_at', null)
    .order('created_at', { ascending: true })
    .limit(200);

  if (error) {
    return new Response(JSON.stringify({ error: error.message }), { status: 500 });
  }
  if (!rows || rows.length === 0) {
    return new Response(JSON.stringify({ processed: 0, sent: 0 }), { status: 200 });
  }

  const userIds = [...new Set(rows.map((r) => r.user_id as string))];
  const { data: tokenRows, error: tokenError } = await supabase
    .from('device_tokens')
    .select('user_id, fcm_token, locale')
    .in('user_id', userIds);
  if (tokenError) {
    return new Response(JSON.stringify({ error: tokenError.message }), { status: 500 });
  }

  const tokensByUser = new Map<string, { token: string; locale: string }[]>();
  for (const t of tokenRows ?? []) {
    const list = tokensByUser.get(t.user_id) ?? [];
    list.push({ token: t.fcm_token, locale: t.locale });
    tokensByUser.set(t.user_id, list);
  }

  let sentCount = 0;
  const staleTokens = new Set<string>();
  const doneIds: string[] = [];

  for (const row of rows) {
    const tokens = tokensByUser.get(row.user_id as string) ?? [];
    for (const { token, locale } of tokens) {
      const body = pickText(
        locale,
        row.kind as string,
        (row.payload as Record<string, unknown>) ?? {},
      );
      const result = await sendToToken(token, body);
      if (result === 'ok') sentCount++;
      if (result === 'stale') staleTokens.add(token);
    }
    doneIds.push(row.id as string);
  }

  if (doneIds.length > 0) {
    await supabase
      .from('notification_outbox')
      .update({ sent_at: new Date().toISOString() })
      .in('id', doneIds);
  }
  if (staleTokens.size > 0) {
    await supabase.from('device_tokens').delete().in('fcm_token', [...staleTokens]);
  }

  return new Response(JSON.stringify({ processed: rows.length, sent: sentCount }), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
});
