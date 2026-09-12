import { createClient } from '@supabase/supabase-js';
import { env } from './env.ts';

// Единственное место, где живёт service_role-ключ. В браузер он не уезжает
// никогда: клиент консоли ходит только в локальный /api.
export const admin = createClient(env.supabaseUrl, env.serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});
