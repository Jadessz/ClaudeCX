// Pure, deterministic helpers. Nothing here interprets meaning beyond literal text patterns.

export function formatDuration(ms) {
  if (typeof ms !== 'number' || !Number.isFinite(ms) || ms < 0) { return '—'; }
  const total = Math.floor(ms / 1000);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (n) => String(n).padStart(2, '0');
  return (h > 0 ? h + ':' + pad(m) : String(m)) + ':' + pad(s);
}

export function formatClock(value) {
  if (!value) { return '—'; }
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? '—' : date.toLocaleString();
}

export function formatUsd(value) {
  return typeof value === 'number' && Number.isFinite(value) ? '$' + value.toFixed(2) : '—';
}

export function formatCount(value) {
  return typeof value === 'number' && Number.isFinite(value) ? String(value) : '—';
}

export function formatBytes(value) {
  if (typeof value !== 'number' || !Number.isFinite(value)) { return '—'; }
  if (value >= 1048576) { return (value / 1048576).toFixed(value % 1048576 ? 1 : 0) + ' MiB'; }
  if (value >= 1024) { return Math.round(value / 1024) + ' KiB'; }
  return value + ' B';
}

// Progress lines are "HH:mm:ss  message". The tone is derived from fixed bridge wording only.
export function parseActivity(line, index) {
  const match = /^(\d{2}:\d{2}:\d{2})\s+(.*)$/.exec(line);
  const time = match ? match[1] : '';
  const text = match ? match[2] : line;
  let kind = 'note';
  let label = 'Update';
  if (/^ClaudeCX run finished successfully/.test(text)) { kind = 'success'; label = 'Finished'; }
  else if (/^ClaudeCX run stopped/.test(text)) { kind = 'stopped'; label = 'Stopped'; }
  else if (/^ClaudeCX run failed/.test(text)) { kind = 'failure'; label = 'Failed'; }
  else if (/error|denied|failed/i.test(text)) { kind = 'warning'; label = 'Attention'; }
  else if (/^Tool (Edit|Write|MultiEdit|NotebookEdit)\b/.test(text)) { kind = 'edit'; label = 'Edit'; }
  else if (/^Tool (Bash|PowerShell)\b/.test(text)) { kind = 'command'; label = 'Command'; }
  else if (/^Tool (Read|Glob|Grep|LS)\b/.test(text)) { kind = 'read'; label = 'Inspect'; }
  else if (/^Tool (WebFetch|WebSearch)\b/.test(text)) { kind = 'web'; label = 'Web'; }
  else if (/^Tool TodoWrite\b/.test(text)) { kind = 'plan'; label = 'Plan'; }
  else if (/^Tool\b/.test(text)) { kind = 'tool'; label = 'Tool'; }
  else if (/^(Preparing|Claude Code started|Claude session started|Dashboard|Progress)/.test(text)) { kind = 'system'; label = 'Bridge'; }
  return { key: index + '|' + line, time, text, kind, label };
}

// Section headings Codex commonly adds to a brief. Matching is literal on heading words.
const SECTION_RULES = [
  { id: 'objective', label: 'Objective', pattern: /\b(objective|goal|summary|overview|context|background)\b/i },
  { id: 'scope', label: 'Scope and non-goals', pattern: /\b(scope|non-goals?|out of scope)\b/i },
  { id: 'constraints', label: 'Constraints', pattern: /\b(constraints?|invariants?|rules|requirements|architecture)\b/i },
  { id: 'acceptance', label: 'Acceptance criteria', pattern: /\b(acceptance|done when|definition of done|success criteria)\b/i },
  { id: 'tests', label: 'Tests and verification', pattern: /\b(tests?|testing|verification|verify|checks?)\b/i },
  { id: 'risks', label: 'Risks and edge cases', pattern: /\b(risks?|edge cases?|security|privacy)\b/i },
  { id: 'docs', label: 'Documentation', pattern: /\b(documentation|docs)\b/i }
];

// Splits Markdown into headings with bullet counts. No Markdown is ever rendered as HTML.
export function outlineMarkdown(text) {
  const sections = [];
  let current = null;
  let fenced = false;
  for (const raw of String(text || '').split('\n')) {
    const line = raw.replace(/\r$/, '');
    if (/^\s*(```|~~~)/.test(line)) { fenced = !fenced; continue; }
    if (fenced) { continue; }
    const heading = /^(#{1,6})\s+(.+?)\s*#*\s*$/.exec(line);
    if (heading) {
      current = { level: heading[1].length, title: heading[2], bullets: 0 };
      sections.push(current);
    } else if (current && /^\s*([-*+]|\d+[.)])\s+\S/.test(line)) {
      current.bullets += 1;
    }
  }
  return sections;
}

export function briefStructure(text) {
  const sections = outlineMarkdown(text);
  const found = SECTION_RULES.map((rule) => {
    const matches = sections.filter((section) => section.level > 1 && rule.pattern.test(section.title));
    return {
      id: rule.id,
      label: rule.label,
      present: matches.length > 0,
      headings: matches.map((section) => section.title),
      bullets: matches.reduce((sum, section) => sum + section.bullets, 0)
    };
  });
  return { sections, found };
}

export function textStats(text) {
  const value = String(text || '');
  const lines = value === '' ? 0 : value.split('\n').length;
  const words = (value.match(/\S+/g) || []).length;
  return { lines, words, chars: value.length };
}
