/** Edge Function: webhook-meta (verify_jwt=false). Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, META_APP_SECRET, META_VERIFY_TOKEN, META_ACCESS_TOKEN, META_API_VERSION. */
import { createClient } from 'npm:@supabase/supabase-js@2';
import { dispatcherFromEnv, jsonLog, rpcFromClient, staffDepsFromRpc } from '../_shared/runtime.ts';
import { handleMetaWebhook } from './handler.ts';

const env = (k: string) => Deno.env.get(k);
const rpc = rpcFromClient(createClient(env('SUPABASE_URL')!, env('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } }));
const log = jsonLog('webhook-meta');
Deno.serve((req) => handleMetaWebhook(req, {
  rpc, appSecret: env('META_APP_SECRET') ?? '', verifyToken: env('META_VERIFY_TOKEN') ?? '', now: () => new Date(),
  dispatcher: dispatcherFromEnv(rpc, env, undefined, log), staff: staffDepsFromRpc(rpc), log,
  kickRunner: async () => { await rpc('kick_agent_runner', {}); },
}));
