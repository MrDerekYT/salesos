/**
 * Reply classification (feature 5). The model only LABELS an inbound message; SQL apply_classification() decides
 * what happens (forward-only, per-dealer threshold, lost always reviewed, do_not_contact immediate).
 *
 *  1. Deterministic pre-rule: opt-out keywords never reach the model (STOP => do_not_contact, confidence 1, source rule).
 *  2. Model output must pass a strict Zod schema; anything else is a recorded failure (retryable), never a guess.
 *  3. Grounding: the evidence quote must appear verbatim in the message, otherwise confidence is capped at 0.5 and the
 *     quote is dropped, which forces human review instead of an automatic move.
 *  4. context_version is captured BEFORE the model call; a newer inbound makes the result stale in SQL.
 * Pattern credit: AgenticCRM / AgentSDR reply classifiers (MIT). Code is original.
 */
import { generateText, type LanguageModel } from 'ai';
import { z } from 'zod';
import { classifyInbound } from './opt-out.ts';

export const REPLY_CATEGORIES = ['test_drive_requested', 'ready_to_buy', 'financing_prequal', 'trade_in_inquiry', 'price_shopper', 'just_looking',
  'reschedule', 'not_now', 'bought_elsewhere', 'do_not_contact', 'other'] as const;
export type ReplyCategory = typeof REPLY_CATEGORIES[number];
export const CLASSIFIER_PROMPT_VERSION = 'classify-v1';

export const classificationOutput = z.object({
  category: z.enum(REPLY_CATEGORIES),
  confidence: z.number().min(0).max(1),
  evidence_quote: z.string().trim().min(1).max(300).nullable(),
  rationale: z.string().trim().max(500),
}).strict();
export type ClassificationOutput = z.infer<typeof classificationOutput>;

export interface ClassificationDecision extends ClassificationOutput { source: 'llm' | 'rule'; grounded: boolean }

const norm = (s: string) => s.toLowerCase().normalize('NFKD').replace(/[\u2018\u2019]/g, "'").replace(/[\u201c\u201d]/g, '"').replace(/\s+/g, ' ').trim();

/** Confidence cap for ungrounded labels; must stay below every dealer threshold (SQL check: >= 0.5). */
export const UNGROUNDED_CAP = 0.5;
export function groundQuote(o: ClassificationOutput, message: string): ClassificationDecision {
  const grounded = !!o.evidence_quote && norm(message).includes(norm(o.evidence_quote));
  return grounded
    ? { ...o, source: 'llm', grounded: true }
    : { ...o, evidence_quote: null, confidence: Math.min(o.confidence, UNGROUNDED_CAP), source: 'llm', grounded: false };
}

/** Rules that must not depend on a model. */
export function preRule(message: string): ClassificationDecision | null {
  const r = classifyInbound(message);
  if (r.level === 'stop') return { category: 'do_not_contact', confidence: 1, evidence_quote: message.slice(0, 300), rationale: `opt-out keyword: ${r.matched ?? 'stop'}`, source: 'rule', grounded: true };
  if (r.level === 'probable_stop') return { category: 'do_not_contact', confidence: Math.max(0.5, Math.min(0.9, r.confidence)), evidence_quote: message.slice(0, 300), rationale: `probable opt-out: ${r.reason}`, source: 'rule', grounded: true };
  return null;
}

export function classifierPrompt(message: string, lead: { stage: string; vehicle?: string | null }): string {
  return [
    'You label one inbound message from a car-dealership customer. Reply with JSON only, no prose:',
    '{"category": one of ' + REPLY_CATEGORIES.join('|') + ', "confidence": 0..1, "evidence_quote": the customer\'s exact words (verbatim substring) or null, "rationale": one short sentence}',
    'Rules: label only what the customer actually said; if unsure use "other" with low confidence; "bought_elsewhere" only if they say they bought/leased a vehicle; any request to stop contact is "do_not_contact".',
    `Lead stage: ${lead.stage}. Vehicle of interest: ${lead.vehicle ?? 'unknown'}.`,
    '<customer_message>', message.slice(0, 2000), '</customer_message>',
  ].join('\n');
}

/** Extract and validate the model's JSON (tolerates code fences). Throws with a short reason on anything invalid. */
export function parseClassification(text: string): ClassificationOutput {
  const m = text.match(/\{[\s\S]*\}/);
  if (!m) throw new Error('classifier returned no JSON object');
  let raw: unknown;
  try { raw = JSON.parse(m[0]); } catch { throw new Error('classifier returned invalid JSON'); }
  const r = classificationOutput.safeParse(raw);
  if (!r.success) throw new Error(`classifier output failed schema: ${r.error.issues.map((i) => i.path.join('.') || i.message).join(', ')}`);
  return r.data;
}

export interface ClassifyDeps {
  model: LanguageModel | null;
  modelId?: string;
  record(a: { messageId: string; decision: ClassificationDecision; contextVersion: number; model: string | null; promptVersion: string }): Promise<{ classification_id: string; status: string }>;
  recordFailure(a: { messageId: string; error: string; model: string | null }): Promise<string>;
  timeoutMs?: number;
}

export async function classifyMessage(
  m: { messageId: string; text: string; contextVersion: number; leadStage: string; vehicle?: string | null }, deps: ClassifyDeps,
): Promise<{ status: string; decision: ClassificationDecision | null; error?: string }> {
  const rule = preRule(m.text);
  if (rule) {
    const r = await deps.record({ messageId: m.messageId, decision: rule, contextVersion: m.contextVersion, model: null, promptVersion: 'rule' });
    return { status: r.status, decision: rule };
  }
  if (!deps.model) {
    await deps.recordFailure({ messageId: m.messageId, error: 'no_model_configured', model: null });
    return { status: 'failed', decision: null, error: 'no_model_configured' };
  }
  try {
    const res = await generateText({ model: deps.model, prompt: classifierPrompt(m.text, { stage: m.leadStage, vehicle: m.vehicle }), temperature: 0,
      abortSignal: AbortSignal.timeout(deps.timeoutMs ?? 8000) });
    const decision = groundQuote(parseClassification(res.text), m.text);
    const r = await deps.record({ messageId: m.messageId, decision, contextVersion: m.contextVersion, model: deps.modelId ?? null, promptVersion: CLASSIFIER_PROMPT_VERSION });
    return { status: r.status, decision };
  } catch (e) {
    const error = (e as Error).message.slice(0, 300);
    await deps.recordFailure({ messageId: m.messageId, error, model: deps.modelId ?? null });
    return { status: 'failed', decision: null, error };
  }
}
