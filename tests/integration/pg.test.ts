/**
 * TS <-> SQL contract tests against the real migrated database (local Postgres, see scripts/pg-local.sh).
 * The Edge Function cores run with an `rpc` that calls the SQL functions AS service_role (so grants are exercised),
 * which proves the JSON shapes the TS expects are the shapes Postgres returns.
 * Run: npm run test:integration (applies the migrations to a fresh salesos_test first).
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { handleMcpRequest, type McpDeps } from '../../supabase/functions/mcp/handler.ts';
import { handleStaffText, type StaffDeps } from '../../supabase/functions/_shared/staff-commands.ts';
import { sweep, type SweeperDeps, type DuePlan } from '../../supabase/functions/outbound-sweeper/process.ts';
import { createKnowledgeSearch } from '../../supabase/functions/_shared/rag.ts';
import { runEmbedWorker, type EmbedJob } from '../../supabase/functions/embed-worker/process.ts';
import { EMBEDDING_DIM, type EmbeddingProvider } from '../../supabase/functions/_shared/embeddings.ts';
import type { ComplianceDecision, VehicleEvidence } from '../../supabase/functions/_shared/before-send.ts';

const PSQL = ['-h', '/tmp', '-p', process.env.PGPORT_LOCAL ?? '54329', '-U', 'postgres', '-d', 'salesos_test', '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1'];
function sql(q: string): string {
  try {
    return execFileSync('psql', [...PSQL, '-c', q], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  } catch (e) {
    const msg = String((e as { stderr?: string }).stderr ?? e).match(/ERROR:\s+(.*)/)?.[1] ?? String(e);
    throw new Error(msg);
  }
}
const available = (() => { try { return sql('select 1') === '1'; } catch { return false; } })();
const lit = (v: unknown): string => {
  if (v === null || v === undefined) return 'NULL';
  if (Array.isArray(v)) return `'{${v.map((x) => `"${String(x).replace(/"/g, '\\"')}"`).join(',')}}'`;
  const s = typeof v === 'object' ? JSON.stringify(v) : String(v);
  return `'${s.replace(/'/g, "''")}'`;
};
/** PostgREST-like: set-returning => array of rows, scalar => value. Runs as service_role. */
async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  if (!/^[a-z_]+$/.test(fn)) throw new Error('bad fn');
  const named = Object.entries(args).map(([k, v]) => `${k} => ${lit(v)}`).join(', ');
  const retset = sql(`select bool_or(proretset) from pg_proc where proname = '${fn}' and pronamespace = 'public'::regnamespace`) === 't';
  const q = retset ? `select coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) from salesos_ai.${fn}(${named}) r` : `select to_jsonb(salesos_ai.${fn}(${named}))`;
  const out = sql(`set role service_role; ${q}`);
  return (out === '' ? null : JSON.parse(out)) as T;
}
const uuid = () => sql('select gen_random_uuid()');
const skip = available ? false : 'local Postgres not running (scripts/pg-local.sh start && npm run test:integration)';

