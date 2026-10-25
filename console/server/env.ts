import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { config } from 'dotenv';

const here = dirname(fileURLToPath(import.meta.url));
config({ path: resolve(here, '..', '.env') });

function required(name: string): string {
  const value = process.env[name];
  if (!value || value.trim() === '') {
    throw new Error(
      `${name} не задан. Скопируй console/.env.example в console/.env и заполни.`,
    );
  }
  return value.trim();
}

// It is easy to mix up the anon key with service_role, and the symptom is
// dumb: requests go out, RLS silently filters them, and the console shows
// empty tables instead of an error. It's cheaper to refuse to start.
function assertServiceRole(key: string): string {
  if (key.startsWith('sb_publishable_')) {
    throw new Error(
      'SUPABASE_SERVICE_ROLE_KEY — это publishable-ключ. Нужен secret (service_role).',
    );
  }
  const parts = key.split('.');
  if (parts.length === 3) {
    try {
      const payload = JSON.parse(
        Buffer.from(parts[1], 'base64url').toString('utf8'),
      ) as { role?: string };
      if (payload.role && payload.role !== 'service_role') {
        throw new Error(
          `SUPABASE_SERVICE_ROLE_KEY содержит роль "${payload.role}", а нужна service_role.`,
        );
      }
    } catch (error) {
      if (error instanceof Error && error.message.startsWith('SUPABASE_'))
        throw error;
      // Not a JWT — so it's a new-generation key (`sb_secret_…`); nothing to
      // check.
    }
  }
  return key;
}

export const env = {
  supabaseUrl: required('SUPABASE_URL'),
  serviceRoleKey: assertServiceRole(required('SUPABASE_SERVICE_ROLE_KEY')),
  apiPort: Number(process.env.CONSOLE_API_PORT ?? 5174),
};
