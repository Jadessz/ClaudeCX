// ClaudeCX control room. All server content is rendered as React text nodes; no HTML injection.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ArrowLeft, CircleAlert, CircleCheck, CircleX, Copy, Lock, OctagonX, RefreshCw, Square, WifiOff } from 'lucide-react';
import { SINGLE_RUN_ROUTES, api, hasToken, isCenter } from './api.js';
import { ControlCenter } from './Center.jsx';
import { formatClock, formatCount, formatDuration, formatUsd } from './format.js';
import { CollaborationFlow, StatusIcon } from './Flow.jsx';
import { ChangesView, FlowView, ReportView, WorkView } from './views.jsx';

const POLL_MS = 1000;
const CHANGES_POLL_MS = 5000;
const TABS = [
  { id: 'flow', label: 'Prompt journey' },
  { id: 'work', label: 'Work' },
  { id: 'changes', label: 'Changes' },
  { id: 'report', label: 'Report' }
];
const STATUS_TEXT = { loading: 'Loading', active: 'Running', succeeded: 'Succeeded', failed: 'Failed', stopped: 'Stopped' };
const HEADLINE = {
  loading: 'Connecting to the run',
  active: 'Claude is implementing the Codex brief',
  succeeded: 'Claude finished; Codex review is next',
  stopped: 'Run stopped; partial edits await Codex review',
  failed: 'Run failed; Codex review is next'
};

export function useCopy() {
  const [copied, setCopied] = useState('');
  const timer = useRef(0);
  const copy = useCallback(async (key, text) => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(key);
    } catch {
      setCopied('error:' + key);
    }
    window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => setCopied(''), 2000);
  }, []);
  return [copied, copy];
}

export default function App() {
  return isCenter() ? <ControlCenter /> : <RunConsole routes={SINGLE_RUN_ROUTES} />;
}

