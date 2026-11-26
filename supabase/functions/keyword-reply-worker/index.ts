/** Edge Function: keyword-reply-worker (service role; pg_cron kicks it every 15 s when a reply is due). Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY + provider credentials. */
import { createClient } from 'npm:@supabase/supabase-js@2';
import { dispatcherFromEnv, jsonLog, rpcFromClient } from '../_shared/runtime.ts';
import { runKeywordReplyWorker } from './process.ts';

Deno.serve(async (req) => {
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!key || req.headers.get('authorization') !== `Bearer ${key}`) return new Response('unauthorized', { status: 401 });
  const rpc = rpcFromClient(createClient(Deno.env.get('SUPABASE_URL')!, key, { auth: { persistSession: false } }));
  const log = jsonLog('keyword-reply-worker');
  const dispatcher = dispatcherFromEnv(rpc, (k) => Deno.env.get(k), undefined, log);
  return Response.json(await runKeywordReplyWorker({ rpc, dispatcher, now: () => new Date(), log }));
});
