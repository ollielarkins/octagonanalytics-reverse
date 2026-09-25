// Every edge function must have its verify_jwt setting declared in supabase/config.toml. Without an
// entry the setting is whatever the last deploy left behind - which is how a batched
// `--no-verify-jwt` deploy opened recruitcrm-sync on 10/08/2026.
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..', 'supabase');
const toml = fs.readFileSync(path.join(root, 'config.toml'), 'utf8');
const dirs = fs.readdirSync(path.join(root, 'functions'), { withFileTypes: true })
  .filter((d) => d.isDirectory() && fs.existsSync(path.join(root, 'functions', d.name, 'index.ts')))
  .map((d) => d.name);

let bad = 0;
for (const name of dirs) {
  const block = new RegExp(`\\[functions\\.${name}\\]([\\s\\S]*?)(?=\\n\\[|$)`).exec(toml);
  if (!block) { console.log(`FAIL ${name}: no [functions.${name}] block in config.toml`); bad++; continue; }
  if (!/^\s*verify_jwt\s*=\s*(true|false)\s*$/m.test(block[1])) { console.log(`FAIL ${name}: block has no verify_jwt`); bad++; }
}
console.log(bad ? `${bad} problem(s)` : `OK   ${dirs.length} functions declare verify_jwt`);
process.exit(bad ? 1 : 0);
