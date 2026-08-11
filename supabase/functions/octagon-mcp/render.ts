// Dashboard → PNG. Claude Web silently drops MCP Apps widgets for custom remote connectors
// (anthropics/claude-ai-mcp#471) but DOES render image content blocks inline, so the dashboard is
// rasterised server-side and returned as a PNG. Verified against the live client: PNG renders
// inline, SVG arrives as an unopened attachment, markdown data URIs render not at all.
//
// No canvas and no font engine exist in the edge runtime, so this composites pixels directly and
// draws text from the pre-rendered glyph atlas in atlas.ts.
import { ATLAS_B64 } from "./atlas.ts";

type Glyph = { w: number; h: number; x: number; y: number; a: number; b: string };
type Style = { asc: number; desc: number; line: number; g: Record<string, Glyph> };
let ATLAS: Record<string, Style> | null = null;
const bmpCache = new Map<string, Uint8Array>();

function b64bytes(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
async function inflate(bytes: Uint8Array): Promise<Uint8Array> {
  const ds = new DecompressionStream("deflate");
  const buf = await new Response(new Blob([bytes]).stream().pipeThrough(ds)).arrayBuffer();
  return new Uint8Array(buf);
}
async function deflate(bytes: Uint8Array): Promise<Uint8Array> {
  const cs = new CompressionStream("deflate");
  const buf = await new Response(new Blob([bytes]).stream().pipeThrough(cs)).arrayBuffer();
  return new Uint8Array(buf);
}
// Decoded once per instance; the atlas is ~90KB of JSON and reparsing it per call would dominate.
async function atlas(): Promise<Record<string, Style>> {
  if (!ATLAS) ATLAS = JSON.parse(new TextDecoder().decode(await inflate(b64bytes(ATLAS_B64))));
  return ATLAS!;
}
function glyphBitmap(g: Glyph): Uint8Array {
  let m = bmpCache.get(g.b);
  if (!m) { m = b64bytes(g.b); bmpCache.set(g.b, m); }
  return m;
}

type Canvas = { w: number; h: number; px: Uint8Array };
type RGB = [number, number, number];

function canvas(w: number, h: number, bg: RGB): Canvas {
  const px = new Uint8Array(w * h * 3);
  for (let i = 0; i < w * h; i++) { px[i*3] = bg[0]; px[i*3+1] = bg[1]; px[i*3+2] = bg[2]; }
  return { w, h, px };
}
function rect(c: Canvas, x: number, y: number, w: number, h: number, col: RGB) {
  const x0 = Math.max(0, x|0), y0 = Math.max(0, y|0);
  const x1 = Math.min(c.w, (x+w)|0), y1 = Math.min(c.h, (y+h)|0);
  for (let yy = y0; yy < y1; yy++) {
    let o = (yy * c.w + x0) * 3;
    for (let xx = x0; xx < x1; xx++) { c.px[o++] = col[0]; c.px[o++] = col[1]; c.px[o++] = col[2]; }
  }
}
function roundRect(c: Canvas, x: number, y: number, w: number, h: number, r: number, col: RGB) {
  for (let yy = 0; yy < h; yy++) for (let xx = 0; xx < w; xx++) {
    const dx = Math.min(xx, w-1-xx), dy = Math.min(yy, h-1-yy);
    if (dx < r && dy < r) { const a = r-dx, b = r-dy; if (a*a + b*b > r*r) continue; }
    const px = x+xx, py = y+yy;
    if (px < 0 || py < 0 || px >= c.w || py >= c.h) continue;
    const o = (py * c.w + px) * 3;
    c.px[o] = col[0]; c.px[o+1] = col[1]; c.px[o+2] = col[2];
  }
}
function width(A: Record<string, Style>, style: string, s: string) {
  const st = A[style]; let w = 0;
  for (const ch of s) w += (st.g[ch] ?? st.g["?"]).a;
  return w;
}
// Glyph y offsets come from PIL's getbbox, which measures from the TOP of the line box — the
// ascent is already baked in. Adding it again drops every string a full line.
function text(c: Canvas, A: Record<string, Style>, style: string, x: number, y: number, s: string, col: RGB) {
  const st = A[style];
  let pen = Math.round(x);
  const top = Math.round(y);
  for (const ch of s) {
    const g = st.g[ch] ?? st.g["?"];
    if (!g) continue;
    const bmp = glyphBitmap(g);
    for (let gy = 0; gy < g.h; gy++) {
      const py = top + g.y + gy;
      if (py < 0 || py >= c.h) continue;
      for (let gx = 0; gx < g.w; gx++) {
        const a = bmp[gy * g.w + gx];
        if (!a) continue;
        const px = pen + g.x + gx;
        if (px < 0 || px >= c.w) continue;
        const o = (py * c.w + px) * 3, k = a / 255;
        c.px[o]   = Math.round(c.px[o]   * (1-k) + col[0] * k);
        c.px[o+1] = Math.round(c.px[o+1] * (1-k) + col[1] * k);
        c.px[o+2] = Math.round(c.px[o+2] * (1-k) + col[2] * k);
      }
    }
    pen += g.a;
  }
}
const CRC = (() => { const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c>>>1) : c>>>1; t[n] = c; }
  return t; })();