test('MCP over HTTP against real SQL: key auth, scoped tools, drafts-only, audit trail', { skip }, async () => {
  const d = uuid(), owner = uuid(), rep = uuid(), lead = uuid(), c = uuid();
  sql(`insert into dealers(id,name,timezone) values ('${d}','IT Motors','America/New_York');
       insert into dealer_members(user_id,dealer_id,role) values ('${owner}','${d}','owner'),('${rep}','${d}','sales');
       insert into channel_numbers(dealer_id,channel,address,activated_at) values ('${d}','sms','+1555777${d.slice(0, 4).replace(/\D/g, '1').padEnd(4, '1')}','2026-01-01');
       insert into contacts(id,dealer_id,first_name,last_name,phone_e164) values ('${c}','${d}','Sarah','Lopez','+15557770001');
       insert into consent_events(dealer_id,contact_id,channel,purpose,action,source) values ('${d}','${c}','sms','conversational','grant','web_form');
       insert into leads(id,dealer_id,contact_id,stage,assigned_to) values ('${lead}','${d}','${c}','qualifying','${rep}');
       insert into vehicles(dealer_id,vin,year,make,model,price_cents,status,condition) values ('${d}','3TMCZ5AN0NM900001',2022,'Toyota','Tacoma',3390000,'available','used'),('${d}','3TMCZ5AN0NM900002',2022,'Toyota','Tacoma',3000000,'sold','used');`);
  const key = (await rpc<{ api_key: string }[]>('create_mcp_api_key', { p_dealer_id: d, p_name: 'IT', p_role: 'sales', p_acting_user_id: rep, p_actor: owner }))[0].api_key;
  const deps: McpDeps = {
    rpc,
    verifyKey: async (k) => (await rpc<any[]>('verify_mcp_api_key', { p_key: k }))[0] ?? null,
    audit: async (a) => { await rpc('mcp_audit', { p_dealer_id: a.principal.dealerId, p_actor_kind: a.principal.actorKind, p_api_key_id: a.principal.apiKeyId ?? null, p_staff_identity_id: a.principal.staffIdentityId ?? null, p_user_id: a.principal.userId, p_tool: a.tool, p_args: a.args, p_result_code: a.resultCode, p_lead_id: a.leadId ?? null, p_draft_id: a.draftId ?? null }); },
  };
  let id = 0;
  const call = async (method: string, params?: unknown) => (await (await handleMcpRequest(new Request('https://x/mcp', { method: 'POST', headers: { authorization: `Bearer ${key}` }, body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params }) }), deps)).json()) as any;

  assert.equal((await call('tools/list')).result.tools.length, 7);
  const found = await call('tools/call', { name: 'find_leads', arguments: { query: 'sarah' } });
  assert.equal(found.result.structuredContent.items[0].lead_id, lead);
  const moved = await call('tools/call', { name: 'move_stage', arguments: { lead_id: lead, stage: 'negotiating', reason: 'customer asked for numbers' } });
  assert.equal(moved.result.structuredContent.decision, 'applied');
  assert.equal(sql(`select stage from leads where id = '${lead}'`), 'negotiating');
  const inv = await call('tools/call', { name: 'search_inventory', arguments: { model: 'tacoma', max_price_cents: 3500000 } });
  assert.deepEqual(inv.result.structuredContent.items.map((v: any) => v.vin), ['3TMCZ5AN0NM900001']);
  const draft = await call('tools/call', { name: 'draft_message', arguments: { lead_id: lead, body: 'Hi Sarah, numbers are ready. Want to stop by Saturday?' } });
  assert.equal(draft.result.structuredContent.status, 'awaiting_review');
  assert.equal(sql(`select status || '/' || actor from outbound_drafts where id = '${draft.result.structuredContent.draft_id}'`), 'awaiting_review/human');
  assert.equal(sql(`select count(*) from messages where lead_id = '${lead}' and direction = 'outbound'`), '0');
  const nf = await call('tools/call', { name: 'get_lead', arguments: { lead_id: uuid() } });
  assert.equal(nf.result.structuredContent.error.code, 'not_found');
  assert.equal(sql(`select string_agg(tool || ':' || result_code, ',' order by id) from mcp_audit_log where dealer_id = '${d}'`),
    'find_leads:ok,move_stage:ok,search_inventory:ok,draft_message:ok,get_lead:not_found');
  assert.equal(sql(`select count(*) from mcp_audit_log where dealer_id = '${d}' and args ? 'body'`), '0');

  // the same tools by text from an allow-listed phone
  sql(`insert into staff_identities(dealer_id,user_id,channel,address,status,verified_at) values ('${d}','${rep}','sms','+15557779999','active',now())`);
  const sdeps: StaffDeps = { ...deps, now: () => new Date(), resolveSender: async (dd, ch, addr) => (await rpc<any[]>('resolve_staff_sender', { p_dealer_id: dd, p_channel: ch, p_address: addr }))[0] ?? null };
  assert.match((await handleStaffText({ dealerId: d, channel: 'sms', address: '+15557779999', text: 'move sarah to test drive' }, sdeps))!, /negotiating -> test_drive/);
  assert.equal(await handleStaffText({ dealerId: d, channel: 'sms', address: '+15557770001', text: 'move sarah to won' }, sdeps), null);   // the customer, not staff
  assert.equal(sql(`select actor_kind from mcp_audit_log where dealer_id = '${d}' order by id desc limit 1`), 'staff_sms');
});

