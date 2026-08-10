// Parses each widget EXACTLY as Deno emits it: evaluate the template literal first, then check the
// <script> body. Reading the raw source hides escape bugs — `\'` inside a template literal becomes a
// bare quote in the emitted JS and kills the whole script, which is invisible to a raw-source test.
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
let failed = 0;

for (const name of ['DASHBOARD_WIDGET_HTML', 'SCORECARD_WIDGET_HTML']) {
  const open = src.indexOf('const ' + name + ' = `');
  const from = src.indexOf('`', open) + 1;
  const to = src.indexOf('`;', from);
  const literal = src.slice(from, to);

  if (literal.includes('${')) { console.log(name + ': contains ${...} — check manually'); }

  let html;
  try { html = new Function('return `' + literal + '`;')(); }
  catch (e) { console.log('FAIL ' + name + ': template literal will not evaluate — ' + e.message); failed++; continue; }

  const js = html.slice(html.indexOf('<script>') + 8, html.indexOf('</script>'));
  try { new Function(js); console.log('OK   ' + name + ' — emitted script parses (' + js.length + ' chars)'); }
  catch (e) { console.log('FAIL ' + name + ': emitted script is a syntax error — ' + e.message); failed++; }
}
process.exit(failed ? 1 : 0);
