// Restricted Markdown for Claude's report summary only. Prompts, activity, diffs, and every other
// field stay exact plain text. Raw HTML is skipped (no raw-HTML plugin), only the elements below can be
// produced, link syntax renders as plain text, and every URL is discarded, so report content cannot
// create HTML, images, forms, frames, scripts, styles, external resources, or clickable links.
// Plain JavaScript (no JSX) so dashboard:check can render it directly under Node.
import { createElement } from 'react';
import Markdown from 'react-markdown';

export const SUMMARY_ALLOWED_ELEMENTS = [
  'p', 'strong', 'em', 'code', 'pre', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  'ul', 'ol', 'li', 'blockquote', 'hr', 'br', 'a'
];

// Markdown headings sit inside the Summary subpanel, so they render at a restrained size
// and are shifted below the panel's own h2.
function heading(level) {
  return function SummaryHeading({ children }) {
    return createElement('h' + Math.min(6, level + 2), { className: 'md-heading', 'data-level': level }, children);
  };
}

const components = {
  a: ({ children }) => createElement('span', { className: 'md-link' }, children),
  h1: heading(1),
  h2: heading(2),
  h3: heading(3),
  h4: heading(4),
  h5: heading(4),
  h6: heading(4)
};

const noUrl = () => '';

export function SafeMarkdown({ text }) {
  return createElement('div', { className: 'markdown' }, createElement(Markdown, {
    skipHtml: true,
    allowedElements: SUMMARY_ALLOWED_ELEMENTS,
    unwrapDisallowed: true,
    urlTransform: noUrl,
    components
  }, text));
}
