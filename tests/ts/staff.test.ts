import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseStaffCommand, parseInventoryQuery, parseDue, parseMoneyCents, handleStaffText, HELP_TEXT, type StaffDeps } from '../../supabase/functions/_shared/staff-commands.ts';

const NOW = new Date('2026-11-26T15:00:00Z');
const L1 = '00000000-0000-4000-8000-000000000001';
const L2 = '00000000-0000-4000-8000-000000000002';

test('parser: every command shape', () => {
  assert.deepEqual(parseStaffCommand('Who needs attention?'), { kind: 'attention' });
  assert.deepEqual(parseStaffCommand('move Sarah Lopez to Test Drive'), { kind: 'move', who: 'Sarah Lopez', stage: 'test_drive' });
  assert.deepEqual(parseStaffCommand('move sarah to sold'), { kind: 'move', who: 'sarah', stage: 'won' });
  assert.deepEqual(parseStaffCommand('move sarah to the moon'), { kind: 'help' });
  assert.deepEqual(parseStaffCommand('task sarah: call about trade tomorrow'), { kind: 'task', who: 'sarah', title: 'call about trade', due: { hours: 24 } });
  assert.deepEqual(parseStaffCommand('remind me for tom: send photos in 3 hours'), { kind: 'task', who: 'tom', title: 'send photos', due: { hours: 3 } });
  assert.deepEqual(parseStaffCommand('draft to Sarah: Hi Sarah,\nthe truck is ready'), { kind: 'draft', who: 'Sarah', body: 'Hi Sarah,\nthe truck is ready' });
  assert.deepEqual(parseStaffCommand('lead tom reyes'), { kind: 'lead', who: 'tom reyes' });
  assert.deepEqual(parseStaffCommand('hello?'), { kind: 'help' });
});

test('inventory query parsing: year, make alias, model, price, condition', () => {
  assert.deepEqual(parseInventoryQuery('2022 tacoma under 35k').filters, { year_min: 2022, year_max: 2022, model: 'tacoma', max_price_cents: 3500000 });
  assert.deepEqual(parseInventoryQuery('used chevy silverado 2019-2021 below $42,500').filters, { max_price_cents: 4250000, year_min: 2019, year_max: 2021, condition: 'used', make: 'chevrolet', model: 'silverado' });
  assert.deepEqual(parseInventoryQuery('certified honda').filters, { condition: 'cpo', make: 'honda' });
  assert.equal(parseMoneyCents('35k'), 3500000);
  assert.equal(parseMoneyCents('abc'), null);
  assert.deepEqual(parseDue('call back in 2 days'), { title: 'call back', hours: 48 });
  assert.deepEqual(parseDue('call back'), { title: 'call back', hours: 24 });
});

function mk(rpc: (fn: string, a: Record<string, unknown>) => unknown, staff = true) {
  const calls: [string, Record<string, unknown>][] = [];
  const audits: any[] = [];
  const deps: StaffDeps = {
    resolveSender: async (_d, _c, addr) => (staff && addr === '+15555550100' ? { staff_identity_id: 'S1', user_id: 'U', role: 'sales', scopes: ['leads:read', 'inventory:read', 'leads:write', 'tasks:write', 'drafts:write'] } : null),
    rpc: async <T>(fn: string, a: Record<string, unknown>) => { calls.push([fn, a]); return rpc(fn, a) as T; },
    audit: async (a) => { audits.push(a); },
    now: () => NOW,
  };
  return { deps, calls, audits };
}
const text = (t: string, from = '+15555550100') => ({ dealerId: 'D', channel: 'sms' as const, address: from, text: t });

test('unknown sender => null (continues as a customer message); nothing is called', async () => {
  const { deps, calls } = mk(() => []);
  assert.equal(await handleStaffText(text('move sarah to won', '+15555559999'), deps), null);
  assert.equal(calls.length, 0);
});

