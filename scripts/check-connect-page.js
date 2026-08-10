// The connect page is served through WordPress. wpautop turns a blank line into "</p> <p>" —
// including inside <script> and <style>, which is a syntax error that silently kills the whole
// block. On 10/08/2026 that broke both the feedback button and OAuth sign-in on the live page.
// This asserts the page stays immune: no blank lines in either block.
const fs = require('fs');
const html = fs.readFileSync(process.argv[2] || 'web/octagon-connect.html', 'utf8');
let bad = 0;
for (const tag of ['script', 'style']) {
  const re = new RegExp('<' + tag + '[^>]*>([\s\S]*?)</' + tag + '>', 'g');
  let m, n = 0;
  while ((m = re.exec(html))) {
    n++;
    const blanks = m[1].split('\n').filter(l => l.trim() === '').length;
    if (blanks) { console.log(`FAIL <${tag}> block ${n} contains ${blanks} blank line(s) — wpautop will inject <p> tags`); bad++; }
  }
  if (!bad) console.log(`OK   <${tag}> blocks have no blank lines`);
}
process.exit(bad ? 1 : 0);