function crc32(b: Uint8Array) { let c = -1; for (let i = 0; i < b.length; i++) c = CRC[(c ^ b[i]) & 255] ^ (c >>> 8); return (c ^ -1) >>> 0; }
function u32(n: number) { return new Uint8Array([(n>>>24)&255,(n>>>16)&255,(n>>>8)&255,n&255]); }
function cat(a: Uint8Array[]) { let n = 0; for (const x of a) n += x.length; const o = new Uint8Array(n); let i = 0; for (const x of a) { o.set(x, i); i += x.length; } return o; }
function chunk(type: string, data: Uint8Array) {
  const t = new TextEncoder().encode(type);
  return cat([u32(data.length), t, data, u32(crc32(cat([t, data])))]);
}
async function toPNG(c: Canvas): Promise<string> {
  const raw = new Uint8Array(c.h * (1 + c.w * 3));
  for (let y = 0; y < c.h; y++) {
    raw[y * (1 + c.w*3)] = 0;
    raw.set(c.px.subarray(y*c.w*3, (y+1)*c.w*3), y * (1 + c.w*3) + 1);
  }
  const png = cat([new Uint8Array([137,80,78,71,13,10,26,10]),
    chunk("IHDR", cat([u32(c.w), u32(c.h), new Uint8Array([8,2,0,0,0])])),
    chunk("IDAT", await deflate(raw)), chunk("IEND", new Uint8Array(0))]);
  let s = ""; for (let i = 0; i < png.length; i += 0x8000) s += String.fromCharCode(...png.subarray(i, i + 0x8000));
  return btoa(s);
}

const CO = {
  bg: [255,255,255] as RGB, card: [247,247,248] as RGB, line: [228,228,231] as RGB,
  fg: [17,17,17] as RGB, mut: [110,110,118] as RGB, good: [19,115,51] as RGB,
  bad: [176,0,32] as RGB, accent: [37,99,235] as RGB, amber: [217,119,6] as RGB,
};
const gbp = (n: any) => n == null ? "—" : "£" + Math.round(Number(n)).toLocaleString("en-GB");
const num = (n: any) => n == null ? "—" : Number(n).toLocaleString("en-GB");
const dmy = (s: any) => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(s ?? "")); return m ? `${m[3]}/${m[2]}/${m[1]}` : String(s ?? ""); };

