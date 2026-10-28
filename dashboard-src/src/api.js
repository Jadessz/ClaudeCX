// Single network surface of the dashboard: fixed same-origin routes, bearer token in a header.
export const API_STATE = '/api/state';
export const API_CHANGES = '/api/changes';
export const API_REPORT = '/api/report';
export const API_PROMPTS = '/api/prompts';
export const API_STOP = '/api/stop';

// The token arrives in the URL fragment and is removed from history immediately.
// It is kept in memory only; reloading the page requires reopening the dashboard link.
function takeToken() {
  const fragment = new URLSearchParams(window.location.hash.slice(1));
  const value = fragment.get('token') || '';
  history.replaceState(null, '', window.location.pathname);
  return value;
}

const token = takeToken();

export function hasToken() {
  return token !== '';
}

export async function api(path, method = 'GET') {
  const response = await fetch(path, {
    method,
    headers: { 'Authorization': 'Bearer ' + token },
    cache: 'no-store',
    credentials: 'omit',
    referrerPolicy: 'no-referrer'
  });
  let body = null;
  try { body = await response.json(); } catch { body = null; }
  return { ok: response.ok, status: response.status, body };
}