test('Follow-up sweeper against real SQL: generate -> claim -> gate context -> can_send -> send/stop -> outcome', { skip }, async () => {
  const d = uuid(), ann = uuid(), ben = uuid(), la = uuid(), lb = uuid(), v = uuid();
  const T0 = '2026-03-10T15:00:00Z';
  sql(`insert into dealers(id,name,timezone) values ('${d}','Sweep Motors','America/New_York');
       update dealer_settings set auto_send_enabled = true, followup_hold_minutes = 0 where dealer_id = '${d}';
       insert into channel_numbers(dealer_id,channel,address,activated_at) values ('${d}','sms','+15558880000','2026-01-01');
       insert into contacts(id,dealer_id,first_name,phone_e164) values ('${ann}','${d}','Ann','+15558880001'),('${ben}','${d}','Ben','+15558880002');
       insert into consent_events(dealer_id,contact_id,channel,purpose,action,source,disclosure_text_version) values ('${d}','${ann}','sms','marketing','grant','web_form','tcpa-v3');
       insert into leads(id,dealer_id,contact_id,stage) values ('${la}','${d}','${ann}','qualifying'),('${lb}','${d}','${ben}','qualified');
       update leads set last_inbound_at = '${T0}'::timestamptz - interval '5 days', last_outbound_at = '${T0}'::timestamptz - interval '3 days' where id = '${lb}';
       insert into vehicles(id,dealer_id,vin,year,make,model,price_cents,status) values ('${v}','${d}','1HGCV1F30LA990001',2022,'Honda','Accord',3000000,'available');
       insert into lead_vehicle_views(dealer_id,lead_id,vehicle_id,viewed_at) values ('${d}','${la}','${v}','${T0}'::timestamptz - interval '2 days');
       update vehicles set price_cents = 2800000 where id = '${v}';`);
  const gen = await rpc<Record<string, number>>('generate_followup_plans', { p_now: T0 });
  assert.equal(gen.price_drop, 1);
  assert.equal(gen.stalled, 1);

  let now = new Date(T0);
  const sent: string[] = [];
  const deps: SweeperDeps = {
    now: () => now,
    claimDrafts: async () => [],
    releaseFacts: async () => { throw new Error('unused'); },
    setDraftStatus: async () => { throw new Error('unused'); },
    gateContext: (dd, cc, ll, ch, n) => rpc('get_gate_context', { p_dealer_id: dd, p_contact_id: cc, p_lead_id: ll, p_channel: ch, p_now: n.toISOString() }),
    canSend: (t, i, commit) => rpc<ComplianceDecision>('can_send', { p_dealer_id: t.dealerId, p_contact_id: t.contactId, p_channel: i.channel, p_purpose: i.purpose, p_kind: i.kind, p_number_id: t.numberId, p_body: i.body, p_lead_id: t.leadId, p_actor: i.actor, p_commit: commit, p_now: i.now.toISOString() }),
    providerSend: async (a) => { sent.push(a.body); return { ok: true, providerMessageId: `pm-${sent.length}` }; },
    finalize: async (id, r, body) => { await rpc('finalize_draft_send', { p_draft_id: id, p_ok: r.ok, p_provider_message_id: r.ok ? r.providerMessageId : null, p_error: r.ok ? null : r.error, p_body: body, p_now: now.toISOString() }); },
    claimFollowups: (limit) => rpc<DuePlan[]>('claim_due_followups', { p_limit: limit, p_now: now.toISOString() }),
    pickRoute: async (dd, cc, pref) => { const r = await rpc<any[]>('pick_send_route', { p_dealer_id: dd, p_contact_id: cc, p_preferred: pref }); return r[0] ? { channel: r[0].channel, numberId: r[0].number_id } : null; },
    followupFacts: async (p) => {
      const first = sql(`select first_name from contacts where id = '${p.contact_id}'`);
      const vid = p.vehicle_id ?? (p.context.vehicle_id as string | undefined);
      const vj = vid ? sql(`select json_build_object('vin',vin,'status',status,'priceCents',price_cents,'year',year,'make',make,'model',model) from vehicles where id = '${vid}'`) : '';
      return { firstName: first || null, vehicle: vj ? (JSON.parse(vj) as VehicleEvidence) : null };
    },
    insertDraft: async (a) => sql(`insert into outbound_drafts(dealer_id,lead_id,contact_id,channel,number_id,actor,purpose,kind,body_ai,status,release_at,reservation_id,evidence,chain_version)
        values ('${a.plan.dealer_id}',${lit(a.plan.lead_id)},'${a.plan.contact_id}','${a.route.channel}','${a.route.numberId}','ai','${a.plan.purpose}','followup',${lit(a.body)},'${a.status}',${lit(a.releaseAt)},${lit(a.reservationId)},${lit(a.evidence)},${a.chainVersion}) returning id`),
    recordOutcome: (id, o, code, nb, dr) => rpc('record_followup_outcome', { p_plan_id: id, p_outcome: o, p_code: code, p_not_before: nb, p_draft_id: dr, p_now: now.toISOString() }),
  };

  const s1 = await sweep(deps);
  assert.equal(s1.followups.claimed, 2);
  assert.equal(s1.followups.sent, 1, JSON.stringify(s1));          // Ann (marketing consent covers the price drop)
  assert.equal(s1.followups.stopped, 1);                            // Ben: no consent => cancelled, not retried
  assert.equal(sql(`select stop_reason from followup_plans where contact_id = '${ben}'`), 'no_consent');
  assert.match(sent[0], /2022 Honda Accord .* now \$28,000/);
  assert.match(sent[0], /STOP/);
  assert.equal(sql(`select count(*) from messages where contact_id = '${ann}' and direction = 'outbound' and status = 'sent'`), '1');
  assert.equal(sql(`select string_agg(status, ',') from send_reservations where contact_id = '${ann}'`), 'sent');
  assert.equal(sql(`select string_agg(trigger_kind || ':' || status, ',') from followup_plans where dealer_id = '${d}'`).split(',').sort().join(','), 'price_drop:sent,stalled:cancelled');

  // Ann replies: nothing further may go to her automatically
  sql(`insert into messages(dealer_id,lead_id,contact_id,channel,direction,body,created_at) values ('${d}','${la}','${ann}','sms','inbound','thanks, I will think about it','2026-03-10T16:00:00Z')`);
  now = new Date('2026-03-12T15:00:00Z');
  const s2 = await sweep(deps);
  assert.equal(s2.followups.claimed, 0);
});

