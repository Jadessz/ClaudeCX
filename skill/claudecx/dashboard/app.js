// ClaudeCX dashboard client. No dependencies. All server content is rendered with textContent.
'use strict';

(function () {
  const POLL_MS = 1000;
  const CHANGES_POLL_MS = 5000;
  const API_STATE = '/api/state';
  const API_CHANGES = '/api/changes';
  const API_REPORT = '/api/report';
  const API_STOP = '/api/stop';

  // The token arrives in the URL fragment and is removed from history immediately.
  // It is kept in memory only; reloading the page requires reopening the dashboard link.
  let token = '';
  const fragment = new URLSearchParams(window.location.hash.slice(1));
  if (fragment.has('token')) {
    token = fragment.get('token') || '';
  }
  history.replaceState(null, '', window.location.pathname);

  const el = (id) => document.getElementById(id);
  const ui = {
    repo: el('repo-name'), status: el('run-status'), elapsed: el('elapsed'), connection: el('connection'),
    refresh: el('refresh'), stop: el('stop'), confirm: el('stop-confirm'), confirmYes: el('stop-confirm-yes'),
    confirmNo: el('stop-confirm-no'), notice: el('notice'), phase: el('phase'), session: el('session-id'),
    copy: el('copy-session'), runKind: el('run-kind'), started: el('started-at'), timeout: el('timeout'),
    maxTurns: el('max-turns'), budget: el('budget'), turns: el('turns'), duration: el('duration'), cost: el('cost'),
    final: el('final-message'), timeline: el('timeline'), timelineEmpty: el('timeline-empty'),
    changesState: el('changes-state'), changesStatus: el('changes-status'), changesDiff: el('changes-diff'),
    reportState: el('report-state'), reportBody: el('report-body')
  };
  const tabs = ['activity', 'changes', 'report'].map((name) => ({
    name, tab: el('tab-' + name), panel: el('panel-' + name)
  }));

  let state = null;
  let activeTab = 'activity';
  let stopRequested = false;
  let reportLoadedFor = '';
  let lastChangesAt = 0;
  let changesBusy = false;

  function setText(node, text) {
    node.textContent = text === null || text === undefined || text === '' ? '—' : String(text);
  }

  function showNotice(text) {
    ui.notice.textContent = text;
    ui.notice.hidden = !text;
  }

  async function api(path, method) {
    const response = await fetch(path, {
      method: method || 'GET',
      headers: { 'Authorization': 'Bearer ' + token },
      cache: 'no-store',
      credentials: 'omit',
      referrerPolicy: 'no-referrer'
    });
    let body = null;
    try { body = await response.json(); } catch (error) { body = null; }
    return { ok: response.ok, status: response.status, body };
  }

  function setConnection(online, label) {
    ui.connection.dataset.state = online ? 'online' : 'offline';
    ui.connection.textContent = label || (online ? 'Connected' : 'Disconnected');
  }

  function formatDuration(ms) {
    if (typeof ms !== 'number' || !isFinite(ms) || ms < 0) { return '—'; }
    const total = Math.floor(ms / 1000);
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    const pad = (n) => String(n).padStart(2, '0');
    return (h > 0 ? h + ':' + pad(m) : String(m)) + ':' + pad(s);
  }

  function formatDate(value) {
    const date = new Date(value);
    return isNaN(date.getTime()) ? '' : date.toLocaleString();
  }

  function updateElapsed() {
    if (!state || !state.started_at) { return; }
    const start = Date.parse(state.started_at);
    const end = state.finished_at ? Date.parse(state.finished_at) : Date.now();
    ui.elapsed.textContent = isNaN(start) ? '--:--' : formatDuration(Math.max(0, (isNaN(end) ? Date.now() : end) - start));
  }

  function renderTimeline(lines) {
    const list = ui.timeline;
    const atBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 24;
    const existing = list.children.length;
    if (lines.length < existing) {
      list.replaceChildren();
    }
    for (let i = list.children.length; i < lines.length; i++) {
      const item = document.createElement('li');
      item.textContent = lines[i];
      if (/\b(error|failed|denied|timeout|stopped)\b/i.test(lines[i])) { item.dataset.tone = 'error'; }
      else if (/finished successfully|finished: success/i.test(lines[i])) { item.dataset.tone = 'success'; }
      list.appendChild(item);
    }
    ui.timelineEmpty.hidden = lines.length > 0;
    if (atBottom) { list.scrollTop = list.scrollHeight; }
  }

  function renderState(next) {
    state = next;
    const labels = { active: 'Active', succeeded: 'Succeeded', failed: 'Failed', stopped: 'Stopped' };
    ui.repo.textContent = next.repository_name || 'Repository';
    document.title = 'ClaudeCX · ' + (next.repository_name || 'dashboard');
    ui.status.dataset.status = next.status;
    ui.status.textContent = labels[next.status] || 'Unknown';
    setText(ui.phase, next.last_activity || 'Waiting for activity…');
    setText(ui.session, next.session_id);
    setText(ui.runKind, next.resumed ? 'Resumed session' : 'New session');
    setText(ui.started, formatDate(next.started_at));
    setText(ui.timeout, typeof next.timeout_seconds === 'number' ? formatDuration(next.timeout_seconds * 1000) : '');
    setText(ui.maxTurns, next.max_turns);
    setText(ui.budget, typeof next.max_budget_usd === 'number' ? 'USD ' + next.max_budget_usd.toFixed(2) : '');
    const result = next.result || {};
    setText(ui.turns, result.num_turns);
    setText(ui.duration, typeof result.duration_ms === 'number' ? formatDuration(result.duration_ms) : '');
    setText(ui.cost, typeof result.total_cost_usd === 'number' ? 'USD ' + result.total_cost_usd.toFixed(4) : '');
    if (next.status !== 'active' && next.final_message) {
      ui.final.textContent = next.final_message;
      ui.final.dataset.status = next.status;
      ui.final.hidden = false;
    } else {
      ui.final.hidden = true;
    }
    if (next.stop_requested) { stopRequested = true; }
    const canStop = next.can_stop && !stopRequested;
    ui.stop.disabled = !canStop;
    if (!canStop) { ui.confirm.hidden = true; }
    if (stopRequested && next.status === 'active') {
      ui.stop.textContent = 'Stop requested…';
    } else if (next.status !== 'active') {
      ui.stop.textContent = 'Stop run';
      if (stopRequested && next.status === 'stopped') {
        showNotice('Run stopped. Partial edits remain in the working tree for Codex review.');
      }
    }
    renderTimeline(Array.isArray(next.activity) ? next.activity : []);
    updateElapsed();
    if (next.status !== 'active' && reportLoadedFor !== next.status) {
      reportLoadedFor = next.status;
      loadReport();
      loadChanges();
    }
  }

  async function loadState() {
    if (!token) {
      setConnection(false, 'No access token');
      showNotice('This page needs the access link opened by the bridge. The token is kept in memory only, so a reload cannot reconnect. The run continues; its progress is in progress.log in the run folder.');
      return;
    }
    try {
      const result = await api(API_STATE);
      if (result.status === 401) {
        setConnection(false, 'Unauthorized');
        showNotice('The access token was rejected. Reopen the dashboard link from the bridge.');
        return;
      }
      if (!result.ok || !result.body) { throw new Error('state ' + result.status); }
      setConnection(true);
      renderState(result.body);
    } catch (error) {
      setConnection(false, 'Disconnected');
    }
  }

  function setLine(node, text, kind) {
    node.textContent = text;
    if (kind) { node.dataset.kind = kind; } else { delete node.dataset.kind; }
  }

  async function loadChanges() {
    if (!token || changesBusy) { return; }
    changesBusy = true;
    lastChangesAt = Date.now();
    setLine(ui.changesState, 'Loading changes…');
    try {
      const result = await api(API_CHANGES);
      if (!result.ok || !result.body) { throw new Error('HTTP ' + result.status); }
      const body = result.body;
      ui.changesStatus.textContent = body.status_text || 'No changes relative to HEAD.';
      ui.changesDiff.textContent = body.diff_text || 'No tracked-file diff against HEAD (untracked files appear in Status only).';
      const notes = [];
      if (body.diff_truncated) { notes.push('Diff truncated at ' + Math.round(body.max_diff_bytes / 1024) + ' KiB; review the full diff in Git.'); }
      if (body.status_truncated) { notes.push('Status list truncated.'); }
      if (Array.isArray(body.errors) && body.errors.length) { notes.push(body.errors.join(' ')); }
      const stamp = 'Updated ' + new Date().toLocaleTimeString() + '.';
      if (Array.isArray(body.errors) && body.errors.length) { setLine(ui.changesState, notes.join(' '), 'error'); }
      else if (notes.length) { setLine(ui.changesState, notes.join(' ') + ' ' + stamp, 'warning'); }
      else { setLine(ui.changesState, stamp); }
    } catch (error) {
      setLine(ui.changesState, 'Changes could not be loaded (' + error.message + ').', 'error');
    } finally {
      changesBusy = false;
    }
  }

  function section(title, build) {
    const wrap = document.createElement('section');
    wrap.className = 'report-section';
    const heading = document.createElement('h2');
    heading.textContent = title;
    wrap.appendChild(heading);
    build(wrap);
    return wrap;
  }

  function listSection(title, items) {
    return section(title, (wrap) => {
      if (!Array.isArray(items) || items.length === 0) {
        const none = document.createElement('p');
        none.className = 'empty';
        none.textContent = 'None reported.';
        wrap.appendChild(none);
        return;
      }
      const list = document.createElement('ul');
      for (const item of items) {
        const li = document.createElement('li');
        li.textContent = String(item);
        list.appendChild(li);
      }
      wrap.appendChild(list);
    });
  }

  function renderReport(body) {
    const nodes = [];
    if (body.kind === 'report' && body.report) {
      const r = body.report;
      setLine(ui.reportState, 'Structured report from Claude. Codex reviews it before anything is accepted.');
      nodes.push(section('Summary', (wrap) => {
        const p = document.createElement('p');
        p.textContent = r.summary || 'No summary.';
        wrap.appendChild(p);
      }));
      nodes.push(listSection('Changed files', r.files_changed));
      nodes.push(section('Checks', (wrap) => {
        if (!Array.isArray(r.checks) || r.checks.length === 0) {
          const none = document.createElement('p');
          none.className = 'empty';
          none.textContent = 'None reported.';
          wrap.appendChild(none);
          return;
        }
        const list = document.createElement('ul');
        for (const check of r.checks) {
          const li = document.createElement('li');
          const badge = document.createElement('span');
          badge.className = 'check-status';
          badge.dataset.status = String(check.status || '');
          badge.textContent = String(check.status || 'unknown');
          const cmd = document.createElement('code');
          cmd.textContent = String(check.command || '');
          const summary = document.createElement('span');
          summary.textContent = check.output_summary ? ' — ' + String(check.output_summary) : '';
          li.append(badge, cmd, summary);
          list.appendChild(li);
        }
        wrap.appendChild(list);
      }));
      nodes.push(listSection('Commands run', r.commands_run));
      nodes.push(listSection('Denied actions', r.denied_actions));
      nodes.push(listSection('Open questions', r.open_questions));
      nodes.push(listSection('Deviations from brief', r.deviations_from_brief));
      nodes.push(listSection('Risks', r.risks));
    } else if (body.kind === 'failure' && body.failure) {
      const f = body.failure;
      setLine(ui.reportState, f.status === 'stopped' ? 'The run was stopped; no structured report was produced.' : 'The run failed; no structured report was produced.', 'error');
      nodes.push(section('Details', (wrap) => {
        const p = document.createElement('p');
        p.textContent = f.message || 'No details recorded.';
        wrap.appendChild(p);
      }));
      if (f.status === 'stopped') {
        nodes.push(section('Partial edits', (wrap) => {
          const p = document.createElement('p');
          p.textContent = 'Any edits Claude made before the stop remain in the working tree for Codex review. See the Changes tab.';
          wrap.appendChild(p);
        }));
      }
    } else {
      setLine(ui.reportState, state && state.status === 'active'
        ? 'The structured report appears here when the run finishes.'
        : 'No report or failure record is available yet.');
    }
    ui.reportBody.replaceChildren(...nodes);
  }

  async function loadReport() {
    if (!token) { return; }
    try {
      const result = await api(API_REPORT);
      if (!result.ok || !result.body) { throw new Error('HTTP ' + result.status); }
      renderReport(result.body);
    } catch (error) {
      setLine(ui.reportState, 'The report could not be loaded (' + error.message + ').', 'error');
    }
  }

  function selectTab(name, focus) {
    activeTab = name;
    for (const t of tabs) {
      const selected = t.name === name;
      t.tab.setAttribute('aria-selected', selected ? 'true' : 'false');
      t.tab.tabIndex = selected ? 0 : -1;
      t.panel.hidden = !selected;
      if (selected && focus) { t.tab.focus(); }
    }
    if (name === 'changes') { loadChanges(); }
    if (name === 'report') { loadReport(); }
  }

  tabs.forEach((t, index) => {
    t.tab.addEventListener('click', () => selectTab(t.name, false));
    t.tab.addEventListener('keydown', (event) => {
      let next = -1;
      if (event.key === 'ArrowRight') { next = (index + 1) % tabs.length; }
      else if (event.key === 'ArrowLeft') { next = (index - 1 + tabs.length) % tabs.length; }
      else if (event.key === 'Home') { next = 0; }
      else if (event.key === 'End') { next = tabs.length - 1; }
      if (next >= 0) {
        event.preventDefault();
        selectTab(tabs[next].name, true);
      }
    });
  });

  ui.refresh.addEventListener('click', () => {
    loadState();
    if (activeTab === 'changes') { loadChanges(); }
    if (activeTab === 'report') { loadReport(); }
  });

  ui.copy.addEventListener('click', async () => {
    const id = state && state.session_id;
    if (!id) { return; }
    try {
      await navigator.clipboard.writeText(id);
      ui.copy.textContent = 'Copied';
    } catch (error) {
      ui.copy.textContent = 'Copy failed';
    }
    setTimeout(() => { ui.copy.textContent = 'Copy'; }, 1500);
  });

  ui.stop.addEventListener('click', () => {
    if (ui.stop.disabled) { return; }
    ui.confirm.hidden = false;
    ui.confirmNo.focus();
  });

  ui.confirmNo.addEventListener('click', () => {
    ui.confirm.hidden = true;
    ui.stop.focus();
  });

  ui.confirm.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      ui.confirm.hidden = true;
      ui.stop.focus();
    }
  });

  ui.confirmYes.addEventListener('click', async () => {
    ui.confirm.hidden = true;
    stopRequested = true;
    ui.stop.disabled = true;
    ui.stop.textContent = 'Stop requested…';
    try {
      const result = await api(API_STOP, 'POST');
      if (result.status === 202) {
        showNotice('Stop requested. The bridge will terminate Claude shortly; partial edits remain for Codex review.');
      } else {
        showNotice('The stop request was not accepted (the run is no longer active).');
      }
    } catch (error) {
      showNotice('The stop request could not be sent. Check the connection and try Refresh.');
      stopRequested = false;
    }
    loadState();
  });

  loadState();
  setInterval(loadState, POLL_MS);
  setInterval(() => {
    updateElapsed();
    if (activeTab === 'changes' && state && state.status === 'active' && Date.now() - lastChangesAt >= CHANGES_POLL_MS) {
      loadChanges();
    }
  }, 1000);
})();
