import { config } from 'dotenv';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

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

// Перепутать anon-ключ с service_role легко, а симптом получается тупой:
// запросы уходят, RLS их молча фильтрует, и консоль показывает пустые
// таблицы вместо ошибки. Дешевле отказаться стартовать.
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
      if (error instanceof Error && error.message.startsWith('SUPABASE_')) throw error;
      // Не JWT — значит ключ нового поколения (`sb_secret_…`), проверить нечем.
    }
  }
  return key;
}

export const env = {
  supabaseUrl: required('SUPABASE_URL'),
  serviceRoleKey: assertServiceRole(required('SUPABASE_SERVICE_ROLE_KEY')),
  apiPort: Number(process.env.CONSOLE_API_PORT ?? 5174),
};
