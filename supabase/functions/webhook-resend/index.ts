/** Edge Function: webhook-resend (verify_jwt=false). Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, RESEND_WEBHOOK_SECRET, RESEND_API_KEY, UNSUBSCRIBE_BASE_URL. */
import { DB_SCHEMA } from '../_shared/db.ts';
import { createClient } from 'npm:@supabase/supabase-js@2';
import { dispatcherFromEnv, jsonLog, rpcFromClient } from '../_shared/runtime.ts';
import { handleResendWebhook } from './handler.ts';

const env = (k: string) => Deno.env.get(k);
const rpc = rpcFromClient(createClient(env('SUPABASE_URL')!, env('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false }, db: { schema: DB_SCHEMA } }));
const log = jsonLog('webhook-resend');
Deno.serve((req) => handleResendWebhook(req, {
  rpc, webhookSecret: env('RESEND_WEBHOOK_SECRET') ?? '', api: env('RESEND_API_KEY') ? { apiKey: env('RESEND_API_KEY')! } : null, now: () => new Date(), dispatcher: dispatcherFromEnv(rpc, env, undefined, log), staff: null, log,
  kickRunner: async () => { await rpc('kick_agent_runner', {}); },
}));
