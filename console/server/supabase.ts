import { createClient } from '@supabase/supabase-js';
import { env } from './env.ts';

// The only place the service_role key lives. It never goes to the browser:
// the console client only talks to the local /api.
export const admin = createClient(env.supabaseUrl, env.serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});