test('move by name: unique match moves and is audited as staff_sms', async () => {
  const { deps, calls, audits } = mk((fn) => fn === 'mcp_find_leads' ? [{ lead_id: L1, name: 'Sarah Lopez', stage: 'qualifying' }] : { decision: 'applied', from: 'qualifying', to: 'negotiating' });
  const r = await handleStaffText(text('move sarah to negotiating'), deps);
  assert.match(r!, /Moved Sarah Lopez: qualifying -> negotiating/);
  assert.equal(calls[1][0], 'mcp_move_stage');
  assert.equal(calls[1][1].p_lead_id, L1);
  assert.equal(audits[1].principal.actorKind, 'staff_sms');
  assert.equal(audits[1].principal.staffIdentityId, 'S1');
});

test('ambiguous name => asks which one, changes nothing; exact full name resolves', async () => {
  const two = [{ lead_id: L1, name: 'Sarah Lopez', stage: 'qualifying' }, { lead_id: L2, name: 'Sarah Kim', stage: 'contacted' }];
  const a = mk(() => two);
  const r = await handleStaffText(text('move sarah to won'), a.deps);
  assert.match(r!, /^Which one\? 1\) Sarah Lopez \(qualifying\) 2\) Sarah Kim/);
  assert.equal(a.calls.length, 1);
  const b = mk((fn) => fn === 'mcp_find_leads' ? two : { decision: 'applied', from: 'contacted', to: 'won' });
  await handleStaffText(text('move Sarah Kim to won'), b.deps);
  assert.equal(b.calls[1][1].p_lead_id, L2);
  const c = mk(() => []);
  assert.match((await handleStaffText(text('lead nobody'), c.deps))!, /No lead matches "nobody"/);
});

test('task, find, draft, attention, help replies', async () => {
  const t = mk((fn) => fn === 'mcp_find_leads' ? [{ lead_id: L1, name: 'Sarah Lopez', stage: 'qualifying' }] : 'T1');
  assert.match((await handleStaffText(text('task sarah: call about trade tomorrow'), t.deps))!, /Task added for Sarah Lopez: "call about trade"/);
  assert.equal(t.calls[1][1].p_due_at, '2026-11-27T15:00:00.000Z');
  const f = mk(() => [{ vin: '3TMCZ5AN0NM000001', year: 2022, make: 'Toyota', model: 'Tacoma', trim: 'SR5', price_cents: 3390000 }]);
  assert.equal(await handleStaffText(text('find 2022 tacoma under 35k'), f.deps), '2022 Toyota Tacoma SR5 $33,900 (…000001)');
  const d = mk((fn) => fn === 'mcp_find_leads' ? [{ lead_id: L1, name: 'Sarah Lopez', stage: 'qualifying' }] : { ok: true, draft_id: 'DR1', status: 'awaiting_review' });
  assert.match((await handleStaffText(text('draft to sarah: Truck is ready Saturday'), d.deps))!, /Draft saved.*nothing was sent/);
  const dn = mk((fn) => fn === 'mcp_find_leads' ? [{ lead_id: L1, name: 'Sarah Lopez', stage: 'qualifying' }] : { ok: false, code: 'dnc_active', message: 'The contact opted out.' });
  assert.match((await handleStaffText(text('draft to sarah: hi'), dn.deps))!, /opted out/);
  const at = mk(() => [{ name: 'Sarah L', reason: 'Replied 2h ago, no answer yet' }]);
  assert.equal(await handleStaffText(text('who needs attention'), at.deps), '1) Sarah L: Replied 2h ago, no answer yet');
  assert.equal(await handleStaffText(text('what?'), at.deps), HELP_TEXT);
});

test('not_found from SQL (another rep\'s lead) is reported without revealing it exists', async () => {
  const { deps } = mk((fn) => { if (fn === 'mcp_get_lead') throw new Error('not_found: lead'); return []; });
  assert.equal(await handleStaffText(text(`lead ${L2}`), deps), 'No such lead (or not yours).');
});
