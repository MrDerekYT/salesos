/**
 * Morning Drive briefing: the testable core. index.ts wires real Supabase/LLM deps into `processBriefings`.
 *
 * Division of labour (the property that makes this safe to charge for):
 *   SQL   decides WHO needs WHAT and in which order (deterministic score, frozen facts, no PII).
 *   LLM   only (a) narrates a 2-3 sentence opener and (b) drafts a suggested reply for a few items.
 *   Gates every suggested draft runs the same before-send chain as live traffic, in dry-run, and lands in the review
 *         queue as `awaiting_review`. Nothing in this file can send a message.
 * If the LLM is down, slow or ungrounded the briefing still ships with deterministic text.
 */
import { runChain, type ChainDeps, type ChainOutcome, type GateInput } from '../_shared/before-send.ts';

export type BriefingKind =
  | 'waiting_reply' | 'test_drive_today' | 'test_drive_noshow' | 'callback_due'
  | 'hot_gone_quiet' | 'price_drop_viewed' | 'trade_in_pending' | 'lease_ending';

export interface ClaimedBriefing { id: string; dealer_id: string; user_id: string; local_date: string; attempts: number }
export interface BriefingItemRow {
  id: string; rank: number; lead_id: string; kind: BriefingKind; score: number; reason_text: string;
  evidence: { also_kinds?: BriefingKind[]; contact_reachable?: boolean } & Record<string, unknown>;
}
export interface BriefingFacts { total_candidates: number; by_kind: Partial<Record<BriefingKind, number>>; size: number }

export interface DraftTarget { dealerId: string; leadId: string; contactId: string; numberId: string }
export interface PreparedDraft { gate: GateInput; target: DraftTarget; chain: ChainDeps }

export interface NarrationInput { localDate: string; facts: BriefingFacts; items: { rank: number; kind: BriefingKind; reason: string }[] }
export interface Narration { narrative: string; itemTexts?: Record<number, string> }

export interface BriefingDeps {
  claim(limit: number): Promise<ClaimedBriefing[]>;
  /** Calls SQL build_briefing_items(), then returns items + frozen facts. */
  build(b: ClaimedBriefing): Promise<{ items: BriefingItemRow[]; facts: BriefingFacts }>;
  /** LLM narration. Must NOT be given names, phones or message bodies. May throw/time out. */
  narrate(input: NarrationInput): Promise<Narration>;
  /** LLM draft for one item (given only kind + reason + the lead's last inbound text it loads itself). */
  draftReply(item: BriefingItemRow): Promise<string | null>;
  /**
   * Loads everything the gates need for this lead/body (settings, DNC, budget, thread, evidence) plus the row ids the
   * draft needs, and a ChainDeps bound to this lead's number. Returns null if the lead is unreachable / has no channel.
   */
  prepareDraft(item: BriefingItemRow, body: string, now: Date): Promise<PreparedDraft | null>;
  insertDraft(a: { item: BriefingItemRow; target: DraftTarget; gate: GateInput; outcome: ChainOutcome }): Promise<string>;
  linkDraft(itemId: string, draftId: string): Promise<void>;
  saveReady(briefingId: string, narrative: string, itemTexts: Record<number, string>): Promise<void>;
  /** In-app (Realtime) + optional push/email digest to the rep. */
  deliver(b: ClaimedBriefing, summary: { narrative: string; itemCount: number }): Promise<void>;
  markDelivered(briefingId: string): Promise<void>;
  markFailed(briefingId: string, error: string, final: boolean): Promise<void>;
  now(): Date;
  log?(event: string, data: Record<string, unknown>): void;
}

export interface BriefingConfig { claimLimit: number; draftTopN: number; narrationTimeoutMs: number; maxAttempts: number }
export const DEFAULT_BRIEFING_CONFIG: BriefingConfig = { claimLimit: 20, draftTopN: 5, narrationTimeoutMs: 8000, maxAttempts: 5 };

/** Kinds where "a suggested reply" makes sense. Appointment-day items are for the rep to prepare, not to text. */
export const DRAFTABLE_KINDS: ReadonlySet<BriefingKind> = new Set<BriefingKind>(['waiting_reply', 'hot_gone_quiet', 'test_drive_noshow', 'callback_due', 'price_drop_viewed']);

const KIND_LABEL: Record<BriefingKind, [string, string]> = {
  waiting_reply: ['reply waiting', 'replies waiting'],
  test_drive_today: ['test drive today', 'test drives today'],
  test_drive_noshow: ['no-show to re-book', 'no-shows to re-book'],
  callback_due: ['callback due', 'callbacks due'],
  hot_gone_quiet: ['hot lead gone quiet', 'hot leads gone quiet'],
  price_drop_viewed: ['price-drop viewer', 'price-drop viewers'],
  trade_in_pending: ['trade-in waiting', 'trade-ins waiting'],
  lease_ending: ['lease ending soon', 'leases ending soon'],
};
const KIND_ORDER: BriefingKind[] = ['waiting_reply', 'test_drive_today', 'test_drive_noshow', 'callback_due', 'hot_gone_quiet', 'price_drop_viewed', 'trade_in_pending', 'lease_ending'];

