// Single network surface of the dashboard: fixed same-origin routes, bearer token in a header.
// The same page runs in two modes: one run's dashboard (started by the bridge) or the always-on
// control center (view=center), where runs are addressed with a validated ?run= id.
export const API_STATE = '/api/state';
export const API_CHANGES = '/api/changes';
export const API_REPORT = '/api/report';
export const API_PROMPTS = '/api/prompts';
export const API_STOP = '/api/stop';

export const API_CENTER = '/api/center';
export const API_RUNS = '/api/runs';
export const API_RUN_STATE = '/api/run/state';
export const API_RUN_CHANGES = '/api/run/changes';
export const API_RUN_REPORT = '/api/run/report';
export const API_RUN_PROMPTS = '/api/run/prompts';
export const API_RUN_STOP = '/api/run/stop';
export const API_SETTINGS = '/api/settings';
export const API_HEALTH = '/api/health';
export const API_PRUNE = '/api/logs/prune';
export const API_QUIT = '/api/center/quit';

// The token arrives in the URL fragment and is removed from history immediately.
// It is kept in memory only; reloading the page requires reopening the link.
function takeFragment() {
  const fragment = new URLSearchParams(window.location.hash.slice(1));
  const values = {
    token: fragment.get('token') || '',
    view: fragment.get('view') === 'center' ? 'center' : 'run',
    run: fragment.get('run') || ''
  };
  history.replaceState(null, '', window.location.pathname);
  return values;
}

const fragment = takeFragment();
const token = fragment.token;

export function hasToken() {
  return token !== '';
}

export function isCenter() {
  return fragment.view === 'center';
}

export function initialRun() {
  return fragment.run;
}

// Route set for one run. The bridge's own dashboard serves a single run on fixed routes.
export const SINGLE_RUN_ROUTES = { state: API_STATE, changes: API_CHANGES, report: API_REPORT, prompts: API_PROMPTS, stop: API_STOP };

export function centerRunRoutes(runId) {
  const query = '?run=' + encodeURIComponent(runId);
  return {
    state: API_RUN_STATE + query,
    changes: API_RUN_CHANGES + query,
    report: API_RUN_REPORT + query,
    prompts: API_RUN_PROMPTS + query,
    stop: API_RUN_STOP + query
  };
}

export async function api(path, method = 'GET', body) {
  const headers = { 'Authorization': 'Bearer ' + token };
  if (body !== undefined) { headers['Content-Type'] = 'application/json'; }
  const response = await fetch(path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    cache: 'no-store',
    credentials: 'omit',
    referrerPolicy: 'no-referrer'
  });
  let result = null;
  try { result = await response.json(); } catch { result = null; }
  return { ok: response.ok, status: response.status, body: result };
}
