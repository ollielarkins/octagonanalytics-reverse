// Migration hygiene. Each rule exists because breaking it has already cost us once:
//   * numbering: unique and contiguous - a gap means a migration is live in production but not here
//     (0053-0057 were applied on 01/09/2026 and never reached main).
//   * header: the first line names the file, so a pasted migration can be traced back.
//   * views: CREATE OR REPLACE VIEW resets the view's options. 0075 dropped security_invoker that
//     way and made deal_pipeline_by_stage readable with the anon key until 0084.
//   * SECURITY DEFINER: PostgREST exposes every public function, so a definer function nobody
//     revoked is callable by anon/authenticated. Revoke in the same file.
// The last two apply from STRICT_FROM on; older files predate the rules and are already live.
const fs = require('fs');
const path = require('path');

const DIR = path.join(__dirname, '..', 'supabase', 'migrations');
const STRICT_FROM = 85;
// Live in production but not yet committed. Remove each number as its file lands.
const KNOWN_GAPS = new Set([53, 54, 55, 56, 57]);

const files = fs.readdirSync(DIR).filter((f) => f.endsWith('.sql')).sort();
let bad = 0;
const fail = (msg) => { console.log('FAIL ' + msg); bad++; };

const seen = new Map();
for (const f of files) {
  const m = /^(\d{4})_[a-z0-9_]+\.sql$/.exec(f);
  if (!m) { fail(`${f}: name must be NNNN_snake_case.sql`); continue; }
  const n = Number(m[1]);
  if (seen.has(n)) fail(`${f}: number ${m[1]} already used by ${seen.get(n)}`);
  seen.set(n, f);

  const sql = fs.readFileSync(path.join(DIR, f), 'utf8').replace(/\r/g, '');
  if (sql.split('\n')[0].trim() !== `-- ${f}`) fail(`${f}: first line must be "-- ${f}"`);

  if (n < STRICT_FROM) continue;
  // Strip comments so a rule mentioned in prose doesn't count as satisfying it.
  const code = sql.replace(/--.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');

  for (const v of code.matchAll(/create\s+(?:or\s+replace\s+)?view\s+([\w."]+)([\s\S]*?)\bas\b/gi)) {
    if (!/security_invoker\s*=\s*(on|true)/i.test(v[2])) fail(`${f}: view ${v[1]} needs WITH (security_invoker = on)`);
  }
  for (const fn of code.matchAll(/create\s+(?:or\s+replace\s+)?function\s+([\w."]+)\s*\(/gi)) {
    const name = fn[1];
    // The function runs until the next top-level CREATE (or end of file); SECURITY DEFINER may sit
    // before or after the body, and bodies are quoted $$, $function$ or anything else.
    const rest = code.slice(fn.index + 1);
    const next = rest.search(/\bcreate\s+(?:or\s+replace\s+)?(?:function|view|table|trigger|index)\b/i);
    const body = next < 0 ? code.slice(fn.index) : code.slice(fn.index, fn.index + 1 + next);
    if (!/security\s+definer/i.test(body)) continue;
    const bare = name.replace(/^public\./i, '').replace(/"/g, '');
    const revoke = new RegExp(`revoke\\s+execute\\s+on\\s+function\\s+(?:public\\.)?"?${bare}"?[\\s\\S]*?from[^;]*\\banon\\b`, 'i');
    if (!revoke.test(code)) fail(`${f}: SECURITY DEFINER function ${name} needs "revoke execute ... from public, anon, authenticated"`);
  }
}

const nums = [...seen.keys()].sort((a, b) => a - b);
for (let n = nums[0]; n <= nums[nums.length - 1]; n++) {
  if (!seen.has(n) && !KNOWN_GAPS.has(n)) fail(`missing ${String(n).padStart(4, '0')}: is it live but uncommitted?`);
  if (seen.has(n) && KNOWN_GAPS.has(n)) fail(`${seen.get(n)} is committed - remove ${n} from KNOWN_GAPS`);
}

console.log(bad ? `${bad} problem(s) in ${files.length} migrations` : `OK   ${files.length} migrations`);
process.exit(bad ? 1 : 0);
