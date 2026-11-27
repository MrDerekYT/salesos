/** Edge Function: unsubscribe (verify_jwt=false; public link). Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY. */
import { DB_SCHEMA } from '../_shared/db.ts';
import { createClient } from 'npm:@supabase/supabase-js@2';
import { rpcFromClient } from '../_shared/runtime.ts';
import { handleUnsubscribe } from './handler.ts';

const rpc = rpcFromClient(createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false }, db: { schema: DB_SCHEMA } }));
Deno.serve((req) => handleUnsubscribe(req, { rpc, now: () => new Date() }));
