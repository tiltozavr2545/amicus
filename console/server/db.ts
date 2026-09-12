import { admin } from './supabase.ts';

const PAGE = 1000;
// Потолок на всякий случай: консоль читает таблицы целиком и агрегирует в
// памяти (проект пилотный, строк немного). Если потолок когда-нибудь
// упрётся — это сигнал переносить агрегацию в SQL-вью, а не поднимать число.
const HARD_CAP = 100_000;

export async function fetchAll<T>(
  table: string,
  columns: string,
  tweak?: (q: any) => any,
): Promise<T[]> {
  const rows: T[] = [];
  for (let from = 0; from < HARD_CAP; from += PAGE) {
    let query = admin.from(table).select(columns).range(from, from + PAGE - 1);
    if (tweak) query = tweak(query);
    const { data, error } = await query;
    if (error) throw new Error(`${table}: ${error.message}`);
    const chunk = (data ?? []) as T[];
    rows.push(...chunk);
    if (chunk.length < PAGE) break;
  }
  return rows;
}

export async function countOf(
  table: string,
  tweak?: (q: any) => any,
): Promise<number> {
  let query = admin.from(table).select('*', { count: 'exact', head: true });
  if (tweak) query = tweak(query);
  const { count, error } = await query;
  if (error) throw new Error(`${table}: ${error.message}`);
  return count ?? 0;
}

// Почта и дата последнего входа живут в auth.users, а не в public.users —
// через PostgREST их не достать, только через админский Auth API.
export type AuthUser = {
  id: string;
  email: string | null;
  createdAt: string | null;
  lastSignInAt: string | null;
  emailConfirmedAt: string | null;
  bannedUntil: string | null;
};

export async function fetchAuthUsers(): Promise<Map<string, AuthUser>> {
  const byId = new Map<string, AuthUser>();
  for (let page = 1; page <= 100; page += 1) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 });
    if (error) throw new Error(`auth.users: ${error.message}`);
    const users = data?.users ?? [];
    for (const u of users) {
      const raw = u as unknown as { banned_until?: string | null };
      byId.set(u.id, {
        id: u.id,
        email: u.email ?? null,
        createdAt: u.created_at ?? null,
        lastSignInAt: u.last_sign_in_at ?? null,
        emailConfirmedAt: u.email_confirmed_at ?? null,
        bannedUntil: raw.banned_until ?? null,
      });
    }
    if (users.length < 200) break;
  }
  return byId;
}

// Одиночный запрос без постраничного обхода — для мест, где сам запрос уже
// ограничен (`.limit()`, `.eq()` по одному человеку). Смешивать его с
// `fetchAll` нельзя: `range()` и `limit()` спорят за один и тот же заголовок.
export async function fetchOnce<T>(
  table: string,
  columns: string,
  tweak?: (q: any) => any,
): Promise<T[]> {
  let query = admin.from(table).select(columns);
  if (tweak) query = tweak(query);
  const { data, error } = await query;
  if (error) throw new Error(`${table}: ${error.message}`);
  return (data ?? []) as T[];
}
