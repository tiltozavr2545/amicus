import { admin } from './supabase.ts';
import { fetchAll } from './db.ts';

export function dayKey(iso: string): string {
  return iso.slice(0, 10);
}

// Ряд за N дней без дырок: пустой день должен рисоваться нулём, а не
// пропадать из графика.
export function series(dates: string[], days: number): { date: string; count: number }[] {
  const counts = new Map<string, number>();
  for (const iso of dates) {
    const key = dayKey(iso);
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  const out: { date: string; count: number }[] = [];
  const today = new Date();
  for (let i = days - 1; i >= 0; i -= 1) {
    const d = new Date(today);
    d.setUTCDate(d.getUTCDate() - i);
    const key = d.toISOString().slice(0, 10);
    out.push({ date: key, count: counts.get(key) ?? 0 });
  }
  return out;
}

export function tally<T>(rows: T[], key: (row: T) => string | null): Map<string, number> {
  const out = new Map<string, number>();
  for (const row of rows) {
    const k = key(row);
    if (k === null) continue;
    out.set(k, (out.get(k) ?? 0) + 1);
  }
  return out;
}

export function groupCount<T>(rows: T[], key: (row: T) => string | null | undefined): Map<string, number> {
  const out = new Map<string, number>();
  for (const row of rows) {
    const k = key(row);
    if (!k) continue;
    out.set(k, (out.get(k) ?? 0) + 1);
  }
  return out;
}

// Id системного аккаунта живёт в БД (`system_account_ids()`), а не копией в
// коде консоли — та же причина, по которой его не носит в себе APK.
export async function systemAccountIds(): Promise<Set<string>> {
  try {
    const { data, error } = await admin.rpc('system_account_ids');
    if (error) throw error;
    const ids = Array.isArray(data) ? data : [data];
    return new Set(ids.filter(Boolean).map(String));
  } catch {
    return new Set();
  }
}

export type DeviceRowRaw = {
  user_id: string;
  fcm_token: string;
  locale: string;
  app_version: string | null;
  app_build: number | null;
  platform: string | null;
  os_version: string | null;
  created_at: string;
  updated_at: string;
};

export function loadDevices(): Promise<DeviceRowRaw[]> {
  return fetchAll<DeviceRowRaw>(
    'device_tokens',
    'user_id, fcm_token, locale, app_version, app_build, platform, os_version, created_at, updated_at',
  );
}
