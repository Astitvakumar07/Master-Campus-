import test from 'node:test';
import assert from 'node:assert/strict';
import { allowedOrigins, validateQuizQuestions, WindowRateLimiter } from './security.js';

test('production origins are explicit and normalized', () => {
  const origins = allowedOrigins({ configured: 'https://campus.example, https://admin.example', production: true });
  assert.deepEqual([...origins].sort(), ['https://admin.example', 'https://campus.example']);
  assert.equal(origins.has('http://localhost:5173'), false);
  assert.throws(() => allowedOrigins({ configured: 'javascript:alert(1)', production: true }));
  assert.throws(() => allowedOrigins({ configured: 'https://campus.example/path', production: true }));
});

test('development origin defaults stay local', () => {
  const origins = allowedOrigins({ production: false });
  assert.equal(origins.has('http://localhost:5173'), true);
  assert.equal(origins.has('https://unknown.example'), false);
});

test('rate limiter enforces windows and resets after expiration', () => {
  let time = 1_000;
  const limiter = new WindowRateLimiter({ limit: 2, windowMs: 5_000, now: () => time });
  assert.equal(limiter.consume('one').allowed, true);
  assert.equal(limiter.consume('one').allowed, true);
  assert.equal(limiter.consume('one').allowed, false);
  time += 5_001;
  assert.equal(limiter.consume('one').allowed, true);
});

test('rate limiter has a fixed key capacity and does not grow without bound', () => {
  const limiter = new WindowRateLimiter({ limit: 10, windowMs: 60_000, maxKeys: 1, now: () => 10 });
  assert.equal(limiter.consume('one').allowed, true);
  assert.equal(limiter.consume('two').allowed, false);
  assert.equal(limiter.windows.size, 1);
});

test('quiz output validator rejects malformed or oversized AI output', () => {
  const valid = [{ question: 'Which one?', options: ['A', 'B', 'C', 'D'], answer_index: 2, explanation: 'Because.' }];
  assert.equal(validateQuizQuestions(valid, 1), true);
  assert.equal(validateQuizQuestions([{ ...valid[0], answer_index: 4 }], 1), false);
  assert.equal(validateQuizQuestions([{ ...valid[0], options: ['A'] }], 1), false);
  assert.equal(validateQuizQuestions([{ ...valid[0], question: 'x'.repeat(601) }], 1), false);
  assert.equal(validateQuizQuestions([], 1), false);
});