test('RAG against real SQL: FTS-only works with no provider; worker embeds; hybrid ranks the doc in both lists first', { skip }, async () => {
  const d = uuid();
  sql(`insert into dealers(id,name,timezone) values ('${d}','RAG Motors','America/New_York');
       insert into kb_documents(dealer_id,title,kind,body) values
        ('${d}','Trade-in policy','trade_in','We appraise trade-ins in 24 hours. Bring the title and any lien payoff letter.'),
        ('${d}','Service hours','faq','Service is open Saturday 8am to 2pm. Loaner cars need a reservation.'),
        ('${d}','Financing','financing','We work with 12 lenders. Pre-qualification does not affect your credit score.');`);
  const ftsOnly = createKnowledgeSearch({ dealerId: d, embed: null, rpc });
  const h1 = await ftsOnly({ query: 'what do I bring for my trade-in lien?', topK: 3 });
  assert.equal(h1[0].title, 'Trade-in policy');
  assert.equal(h1[0].citation?.sourceKind, 'kb');

  // deterministic "embedding": one hot on a hash of the first word that matters, so we control similarity
  const hot = (t: string) => { const v = new Array(EMBEDDING_DIM).fill(0); v[createHash('md5').update(/financ|lender|credit/i.test(t) ? 'fin' : t.slice(0, 12)).digest()[0] % EMBEDDING_DIM] = 1; return v; };
  const provider: EmbeddingProvider = { model: 'it-hot-1', embed: async (texts) => texts.map(hot) };
  const sum = await runEmbedWorker({
    claim: (n) => rpc<EmbedJob[]>('claim_embed_jobs', { p_limit: n }),
    complete: (j, vlit, m) => rpc('complete_embed_job', { p_kind: j.target_kind, p_id: j.target_id, p_embedding: vlit, p_model: m, p_content_hash: j.content_hash }),
    fail: (j, e) => rpc('fail_embed_job', { p_kind: j.target_kind, p_id: j.target_id, p_error: e }),
    defer: (m, r) => rpc('defer_embed_jobs', { p_minutes: m, p_reason: r }),
  }, provider, { batch: 500, deferMinutes: 60 });
  assert.ok(sum.stored >= 3, JSON.stringify(sum));
  assert.equal(sql(`select count(*) from kb_chunks where dealer_id = '${d}' and embedding is null`), '0');
  const hybrid = createKnowledgeSearch({ dealerId: d, embed: provider, rpc });
  const h2 = await hybrid({ query: 'does checking my credit with lenders hurt?', topK: 3 });
  assert.equal(h2[0].title, 'Financing');
  const mode = (await rpc<any[]>('match_kb', { p_dealer_id: d, p_query: 'lenders credit', p_query_embedding: `[${hot('credit').join(',')}]`, p_embedding_model: 'it-hot-1' }))[0].mode;
  assert.equal(mode, 'hybrid');
});
