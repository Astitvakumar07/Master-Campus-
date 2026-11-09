import test from 'node:test';
import assert from 'node:assert/strict';
import { cleanResourceUrl, MAX_CAMPUS_FILE_BYTES, validateCampusFile } from './fileRules.js';

test('accepts PDF and CSV uploads up to the application limit', () => {
  assert.doesNotThrow(() => validateCampusFile({ name: 'notes.PDF', size: MAX_CAMPUS_FILE_BYTES, type: 'application/pdf' }));
  assert.doesNotThrow(() => validateCampusFile({ name: 'roster.csv', size: 512, type: 'text/csv' }));
});

test('rejects unsupported file types, MIME mismatches and oversized files', () => {
  assert.throws(() => validateCampusFile({ name: 'notes.exe', size: 1, type: 'application/octet-stream' }), /Only PDF and CSV/);
  assert.throws(() => validateCampusFile({ name: 'notes.pdf', size: 1, type: 'text/html' }), /Choose a PDF or CSV/);
  assert.throws(() => validateCampusFile({ name: 'notes.pdf', size: MAX_CAMPUS_FILE_BYTES + 1, type: 'application/pdf' }), /10 MB/);
});

test('resource links allow HTTP(S) and reject executable URL schemes', () => {
  assert.equal(cleanResourceUrl('https://example.com/course'), 'https://example.com/course');
  assert.throws(() => cleanResourceUrl('javascript:alert(1)'), /Only http or https/);
  assert.throws(() => cleanResourceUrl('not a url'), /complete link/);
});
