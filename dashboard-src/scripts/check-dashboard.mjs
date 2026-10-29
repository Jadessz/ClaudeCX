// Deterministic static and design checks for the dashboard source and the checked-in build.
// Contributor-only: installed users never run Node. Exits nonzero on any finding.
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repo = fileURLToPath(new URL('../..', import.meta.url));
const srcDir = join(repo, 'dashboard-src', 'src');
const outDir = join(repo, 'skill', 'claudecx', 'dashboard');
const failures = [];
let passed = 0;

function check(condition, message) {
  if (condition) { passed += 1; } else { failures.push(message); }
}

function walk(dir) {
  return readdirSync(dir).flatMap((name) => {
    const full = join(dir, name);
    return statSync(full).isDirectory() ? walk(full) : [full];
  });
}

// XML namespace identifiers React needs to create SVG/MathML nodes. They are never fetched.
const NAMESPACE_URIS = new Set([
  'http://www.w3.org/2000/svg', 'http://www.w3.org/1999/xlink', 'http://www.w3.org/1998/Math/MathML',
  'http://www.w3.org/XML/1998/namespace', 'http://www.w3.org/1999/xhtml'
]);
const URL_PATTERN = /(?:https?:|wss?:)?\/\/[a-z0-9.-]+\.[a-z]{2,}[^\s"'`)]*/gi;

// --- Built assets ---
const built = readdirSync(outDir).sort();
check(built.join(',') === 'app.js,index.html,styles.css', 'build emits exactly app.js, index.html, styles.css (found ' + built.join(',') + ')');
const html = readFileSync(join(outDir, 'index.html'), 'utf8');
const js = readFileSync(join(outDir, 'app.js'), 'utf8');
const css = readFileSync(join(outDir, 'styles.css'), 'utf8');
for (const [name, text] of [['index.html', html], ['app.js', js], ['styles.css', css]]) {
  check(!text.startsWith('﻿'), name + ' has no BOM');
  check(!text.includes('\r'), name + ' uses LF line endings');
  check(!/sourceMappingURL/.test(text), name + ' has no source map reference');
  const external = (text.match(URL_PATTERN) || []).filter((url) => !NAMESPACE_URIS.has(url));
  check(external.length === 0, name + ' references no external origin (' + external.slice(0, 5).join(', ') + ')');
}
check((html.match(/<script\b/g) || []).length === 1, 'index.html has exactly one script element');
check(/<script type="module" crossorigin src="\/app\.js"><\/script>/.test(html), 'index.html loads only /app.js');
check(/<link rel="stylesheet" crossorigin href="\/styles\.css">/.test(html), 'index.html loads only /styles.css');
check(!/<style\b|\sstyle\s*=/i.test(html), 'index.html has no inline styles');
check(!/\son[a-z]+\s*=/i.test(html), 'index.html has no inline event handlers');
check(!/@import|url\(/i.test(css), 'styles.css loads no other resources');
check(css.includes('prefers-reduced-motion'), 'styles.css honours prefers-reduced-motion');
check(!/\beval\(|new Function\(/.test(js), 'app.js does not use eval or new Function');

// --- Source ---
const sources = walk(srcDir);
for (const file of sources) {
  const text = readFileSync(file, 'utf8');
  const name = file.slice(repo.length);
  check(!text.includes('dangerouslySetInnerHTML'), name + ' does not use dangerouslySetInnerHTML');
  for (const pattern of ['innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write', 'eval(', 'new Function', 'localStorage', 'sessionStorage', 'window.open', 'location.href =']) {
    check(!text.includes(pattern), name + ' does not use ' + pattern);
  }
  check(!/\p{Extended_Pictographic}/u.test(text), name + ' contains no emoji');
  check(!/style=\{/.test(text), name + ' sets no inline style props');
  check(!(text.match(URL_PATTERN) || []).length, name + ' references no external origin');
}
const fetchSites = sources.flatMap((file) => (readFileSync(file, 'utf8').match(/\bfetch\(/g) || []).map(() => file));
check(fetchSites.length === 1 && fetchSites[0].endsWith('api.js'), 'source has a single fetch call site in api.js');
const apiSource = readFileSync(join(srcDir, 'api.js'), 'utf8');
check(apiSource.includes("history.replaceState") && apiSource.includes("'Authorization': 'Bearer ' + token"), 'api.js strips the fragment token and sends it as a bearer header');
const routes = [...apiSource.matchAll(/'(\/api\/[a-z]+)'/g)].map((match) => match[1]).sort();
check(routes.join(',') === '/api/changes,/api/prompts,/api/report,/api/state,/api/stop', 'api.js uses only the fixed API routes (' + routes.join(',') + ')');

// --- Restricted Markdown (report summary only) ---
const markdownSource = readFileSync(join(srcDir, 'safe-markdown.js'), 'utf8');
const pkg = JSON.parse(readFileSync(join(repo, 'package.json'), 'utf8'));
const packageNames = Object.keys({ ...(pkg.dependencies || {}), ...(pkg.devDependencies || {}) });
check(!packageNames.some((name) => /rehype-raw|rehype-sanitize|html-react-parser|remark-html/.test(name)), 'no raw-HTML Markdown plugin is installed (' + packageNames.join(',') + ')');
check(!sources.some((file) => /rehype-raw|rehypePlugins|remarkPlugins|allowDangerousHtml/.test(readFileSync(file, 'utf8'))), 'source enables no rehype/remark plugins or dangerous HTML');
check(/skipHtml: true/.test(markdownSource), 'SafeMarkdown skips raw HTML');
check(/urlTransform: noUrl/.test(markdownSource) && /const noUrl = \(\) => '';/.test(markdownSource), 'SafeMarkdown discards every URL');
check(/a: \(\{ children \}\) => createElement\('span', \{ className: 'md-link' \}/.test(markdownSource), 'SafeMarkdown renders link syntax as non-clickable text');
check(/unwrapDisallowed: true/.test(markdownSource), 'SafeMarkdown unwraps disallowed elements instead of rendering them');
const allowedMatch = /SUMMARY_ALLOWED_ELEMENTS = \[([^\]]*)\]/.exec(markdownSource);
const allowed = allowedMatch ? [...allowedMatch[1].matchAll(/'([a-z0-9]+)'/g)].map((match) => match[1]) : [];
const expectedAllowed = 'a,blockquote,br,code,em,h1,h2,h3,h4,h5,h6,hr,li,ol,p,pre,strong,ul';
check(allowed.slice().sort().join(',') === expectedAllowed, 'SafeMarkdown allows only the fixed text elements (' + allowed.join(',') + ')');
const markdownUsers = sources.filter((file) => /from 'react-markdown'/.test(readFileSync(file, 'utf8')));
check(markdownUsers.length === 1 && markdownUsers[0].endsWith('safe-markdown.js'), 'react-markdown is imported only by safe-markdown.js');

// Render hostile and representative summaries and inspect the actual markup.
const { createElement } = await import('react');
const { renderToStaticMarkup } = await import('react-dom/server');
const { SafeMarkdown } = await import(pathToFileURL(join(srcDir, 'safe-markdown.js')).href);
const render = (text) => renderToStaticMarkup(createElement(SafeMarkdown, { text }));
const hostile = render([
  '<script>alert(1)</script>', '<img src=x onerror=alert(1)>', '<iframe src="https://example.com"></iframe>',
  '<style>body{display:none}</style>', '<form action="/api/stop"><input></form>', '<b onclick="x()">raw</b>',
  '![tracker](https://example.com/pixel.png)', '[click me](javascript:alert(1))', '[site](https://example.com/a)',
  '<https://example.com/auto>', '[ref][r]', '', '[r]: https://example.com/ref'
].join('\n\n'));
for (const pattern of [/<script/i, /<img/i, /<iframe/i, /<style/i, /<form/i, /<input/i, /<a\b/i, /\shref=/i, /\ssrc=/i, /\son[a-z]+=/i, /\sstyle=/i, /javascript:/i, /<b>/i]) {
  check(!pattern.test(hostile), 'hostile summary renders no ' + pattern + ' (' + hostile.slice(0, 160) + ')');
}
check(hostile.includes('<span class="md-link">click me</span>') && hostile.includes('<span class="md-link">site</span>'), 'link syntax renders as non-clickable text');
const sample = render('Done.\n\n1. **Run facts:** tiles\n   - nested `code`\n   - *second*\n2. Flow\n\n## Notes\n\n> quoted\n\n---\n\n```\nnpm test\n```\n').replaceAll('\n<', '<');
check(sample.includes('<ol><li><strong>Run facts:</strong> tiles<ul><li>nested <code>code</code></li><li><em>second</em></li></ul></li><li>Flow</li></ol>'), 'ordered list with bold label and nested bullets renders (' + sample + ')');
check(sample.includes('<h4 class="md-heading" data-level="2">Notes</h4>'), 'summary headings render at a restrained level');
check(sample.includes('<blockquote>') && sample.includes('<hr/>') && sample.includes('<pre><code>npm test</code></pre>'), 'blockquote, rule, and fenced code render');
const viewsSource = readFileSync(join(srcDir, 'views.jsx'), 'utf8');
const markdownUses = viewsSource.match(/<SafeMarkdown\b[^>]*>/g) || [];
check(markdownUses.length === 1 && markdownUses[0] === '<SafeMarkdown text={body.summary} />', 'Markdown is rendered only for report.summary');

// --- Design rules (deterministic subset of the brief's visual direction) ---
const sourceCss = readFileSync(join(srcDir, 'styles.css'), 'utf8');
check(!/backdrop-filter/i.test(sourceCss), 'no glassmorphism (backdrop-filter)');
check(!/@font-face|fonts\.googleapis/i.test(sourceCss), 'system fonts only');
// Bold summary Markdown uses the cyan accent; no other rule targets strong text.
const strongRules = [...sourceCss.matchAll(/([^{}]*\bstrong\b[^{}]*)\{([^}]*)\}/g)]
  .map((match) => [match[1].trim(), match[2].trim()])
  .filter(([selector]) => !selector.startsWith('--') && !/^:root$/.test(selector) && /(^|[\s,>+~])strong\b/.test(selector));
check(strongRules.length === 1 && strongRules[0][0] === '.markdown strong', 'only .markdown strong styles bold text (' + strongRules.map((rule) => rule[0]).join(' | ') + ')');
check(strongRules.length === 1 && strongRules[0][1] === 'font-weight: 650; color: var(--cyan);', 'summary bold text uses font-weight 650 and the cyan theme accent');
check(css.includes('.markdown strong{font-weight:650;color:var(--cyan)}'), 'built styles.css carries the cyan summary bold rule');
const purple = [...sourceCss.matchAll(/#([0-9a-f]{6})\b/gi)].map((match) => match[1]).filter((hex) => {
  const [r, g, b] = [0, 2, 4].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  if (max - min < 0.25) { return false; }
  let hue;
  if (max === r) { hue = ((g - b) / (max - min)) % 6; } else if (max === g) { hue = (b - r) / (max - min) + 2; } else { hue = (r - g) / (max - min) + 4; }
  hue = (hue * 60 + 360) % 360;
  return hue >= 255 && hue <= 330;
});
check(purple.length === 0, 'no purple/violet accent colours (' + purple.join(', ') + ')');
check((sourceCss.match(/linear-gradient/g) || []).length <= 1, 'at most one subtle gradient');

// --- Brief structure detection (behaviour) ---
const { briefStructure } = await import(pathToFileURL(join(srcDir, 'format.js')).href);
const present = (text) => new Set(briefStructure(text).found.filter((item) => item.present).map((item) => item.id));
const topLevel = present('# Objective\nDo it.\n\n# Non-goals\n- a\n\n# Repository conventions and fixed invariants\n- b\n\n# Acceptance criteria\n- c\n\n# Validation\n- d\n');
for (const id of ['objective', 'scope', 'constraints', 'acceptance', 'tests']) {
  check(topLevel.has(id), 'a brief whose sections are # headings counts its ' + id + ' section');
}
const titled = present('# Security fix for login\n\n## Objective\n- a\n\n## Acceptance criteria\n- b\n');
check(titled.has('objective') && titled.has('acceptance'), 'a # title followed by ## sections counts the ## sections');
check(!titled.has('risks'), 'a lone # title is not counted as a section');
check(present('# Objective\nDo it.\n').has('objective'), 'a brief with a single heading counts it');
check(present('# Plan\n\n## Validate\n- run tests\n').has('tests'), 'a Validate heading counts as tests and verification');

if (failures.length) {
  console.error('check-dashboard: ' + failures.length + ' failed, ' + passed + ' passed');
  for (const failure of failures) { console.error(' - ' + failure); }
  process.exit(1);
}
console.log('check-dashboard: all ' + passed + ' checks passed');
