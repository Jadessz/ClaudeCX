// The always-on control center: live run, history, settings, and setup health. Text nodes only.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  Activity, Archive, Bot, CircleAlert, CircleCheck, CircleX, Clock, Coins, Gauge, History, Lock, MonitorPlay, Power,
  RefreshCw, RotateCcw, Save, Server, Settings, ShieldCheck, Stethoscope, Trash2
} from 'lucide-react';
import {
  API_CENTER, API_HEALTH, API_PRUNE, API_QUIT, API_RUNS, API_SETTINGS, api, centerRunRoutes, hasToken, initialRun
} from './api.js';
import { formatBytes, formatClock, formatDuration, formatUsd } from './format.js';
import { ConnectionBadge, ConnectionNotice, RunConsole } from './App.jsx';
import { StatusIcon } from './Flow.jsx';
import { EmptyState } from './views.jsx';
import { NumberField, SearchField, Select, Switch, TagInput } from './Controls.jsx';
import { DataCard } from './Data.jsx';

const CENTER_POLL_MS = 2000;
const VIEWS = [
  { id: 'live', label: 'Live', icon: Activity },
  { id: 'history', label: 'History', icon: History },
  { id: 'settings', label: 'Settings', icon: Settings },
  { id: 'health', label: 'Health', icon: Stethoscope }
];
const RUN_STATUS_TEXT = { active: 'Running', succeeded: 'Succeeded', failed: 'Failed', stopped: 'Stopped', interrupted: 'Interrupted' };
const GROUPS = [
  { id: 'limits', title: 'Limits per run', icon: Gauge, text: 'Your ceiling. Codex can ask for less on a run, never more. A project can lower them in its committed .claudecx.json.' },
  { id: 'claude', title: 'Claude', icon: Bot, text: 'Which model writes the code.' },
  { id: 'display', title: 'Live view', icon: MonitorPlay, text: 'How you follow a run while it works.' },
  { id: 'safety', title: 'Protected paths', icon: ShieldCheck, text: 'Checked against git status after every run; a run that touches one fails. .claudecx.json is always protected.' },
  { id: 'housekeeping', title: 'Logs', icon: Archive, text: 'Run logs keep your briefs, Claude\'s output, and parts of your code.' }
];
const CHOICES = {
  model: {
    default: ['Claude Code default', 'Whatever model your Claude Code uses'],
    sonnet: ['Sonnet', 'Fast and capable, lower cost'],
    opus: ['Opus', 'Most capable, highest cost'],
    haiku: ['Haiku', 'Fastest and cheapest, for small fixes']
  },
  progress_display: {
    dashboard: ['Browser dashboard', 'Opens the run in your browser'],
    window: ['Progress window', 'A small read-only window'],
    console: ['Terminal', 'Progress lines in the terminal'],
    none: ['Nothing', 'Logs only']
  }
};
const PATH_SUGGESTIONS = ['.github/workflows/', '*.lock', 'migrations/', 'infra/'];

function RunRoute({ runId, onBack, backLabel }) {
  const routes = useMemo(() => centerRunRoutes(runId), [runId]);
  return <RunConsole key={runId} routes={routes} embedded onBack={onBack} backLabel={backLabel} />;
}

function RunStatus({ status }) {
  const tone = status === 'interrupted' ? 'stopped' : status;
  return (
    <span className="status-badge" data-status={tone}>
      <StatusIcon status={tone} size={13} />
      <span>{RUN_STATUS_TEXT[status] || status}</span>
    </span>
  );
}

function runDuration(run) {
  if (typeof run.duration_ms === 'number') { return formatDuration(run.duration_ms); }
  const start = Date.parse(run.started_at || '');
  const end = Date.parse(run.finished_at || '');
  return Number.isFinite(start) && Number.isFinite(end) ? formatDuration(end - start) : '—';
}

function PageHead({ title, text, children }) {
  return (
    <div className="center-head">
      <div>
        <h1 className="center-title">{title}</h1>
        {text && <p className="center-lede">{text}</p>}
      </div>
      {children && <div className="center-tools">{children}</div>}
    </div>
  );
}

