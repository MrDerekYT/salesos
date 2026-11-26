/** Retries keyword confirmations (STOP/START/HELP) that failed to send. See _shared/keyword-replies.ts for the contract. */
import { deliverKeywordReply, type ClaimedKeywordReply, type KeywordReplyDeps } from '../_shared/keyword-replies.ts';

export interface KeywordWorkerSummary { claimed: number; sent: number; retrying: number; terminal: number }

export async function runKeywordReplyWorker(deps: KeywordReplyDeps, limit = 20): Promise<KeywordWorkerSummary> {
  const sum: KeywordWorkerSummary = { claimed: 0, sent: 0, retrying: 0, terminal: 0 };
  const rows = await deps.rpc<ClaimedKeywordReply[]>('claim_keyword_replies', { p_limit: limit, p_now: deps.now().toISOString() });
  sum.claimed = rows.length;
  for (const r of rows) {
    const out = await deliverKeywordReply(r, deps);
    if (out.ok) sum.sent++; else if (out.status === 'pending') sum.retrying++; else sum.terminal++;
  }
  return sum;
}
