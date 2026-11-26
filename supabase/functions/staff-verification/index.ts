/** Edge Function: staff-verification. Keep verify_jwt = true (default): the caller is a signed-in dealership user. Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY + SMS/WhatsApp provider credentials. */
import { createClient } from 'npm:@supabase/supabase-js@2';
import { dispatcherFromEnv, jsonLog, rpcFromClient } from '../_shared/runtime.ts';
import { handleStaffVerification } from './handler.ts';

const env = (k: string) => Deno.env.get(k);
const db = createClient(env('SUPABASE_URL')!, env('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
const rpc = rpcFromClient(db);
const log = jsonLog('staff-verification');
Deno.serve((req) => handleStaffVerification(req, {
  rpc, now: () => new Date(), log, dispatcher: dispatcherFromEnv(rpc, env, undefined, log),
  async authenticate(r) {
    const token = (r.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
    if (!token) return null;
    const { data, error } = await db.auth.getUser(token);
    return error ? null : data.user?.id ?? null;
  },
}));
