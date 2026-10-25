import { admin } from './supabase.ts';

// It is enough to describe the methods the calling code actually uses: the
// real PostgrestFilterBuilder type drags in eight generic parameters tied to
// a Database schema that the console doesn't have.
interface Filterable<Self> {
  eq(column: string, value: unknown): Self;
  is(column: string, value: unknown): Self;
  in(column: string, values: readonly unknown[]): Self;
  gte(column: string, value: unknown): Self;
  order(column: string, options?: { ascending?: boolean }): Self;
  limit(count: number): Self;
}

const PAGE = 1000;
// A ceiling just in case: the console reads whole tables and aggregates in
// memory (the project is a pilot, there aren't many rows). If the ceiling is
// ever hit, that's a signal to move the aggregation into an SQL view, not to
// raise the number.
const HARD_CAP = 100_000;

export async function fetchAll<T>(
  table: string,
  columns: string,
  tweak?: <Q extends Filterable<Q>>(q: Q) => Q,
): Promise<T[]> {
  const rows: T[] = [];
  for (let from = 0; from < HARD_CAP; from += PAGE) {
    let query = admin
      .from(table)
      .select(columns)
      .range(from, from + PAGE - 1);
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
  tweak?: <Q extends Filterable<Q>>(q: Q) => Q,
): Promise<number> {
  let query = admin.from(table).select('*', { count: 'exact', head: true });
  if (tweak) query = tweak(query);
  const { count, error } = await query;
  if (error) throw new Error(`${table}: ${error.message}`);
  return count ?? 0;
}

// Email and last sign-in date live in auth.users, not public.users — they
// can't be reached through PostgREST, only through the admin Auth API.
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
    const { data, error } = await admin.auth.admin.listUsers({
      page,
      perPage: 200,
    });
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

// A single request without paging — for places where the query is already
// bounded (`.limit()`, `.eq()` on one person). It must not be mixed with
// `fetchAll`: `range()` and `limit()` fight over the same header.
export async function fetchOnce<T>(
  table: string,
  columns: string,
  tweak?: <Q extends Filterable<Q>>(q: Q) => Q,
): Promise<T[]> {
  let query = admin.from(table).select(columns);
  if (tweak) query = tweak(query);
  const { data, error } = await query;
  if (error) throw new Error(`${table}: ${error.message}`);
  return (data ?? []) as T[];
}