// One run: the bridge's own dashboard, or a run opened inside the control center (embedded).
export function RunConsole({ routes, embedded = false, onBack, backLabel = 'Back' }) {
  const tokenPresent = hasToken();
  const [state, setState] = useState(null);
  const [connection, setConnection] = useState(tokenPresent ? 'connecting' : 'no-token');
  const [prompts, setPrompts] = useState({ status: 'idle', data: null });
  const [changes, setChanges] = useState({ status: 'idle', data: null, error: '' });
  const [report, setReport] = useState({ status: 'idle', data: null, forStatus: '' });
  const [tab, setTab] = useState('flow');
  const [notice, setNotice] = useState('');
  const [stopPending, setStopPending] = useState(false);
  const [now, setNow] = useState(() => Date.now());
  const [copied, copy] = useCopy();
  const dialogRef = useRef(null);
  const stopButtonRef = useRef(null);
  const tabRefs = useRef({});
  const changesBusy = useRef(false);

  const loadState = useCallback(async () => {
    if (!tokenPresent) { return; }
    try {
      const result = await api(routes.state);
      if (result.status === 401) { setConnection('unauthorized'); return; }
      if (!result.ok || !result.body) { setConnection('offline'); return; }
      setConnection('online');
      setState(result.body);
      setNow(Date.now());
    } catch {
      setConnection('offline');
    }
  }, [tokenPresent, routes]);

  const loadPrompts = useCallback(async () => {
    if (!tokenPresent) { return; }
    const keep = (current) => ({ status: current.data ? 'ok' : 'error', data: current.data });
    setPrompts((current) => ({ ...current, status: current.data ? 'ok' : 'loading' }));
    try {
      const result = await api(routes.prompts);
      if (!result.ok || !result.body) { setPrompts(keep); return; }
      setPrompts({ status: 'ok', data: result.body });
    } catch {
      setPrompts(keep);
    }
  }, [tokenPresent, routes]);

  const loadChanges = useCallback(async () => {
    if (!tokenPresent || changesBusy.current) { return; }
    changesBusy.current = true;
    setChanges((current) => ({ ...current, status: current.data ? current.status : 'loading' }));
    try {
      const result = await api(routes.changes);
      if (!result.ok || !result.body) {
        setChanges((current) => ({ ...current, status: 'error', error: 'The server could not read repository changes (HTTP ' + result.status + ').' }));
      } else {
        setChanges({ status: 'ok', data: result.body, error: '' });
      }
    } catch {
      setChanges((current) => ({ ...current, status: 'error', error: 'The dashboard server is unreachable.' }));
    } finally {
      changesBusy.current = false;
    }
  }, [tokenPresent, routes]);

  const loadReport = useCallback(async (forStatus) => {
    if (!tokenPresent) { return; }
    try {
      const result = await api(routes.report);
      if (!result.ok || !result.body) { setReport({ status: 'error', data: null, forStatus: '' }); return; }
      setReport({ status: 'ok', data: result.body, forStatus: result.body.kind === 'pending' ? '' : forStatus });
    } catch {
      setReport({ status: 'error', data: null, forStatus: '' });
    }
  }, [tokenPresent, routes]);

  useEffect(() => {
    loadState();
    loadPrompts();
    const id = window.setInterval(loadState, POLL_MS);
    return () => window.clearInterval(id);
  }, [loadState, loadPrompts]);

  useEffect(() => {
    if (tab !== 'changes') { return undefined; }
    loadChanges();
    const id = window.setInterval(loadChanges, CHANGES_POLL_MS);
    return () => window.clearInterval(id);
  }, [tab, loadChanges]);

  const status = state ? state.status : 'loading';
  useEffect(() => {
    if (status === 'loading' || status === 'active') { return; }
    if (report.forStatus !== status) { loadReport(status); }
  }, [status, report.forStatus, loadReport]);

  useEffect(() => {
    if (tab === 'report' && report.status === 'idle') { loadReport(status); }
  }, [tab, report.status, status, loadReport]);

  const refresh = useCallback(() => {
    loadState();
    loadPrompts();
    loadReport(status);
    if (tab === 'changes') { loadChanges(); }
  }, [loadState, loadPrompts, loadReport, loadChanges, tab, status]);

  const openStop = () => {
    const dialog = dialogRef.current;
    if (dialog && !dialog.open) { dialog.showModal(); }
  };
  const closeStop = () => {
    const dialog = dialogRef.current;
    if (dialog && dialog.open) { dialog.close(); }
    stopButtonRef.current?.focus();
  };
  const confirmStop = async () => {
    closeStop();
    setStopPending(true);
    setNotice('Stop requested…');
    try {
      const result = await api(routes.stop, 'POST');
      if (result.status === 202) {
        setNotice('Stop requested… The bridge terminates Claude within a second. Partial edits remain in the working tree for Codex review.');
      } else if (result.status === 409) {
        setNotice('The run is no longer active, so there is nothing to stop.');
      } else {
        setNotice('The stop request was not accepted (HTTP ' + result.status + ').');
      }
    } catch {
      setNotice('The stop request could not reach the dashboard server.');
    }
    setStopPending(false);
    loadState();
  };

  const onTabKey = (event, index) => {
    let next = -1;
    if (event.key === 'ArrowRight') { next = (index + 1) % TABS.length; }
    else if (event.key === 'ArrowLeft') { next = (index - 1 + TABS.length) % TABS.length; }
    else if (event.key === 'Home') { next = 0; }
    else if (event.key === 'End') { next = TABS.length - 1; }
    if (next >= 0) {
      event.preventDefault();
      setTab(TABS[next].id);
      tabRefs.current[TABS[next].id]?.focus();
    }
  };

  const elapsedMs = useMemo(() => {
    if (!state || !state.started_at) { return null; }
    const start = Date.parse(state.started_at);
    const end = state.finished_at ? Date.parse(state.finished_at) : now;
    return Number.isFinite(start) && Number.isFinite(end) ? Math.max(0, end - start) : null;
  }, [state, now]);

  const canStop = Boolean(state && state.can_stop && connection === 'online' && !stopPending);
  const sessionId = state ? state.session_id : '';
  const result = state && state.result ? state.result : null;
  const originalAvailable = prompts.data ? prompts.data.original_available : null;
  const briefAvailable = prompts.data ? prompts.data.brief_available : null;
  const blocked = connection === 'no-token' || connection === 'unauthorized' || connection === 'offline';
  const timeoutMs = state && typeof state.timeout_seconds === 'number' ? state.timeout_seconds * 1000 : null;

  const toolbar = (
    <header className={embedded ? 'commandbar embedded' : 'commandbar'}>
      <div className="brand">
        {embedded
          ? (onBack && (
            <button type="button" className="button ghost small" onClick={onBack}>
              <ArrowLeft aria-hidden="true" size={14} /> {backLabel}
            </button>
          ))
          : (
            <>
              <img className="brand-mark" src="/icon.svg" alt="" width="22" height="22" />
              <span className="brand-name">ClaudeCX</span>
            </>
          )}
        <span className="repo" title="Repository">{state ? state.repository_name || '—' : 'Loading…'}</span>
      </div>
      <div className="commandbar-status">
        <span className="status-badge" data-status={status} role="status" aria-live="polite">
          <StatusIcon status={status} size={14} />
          <span>{STATUS_TEXT[status] || 'Unknown'}</span>
        </span>
        <span className="elapsed"><span className="muted">Elapsed</span> <span className="mono">{formatDuration(elapsedMs)}</span></span>
        {!embedded && <ConnectionBadge connection={connection} />}
      </div>
      <div className="commandbar-actions">
        <button type="button" className="button ghost" onClick={refresh} disabled={!tokenPresent}>
          <RefreshCw aria-hidden="true" size={15} /> Refresh
        </button>
        <button type="button" className="button ghost" onClick={() => copy('session', sessionId)} disabled={!sessionId}>
          <Copy aria-hidden="true" size={15} />
          {copied === 'session' ? 'Copied' : copied === 'error:session' ? 'Copy failed' : 'Copy session'}
        </button>
        <button type="button" className="button danger" ref={stopButtonRef} onClick={openStop} disabled={!canStop}>
          <Square aria-hidden="true" size={13} /> {state && state.stop_requested ? 'Stop requested…' : 'Stop run'}
        </button>
      </div>
    </header>
  );

  const runChips = state ? [
    ...(state.model && state.model !== 'default' ? [{ key: 'model', text: 'Model: ' + state.model }] : []),
    ...(state.protected_paths && state.protected_paths.length > 0
      ? [{ key: 'protected', text: 'Protected: ' + state.protected_paths.join(', '), icon: true }] : []),
    ...(state.settings_notes || []).map((note) => ({ key: note, text: note }))
  ] : [];

  const body = (
    <>
      {blocked && <ConnectionNotice connection={connection} center={embedded} />}
      {notice && <p className="notice" role="status" aria-live="polite">{notice}</p>}

      <section className="hero" data-status={status} aria-labelledby="run-title">
        <div className="hero-main">
          <h1 id="run-title" className="run-title">{HEADLINE[status] || HEADLINE.loading}</h1>
          <p className="run-line">
            <span className="eyebrow">{status === 'active' ? 'Current activity' : 'Outcome'}</span>
            <span className="run-line-text">
              {status === 'active'
                ? (state && state.last_activity) || 'Waiting for the first activity…'
                : (state && state.final_message) || (state ? 'No final message was recorded.' : '—')}
            </span>
          </p>
        </div>
        <dl className="facts">
          <div><dt>Session</dt><dd><code>{sessionId ? sessionId.slice(0, 8) : '—'}</code> <span className="muted">{state ? (state.resumed ? 'resumed' : 'new') : ''}</span></dd></div>
          <div><dt>Started</dt><dd>{formatClock(state && state.started_at)}</dd></div>
          <div><dt>Turns</dt><dd>{formatCount(result && result.num_turns)} <span className="muted">/ {formatCount(state && state.max_turns)}</span></dd></div>
          <div><dt>Cost</dt><dd>{formatUsd(result && result.total_cost_usd)} <span className="muted">/ {formatUsd(state && state.max_budget_usd)}</span></dd></div>
          <div><dt>Duration</dt><dd>{formatDuration(result && result.duration_ms)} <span className="muted">/ {formatDuration(timeoutMs)}</span></dd></div>
        </dl>
      </section>

      {runChips.length > 0 && (
        <ul className="chips" aria-label="Settings for this run">
          {runChips.map((chip) => (
            <li key={chip.key} className="chip">{chip.icon && <Lock aria-hidden="true" size={12} />}<span>{chip.text}</span></li>
          ))}
        </ul>
      )}

      <CollaborationFlow status={status} originalAvailable={originalAvailable} briefAvailable={briefAvailable} />

      <section className="workspace" aria-label="Run details">
        <div className="tabs" role="tablist" aria-label="Run details">
          {TABS.map((item, index) => (
            <button
              key={item.id}
              type="button"
              role="tab"
              id={'tab-' + item.id}
              aria-controls={'panel-' + item.id}
              aria-selected={tab === item.id}
              tabIndex={tab === item.id ? 0 : -1}
              ref={(node) => { tabRefs.current[item.id] = node; }}
              onClick={() => setTab(item.id)}
              onKeyDown={(event) => onTabKey(event, index)}
            >
              {item.label}
              {item.id === 'work' && state && state.activity.length > 0 && <span className="tab-count">{state.activity.length}</span>}
            </button>
          ))}
        </div>
        <div role="tabpanel" id={'panel-' + tab} aria-labelledby={'tab-' + tab} className="panel">
          {tab === 'flow' && <FlowView prompts={prompts} copied={copied} copy={copy} />}
          {tab === 'work' && <WorkView state={state} />}
          {tab === 'changes' && <ChangesView changes={changes} />}
          {tab === 'report' && <ReportView report={report} status={status} />}
        </div>
      </section>
    </>
  );

  const dialog = (
    <dialog ref={dialogRef} className="stop-dialog" aria-labelledby="stop-title" aria-describedby="stop-text" onCancel={closeStop}>
      <h2 id="stop-title"><OctagonX aria-hidden="true" size={18} /> Stop this Claude run?</h2>
      <p id="stop-text">The bridge will terminate Claude and report the run as stopped. Partial edits remain in the working tree for Codex review; nothing is reverted.</p>
      <div className="dialog-actions">
        <button type="button" className="button" onClick={closeStop} autoFocus>Keep running</button>
        <button type="button" className="button danger solid" onClick={confirmStop}>Yes, stop the run</button>
      </div>
    </dialog>
  );

  if (embedded) {
    return <div className="run-embedded">{toolbar}{body}{dialog}</div>;
  }
  return (
    <>
      <a className="skip-link" href="#main">Skip to content</a>
      {toolbar}
      <main id="main" className="layout" tabIndex={-1}>{body}</main>
      <footer className="footer">
        <Lock aria-hidden="true" size={13} /> Local only (127.0.0.1). Closing this page does not stop Claude.
      </footer>
      {dialog}
    </>
  );
}

