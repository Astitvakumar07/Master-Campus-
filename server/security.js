export function allowedOrigins({ configured = '', production = false } = {}) {
  const configuredList = String(configured)
    .split(',')
    .map(value => value.trim())
    .filter(Boolean)
    .map(value => {
      const url = new URL(value);
      if (!['http:', 'https:'].includes(url.protocol) || url.origin !== value || url.username || url.password) {
        throw new Error('APP_ORIGIN values must be exact http(s) origins without paths or credentials.');
      }
      return url.origin;
    });
  const developmentList = production
    ? []
    : ['http://localhost:5173', 'http://127.0.0.1:5173', 'http://localhost:4173', 'http://127.0.0.1:4173'];
  return new Set([...configuredList, ...developmentList]);
}

export class WindowRateLimiter {
  constructor({ limit, windowMs, maxKeys = 10_000, now = Date.now }) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.maxKeys = maxKeys;
    this.now = now;
    this.windows = new Map();
  }

  consume(key) {
    const now = this.now();
    let entry = this.windows.get(key);
    if (!entry || now - entry.startedAt >= this.windowMs) {
      if (!entry && this.windows.size >= this.maxKeys) {
        for (const [candidate, window] of this.windows) {
          if (now - window.startedAt >= this.windowMs) this.windows.delete(candidate);
        }
        if (this.windows.size >= this.maxKeys) return { allowed: false, retryAfterMs: this.windowMs };
      }
      entry = { startedAt: now, count: 0 };
      this.windows.set(key, entry);
    }
    if (entry.count >= this.limit) {
      return { allowed: false, retryAfterMs: Math.max(1, this.windowMs - (now - entry.startedAt)) };
    }
    entry.count += 1;
    return { allowed: true, retryAfterMs: 0 };
  }
}

export function validateQuizQuestions(questions, expectedCount) {
  if (!Array.isArray(questions) || questions.length !== expectedCount) return false;
  return questions.every(question =>
    question &&
    typeof question.question === 'string' && question.question.trim().length > 0 && question.question.length <= 600 &&
    Array.isArray(question.options) && question.options.length === 4 &&
    question.options.every(option => typeof option === 'string' && option.trim().length > 0 && option.length <= 300) &&
    Number.isInteger(question.answer_index) && question.answer_index >= 0 && question.answer_index < 4 &&
    typeof question.explanation === 'string' && question.explanation.length <= 1200
  );
}
