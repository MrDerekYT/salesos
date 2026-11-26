/**
 * staff-verification: proves a staff member controls the phone they registered before it may text the CRM.
 *   POST {action:'start',   identity_id}        -> texts a 6-digit code through the channel adapter (never returned to the caller)
 *   POST {action:'confirm', identity_id, code}  -> 200 {result:'verified'} | 400 {result:'wrong_code'|'expired'|'locked'|'no_pending', attempts_left}
 * The caller is identified by their Supabase user JWT (platform verify_jwt stays ON for this function). Starting is allowed for
 * the identity's own user or an owner/admin; confirming only for the identity's own user (proof of possession).
 * The code is hashed at rest (salted sha256), expires in 10 minutes, allows 5 guesses, and codes are rate limited (SQL).
 */
import type { Rpc } from '../_shared/crm-tools.ts';
import type { Dispatcher } from '../_shared/channels/dispatch.ts';

export interface StaffVerificationDeps {
  rpc: Rpc; dispatcher: Dispatcher; now(): Date;
  /** returns the authenticated user id for the request, or null */
  authenticate(req: Request): Promise<string | null>;
  log?(event: string, data: Record<string, unknown>): void;
}
interface StartRow {
  verification_id: string; dealer_id: string; code: string; expires_at: string; to_address: string; channel: 'sms' | 'whatsapp';
  number_id: string; number_address: string; provider: string; number_config: Record<string, unknown>; dealer_name: string;
}
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });

export function statusForError(message: string): { status: number; code: string } {
  const m = message.toLowerCase();
  if (m.includes('rate_limited') || m.includes('cooldown')) return { status: 429, code: m.includes('cooldown') ? 'cooldown' : 'rate_limited' };
  if (m.includes('forbidden') || m.includes('actor required')) return { status: 403, code: 'forbidden' };
  if (m.includes('not_found')) return { status: 404, code: 'not_found' };
  if (m.includes('unsupported_channel')) return { status: 400, code: 'unsupported_channel' };
  if (m.includes('no_sending_number')) return { status: 409, code: 'no_sending_number' };
  if (m.includes('already verified')) return { status: 409, code: 'already_verified' };
  return { status: 400, code: 'invalid_request' };
}

export async function handleStaffVerification(req: Request, deps: StaffVerificationDeps): Promise<Response> {
  if (req.method !== 'POST') return json(405, { error: 'method_not_allowed' });
  const user = await deps.authenticate(req);
  if (!user) return json(401, { error: 'unauthorized' });
  let body: { action?: unknown; identity_id?: unknown; code?: unknown };
  try { body = await req.json(); } catch { return json(400, { error: 'bad_json' }); }
  const id = typeof body.identity_id === 'string' && /^[0-9a-f-]{36}$/i.test(body.identity_id) ? body.identity_id : null;
  if (!id) return json(400, { error: 'identity_id_required' });
  const now = deps.now();
  try {
    if (body.action === 'start') {
      const row = (await deps.rpc<StartRow[]>('start_staff_verification', { p_identity_id: id, p_actor: user, p_now: now.toISOString() }))[0];
      const text = `${row.dealer_name}: your verification code is ${row.code}. It expires in 10 minutes. Do not share it.`;
      const sent = await deps.dispatcher.sendRaw({
        dealerId: row.dealer_id, number: { id: row.number_id, channel: row.channel, provider: row.provider, address: row.number_address, config: row.number_config },
        to: row.to_address, body: text, idempotencyKey: `staffcode:${row.verification_id}`,
      });
      await deps.rpc('mark_staff_verification_sent', { p_verification_id: row.verification_id, p_ok: sent.ok, p_error: sent.ok ? null : sent.error, p_now: deps.now().toISOString() });
      if (!sent.ok) { deps.log?.('staff_code_send_failed', { identity_id: id, error: sent.error }); return json(502, { ok: false, error: 'code_not_sent', detail: sent.error }); }
      return json(200, { ok: true, expires_at: row.expires_at, sent_to: maskPhone(row.to_address) });
    }
    if (body.action === 'confirm') {
      const code = typeof body.code === 'string' ? body.code.trim() : '';
      if (!/^[0-9]{6}$/.test(code)) return json(400, { result: 'wrong_code', error: 'code_format' });
      const r = (await deps.rpc<{ result: string; attempts_left: number }[]>('confirm_staff_verification', { p_identity_id: id, p_code: code, p_actor: user, p_now: now.toISOString() }))[0];
      return json(r.result === 'verified' ? 200 : 400, { result: r.result, attempts_left: r.attempts_left });
    }
    return json(400, { error: 'unknown_action' });
  } catch (e) {
    const msg = (e as Error).message ?? '';
    const m = statusForError(msg);
    if (m.status >= 500 || m.code === 'invalid_request') deps.log?.('staff_verification_error', { error: msg.slice(0, 200) });
    return json(m.status, { ok: false, error: m.code });
  }
}

export const maskPhone = (p: string): string => (p.length > 4 ? `${p.slice(0, 2)}${'•'.repeat(Math.max(p.length - 6, 2))}${p.slice(-4)}` : '••••');
