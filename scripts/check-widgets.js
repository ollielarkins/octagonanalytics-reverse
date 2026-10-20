// Checks each MCP Apps widget EXACTLY as the server emits it: imports widgets.ts (Node 22.18+
// strips the TypeScript types natively), takes the finished HTML, and parses every <script> body.
// Reading the raw source hides escape bugs — a regex escape lost in a template literal kills the
// whole script, which only shows up in the emitted page.
//
// Usage: node scripts/check-widgets.js   (Node 22.18 or newer)
const { pathToFileURL } = require('node:url');
const path = require('node:path');

(async () => {
const w = await import(pathToFileURL(path.join(__dirname, '..', 'supabase', 'functions', 'octagon-mcp', 'widgets.ts')).href);
let failed = 0;

for (const name of ['DASHBOARD_WIDGET_HTML', 'SCORECARD_WIDGET_HTML', 'CONFIRM_WIDGET_HTML', 'REPORT_WIDGET_HTML']) {
  const html = w[name];
  if (typeof html !== 'string' || !html.startsWith('<!doctype html>')) { console.log('FAIL ' + name + ': not an HTML document'); failed++; continue; }
  const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
  if (scripts.length !== 3) { console.log('FAIL ' + name + ': expected 3 scripts (SDK, widget, runtime), found ' + scripts.length + ' — a stray </script> would cause this'); failed++; continue; }
  let ok = true;
  scripts.forEach((js, i) => { try { new Function(js); } catch (e) { ok = false; console.log('FAIL ' + name + ' script ' + (i + 1) + ': syntax error — ' + e.message); } });
  if (!/window\.McpApps=\{/.test(scripts[0])) { ok = false; console.log('FAIL ' + name + ': SDK bundle does not expose window.McpApps'); }
  if (ok) console.log('OK   ' + name + ' — ' + scripts.length + ' scripts parse, ' + Math.round(html.length / 1024) + ' KB');
  else failed++;
}

const meta = w.WIDGET_RESOURCE_META?.ui;
if (!meta || !meta.csp || meta.prefersBorder !== true) { console.log('FAIL WIDGET_RESOURCE_META: missing csp or prefersBorder'); failed++; }
else console.log('OK   WIDGET_RESOURCE_META — csp ' + JSON.stringify(meta.csp) + ', prefersBorder');
console.log('     DASHBOARD_WIDGET_LINKED = ' + w.DASHBOARD_WIDGET_LINKED);
process.exit(failed ? 1 : 0);
})();
