/** psql-backed helpers for integration tests: `rpc` behaves like PostgREST (set-returning => array) and runs AS service_role. */
import { execFileSync } from 'node:child_process';

const PSQL = ['-h', '/tmp', '-p', process.env.PGPORT_LOCAL ?? '54329', '-U', 'postgres', '-d', 'salesos_test', '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1'];
export function sql(q: string): string {
  try {
    return execFileSync('psql', [...PSQL, '-c', q], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  } catch (e) {
    const msg = String((e as { stderr?: string }).stderr ?? e).match(/ERROR:\s+(.*)/)?.[1] ?? String(e);
    throw new Error(msg);
  }
}
export const available = (() => { try { return sql('select 1') === '1'; } catch { return false; } })();
export const lit = (v: unknown): string => {
  if (v === null || v === undefined) return 'NULL';
  if (Array.isArray(v) && v.every((x) => typeof x !== 'object')) return `'{${v.map((x) => `"${String(x).replace(/"/g, '\\"')}"`).join(',')}}'`;
  const s = typeof v === 'object' ? JSON.stringify(v) : String(v);
  return `'${s.replace(/'/g, "''")}'`;
};
const retsetCache = new Map<string, boolean>();
const jsonbParams = new Map<string, Set<string>>();
/** PostgREST sends JSON bodies, so a string passed to a jsonb parameter arrives as a JSON string; mimic that. */
function jsonbArgs(fn: string): Set<string> {
  if (!jsonbParams.has(fn)) {
    const out = sql(`select coalesce(string_agg(a.name, ','), '') from pg_proc p, lateral unnest(p.proargnames[1:p.pronargs], string_to_array(p.proargtypes::text, ' ')::oid[]) as a(name, typ) where p.proname = '${fn}' and p.pronamespace = 'public'::regnamespace and a.typ = 'jsonb'::regtype`);
    jsonbParams.set(fn, new Set(out ? out.split(',') : []));
  }
  return jsonbParams.get(fn)!;
}
export async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  if (!/^[a-z_]+$/.test(fn)) throw new Error('bad fn');
  const jb = jsonbArgs(fn);
  const named = Object.entries(args).map(([k, v]) => `${k} => ${lit(jb.has(k) && typeof v === 'string' ? JSON.stringify(v) : v)}`).join(', ');
  if (!retsetCache.has(fn)) retsetCache.set(fn, sql(`select bool_or(proretset) from pg_proc where proname = '${fn}' and pronamespace = 'public'::regnamespace`) === 't');
  const q = retsetCache.get(fn) ? `select coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) from public.${fn}(${named}) r` : `select to_jsonb(public.${fn}(${named}))`;
  const out = sql(`set role service_role; ${q}`);
  return (out === '' ? null : JSON.parse(out)) as T;
}
export const uuid = () => sql('select gen_random_uuid()');
export const skip = available ? false : 'local Postgres not running (scripts/pg-local.sh start && npm run test:integration)';
