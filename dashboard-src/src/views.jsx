// Tab views. Markdown and diffs are displayed as plain text; nothing is parsed into HTML.
import { memo, useEffect, useMemo, useRef, useState } from 'react';
import {
  ArrowDown, Check, CircleAlert, CircleCheck, CircleX, ClipboardList, Copy, Eye, FileDiff, Globe, Info,
  ListChecks, Minus, OctagonX, Pencil, Server, Terminal, Wrench
} from 'lucide-react';
import { SafeMarkdown } from './safe-markdown.js';
import { briefStructure, formatBytes, formatClock, parseActivity, textStats } from './format.js';

const DIFF_COLOR_LINE_LIMIT = 20000;

export function EmptyState({ icon: Icon = Info, title, children, tone }) {
  return (
    <div className="empty" data-tone={tone}>
      <Icon aria-hidden="true" size={18} />
      <div>
        <p className="empty-title">{title}</p>
        {children && <p className="empty-text">{children}</p>}
      </div>
    </div>
  );
}

function CopyButton({ id, text, copied, copy, label }) {
  const state = copied === id ? 'Copied' : copied === 'error:' + id ? 'Copy failed' : label;
  return (
    <button type="button" className="button ghost small" onClick={() => copy(id, text)} disabled={!text}>
      {copied === id ? <Check aria-hidden="true" size={14} /> : <Copy aria-hidden="true" size={14} />} {state}
    </button>
  );
}

function PromptDocument({ id, eyebrow, title, text, available, copied, copy, unavailable }) {
  const stats = useMemo(() => textStats(text), [text]);
  return (
    <article className="document" aria-labelledby={id + '-title'}>
      <header className="document-head">
        <div>
          <p className="eyebrow">{eyebrow}</p>
          <h2 id={id + '-title'}>{title}</h2>
        </div>
        {available && (
          <div className="document-tools">
            <span className="muted mono">{stats.words} words · {stats.lines} lines</span>
            <CopyButton id={id} text={text} copied={copied} copy={copy} label="Copy" />
          </div>
        )}
      </header>
      {available
        ? <pre className="document-body" tabIndex={0} aria-label={title}>{text}</pre>
        : unavailable}
    </article>
  );
}

function BriefStructure({ text }) {
  const structure = useMemo(() => briefStructure(text), [text]);
  const present = structure.found.filter((item) => item.present).length;
  return (
    <section className="structure" aria-labelledby="structure-title">
      <div className="structure-head">
        <h2 id="structure-title"><ListChecks aria-hidden="true" size={16} /> Structure Codex added</h2>
        <p className="muted">
          {present} of {structure.found.length} common brief sections detected from {structure.sections.length} Markdown headings.
          Derived from heading text only; this is not a semantic comparison.
        </p>
      </div>
      <ul className="structure-list">
        {structure.found.map((item) => (
          <li key={item.id} data-present={item.present}>
            {item.present ? <CircleCheck aria-hidden="true" size={15} /> : <Minus aria-hidden="true" size={15} />}
            <span className="structure-label">{item.label}</span>
            <span className="structure-meta">
              {item.present
                ? (item.bullets > 0 ? item.bullets + (item.bullets === 1 ? ' item' : ' items') : 'present')
                : 'not found'}
            </span>
          </li>
        ))}
      </ul>
    </section>
  );
}

export function FlowView({ prompts, copied, copy }) {
  if (prompts.status === 'loading' || prompts.status === 'idle') {
    return <EmptyState title="Loading the handoff…" />;
  }
  if (prompts.status === 'error' || !prompts.data) {
    return (
      <EmptyState icon={CircleAlert} tone="danger" title="The handoff could not be loaded">
        The dashboard server did not return the prompt artifacts. Use Refresh to retry.
      </EmptyState>
    );
  }
  const data = prompts.data;
  return (
    <div className="journey">
      {data.brief_available && <BriefStructure text={data.codex_brief} />}
      <div className="journey-docs">
        <PromptDocument
          id="original" eyebrow="Step 1 · What you asked Codex" title="Original request"
          text={data.original_prompt || ''} available={data.original_available} copied={copied} copy={copy}
          unavailable={(
            <EmptyState title="Original request not captured">
              This run was started without -OriginalPromptPath, so only the Codex brief is available. The brief is the exact input Claude received.
            </EmptyState>
          )}
        />
        <PromptDocument
          id="brief" eyebrow="Step 2 · What Codex sent Claude" title="Codex implementation brief"
          text={data.codex_brief || ''} available={data.brief_available} copied={copied} copy={copy}
          unavailable={(
            <EmptyState icon={CircleAlert} tone="danger" title="Brief copy unavailable">
              The fixed codex-brief.md artifact is missing, unreadable, or larger than {formatBytes(data.max_bytes)}.
            </EmptyState>
          )}
        />
      </div>
    </div>
  );
}