export function ControlCenter() {
  const tokenPresent = hasToken();
  const [view, setView] = useState('live');
  const [connection, setConnection] = useState(tokenPresent ? 'connecting' : 'no-token');
  const [overview, setOverview] = useState(null);
  const [liveRun, setLiveRun] = useState(initialRun());
  const [historyRun, setHistoryRun] = useState('');
  const [stopped, setStopped] = useState(false);
  const [removed, setRemoved] = useState(false);
  const viewRefs = useRef({});

  const loadOverview = useCallback(async () => {
    if (!tokenPresent) { return; }
    try {
      const result = await api(API_CENTER);
      if (result.status === 401) { setConnection('unauthorized'); return; }
      if (!result.ok || !result.body) { setConnection('offline'); return; }
      setConnection('online');
      setOverview(result.body);
    } catch {
      setConnection('offline');
    }
  }, [tokenPresent]);

  useEffect(() => {
    if (stopped) { return undefined; }
    loadOverview();
    const id = window.setInterval(loadOverview, CENTER_POLL_MS);
    return () => window.clearInterval(id);
  }, [loadOverview, stopped]);

  // Follow a newly started run; keep showing a finished one until the user goes back.
  const active = overview ? overview.active : [];
  const activeIds = active.map((run) => run.id).join('|');
  const followed = useRef(liveRun);
  useEffect(() => {
    if (active.length === 0) { return; }
    const current = followed.current;
    const stillActive = active.some((run) => run.id === current);
    if (!current || !stillActive) {
      const next = active[0].id;
      if (next !== current) {
        followed.current = next;
        setLiveRun(next);
        setView('live');
      }
    }
  }, [activeIds]);

  const onViewKey = (event, index) => {
    let next = -1;
    if (event.key === 'ArrowRight') { next = (index + 1) % VIEWS.length; }
    else if (event.key === 'ArrowLeft') { next = (index - 1 + VIEWS.length) % VIEWS.length; }
    if (next >= 0) {
      event.preventDefault();
      setView(VIEWS[next].id);
      viewRefs.current[VIEWS[next].id]?.focus();
    }
  };

  const blocked = connection === 'no-token' || connection === 'unauthorized' || (connection === 'offline' && !stopped);

  return (
    <>
      <a className="skip-link" href="#main">Skip to content</a>
      <header className="commandbar center-bar">
        <div className="brand">
          <img className="brand-mark" src="/icon.svg" alt="" width="22" height="22" />
          <span className="brand-name">ClaudeCX</span>
          <span className="brand-sub">Control center</span>
        </div>
        <nav className="center-nav" role="tablist" aria-label="Control center">
          {VIEWS.map((item, index) => {
            const Icon = item.icon;
            return (
              <button
                key={item.id}
                type="button"
                role="tab"
                id={'view-' + item.id}
                aria-controls="main"
                aria-selected={view === item.id}
                tabIndex={view === item.id ? 0 : -1}
                ref={(node) => { viewRefs.current[item.id] = node; }}
                onClick={() => {
                  // Choosing the open view again returns to its overview.
                  if (item.id === view && item.id === 'history') { setHistoryRun(''); }
                  if (item.id === view && item.id === 'live') { followed.current = ''; setLiveRun(''); }
                  setView(item.id);
                }}
                onKeyDown={(event) => onViewKey(event, index)}
              >
                <Icon aria-hidden="true" size={15} /> {item.label}
                {item.id === 'live' && active.length > 0 && <span className="live-dot" aria-label={active.length + ' running'} />}
              </button>
            );
          })}
        </nav>
        <ConnectionBadge connection={stopped ? 'offline' : connection} />
      </header>

      <main id="main" className="layout center-layout" tabIndex={-1} role="tabpanel" aria-labelledby={'view-' + view}>
        {blocked && <ConnectionNotice connection={connection} center />}
        {stopped && !removed && (
          <div className="banner" role="status">
            <Power aria-hidden="true" size={18} />
            <p>The control center is stopped. Runs still work and open their own dashboard. Open ClaudeCX from the Start menu to start it again.</p>
          </div>
        )}
        {overview && overview.settings_errors.length > 0 && (
          <div className="banner" data-tone="danger" role="alert">
            <CircleAlert aria-hidden="true" size={18} />
            <p>Your settings file has problems, so new runs will refuse to start: {overview.settings_errors.join(' ')} Fix them in Settings.</p>
          </div>
        )}
        {!removed && view === 'live' && (
          liveRun
            ? <RunRoute runId={liveRun} onBack={() => { followed.current = ''; setLiveRun(''); }} backLabel="Overview" />
            : <LiveIdle overview={overview} onOpen={(id) => { setHistoryRun(id); setView('history'); }} />
        )}
        {!removed && view === 'history' && (
          historyRun
            ? <RunRoute runId={historyRun} onBack={() => setHistoryRun('')} backLabel="All runs" />
            : <HistoryView onOpen={setHistoryRun} />
        )}
        {!removed && view === 'settings' && <SettingsView />}
        {removed
          ? (
            <section className="idle-card" aria-labelledby="removed-title">
              <span className="idle-icon" aria-hidden="true"><CircleCheck size={22} /></span>
              <div>
                <h1 id="removed-title" className="center-title">ClaudeCX was removed</h1>
                <p className="center-lede">The skill, its shortcuts, and the data you chose are deleted, and the control center has stopped. Restart Codex so it forgets the skill. To use ClaudeCX again, run install.ps1 from the repository. You can close this tab.</p>
              </div>
            </section>
          )
          : view === 'health' && <HealthView onStopped={() => setStopped(true)} onRemoved={() => { setRemoved(true); setStopped(true); }} stopped={stopped} />}
      </main>

      <footer className="footer">
        <Lock aria-hidden="true" size={13} /> Local only (127.0.0.1). Closing this page does not stop Claude or the control center.
      </footer>
    </>
  );
}

