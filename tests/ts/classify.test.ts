import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MockLanguageModelV4 } from 'ai/test';
import { classifyMessage, groundQuote, parseClassification, preRule, classificationOutput, UNGROUNDED_CAP, type ClassifyDeps } from '../../supabase/functions/_shared/classify.ts';

const usage = { inputTokens: { total: 1, noCache: 1, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 1, text: 1, reasoning: 0 } };
const model = (text: string) => new MockLanguageModelV4({ doGenerate: async () => ({ content: [{ type: 'text', text }], finishReason: { unified: 'stop', raw: 'stop' }, usage, warnings: [] }) });
function deps(m: ClassifyDeps['model']) {
  const log: any[] = [];
  const d: ClassifyDeps = {
    model: m, modelId: 'mock-1',
    record: async (a) => { log.push(['record', a]); return { classification_id: 'k1', status: a.decision.confidence >= 0.85 ? 'auto_applied' : 'proposed' }; },
    recordFailure: async (a) => { log.push(['fail', a]); return 'f1'; },
  };
  return { d, log };
}
const MSG = { messageId: 'M1', text: 'Can I come Saturday morning to drive the Accord?', contextVersion: 7, leadStage: 'contacted' };

test('schema is strict: extra fields and unknown categories are rejected', () => {
  assert.equal(classificationOutput.safeParse({ category: 'ready_to_buy', confidence: 0.9, evidence_quote: null, rationale: 'x', stage: 'won' }).success, false);
  assert.equal(classificationOutput.safeParse({ category: 'sold', confidence: 0.9, evidence_quote: null, rationale: 'x' }).success, false);
  assert.equal(classificationOutput.safeParse({ category: 'other', confidence: 1.2, evidence_quote: null, rationale: 'x' }).success, false);
});

test('parse tolerates code fences; rejects prose and bad JSON', () => {
  assert.equal(parseClassification('```json\n{"category":"other","confidence":0.4,"evidence_quote":null,"rationale":"unclear"}\n```').category, 'other');
  assert.throws(() => parseClassification('I think they want a test drive'), /no JSON/);
  assert.throws(() => parseClassification('{"category":"other",}'), /invalid JSON/);
  assert.throws(() => parseClassification('{"category":"other","confidence":0.4,"rationale":"x"}'), /schema: evidence_quote/);
});

test('grounding: verbatim quote (case/space/curly-quote insensitive) keeps confidence; invented quote is capped', () => {
  const g = groundQuote({ category: 'test_drive_requested', confidence: 0.95, evidence_quote: 'come  saturday MORNING', rationale: 'r' }, MSG.text);
  assert.deepEqual([g.grounded, g.confidence], [true, 0.95]);
  const curly = groundQuote({ category: 'other', confidence: 0.9, evidence_quote: "don't know", rationale: 'r' }, 'I don\u2019t know yet');
  assert.equal(curly.grounded, true);
  const u = groundQuote({ category: 'ready_to_buy', confidence: 0.97, evidence_quote: 'ready to sign today', rationale: 'r' }, MSG.text);
  assert.deepEqual([u.grounded, u.confidence, u.evidence_quote], [false, UNGROUNDED_CAP, null]);
});

test('pre-rule: STOP never reaches the model (do_not_contact, confidence 1, source rule)', async () => {
  assert.equal(preRule('STOP')?.confidence, 1);
  assert.equal(preRule('please stop texting me')?.category, 'do_not_contact');
  assert.equal(preRule('Can I come Saturday?'), null);
  let called = 0;
  const m = new MockLanguageModelV4({ doGenerate: async () => { called++; throw new Error('should not be called'); } });
  const { d, log } = deps(m);
  const r = await classifyMessage({ ...MSG, text: 'STOP' }, d);
  assert.equal(called, 0);
  assert.equal(log[0][1].decision.source, 'rule');
  assert.equal(log[0][1].promptVersion, 'rule');
  assert.equal(r.decision?.category, 'do_not_contact');
});

test('model path: grounded label recorded with the context_version captured before the call', async () => {
  const { d, log } = deps(model('{"category":"test_drive_requested","confidence":0.93,"evidence_quote":"come Saturday morning to drive","rationale":"asks to drive"}'));
  const r = await classifyMessage(MSG, d);
  assert.equal(r.status, 'auto_applied');
  assert.equal(log[0][1].contextVersion, 7);
  assert.equal(log[0][1].model, 'mock-1');
  assert.equal(log[0][1].promptVersion, 'classify-v1');
});

test('model path: hallucinated quote => capped => proposal for a person, not an automatic move', async () => {
  const { d } = deps(model('{"category":"ready_to_buy","confidence":0.99,"evidence_quote":"I want to buy it today","rationale":"x"}'));
  const r = await classifyMessage(MSG, d);
  assert.deepEqual([r.status, r.decision?.confidence], ['proposed', UNGROUNDED_CAP]);
});

test('failures are recorded (retryable), never guessed: bad output, model error, no model', async () => {
  const a = deps(model('Sure! They want a test drive.'));
  assert.equal((await classifyMessage(MSG, a.d)).status, 'failed');
  assert.equal(a.log[0][0], 'fail');
  const b = deps(new MockLanguageModelV4({ doGenerate: async () => { throw new Error('upstream 503'); } }));
  const rb = await classifyMessage(MSG, b.d);
  assert.match(rb.error!, /503/);
  const c = deps(null);
  assert.equal((await classifyMessage(MSG, c.d)).error, 'no_model_configured');
});