const ACTIVITY_ICONS = {
  success: CircleCheck, stopped: OctagonX, failure: CircleX, warning: CircleAlert, edit: Pencil, command: Terminal,
  read: Eye, web: Globe, plan: ClipboardList, tool: Wrench, system: Server, note: Info
};

const ActivityItem = memo(function ActivityItem({ item, current }) {
  const Icon = ACTIVITY_ICONS[item.kind] || Info;
  return (
    <li className="activity" data-kind={item.kind} data-current={current || undefined}>
      <span className="activity-icon"><Icon aria-hidden="true" size={15} /></span>
      <span className="activity-label">{item.label}</span>
      <span className="activity-text">{item.text}</span>
      <time className="activity-time mono">{item.time}</time>
    </li>
  );
});

export function WorkView({ state }) {
  const activity = state ? state.activity : [];
  const signature = activity.length + '|' + (activity.length ? activity[activity.length - 1] : '');
  const items = useMemo(() => activity.map(parseActivity), [signature]);
  const scroller = useRef(null);
  const [follow, setFollow] = useState(true);
  const active = state && state.status === 'active';

  useEffect(() => {
    const node = scroller.current;
    if (node && follow) { node.scrollTop = node.scrollHeight; }
  }, [signature, follow]);

  const onScroll = () => {
    const node = scroller.current;
    if (!node) { return; }
    setFollow(node.scrollHeight - node.scrollTop - node.clientHeight < 24);
  };

  return (
    <div className="work">
      <p className="hint">
        Sanitized bridge progress: tool names and short path summaries. Prompts, tool input and output, command arguments,
        and Claude's reasoning are never recorded here.
      </p>
      {items.length === 0
        ? <EmptyState title="No activity yet">Claude's first tool call appears here as soon as the bridge sees it.</EmptyState>
        : (
          <div className="timeline-wrap">
            <ol className="timeline" ref={scroller} onScroll={onScroll} tabIndex={0} aria-label="Activity timeline">
              {items.map((item, index) => (
                <ActivityItem key={item.key} item={item} current={active && index === items.length - 1} />
              ))}
            </ol>
            {!follow && (
              <button type="button" className="button small jump" onClick={() => setFollow(true)}>
                <ArrowDown aria-hidden="true" size={14} /> Follow latest
              </button>
            )}
          </div>
        )}
      <p className="visually-hidden" aria-live="polite">{active && items.length ? items[items.length - 1].text : ''}</p>
    </div>
  );
}

const DiffText = memo(function DiffText({ text }) {
  const lines = useMemo(() => text.split('\n'), [text]);
  if (lines.length > DIFF_COLOR_LINE_LIMIT) {
    return <pre className="code diff" tabIndex={0} aria-label="Diff">{text}</pre>;
  }
  return (
    <pre className="code diff" tabIndex={0} aria-label="Diff">
      {lines.map((line, index) => {
        let kind = '';
        if (line.startsWith('+++') || line.startsWith('---') || line.startsWith('diff --git') || line.startsWith('index ')) { kind = 'meta'; }
        else if (line.startsWith('@@')) { kind = 'hunk'; }
        else if (line.startsWith('+')) { kind = 'add'; }
        else if (line.startsWith('-')) { kind = 'del'; }
        return <span key={index} className="diff-line" data-kind={kind || undefined}>{line + '\n'}</span>;
      })}
    </pre>
  );
});

