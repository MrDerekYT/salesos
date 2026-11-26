/** Edge Function: webhook-twilio (verify_jwt=false). Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, PUBLIC_FUNCTIONS_URL. */
import { createClient } from 'npm:@supabase/supabase-js@2';
import { dispatcherFromEnv, jsonLog, publicUrlFor, rpcFromClient, staffDepsFromRpc } from '../_shared/runtime.ts';
import { handleTwilioWebhook } from './handler.ts';

const env = (k: string) => Deno.env.get(k);
const rpc = rpcFromClient(createClient(env('SUPABASE_URL')!, env('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } }));
const log = jsonLog('webhook-twilio');
Deno.serve((req) => handleTwilioWebhook(req, {
  rpc, authToken: env('TWILIO_AUTH_TOKEN') ?? '', publicUrl: publicUrlFor('webhook-twilio', env), now: () => new Date(),
  dispatcher: dispatcherFromEnv(rpc, env, undefined, log), staff: staffDepsFromRpc(rpc), log,
  kickRunner: async () => { await rpc('kick_agent_runner', {}); },
}));
