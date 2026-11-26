// SalesOS agent tools. The implementation lives with the Edge Functions so `supabase functions deploy`
// bundles it; this re-export lets the Next.js app (and tests) import it from lib/agent as before.
export * from '../../supabase/functions/_shared/agent-tools.ts';