export function ChangesView({ changes }) {
  if (changes.status === 'idle' || changes.status === 'loading') {
    return <EmptyState title="Loading repository changes…" />;
  }
  const data = changes.data;
  return (
    <div className="changes">
      {data && data.snapshot
        ? <p className="hint"><code>git status --short</code> and <code>git diff HEAD</code> as saved when this run ended, shown as plain text. The repository may have changed since.</p>
        : <p className="hint">Current <code>git status --short</code> and <code>git diff HEAD</code> of the repository, shown as plain text and refreshed every 5 seconds while this tab is open.</p>}
      {changes.status === 'error' && <div className="banner" data-tone="warning" role="alert"><CircleAlert aria-hidden="true" size={18} /><p>{changes.error}</p></div>}
      {data && data.errors && data.errors.length > 0 && (
        <div className="banner" data-tone="warning" role="alert"><CircleAlert aria-hidden="true" size={18} /><p>{data.errors.join(' ')}</p></div>
      )}
      {data && (
        <>
          <p className="state-line muted" role="status">Updated {formatClock(data.generated_at)}</p>
          <section className="subpanel" aria-labelledby="changes-status">
            <header className="subpanel-head"><h2 id="changes-status" className="subhead">Status</h2></header>
            {data.status_text
              ? <pre className="code" tabIndex={0} aria-label="Git status">{data.status_text}</pre>
              : <EmptyState title="Working tree is clean">No tracked or untracked changes yet.</EmptyState>}
            {data.status_truncated && <p className="truncated">Status output was truncated.</p>}
          </section>
          <section className="subpanel" aria-labelledby="changes-diff">
            <header className="subpanel-head"><h2 id="changes-diff" className="subhead"><FileDiff aria-hidden="true" size={16} /> Diff against HEAD</h2></header>
            {data.diff_truncated && (
              <div className="banner" data-tone="warning" role="status">
                <CircleAlert aria-hidden="true" size={18} />
                <p>Diff truncated at {formatBytes(data.max_diff_bytes)}. Run <code>git diff HEAD</code> locally for the rest; untracked files appear only in Status.</p>
              </div>
            )}
            {data.diff_text
              ? <DiffText text={data.diff_text} />
              : <EmptyState title="No diff against HEAD">Untracked files, if any, are listed under Status.</EmptyState>}
          </section>
        </>
      )}
    </div>
  );
}

const REPORT_LISTS = [
  ['files_changed', 'Files changed'],
  ['commands_run', 'Commands run'],
  ['deviations_from_brief', 'Deviations from brief'],
  ['open_questions', 'Open questions'],
  ['risks', 'Risks'],
  ['denied_actions', 'Denied actions']
];

export function ReportView({ report, status }) {
  if (report.status === 'idle') {
    return <EmptyState title="Loading the report…" />;
  }
  if (report.status === 'error') {
    return <EmptyState icon={CircleAlert} tone="danger" title="The report could not be loaded">Use Refresh to retry.</EmptyState>;
  }
  const data = report.data;
  if (data.kind === 'pending') {
    return (
      <EmptyState title={status === 'active' ? 'Report pending' : 'No report was written'}>
        {status === 'active'
          ? 'Claude returns a structured report when the run finishes. It appears here automatically.'
          : 'The run ended without a structured report or failure record.'}
      </EmptyState>
    );
  }
  if (data.kind === 'failure') {
    const failure = data.failure;
    return (
      <div className="report">
        <div className="banner" data-tone={failure.status === 'stopped' ? 'warning' : 'danger'} role="alert">
          {failure.status === 'stopped' ? <OctagonX aria-hidden="true" size={18} /> : <CircleX aria-hidden="true" size={18} />}
          <div>
            <p className="empty-title">{failure.status === 'stopped' ? 'Run stopped' : 'Run failed'} · {formatClock(failure.occurred_at)}</p>
            <p className="prewrap">{failure.message || 'No message was recorded.'}</p>
          </div>
        </div>
      </div>
    );
  }
  const body = data.report;
  return (
    <div className="report">
      <section className="subpanel" aria-labelledby="report-summary">
        <header className="subpanel-head"><h2 id="report-summary" className="subhead">Summary</h2></header>
        <div className="summary subpanel-body">{body.summary ? <SafeMarkdown text={body.summary} /> : <p>—</p>}</div>
      </section>
      <section className="subpanel" aria-labelledby="report-checks">
        <header className="subpanel-head"><h2 id="report-checks" className="subhead">Checks <span className="muted">{body.checks.length}</span></h2></header>
        {body.checks.length === 0
          ? <p className="muted subpanel-body">No checks reported.</p>
          : (
            <ul className="checks">
              {body.checks.map((check, index) => (
                <li key={index} data-status={check.status}>
                  <span className="check-status">
                    {check.status === 'passed' ? <CircleCheck aria-hidden="true" size={15} /> : check.status === 'failed' ? <CircleX aria-hidden="true" size={15} /> : <Minus aria-hidden="true" size={15} />}
                    {check.status || 'unknown'}
                  </span>
                  <code className="check-command">{check.command}</code>
                  <p className="check-output prewrap">{check.output_summary}</p>
                </li>
              ))}
            </ul>
          )}
      </section>
      <div className="report-lists">
        {REPORT_LISTS.map(([field, label]) => (
          <section key={field} className="subpanel" aria-labelledby={'report-' + field}>
            <header className="subpanel-head"><h2 id={'report-' + field} className="subhead">{label} <span className="muted">{body[field].length}</span></h2></header>
            {body[field].length === 0
              ? <p className="muted subpanel-body">None.</p>
              : <ul className="plain-list subpanel-body">{body[field].map((entry, index) => <li key={index} className="prewrap">{entry}</li>)}</ul>}
          </section>
        ))}
      </div>
    </div>
  );
}