export function ConnectionBadge({ connection }) {
  const map = {
    connecting: ['Connecting', null],
    online: ['Connected', CircleCheck],
    offline: ['Server unreachable', WifiOff],
    unauthorized: ['Token rejected', CircleX],
    'no-token': ['No access token', Lock]
  };
  const [label, Icon] = map[connection] || map.connecting;
  return (
    <span className="connection" data-state={connection} role="status" aria-live="polite">
      {Icon ? <Icon aria-hidden="true" size={14} /> : <span className="pulse-dot" aria-hidden="true" />}
      {label}
    </span>
  );
}

export function ConnectionNotice({ connection, center = false }) {
  const text = center ? {
    'no-token': 'This page needs the link that opens the control center. The token is kept in memory only, so a reload cannot reconnect. Open ClaudeCX again from the Start menu.',
    unauthorized: 'The access token was rejected. Open ClaudeCX again from the Start menu.',
    offline: 'The control center is not responding. Open ClaudeCX from the Start menu to start it again. Runs keep going without it.'
  }[connection] : {
    'no-token': 'This page needs the access link opened by the bridge. The token is kept in memory only, so a reload cannot reconnect. The run continues; its progress is in progress.log in the run folder.',
    unauthorized: 'The access token was rejected. Reopen the dashboard link from the bridge.',
    offline: 'The dashboard server is not responding. It exits shortly after the run ends; the run folder still holds progress.log and report.json or failure.json.'
  }[connection];
  return (
    <div className="banner" data-tone={connection === 'offline' ? 'warning' : 'danger'} role="alert">
      <CircleAlert aria-hidden="true" size={18} />
      <p>{text}</p>
    </div>
  );
}
