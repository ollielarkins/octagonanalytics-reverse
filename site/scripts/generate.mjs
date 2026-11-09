// Builds the data the knowledge base renders from the platform's own source, so the
// Commands, Tools and "at a glance" figures never drift from what actually ships.
//
//   commands  <- octagon-plugins/plugins/<plugin>/skills/<command>/SKILL.md
//   tools     <- supabase/functions/octagon-mcp/index.ts (TOOLS and PROMPTS arrays)
//   platform  <- connector version, migration count, edge functions, cron jobs
//
// Runs before `dev` and `build`. Set OCTAGON_PLUGINS_DIR if octagon-plugins is not
// checked out next to this repo.

import { readFileSync, readdirSync, existsSync, mkdirSync, writeFileSync, statSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const site = resolve(here, '..');
const repo = resolve(site, '..');
const pluginsDir = resolve(process.env.OCTAGON_PLUGINS_DIR ?? join(repo, '..', 'octagon-plugins', 'plugins'));
const mcpFile = join(repo, 'supabase', 'functions', 'octagon-mcp', 'index.ts');
const outDir = join(site, 'src', 'data');
mkdirSync(outDir, { recursive: true });

const warn = (m) => console.warn(`[generate] ${m}`);

// ---- Tools and prompts ---------------------------------------------------------------

const src = readFileSync(mcpFile, 'utf8');
const version = src.match(/const SERVER = \{ name: "[^"]+", version: "([^"]+)" \}/)?.[1] ?? 'unknown';
const toolsStart = src.indexOf('const TOOLS = [');
const promptsStart = src.indexOf('const PROMPTS = [');

const unquote = (s) => JSON.parse(`"${s}"`);
const defRe = /^\s*\{ name: "([a-z0-9_]+)", description: "((?:[^"\\]|\\.)*)"(.*)$/gm;