export async function dashboardPNG(d: any): Promise<string> {
  const A = await atlas();
  const v = d.viewer ?? {}, k = d.kpis ?? {};
  const mine = !!(v.name && !v.is_admin);
  const W = 940, H = mine ? 690 : 640;
  const c = canvas(W, H, CO.bg);
  const T = (st: string, x: number, y: number, s: string, col: RGB) => text(c, A, st, x, y, s, col);
  const TR = (st: string, xr: number, y: number, s: string, col: RGB) => text(c, A, st, xr - width(A, st, s), y, s, col);
  const M = 32;
  let y = 26;

  T("big", M, y, mine ? `Your desk — ${v.name}` : "Octagon Recruitment Dashboard", CO.fg);
  const ok = (d.health ?? {}).overall === "ok";
  const pill = ok ? "sync healthy" : "SYNC ISSUE";
  const pw = width(A, "small", pill) + 20;
  roundRect(c, W - M - pw, y + 10, pw, 22, 11, ok ? [230,244,234] : [250,226,230]);
  T("small", W - M - pw + 10, y + 13, pill, ok ? CO.good : CO.bad);
  y += 52;

  const cards: [string, string][] = mine ? [
    ["Placed 2026", num((v.my_2026 ?? {}).placed)],
    ["Won this quarter", gbp((v.my_billing ?? {}).won_qtr)],
    ["Open pipeline", gbp((v.my_billing ?? {}).pipeline_open)],
    ["Active in play", num((v.my_day ?? {}).active_in_play)],
    ["Aging offers", num(((v.my_day ?? {}).aging_offers ?? []).length)],
    ["Cold open roles", num((v.my_day ?? {}).cold_open_roles)],
  ] : [
    ["Placed 2026", num(k.placed_2026)], ["Open jobs", num(k.open_jobs)],
    ["Open pipeline", gbp(k.open_pipeline)], ["Won (all time)", gbp(k.won)],
    ["Clients", num(k.clients)], ["In pipeline", num(k.candidates_in_pipeline)],
  ];
  const cw = (W - M*2 - 24) / 3, chh = 78;
  cards.forEach((cd, i) => {
    const cx = M + (i % 3) * (cw + 12), cy = y + Math.floor(i / 3) * (chh + 12);
    roundRect(c, cx, cy, cw, chh, 10, CO.card);
    T("big", cx + 14, cy + 12, cd[1], CO.fg);
    T("small", cx + 14, cy + 54, cd[0], CO.mut);
  });
  y += chh * 2 + 12 + 26;

  if (mine && v.my_weekly) {
    T("mid", M, y, `This week vs target — from ${dmy(v.week_start)}`, CO.fg); y += 28;
    for (const [label, key] of [["CV sends","cv_sent"],["Interview requests","interview_request"],
         ["Interviews","first_interview"],["BD calls","bd_calls"],["Client calls","client_calls"]]) {
      const m = v.my_weekly[key] ?? {}, a = m.actual ?? 0, t = m.target;
      const behind = t != null && a < t;
      T("body", M, y, label, CO.fg);
      const bx = M + 210, bw = 420;
      roundRect(c, bx, y + 3, bw, 13, 6, CO.line);
      if (t) roundRect(c, bx, y + 3, Math.max(3, Math.min(1, a / t) * bw), 13, 6, behind ? CO.amber : CO.good);
      TR("body", W - M, y, t != null ? `${a} / ${t}` : String(a), behind ? CO.bad : CO.good);
      y += 26;
    }
    y += 10;
  }

  const f = mine ? (v.my_2026 ?? {}) : (d.funnel ?? {});
  const stages: [string, string][] = mine
    ? [["Shortlist","shortlist"],["CV Sent","cv_sent"],["Interview Request","interview_request"],
       ["1st Interview","first_interview"],["Offered","offered"],["Placed","placed"]]
    : [["Shortlist","shortlist"],["CV Sent","cv_sent"],["Interview Request","interview_request"],
       ["1st Interview","first_interview"],["2nd Interview","second_interview"],
       ["3rd Interview","third_interview"],["Offered","offered"],["Placed","placed"]];
  T("mid", M, y, mine ? "Your 2026 funnel" : "2026 funnel", CO.fg); y += 28;
  const max = Math.max(1, ...stages.map(s => f[s[1]] ?? 0));
  for (const [label, key] of stages) {
    const val = f[key] ?? 0;
    T("body", M, y, label, CO.mut);
    const bx = M + 170, bw = Math.max(2, (val / max) * 500);
    roundRect(c, bx, y + 2, bw, 14, 7, CO.accent);
    T("body", bx + bw + 10, y, num(val), CO.fg);
    y += 24;
  }

  y += 8; rect(c, M, y, W - M*2, 1, CO.line); y += 12;
  T("small", M, y, `Firm 2026: ${num(k.cv_2026)} CV sent · ${num(k.placed_2026)} placed · ${num(k.open_jobs)} open jobs · ${gbp(k.open_pipeline)} pipeline`, CO.mut);
  return await toPNG(c);
}