/** Always-available opener built from the frozen facts. */
export function fallbackNarrative(facts: BriefingFacts, shown: number): string {
  const parts: string[] = [];
  for (const k of KIND_ORDER) {
    const n = facts.by_kind[k] ?? 0;
    if (n > 0) parts.push(`${n} ${KIND_LABEL[k][n === 1 ? 0 : 1]}`);
  }
  if (parts.length === 0) return 'Nothing urgent this morning. A good day to reach out to new leads.';
  const list = parts.length === 1 ? parts[0] : `${parts.slice(0, -1).join(', ')} and ${parts[parts.length - 1]}`;
  const tail = facts.total_candidates > shown ? ` Showing the top ${shown}.` : '';
  return `Good morning. ${list.charAt(0).toUpperCase()}${list.slice(1)}.${tail}`;
}

/**
 * Grounding check: every number in LLM text must appear in the source (facts, reasons). A narration that invents a
 * count ("12 hot leads") is discarded. Cheap, deterministic, catches the failure that erodes trust fastest.
 */
export function isGrounded(text: string, sources: string[]): boolean {
  const allowed = new Set<string>();
  for (const s of sources) for (const m of s.matchAll(/\d+(?:[.,]\d+)?/g)) allowed.add(m[0]);
  for (const m of text.matchAll(/\d+(?:[.,]\d+)?/g)) if (!allowed.has(m[0])) return false;
  return true;
}
const BAD_TEXT = /\b(guarantee|approved|pre-?approved|\$\d|apr|stop\b|reply stop)\b/i;

export function validateNarration(n: Narration, input: NarrationInput): { narrative: string; itemTexts: Record<number, string>; usedLlm: boolean } {
  const factText = JSON.stringify(input.facts) + ' ' + input.items.map((i) => `${i.rank} ${i.reason}`).join(' ');
  const fb = fallbackNarrative(input.facts, input.items.length);
  const narrative = n.narrative?.trim() ?? '';
  const okNarr = narrative.length >= 10 && narrative.length <= 600 && isGrounded(narrative, [factText, input.localDate]) && !BAD_TEXT.test(narrative);
  const itemTexts: Record<number, string> = {};
  for (const it of input.items) {
    const t = n.itemTexts?.[it.rank]?.trim();
    // a rewrite must stay grounded in the item's own reason text; otherwise the deterministic reason is used downstream
    if (t && t.length <= 240 && isGrounded(t, [it.reason, String(it.rank)]) && !BAD_TEXT.test(t)) itemTexts[it.rank] = t;
  }
  return { narrative: okNarr ? narrative : fb, itemTexts, usedLlm: okNarr };
}

function withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
  let t: ReturnType<typeof setTimeout>;
  const timeout = new Promise<never>((_, rej) => { t = setTimeout(() => rej(new Error('timeout')), ms); });
  return Promise.race([p, timeout]).finally(() => clearTimeout(t));
}

export interface ProcessSummary { claimed: number; delivered: number; failed: number; drafts: number; llmFallbacks: number }

export async function processBriefings(deps: BriefingDeps, cfg: BriefingConfig = DEFAULT_BRIEFING_CONFIG): Promise<ProcessSummary> {
  const sum: ProcessSummary = { claimed: 0, delivered: 0, failed: 0, drafts: 0, llmFallbacks: 0 };
  const claimed = await deps.claim(cfg.claimLimit);
  sum.claimed = claimed.length;
  for (const b of claimed) {
    try {
      const { items, facts } = await deps.build(b);

      // 1) narration: best-effort, grounded, deterministic fallback
      const input: NarrationInput = { localDate: b.local_date, facts, items: items.map((i) => ({ rank: i.rank, kind: i.kind, reason: i.reason_text })) };
      let raw: Narration = { narrative: '' };
      try { raw = await withTimeout(deps.narrate(input), cfg.narrationTimeoutMs); } catch (e) { deps.log?.('narrate_failed', { briefing: b.id, error: String(e) }); }
      const v = validateNarration(raw, input);
      if (!v.usedLlm) sum.llmFallbacks += 1;

      // 2) suggested replies for the top draftable items, through the real gate chain (dry run => review queue only)
      let made = 0;
      for (const item of items) {
        if (made >= cfg.draftTopN) break;
        if (!DRAFTABLE_KINDS.has(item.kind) || item.evidence.contact_reachable === false) continue;
        try {
          const body = await withTimeout(deps.draftReply(item), cfg.narrationTimeoutMs);
          if (!body) continue;
          const prep = await deps.prepareDraft(item, body, deps.now());
          if (!prep) continue;
          const gate: GateInput = { ...prep.gate, body, actor: 'ai', kind: item.kind === 'waiting_reply' ? 'reply' : 'followup' };
          const outcome = await runChain(gate, prep.chain);
          // veto => no draft (the rep still sees the reason). hold/delay/allow => queued for review, never auto-sent from here.
          if (outcome.result.verdict === 'veto') { deps.log?.('draft_vetoed', { item: item.id, code: outcome.result.code }); continue; }
          const draftId = await deps.insertDraft({ item, target: prep.target, gate, outcome });
          await deps.linkDraft(item.id, draftId);
          made += 1;
        } catch (e) { deps.log?.('draft_failed', { item: item.id, error: String(e) }); }
      }
      sum.drafts += made;

      // 3) persist + deliver
      await deps.saveReady(b.id, v.narrative, v.itemTexts);
      await deps.deliver(b, { narrative: v.narrative, itemCount: items.length });
      await deps.markDelivered(b.id);
      sum.delivered += 1;
    } catch (e) {
      sum.failed += 1;
      await deps.markFailed(b.id, e instanceof Error ? e.message.slice(0, 300) : String(e), b.attempts >= cfg.maxAttempts);
    }
  }
  return sum;
}