function parseDefs(text) {
  const out = [];
  for (const m of text.matchAll(defRe)) {
    const rest = m[3];
    const props = rest.match(/properties: \{(.*)\}, (?:required|additionalProperties)/)?.[1] ?? '';
    const args = [...new Set([...props.matchAll(/(?:^|[,{])\s*([a-z_]+): \{ type/g)].map((a) => a[1]))]
      .filter((a) => a !== 'auth_token');
    const required = (rest.match(/required: \[([^\]]*)\]/)?.[1] ?? '')
      .split(',').map((s) => s.trim().replace(/"/g, '')).filter(Boolean);
    out.push({ name: m[1], description: unquote(m[2]), args, required });
  }
  return out;
}

// End the tools section at the first line after the array closes.
const toolsText = src.slice(toolsStart, src.indexOf('\n];', toolsStart));
const promptsText = src.slice(promptsStart, src.indexOf('\n];', promptsStart));

const WRITE_HINT = /\b(preview|confirm|card_nonce|writes?|creates?|updates?|deletes?|sends?)\b/i;
const tools = parseDefs(toolsText).map((t) => {
  const readOnly = /read-only/i.test(t.description);
  const kind = readOnly ? 'read' : WRITE_HINT.test(t.description) ? 'write' : 'read';
  const widget = /widget/i.test(t.description);
  return { ...t, kind, widget };
});
const prompts = parseDefs(promptsText).map(({ name, description }) => ({ name, description }));

// ---- Commands ------------------------------------------------------------------------

const PLUGINS = {
  'octagon-dashboard': { title: 'Dashboard', blurb: 'The live dashboard and KPI views.' },
  'octagon-reporting': { title: 'Reporting', blurb: 'Read-only questions about your desk, your clients and the firm.' },
  'octagon-actions': { title: 'Actions', blurb: 'Changes to RecruitCRM. Every one previews first and applies only when you confirm.' },
  'octagon-admin': { title: 'Admin', blurb: 'Platform administration. Admins only.' },
};

const toolNames = new Set(tools.map((t) => t.name));
const commands = [];
const pluginVersions = {};

if (!existsSync(pluginsDir)) {
  warn(`octagon-plugins not found at ${pluginsDir}; Commands will be empty. Set OCTAGON_PLUGINS_DIR.`);
} else {
  for (const plugin of readdirSync(pluginsDir)) {
    const manifest = join(pluginsDir, plugin, '.claude-plugin', 'plugin.json');
    if (existsSync(manifest)) pluginVersions[plugin] = JSON.parse(readFileSync(manifest, 'utf8')).version;
    const skillsDir = join(pluginsDir, plugin, 'skills');
    if (!existsSync(skillsDir)) continue;
    for (const skill of readdirSync(skillsDir)) {
      const file = join(skillsDir, skill, 'SKILL.md');
      if (!existsSync(file)) continue;
      const raw = readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
      const fm = raw.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
      if (!fm) { warn(`no frontmatter: ${file}`); continue; }
      const meta = Object.fromEntries(
        fm[1].split('\n').map((l) => l.match(/^([a-z-]+):\s*(.*)$/)).filter(Boolean).map((m) => [m[1], m[2].trim()]),
      );
      const body = fm[2];
      const description = (meta.description ?? '').replace(/^["']|["']$/g, '');
      // The "Use when ..." tail is routing guidance for Claude, not for people.
      let summary = description.split(/\s+Use (?:when|whenever)\b/)[0].trim();
      const audience = summary.match(/^\[([^\]]+)\]\s*/)?.[1] ?? (plugin === 'octagon-admin' ? 'Admins' : null);
      summary = summary.replace(/^\[[^\]]+\]\s*/, '');
      const usageLine = body.split('\n').find((l) => /^Usage:/i.test(l)) ?? '';
      const examples = [...usageLine.matchAll(/`([^`]+)`/g)].map((m) => m[1]);
      const calls = [...new Set([...body.matchAll(/`([a-z][a-z0-9_]+)`/g)].map((m) => m[1]).filter((n) => toolNames.has(n)))];
      commands.push({
        name: meta.name ?? skill,
        plugin,
        summary,
        audience,
        examples: examples.length ? examples : [`/${meta.name ?? skill}`],
        calls,
      });
    }
  }
}
commands.sort((a, b) => a.name.localeCompare(b.name));

// Which commands lean on each tool, so the Tools page can link back.
for (const t of tools) t.usedBy = commands.filter((c) => c.calls.includes(t.name)).map((c) => c.name);

// ---- Platform at a glance ------------------------------------------------------------

const migrationsDir = join(repo, 'supabase', 'migrations');
const migrations = readdirSync(migrationsDir).filter((f) => f.endsWith('.sql')).sort();
const lastMigration = migrations.at(-1) ?? '';

const fnDir = join(repo, 'supabase', 'functions');
const functions = readdirSync(fnDir).filter((f) => !f.startsWith('_') && statSync(join(fnDir, f)).isDirectory());

const platform = {
  generatedAt: new Date().toISOString(),
  connectorVersion: version,
  toolCount: tools.length,
  readTools: tools.filter((t) => t.kind === 'read').length,
  writeTools: tools.filter((t) => t.kind === 'write').length,
  promptCount: prompts.length,
  commandCount: commands.length,
  plugins: Object.entries(PLUGINS).map(([id, p]) => ({
    id, ...p, version: pluginVersions[id] ?? null, commands: commands.filter((c) => c.plugin === id).length,
  })),
  migrationCount: migrations.length,
  lastMigration,
  edgeFunctions: functions,
};

const write = (name, data) => writeFileSync(join(outDir, name), JSON.stringify(data, null, 2) + '\n');
write('tools.json', tools);
write('prompts.json', prompts);
write('commands.json', commands);
write('platform.json', platform);

console.log(
  `[generate] connector ${version}: ${tools.length} tools, ${prompts.length} prompts; ` +
  `${commands.length} commands; ${migrations.length} migrations`,
);
