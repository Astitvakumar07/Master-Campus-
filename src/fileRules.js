export const MAX_CAMPUS_FILE_BYTES = 10 * 1024 * 1024;

const ALLOWED_MIME_TYPES = new Set([
  'application/pdf',
  'text/csv',
  'application/csv',
  'application/vnd.ms-excel',
  'application/octet-stream',
]);

export function validateCampusFile(file) {
  if (!file) return;
  if (file.size > MAX_CAMPUS_FILE_BYTES) {
    throw new Error('Files must be 10 MB or smaller on the free setup.');
  }
  const extension = file.name?.split('.').pop()?.toLowerCase();
  if (!['pdf', 'csv'].includes(extension)) {
    throw new Error('Only PDF and CSV files are supported.');
  }
  if (file.type && !ALLOWED_MIME_TYPES.has(file.type)) {
    throw new Error('Choose a PDF or CSV file.');
  }
}

export function cleanResourceUrl(value) {
  const raw = String(value || '').trim();
  if (!raw) return null;
  let url;
  try {
    url = new URL(raw);
  } catch {
    throw new Error('Enter a complete link starting with https://');
  }
  if (!['https:', 'http:'].includes(url.protocol)) {
    throw new Error('Only http or https links are supported.');
  }
  return url.toString();
}
