import { test } from 'node:test';
import assert from 'node:assert/strict';
import { classifyInbound, blocksAutomation, normalizeInbound } from '../../supabase/functions/_shared/opt-out.ts';

const level = (t: string) => classifyInbound(t).level;

test('CTIA keywords are certain stops, case/punctuation/whitespace insensitive', () => {
  for (const t of ['STOP', 'stop', ' Stop. ', 'STOP!!', 'stopall', 'Unsubscribe', 'CANCEL', 'END', 'QUIT', 'revoke', 'opt out', 'OPT-OUT']) {
    assert.equal(level(t), 'stop', t);
  }
});

test('stop phrases that pair a cessation verb with a communication object', () => {
  for (const t of ['please stop texting me', 'Stop sending me messages', 'don\'t text me again', 'take me off your list', 'remove me from your list', 'do not contact me', 'unsubscribe me please']) {
    assert.equal(level(t), 'stop', t);
  }
});

test('automotive phrases that contain stop-ish words are NOT opt-outs', () => {
  for (const t of ['I will stop by around 5', 'can I stop in tomorrow?', 'Please cancel my appointment, I will reschedule', 'end of the month works', 'I need to quit my job first, then buy', 'text me after 5pm', 'call me instead of texting', 'email is better than text']) {
    assert.ok(!blocksAutomation(classifyInbound(t)), `should not block: ${t} -> ${level(t)}`);
  }
});

test('ambiguous / hostile / legal messages silence the bot and escalate', () => {
  for (const t of ['leave me alone', 'wrong number', 'I never signed up for this', 'this is harassment, I will call my lawyer', 'TCPA violation']) {
    const r = classifyInbound(t);
    assert.ok(blocksAutomation(r), t);
    assert.equal(r.action, 'silence_and_escalate', t);
  }
});

test('HELP and START are routed, YES is not a START', () => {
  assert.equal(level('HELP'), 'help');
  assert.equal(level('start'), 'start');
  assert.ok(!blocksAutomation(classifyInbound('yes')));
  assert.equal(level('yes'), 'none');
});

test('null / empty input is harmless', () => {
  assert.equal(level(''), 'none');
  assert.equal(classifyInbound(null).level, 'none');
  assert.equal(normalizeInbound('  STOP!! '), 'stop');
});