function LiveIdle({ overview, onOpen }) {
  const latest = overview ? overview.latest : null;
  return (
    <div className="center-stack">
      <section className="idle-card" aria-labelledby="idle-title">
        <span className="idle-icon" aria-hidden="true"><Activity size={22} /></span>
        <div>
          <h1 id="idle-title" className="center-title">No run in progress</h1>
          <p className="center-lede">
            Type <code>$claudecx</code> and your request in a Codex chat. The run appears here as soon as the bridge starts it.
          </p>
        </div>
      </section>
      <section className="card" aria-labelledby="latest-title">
        <header className="card-head"><h2 id="latest-title" className="card-title">Last run</h2></header>
        {latest
          ? (
            <button type="button" className="latest" onClick={() => onOpen(latest.id)}>
              <RunStatus status={latest.status} />
              <span className="latest-text">
                <span className="latest-request">{latest.request || 'Request not captured'}</span>
                <span className="latest-meta">{latest.repository_name} · {formatClock(latest.started_at)} · {formatUsd(latest.total_cost_usd)}</span>
              </span>
              <span className="latest-open">Open</span>
            </button>
          )
          : <div className="card-body"><EmptyState title={overview ? 'No runs yet' : 'Loading…'}>{overview ? 'Finished runs are listed under History.' : null}</EmptyState></div>}
      </section>
    </div>
  );
}

function Stat({ icon: Icon, label, value, detail }) {
  return (
    <div className="stat">
      <span className="stat-icon" aria-hidden="true"><Icon size={16} /></span>
      <span className="stat-text">
        <span className="stat-label">{label}</span>
        <span className="stat-value">{value}</span>
        {detail && <span className="stat-detail">{detail}</span>}
      </span>
    </div>
  );
}

