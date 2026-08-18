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

const APP_TITLE = 'Amicus';

// Four variants per kind so repeat notifications don't read identically.
// `new_post` covers both the system account and favorited Connections — the
// account's own display name ("Amicus") already satisfies "say who posted"
// for itself, so one template set covers both without a separate copy.
const TEXTS: Record<string, string[]> = {
  new_post: [
    'Новый пост от {author_name} — загляните в ленту',
    '{author_name}: в ленте новый пост',
    'У {author_name} свежий пост, не пропустите',
    'Новости от {author_name} уже в вашей ленте',
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
};

function pickText(kind: string, payload: Record<string, unknown>): string {
  const variants = TEXTS[kind];
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

// FCM's per-message response distinguishes a dead token (404/400 —
// unregistered or malformed) from everything else (network blip, quota,
// transient 5xx). Only the former is safe to prune; the rest just fails this
// round and the row still gets marked sent (best-effort push, not
// at-least-once — a missed nudge isn't worth a retry queue for this app).
async function sendToToken(token: string, body: string): Promise<'ok' | 'stale' | 'error'> {
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
}

Deno.serve(async () => {
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
    .select('user_id, fcm_token')
    .in('user_id', userIds);
  if (tokenError) {
    return new Response(JSON.stringify({ error: tokenError.message }), { status: 500 });
  }

  const tokensByUser = new Map<string, string[]>();
  for (const t of tokenRows ?? []) {
    const list = tokensByUser.get(t.user_id) ?? [];
    list.push(t.fcm_token);
    tokensByUser.set(t.user_id, list);
  }

  let sentCount = 0;
  const staleTokens = new Set<string>();
  const doneIds: string[] = [];

  for (const row of rows) {
    const tokens = tokensByUser.get(row.user_id as string) ?? [];
    const body = pickText(row.kind as string, (row.payload as Record<string, unknown>) ?? {});
    for (const token of tokens) {
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