function HistoryView({ onOpen }) {
  const [state, setState] = useState({ status: 'loading', data: null });
  const [filter, setFilter] = useState('');

  const load = useCallback(async () => {
    setState((current) => ({ ...current, status: current.data ? 'refreshing' : 'loading' }));
    try {
      const result = await api(API_RUNS);
      setState(result.ok && result.body ? { status: 'ok', data: result.body } : { status: 'error', data: null });
    } catch {
      setState({ status: 'error', data: null });
    }
  }, []);
  useEffect(() => { load(); }, [load]);

  const runs = state.data ? state.data.runs : [];
  const needle = filter.trim().toLowerCase();
  const shown = needle
    ? runs.filter((run) => (run.repository_name + ' ' + (run.request || '') + ' ' + run.status).toLowerCase().includes(needle))
    : runs;
  const costs = shown.map((run) => run.total_cost_usd).filter((cost) => typeof cost === 'number');
  const totalCost = costs.reduce((sum, cost) => sum + cost, 0);
  const durations = shown.map((run) => run.duration_ms).filter((ms) => typeof ms === 'number');
  const succeeded = shown.filter((run) => run.status === 'succeeded').length;

  return (
    <div className="center-stack">
      <PageHead title="History" text="Every run on this computer, newest first, from every log folder.">
        <SearchField id="history-filter" label="Filter runs" value={filter} onChange={setFilter} placeholder="Filter by project, request, or status" />
        <button type="button" className="button ghost" onClick={load} disabled={state.status === 'refreshing'}>
          <RefreshCw aria-hidden="true" size={15} className={state.status === 'refreshing' ? 'spin' : undefined} /> Refresh
        </button>
      </PageHead>
      {state.data && runs.length > 0 && (
        <div className="stats">
          <Stat icon={History} label="Runs" value={String(shown.length)} detail={needle ? 'of ' + state.data.total : null} />
          <Stat icon={CircleCheck} label="Succeeded" value={shown.length ? Math.round((succeeded / shown.length) * 100) + '%' : '—'} detail={succeeded + ' of ' + shown.length} />
          <Stat icon={Coins} label="Total cost" value={formatUsd(totalCost)} detail={costs.length ? formatUsd(totalCost / costs.length) + ' per run' : null} />
          <Stat icon={Clock} label="Average time" value={durations.length ? formatDuration(durations.reduce((a, b) => a + b, 0) / durations.length) : '—'} />
        </div>
      )}
      {state.status === 'loading' && <EmptyState title="Loading runs…" />}
      {state.status === 'error' && <EmptyState icon={CircleAlert} tone="danger" title="Runs could not be loaded">Use Refresh to retry.</EmptyState>}
      {state.data && shown.length === 0 && <EmptyState title={runs.length ? 'No run matches the filter' : 'No runs yet'}>{runs.length ? null : 'Runs appear here once $claudecx has been used.'}</EmptyState>}
      {shown.length > 0 && (
        <div className="table-wrap">
          <table className="history">
            <thead>
              <tr><th scope="col">Status</th><th scope="col">Request</th><th scope="col">Project</th><th scope="col">Started</th><th scope="col" className="num">Time</th><th scope="col" className="num">Cost</th><th scope="col"><span className="visually-hidden">Open</span></th></tr>
            </thead>
            <tbody>
              {shown.map((run) => (
                <tr key={run.id} onClick={() => onOpen(run.id)}>
                  <td><RunStatus status={run.status} /></td>
                  <td className="history-request">
                    <span className="history-request-text">{run.request || 'Request not captured'}</span>
                    <span className="history-tags">
                      {run.resumed && <span className="tag">Follow-up</span>}
                      {run.source === 'codex-app' && <span className="tag" title="Logged by the Codex desktop app in its own folder">Codex app</span>}
                    </span>
                  </td>
                  <td><span className="project">{run.repository_name}</span></td>
                  <td className="nowrap muted">{formatClock(run.started_at)}</td>
                  <td className="num mono">{runDuration(run)}</td>
                  <td className="num mono">{formatUsd(run.total_cost_usd)}</td>
                  <td className="num"><button type="button" className="button small ghost" onClick={(event) => { event.stopPropagation(); onOpen(run.id); }}>Open</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

function toDraft(values) {
  const draft = {};
  for (const [key, value] of Object.entries(values)) {
    draft[key] = Array.isArray(value) ? [...value] : typeof value === 'number' ? String(value) : value;
  }
  return draft;
}

function fromDraft(draft, fields) {
  const values = {};
  for (const field of fields) {
    const raw = draft[field.key];
    values[field.key] = field.type === 'number' || field.type === 'integer' ? (raw === '' ? NaN : Number(raw)) : raw;
  }
  return values;
}

function choiceOptions(field) {
  const text = CHOICES[field.key] || {};
  return field.choices.map((choice) => ({ value: choice, label: text[choice] ? text[choice][0] : choice, description: text[choice] ? text[choice][1] : '' }));
}

function rangeText(field) {
  if (field.type !== 'number' && field.type !== 'integer') { return ''; }
  return field.min + ' to ' + field.max + (field.unit ? ' ' + field.unit : '');
}

function SettingRow({ field, value, onChange }) {
  const id = 'setting-' + field.key;
  const helpId = id + '-help';
  const labelId = id + '-label';
  let control;
  if (field.type === 'bool') {
    control = <Switch id={id} checked={Boolean(value)} onChange={onChange} describedBy={helpId} labelledBy={labelId} />;
  } else if (field.type === 'choice') {
    control = <Select id={id} value={value} options={choiceOptions(field)} onChange={onChange} describedBy={helpId} label={field.label} />;
  } else if (field.type === 'paths') {
    control = <TagInput id={id} values={value || []} onChange={onChange} suggestions={PATH_SUGGESTIONS} describedBy={helpId} placeholder="Type a path such as .github/workflows/ and press Enter" />;
  } else {
    control = (
      <NumberField id={id} value={value} min={field.min} max={field.max} step={field.step || 1} unit={field.unit}
        decimals={field.type === 'number' ? 2 : 0} onChange={onChange} describedBy={helpId} />
    );
  }
  return (
    <div className="setting" data-type={field.type}>
      <div className="setting-text">
        <label htmlFor={id} id={labelId} className="setting-label">{field.label}</label>
        <p id={helpId} className="setting-help">{field.help}{rangeText(field) && <span className="setting-range"> · {rangeText(field)}</span>}</p>
      </div>
      <div className="setting-control">{control}</div>
    </div>
  );
}

function SettingsView() {
  const [payload, setPayload] = useState(null);
  const [draft, setDraft] = useState(null);
  const [status, setStatus] = useState({ kind: 'loading', messages: [] });

  const load = useCallback(async () => {
    try {
      const result = await api(API_SETTINGS);
      if (!result.ok || !result.body) { setStatus({ kind: 'error', messages: ['Settings could not be loaded.'] }); return; }
      setPayload(result.body);
      setDraft(toDraft(result.body.values));
      setStatus({ kind: 'idle', messages: [] });
    } catch {
      setStatus({ kind: 'error', messages: ['The control center is unreachable.'] });
    }
  }, []);
  useEffect(() => { load(); }, [load]);

  if (!payload || !draft) {
    return status.kind === 'error'
      ? <EmptyState icon={CircleAlert} tone="danger" title={status.messages[0]} />
      : <EmptyState title="Loading settings…" />;
  }
  const saved = toDraft(payload.values);
  const changed = payload.fields.filter((field) => JSON.stringify(draft[field.key]) !== JSON.stringify(saved[field.key])).length;
  const update = (key, value) => { setDraft((current) => ({ ...current, [key]: value })); setStatus({ kind: 'idle', messages: [] }); };

  const save = async (event) => {
    event.preventDefault();
    setStatus({ kind: 'saving', messages: [] });
    try {
      const result = await api(API_SETTINGS, 'POST', { values: fromDraft(draft, payload.fields) });
      if (result.ok && result.body) {
        setPayload(result.body);
        setDraft(toDraft(result.body.values));
        setStatus({ kind: 'saved', messages: ['Saved. The new settings apply to the next run.'] });
      } else {
        const messages = result.body && result.body.messages ? result.body.messages : ['The settings were not saved (HTTP ' + result.status + ').'];
        setStatus({ kind: 'invalid', messages });
      }
    } catch {
      setStatus({ kind: 'invalid', messages: ['The control center is unreachable.'] });
    }
  };

  return (
    <form className="center-stack settings-page" onSubmit={save} noValidate>
      <PageHead title="Settings" text="Apply to the next run, never to one in progress.">
        <button type="button" className="button ghost" onClick={() => { setDraft(toDraft(payload.defaults)); setStatus({ kind: 'idle', messages: [] }); }}>
          <RotateCcw aria-hidden="true" size={15} /> Reset to defaults
        </button>
      </PageHead>
      {(payload.errors.length > 0 || payload.warnings.length > 0) && (
        <div className="banner" data-tone={payload.errors.length ? 'danger' : 'warning'} role="alert">
          <CircleAlert aria-hidden="true" size={18} />
          <p>{payload.errors.concat(payload.warnings).join(' ')}</p>
        </div>
      )}
      {GROUPS.map((group) => {
        const fields = payload.fields.filter((field) => field.group === group.id);
        if (fields.length === 0) { return null; }
        const Icon = group.icon;
        return (
          <section key={group.id} className="card" aria-labelledby={'group-' + group.id}>
            <header className="card-head">
              <span className="card-icon" aria-hidden="true"><Icon size={16} /></span>
              <div>
                <h2 id={'group-' + group.id} className="card-title">{group.title}</h2>
                <p className="card-text">{group.text}</p>
              </div>
            </header>
            <div className="card-body settings-rows">
              {fields.map((field) => (
                <SettingRow key={field.key} field={field} value={draft[field.key]} onChange={(value) => update(field.key, value)} />
              ))}
            </div>
          </section>
        );
      })}
      <section className="card locked-card" aria-labelledby="group-locked">
        <header className="card-head">
          <span className="card-icon" aria-hidden="true"><Lock size={16} /></span>
          <div>
            <h2 id="group-locked" className="card-title">Always on</h2>
            <p className="card-text">Safety rules that no setting can switch off.</p>
          </div>
        </header>
        <ul className="locked card-body">
          {payload.locked.map((item) => (
            <li key={item.label}>
              <ShieldCheck aria-hidden="true" size={15} />
              <span><span className="setting-label">{item.label}</span><span className="setting-help">{item.reason}</span></span>
            </li>
          ))}
        </ul>
      </section>
      <p className="muted file-note">Saved in <code>{payload.path}</code></p>

      {(changed > 0 || status.messages.length > 0) && (
        <div className="savebar" data-tone={status.kind} role="status" aria-live="polite">
          <span className="savebar-text">
            {status.kind === 'saved' ? <CircleCheck aria-hidden="true" size={16} /> : status.kind === 'invalid' ? <CircleX aria-hidden="true" size={16} /> : <span className="savebar-dot" aria-hidden="true" />}
            {status.messages.length > 0 ? status.messages.join(' ') : changed + (changed === 1 ? ' unsaved change' : ' unsaved changes')}
          </span>
          {changed > 0 && (
            <span className="savebar-actions">
              <button type="button" className="button ghost" onClick={() => { setDraft(saved); setStatus({ kind: 'idle', messages: [] }); }}>Discard</button>
              <button type="submit" className="button primary" disabled={status.kind === 'saving'}>
                <Save aria-hidden="true" size={15} /> {status.kind === 'saving' ? 'Saving…' : 'Save changes'}
              </button>
            </span>
          )}
        </div>
      )}
    </form>
  );
}

function HealthView({ onStopped, onRemoved, stopped }) {
  const [state, setState] = useState({ status: 'loading', data: null });
  const [days, setDays] = useState('30');
  const [prune, setPrune] = useState({ step: 'idle', text: '' });
  const [quit, setQuit] = useState('idle');

  const load = useCallback(async () => {
    setState((current) => ({ status: current.data ? 'refreshing' : 'loading', data: current.data }));
    try {
      const result = await api(API_HEALTH);
      if (result.ok && result.body) {
        setState({ status: 'ok', data: result.body });
        if (result.body.keep_logs_days > 0) { setDays(String(result.body.keep_logs_days)); }
      } else {
        setState({ status: 'error', data: null });
      }
    } catch {
      setState({ status: 'error', data: null });
    }
  }, []);
  useEffect(() => { if (!stopped) { load(); } }, [load, stopped]);

  const runPrune = async () => {
    if (prune.step !== 'confirm') { setPrune({ step: 'confirm', text: '' }); return; }
    setPrune({ step: 'busy', text: '' });
    try {
      const result = await api(API_PRUNE, 'POST', { days: Number(days) });
      if (result.ok && result.body) {
        setPrune({ step: 'idle', text: 'Deleted ' + result.body.removed_runs + ' finished runs and freed ' + formatBytes(result.body.freed_bytes) + '.' });
        load();
      } else {
        setPrune({ step: 'idle', text: result.body && result.body.messages ? result.body.messages.join(' ') : 'Nothing was deleted (HTTP ' + result.status + ').' });
      }
    } catch {
      setPrune({ step: 'idle', text: 'The control center is unreachable.' });
    }
  };

  const stopCenter = async () => {
    if (quit !== 'confirm') { setQuit('confirm'); return; }
    try { await api(API_QUIT, 'POST', {}); } catch { /* the server may close before answering */ }
    setQuit('idle');
    onStopped();
  };

  const data = state.data;
  const failing = data ? data.checks.filter((check) => check.status === 'fail').length : 0;
  const totalBytes = data ? data.storage.reduce((sum, root) => sum + root.bytes, 0) : 0;
  const totalRuns = data ? data.storage.reduce((sum, root) => sum + root.runs, 0) : 0;
  return (
    <div className="center-stack">
      <PageHead title="Health" text="Git, Claude Code, your sign-in, your settings, and the installed skill.">
        <button type="button" className="button ghost" onClick={load} disabled={state.status === 'loading' || state.status === 'refreshing' || stopped}>
          <RefreshCw aria-hidden="true" size={15} className={state.status === 'refreshing' ? 'spin' : undefined} /> Check again
        </button>
      </PageHead>
      {state.status === 'loading' && <EmptyState title="Running checks…">This can take a few seconds while Claude Code answers.</EmptyState>}
      {state.status === 'error' && <EmptyState icon={CircleAlert} tone="danger" title="Checks could not run">Use Check again to retry.</EmptyState>}
      {data && (
        <>
          <section className="health-summary" data-ready={data.ready} aria-live="polite">
            <span className="health-summary-icon" aria-hidden="true">{data.ready ? <CircleCheck size={22} /> : <CircleAlert size={22} />}</span>
            <span>
              <span className="health-summary-title">{data.ready ? 'Everything ClaudeCX needs is in place' : failing + (failing === 1 ? ' check needs' : ' checks need') + ' attention'}</span>
              <span className="health-summary-text">Checked {formatClock(data.generated_at)}</span>
            </span>
          </section>
          <section className="card" aria-labelledby="checks-title">
            <header className="card-head">
              <span className="card-icon" aria-hidden="true"><Stethoscope size={16} /></span>
              <div><h2 id="checks-title" className="card-title">Setup</h2></div>
            </header>
            <ul className="health-list">
              {data.checks.map((check) => (
                <li key={check.id} data-status={check.status}>
                  <span className="health-icon" aria-hidden="true">
                    {check.status === 'ok' ? <CircleCheck size={16} /> : check.status === 'fail' ? <CircleX size={16} /> : <CircleAlert size={16} />}
                  </span>
                  <span className="health-label">{check.label}</span>
                  <span className="health-message">{check.message}</span>
                  {check.fix && <span className="health-fix">Fix: <code>{check.fix}</code></span>}
                </li>
              ))}
            </ul>
          </section>
          <section className="card" aria-labelledby="storage-title">
            <header className="card-head">
              <span className="card-icon" aria-hidden="true"><Archive size={16} /></span>
              <div>
                <h2 id="storage-title" className="card-title">Run logs</h2>
                <p className="card-text">{totalRuns} runs · {formatBytes(totalBytes)}. Logs can contain parts of your code.</p>
              </div>
            </header>
            <ul className="folders">
              {data.storage.map((root) => (
                <li key={root.path}>
                  <span className="folder-text">
                    <span className="folder-kind">{root.kind === 'packaged' ? (root.app || 'A packaged app') + ' folder' : 'Standard folder'}</span>
                    <span className="folder-path mono">{root.path}</span>
                  </span>
                  <span className="folder-size mono">{root.runs} runs · {formatBytes(root.bytes)}</span>
                </li>
              ))}
            </ul>
            <div className="card-body prune">
              <span className="setting-label">Delete finished runs older than</span>
              <div className="prune-row">
                <NumberField id="prune-days" value={days} min={1} max={3650} unit="days" onChange={(value) => { setDays(value); setPrune({ step: 'idle', text: '' }); }} />
                <button type="button" className="button danger" onClick={runPrune} disabled={prune.step === 'busy'}>
                  <Trash2 aria-hidden="true" size={14} /> {prune.step === 'confirm' ? 'Confirm delete' : prune.step === 'busy' ? 'Deleting…' : 'Delete'}
                </button>
                {prune.step === 'confirm' && <button type="button" className="button ghost" onClick={() => setPrune({ step: 'idle', text: '' })}>Cancel</button>}
              </div>
              <p className="setting-help">{data.keep_logs_days > 0 ? 'Runs older than ' + data.keep_logs_days + ' days are also deleted automatically when a new run starts.' : 'Set an automatic limit in Settings to do this on every run.'}</p>
              {prune.text && <p className="state-line" role="status">{prune.text}</p>}
            </div>
          </section>
        </>
      )}
      <DataCard onRemoved={onRemoved} onChanged={load} disabled={stopped} />
      <section className="card" aria-labelledby="center-title">
        <header className="card-head">
          <span className="card-icon" aria-hidden="true"><Server size={16} /></span>
          <div>
            <h2 id="center-title" className="card-title">Control center</h2>
            <p className="card-text">Runs quietly in the background and talks only to 127.0.0.1. Stopping it is safe: runs then open their own dashboard.</p>
          </div>
        </header>
        <div className="card-body prune-row">
          <button type="button" className="button danger" onClick={stopCenter} disabled={stopped}>
            <Power aria-hidden="true" size={14} /> {quit === 'confirm' ? 'Confirm stop' : 'Stop the control center'}
          </button>
          {quit === 'confirm' && <button type="button" className="button ghost" onClick={() => setQuit('idle')}>Cancel</button>}
        </div>
      </section>
    </div>
  );
}
