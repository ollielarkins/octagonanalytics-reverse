// ---- MCP Apps (SEP-1865) widgets --------------------------------------------------------------
// Inline UI that Claude renders for tools whose definition carries _meta.ui.resourceUri.
//
// Each widget is one self-contained HTML document:
//   1. the MCP Apps SDK browser client, inlined (ext_apps_bundle.ts, exposed as window.McpApps) and
//      wrapped in its own function scope, so its minified top-level names cannot collide with ours —
//      it does the ui/initialize handshake, receives the tool result, and reports the content
//      height to the host. The old hand-rolled postMessage code never completed the handshake or
//      reported a size, which is why the iframe so often mounted at zero height.
//   2. the Octagon theme kit: Claude's host style variables for structure (backgrounds, text,
//      borders, fonts — so it reads as native Claude in light and dark), Octagon colours only as
//      accents, each adjusted per theme to pass WCAG AA.
//   3. a render function per widget, given the tool's structuredContent and the display mode.
//
// JS and CSS blocks are String.raw so regex escapes survive into the emitted page, and contain no
// template interpolation; parts are joined with +. scripts/check-widgets.js parses the emitted
// scripts exactly as the host will see them.
import { EXT_APPS_JS } from "./ext_apps_bundle.ts";

export const MCP_APP_MIME = "text/html;profile=mcp-app";
export const DASH_UI = "ui://octagon/dashboard";
export const SCORE_UI = "ui://octagon/scorecard";
export const CONFIRM_UI = "ui://octagon/confirm";
export const REPORT_UI = "ui://octagon/report";
export const MIXED_UI = "ui://octagon/mixed";

// get_dashboard links to its widget (on from 3.64.0, once the SDK runtime was live via weekly_kpis /
// billing). octagon-dashboard 0.5.0 stopped redrawing the bare dashboard with visualize at the same
// time — set this false again only together with reverting that skill, or the dashboard vanishes.
export const DASHBOARD_WIDGET_LINKED = true;

// Returned with every resources/read. Everything is inline, so the sandbox needs no external
// origins at all; prefersBorder lets Claude draw its own card border round the widget, which is
// what makes it sit in the conversation like Claude's own inline cards.
export const WIDGET_RESOURCE_META = { ui: { csp: { connectDomains: [], resourceDomains: [] }, prefersBorder: true } };

const LOGO_LIGHT = "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";
const LOGO_DARK = "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";

// ---- Theme kit ---------------------------------------------------------------------------------
// --o-* tokens read Claude's host variables first (applied at runtime by applyHostStyleVariables)
// and fall back to Claude's published values for that theme. Octagon accents:
//   action  pink  #c81e55 light (white text 5.6:1) / #ff7aa0 dark (navy text 6.6:1)
//   bar     teal  #2f7f88 light (4.7:1 on white)   / #7fc9d0 dark (7.0:1)
//   series2 navy  #07213f light                    / #8fb4dc dark (6.1:1)
//   chip    teal  #7fc9d0 fill with navy #07213f text (8.6:1), both themes
const THEME_CSS = String.raw`
:root{color-scheme:light;
--o-bg:var(--color-background-primary,#FFFFFF);--o-bg-2:var(--color-background-secondary,#F5F4ED);
--o-text:var(--color-text-primary,#141413);--o-text-2:var(--color-text-secondary,#3D3D3A);--o-text-3:var(--color-text-tertiary,#73726C);
--o-border:var(--color-border-tertiary,rgba(31,30,29,.15));--o-border-2:var(--color-border-secondary,rgba(31,30,29,.3));
--o-success:var(--color-text-success,#265B19);
--o-warn:var(--color-text-warning,#5A4815);--o-warn-bg:var(--color-background-warning,#F6EEDF);
--o-track:var(--color-background-secondary,#F5F4ED);
--o-action:#c81e55;--o-on-action:#FFFFFF;--o-bar:#2f7f88;--o-series-2:#07213f;--o-chip:#7fc9d0;--o-on-chip:#07213f;
--o-font:var(--font-sans,"Anthropic Sans",ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif);
--o-r-sm:var(--border-radius-sm,6px);--o-r-md:var(--border-radius-md,8px);--o-r-full:var(--border-radius-full,9999px);
--o-bw:var(--border-width-regular,.5px)}
:root[data-theme=dark]{color-scheme:dark;
--o-bg:var(--color-background-primary,#30302E);--o-bg-2:var(--color-background-secondary,#262624);
--o-text:var(--color-text-primary,#FAF9F5);--o-text-2:var(--color-text-secondary,#C2C0B6);--o-text-3:var(--color-text-tertiary,#9C9A92);
--o-border:var(--color-border-tertiary,rgba(222,220,209,.15));--o-border-2:var(--color-border-secondary,rgba(222,220,209,.3));
--o-success:var(--color-text-success,#7AB948);
--o-warn:var(--color-text-warning,#D1A041);--o-warn-bg:var(--color-background-warning,#483A0F);
--o-track:var(--color-background-tertiary,#141413);
--o-action:#ff7aa0;--o-on-action:#07213f;--o-bar:#7fc9d0;--o-series-2:#8fb4dc;--o-chip:#7fc9d0;--o-on-chip:#07213f}
*{box-sizing:border-box}
html,body{margin:0;background:transparent;color:var(--o-text);font-family:var(--o-font);font-size:var(--font-text-sm-size,14px);line-height:1.4}
#app{padding:16px}
.full #app{padding:24px;max-width:960px;margin:0 auto}
.head{display:flex;align-items:center;gap:8px;margin-bottom:16px;min-height:20px}
.logo{width:16px;height:16px;flex:none}
.logo.dk{display:none}:root[data-theme=dark] .logo.lt{display:none}:root[data-theme=dark] .logo.dk{display:block}
.title{font-size:var(--font-heading-md-size,16px);font-weight:var(--font-weight-medium,500)}
.cap{margin-left:auto;font-size:12px;color:var(--o-text-3);text-align:right}
.note{font-size:12px;color:var(--o-text-3);margin-top:12px}
.sec{font-size:var(--font-heading-md-size,16px);font-weight:var(--font-weight-medium,500);margin:24px 0 12px}
.chip{display:inline-block;font-size:12px;font-weight:500;padding:2px 8px;border-radius:var(--o-r-full);background:var(--o-chip);color:var(--o-on-chip)}
.warn{margin:0 0 14px;padding:8px 12px;border-radius:var(--o-r-md);background:var(--o-warn-bg);color:var(--o-warn);font-size:13px}
.ok{color:var(--o-success)}
.kpis{display:grid;gap:12px}
.kpi{display:grid;grid-template-columns:1fr auto;gap:6px 12px}
.kpi .l{color:var(--o-text-2)}
.kpi .v{font-variant-numeric:tabular-nums;color:var(--o-text-3);white-space:nowrap}
.kpi .v b{color:var(--o-text);font-weight:var(--font-weight-medium,500)}
.kpi.met .v b{color:var(--o-success)}
.bar{grid-column:1/-1;height:6px;border-radius:var(--o-r-full);background:var(--o-track);overflow:hidden}
.bar i{display:block;height:100%;background:var(--o-bar);border-radius:inherit}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:12px}
.tile{background:var(--o-bg-2);border-radius:var(--o-r-md);padding:14px 16px;container-type:inline-size;min-width:0}
.tile .l{font-size:13px;color:var(--o-text-2);margin:0 0 4px}
.tile .v{font-size:clamp(16px,16cqi,24px);white-space:nowrap;font-weight:var(--font-weight-medium,500);font-variant-numeric:tabular-nums;line-height:1.2}
.tile .s{font-size:12px;color:var(--o-text-3);margin-top:4px}
.big{font-size:28px;font-weight:var(--font-weight-medium,500);font-variant-numeric:tabular-nums;line-height:1.1}
.big small{font-size:14px;font-weight:400;color:var(--o-text-3)}
.rows{display:grid;grid-template-columns:1fr auto;gap:8px 12px;margin-top:14px}
.rows dt{color:var(--o-text-3)}.rows dd{margin:0;text-align:right;font-variant-numeric:tabular-nums}
.tw{overflow-x:auto;margin:0 -2px}
table{width:100%;border-collapse:collapse;font-size:13px}
th{font-weight:var(--font-weight-normal,400);color:var(--o-text-2);text-align:left;padding:6px 8px;border-bottom:var(--o-bw) solid var(--o-border-2);white-space:nowrap}
td{padding:7px 8px;border-bottom:var(--o-bw) solid var(--o-border)}
tr:last-child td{border-bottom:0}
.num{text-align:right;font-variant-numeric:tabular-nums}
td.met{color:var(--o-success);font-weight:var(--font-weight-medium,500)}
.fun{display:grid;grid-template-columns:minmax(110px,auto) 1fr auto;gap:10px 12px;align-items:center}
.fun .l{color:var(--o-text-2);font-size:13px}.fun .n{font-variant-numeric:tabular-nums;font-size:13px;text-align:right}
.fun .t{height:20px}.fun .t i{display:block;height:100%;min-width:2px;background:var(--o-bar);border-radius:4px}
.foot{display:flex;align-items:center;gap:8px;margin-top:16px;padding-top:14px;border-top:var(--o-bw) solid var(--o-border)}
.foot .hint{font-size:12px;color:var(--o-text-3);margin-right:auto}
.btn{font:inherit;font-weight:var(--font-weight-medium,500);min-height:32px;padding:0 12px;border-radius:var(--o-r-md);cursor:pointer}
.btn-p{background:var(--o-action);color:var(--o-on-action);border:0}
.btn-g{background:transparent;color:var(--o-text);border:var(--o-bw) solid var(--o-border-2)}
.btn:focus-visible{outline:2px solid var(--o-bar);outline-offset:2px}
@media (pointer:coarse){.btn{min-height:44px}}
.sk{background:var(--o-track);border-radius:var(--o-r-sm);height:12px;animation:pulse 1.4s ease-in-out infinite}
@keyframes pulse{50%{opacity:.5}}
@media (prefers-reduced-motion:reduce){.sk{animation:none}}
.kv{display:grid;grid-template-columns:minmax(90px,max-content) 1fr;gap:8px 16px;margin:0}
.kv dt{color:var(--o-text-3)}.kv dd{margin:0;overflow-wrap:anywhere}
.kv dd .from{color:var(--o-text-3)}.kv dd .arrow{color:var(--o-text-3);margin:0 6px}.kv dd .to{font-weight:var(--font-weight-medium,500)}
.body{white-space:pre-wrap;background:var(--o-bg-2);border-radius:var(--o-r-md);padding:12px 14px;font-size:13px;line-height:1.5;max-height:9.5em;overflow:hidden;position:relative}
.body.open{max-height:none}
.link{font:inherit;font-size:12px;background:none;border:0;padding:4px 0;color:var(--o-text-2);text-decoration:underline;cursor:pointer}
.danger{margin:0 0 14px;padding:8px 12px;border-radius:var(--o-r-md);background:var(--color-background-danger,#F7ECEC);color:var(--color-text-danger,#7F2C28);font-size:13px}
:root[data-theme=dark] .danger{background:var(--color-background-danger,#602A28);color:var(--color-text-danger,#EE8884)}
.state{display:flex;align-items:center;gap:8px;font-size:13px}
.state.ok{color:var(--o-success)}.state.bad{color:var(--color-text-danger,#7F2C28)}
:root[data-theme=dark] .state.bad{color:var(--color-text-danger,#EE8884)}
.btn[disabled]{opacity:.5;cursor:default}
.note+.tiles,.fun+.tiles,.tw+.tiles{margin-top:14px}
.li{display:grid;gap:0;margin-top:4px}
.li .row{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:8px 0;border-bottom:var(--o-bw) solid var(--o-border)}
.li .row:last-child{border-bottom:0}
.tag{font-size:12px;color:var(--o-text-2);background:var(--o-bg-2);border-radius:var(--o-r-full);padding:2px 8px;white-space:nowrap}
.m{font-size:12px;color:var(--o-text-3)}
.car{display:grid;grid-auto-flow:column;grid-auto-columns:220px;gap:12px;overflow-x:auto;scroll-snap-type:x mandatory;padding-bottom:4px}
.cc{scroll-snap-align:start;background:var(--o-bg-2);border-radius:var(--o-r-md);padding:14px;display:flex;flex-direction:column;gap:4px}
.cc .t{font-weight:var(--font-weight-medium,500)}.cc .m{font-size:12px}
.cc .chips{display:flex;flex-wrap:wrap;gap:4px;margin:6px 0 10px}.cc .btn{margin-top:auto;align-self:flex-start}
.board{display:grid;grid-auto-flow:column;grid-auto-columns:minmax(180px,1fr);gap:12px;overflow-x:auto}
.col{background:var(--o-bg-2);border-radius:var(--o-r-md);padding:10px;display:flex;flex-direction:column;gap:8px;min-height:80px}
.col .ch{font-size:13px;font-weight:var(--font-weight-medium,500);display:flex;justify-content:space-between}.col .ch span{color:var(--o-text-3);font-weight:400}
.bc{background:var(--o-bg);border:var(--o-bw) solid var(--o-border);border-radius:var(--o-r-sm);padding:8px 10px;font-size:13px}
.vb{display:grid;grid-auto-flow:column;grid-auto-columns:1fr;gap:6px;align-items:end;height:160px;margin-top:4px}
.vb .c{display:flex;flex-direction:column;align-items:center;justify-content:flex-end;height:100%;gap:4px}
.vb .c i{display:block;width:100%;max-width:28px;background:var(--o-bar);border-radius:4px 4px 0 0}
.vb .n{font-size:11px;color:var(--o-text-3)}.vb .l{font-size:12px;color:var(--o-text-2)}
.dot{display:inline-block;width:10px;height:10px;border-radius:50%}.dot.u{background:var(--o-bar)}.dot.t{background:var(--o-chip);opacity:.6}.dot.n{background:var(--o-track);box-shadow:inset 0 0 0 1px var(--o-border-2)}
.dpe{display:grid;grid-template-columns:minmax(120px,max-content) 1fr;gap:8px 16px;align-items:center}
.dpe .l{color:var(--o-text-2)}
.seg2{display:inline-flex;justify-self:start;width:max-content;border:var(--o-bw) solid var(--o-border-2);border-radius:var(--o-r-md);overflow:hidden}
.seg2 button{font:inherit;min-width:36px;min-height:32px;border:0;background:transparent;color:var(--o-text);cursor:pointer;border-right:var(--o-bw) solid var(--o-border)}
.seg2 button:last-child{border-right:0}.seg2 button.on{background:var(--o-chip);color:var(--o-on-chip);font-weight:var(--font-weight-medium,500)}
@media (pointer:coarse){.seg2 button{min-width:44px;min-height:44px}}
.tot{display:grid;grid-template-columns:repeat(3,auto);justify-content:start;gap:24px;margin-top:16px;align-items:end}
.tot .l{font-size:13px;color:var(--o-text-2);margin-bottom:4px}.tot .v{font-size:24px;font-weight:var(--font-weight-medium,500)}.tot small{font-size:14px;color:var(--o-text-3);font-weight:400}
.badge{display:inline-block;margin:0 0 12px;padding:6px 12px;border-radius:var(--o-r-md);font-weight:var(--font-weight-medium,500)}
.badge.stop{background:var(--color-background-danger,#F7ECEC);color:var(--color-text-danger,#7F2C28)}
.badge.go{background:var(--color-background-success,#E9F1DC);color:var(--o-success)}
:root[data-theme=dark] .badge.stop{background:var(--color-background-danger,#602A28);color:var(--color-text-danger,#EE8884)}
:root[data-theme=dark] .badge.go{background:var(--color-background-success,#1B4614)}
.chk{font:inherit;width:22px;height:22px;border-radius:6px;border:var(--o-bw) solid var(--o-border-2);background:transparent;color:var(--o-on-chip);cursor:pointer;vertical-align:middle;padding:0;font-size:13px}
.chk.on{background:var(--o-chip);border-color:var(--o-chip)}
@media (pointer:coarse){.chk{width:32px;height:32px}}
.sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}
`;

// Shared helpers + runtime. Expects window.OCT = { name, accept(data) -> bool, render(data, ctx) -> html }.
// ctx = { mode: 'inline'|'fullscreen', canFull: bool }.
const RUNTIME_JS = String.raw`
var GBP=function(n){return n==null?'—':'£'+Math.round(Number(n)).toLocaleString('en-GB')};
var N=function(n){return n==null?'—':Number(n).toLocaleString('en-GB')};
function esc(s){return String(s==null?'':s).replace(/[&<>"']/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]})}
function D(s){var m=/^(\d{4})-(\d{2})-(\d{2})/.exec(String(s==null?'':s));return m?m[3]+'/'+m[2]+'/'+m[1]:esc(s)}
function lc(s){return String(s).replace(/^[A-Z][a-z]/,function(c){return c.toLowerCase()})}
// Leavers (left:true) stay below current staff and are tagged, never dropped (see the dashboard skill's house rules).
function rank(cs,key){return cs.slice().sort(function(a,b){return ((a.left?1:0)-(b.left?1:0))||(key(b)-key(a))})}
function who(c){return esc(c.name)+(c.left?' <span style="font-size:12px;color:var(--o-text-3)">left</span>':'')}
function pct(a,t){return t?Math.max(0,Math.min(100,Math.round(100*(a||0)/t))):0}
function head(title,cap){return '<div class="head"><img class="logo lt" src="data:image/png;base64,'+OCT_LOGO_L+'" alt=""><img class="logo dk" src="data:image/png;base64,'+OCT_LOGO_D+'" alt=""><span class="title">'+esc(title)+'</span>'+(cap?'<span class="cap">'+cap+'</span>':'')+'</div>'}
function skeleton(){return '<div class="head"><div class="sk" style="width:20px;height:20px;border-radius:6px"></div><div class="sk" style="width:120px"></div></div><div class="kpis">'+[70,55,62,40,48].map(function(w){return '<div><div class="sk" style="width:'+w+'%;margin-bottom:8px"></div><div class="sk" style="height:6px"></div></div>'}).join('')+'</div>'}
(function(){
var M=window.McpApps,O=window.OCT,root=document.getElementById('app');
var DATA=null,MODE='inline',FULL=false,FAILED=false,CAN_TOOLS=false;
root.innerHTML=skeleton();
function fail(msg){if(DATA)return;FAILED=true;root.innerHTML=head(O.title||'Octagon')+'<div class="note">'+esc(msg)+'</div>'}
if(!M||!M.App){fail('The widget could not start. Ask again, and if it keeps happening, ping Ollie on Slack.');return}
var app=new M.App({name:O.name,version:'2.0.0'},{availableDisplayModes:O.full?['inline','fullscreen']:['inline']},{autoResize:true});
function draw(){if(!DATA)return;document.documentElement.classList.toggle('full',MODE==='fullscreen');
try{root.innerHTML=O.render(DATA,{mode:MODE,canFull:FULL,canTools:CAN_TOOLS})}catch(e){root.innerHTML=head(O.title||'Octagon')+'<div class="note">Could not draw this view: '+esc(e&&e.message)+'</div>'}}
function applyCtx(c){if(!c)return;
try{if(c.theme)M.applyDocumentTheme(c.theme);if(c.styles&&c.styles.variables)M.applyHostStyleVariables(c.styles.variables);if(c.styles&&c.styles.css&&c.styles.css.fonts)M.applyHostFonts(c.styles.css.fonts)}catch(e){}
if(c.availableDisplayModes)FULL=!!O.full&&c.availableDisplayModes.indexOf('fullscreen')>=0;
var s=c.safeAreaInsets;if(s)document.body.style.padding=(s.top||0)+'px '+(s.right||0)+'px '+(s.bottom||0)+'px '+(s.left||0)+'px';
var changed=c.displayMode&&c.displayMode!==MODE;if(c.displayMode)MODE=c.displayMode;if(changed||c.availableDisplayModes)draw()}
app.ontoolresult=function(r){var sc=r&&r.structuredContent;
if(r&&r.isError){fail('The tool returned an error. Ask again in a moment.');return}
if(!sc||!O.accept(sc)){fail('No data came back for this view. Ask again in a moment.');return}
DATA=sc;FAILED=false;draw()};
app.ontoolcancelled=function(){fail('Cancelled.')};
app.onhostcontextchanged=applyCtx;
document.addEventListener('click',function(ev){var a=ev.target.closest&&ev.target.closest('[data-act]');
if(a&&O.act){ev.preventDefault();O.act(a.getAttribute('data-act'),DATA,{app:app,set:function(d){DATA=d;draw()},draw:draw});return}
var b=ev.target.closest&&ev.target.closest('[data-mode]');if(!b)return;
app.requestDisplayMode({mode:b.getAttribute('data-mode')}).then(function(r){if(r&&r.mode){MODE=r.mode;draw()}}).catch(function(){})});
app.connect().then(function(){var hc=app.getHostCapabilities&&app.getHostCapabilities();CAN_TOOLS=!!(hc&&hc.serverTools);applyCtx(app.getHostContext());draw()}).catch(function(){fail('Could not connect to Claude. Reconnect the Octagon Analytics connector and ask again.')});
setTimeout(function(){if(!DATA&&!FAILED)fail('This is taking longer than usual. Ask again, and if it keeps happening, ping Ollie on Slack.')},10000);
})();
`;

// ---- Scorecard: weekly_kpis + billing (branches on payload shape) --------------------------------
const SCORECARD_JS = String.raw`
var KPI=[['CV sends','cv_sent'],['Interview requests','interview_request'],['Interviews','first_interview'],['BD calls','bd_calls'],['Client calls','client_calls']];
function weekOne(d,c){var o=head('This week','from '+D(d.week_start))+'<div class="kpis">';
o+=KPI.map(function(k){var m=c[k[1]]||{},a=m.actual||0,t=m.target;var met=t!=null&&a>=t;
return '<div class="kpi'+(met?' met':'')+'"><span class="l">'+k[0]+'</span><span class="v"><b>'+N(a)+'</b>'+(t!=null?' / '+N(t):'')+'</span>'+(t!=null?'<div class="bar" role="img" aria-label="'+k[0]+' '+a+' of '+t+'"><i style="width:'+pct(a,t)+'%"></i></div>':'')+'</div>'}).join('')+'</div>';
var gaps=KPI.map(function(k){var m=c[k[1]]||{};return (m.target!=null&&(m.actual||0)<m.target)?{l:k[0],g:m.target-(m.actual||0)}:null}).filter(Boolean);
var p=c.placed||{};
o+='<div class="note">'+(gaps.length?'To go: '+gaps.map(function(x){return esc(lc(x.l))+' '+x.g}).join(', ')+'. ':(d.has_targets===false?'':'All weekly targets met. '))+(p.actual!=null?'Placed this week: '+N(p.actual)+'. ':'')+(d.has_targets===false?'Targets not loaded. ':'')+'BD and client calls count categorised Devyce calls only, so can undercount.</div>';
return o}
function weekTeam(d,cs){var m=[['CV','cv_sent'],['Int req','interview_request'],['Int','first_interview'],['BD','bd_calls'],['Client','client_calls'],['Placed','placed']];
cs=rank(cs,function(c){return (c.cv_sent||{}).actual||0});
var o=head('This week — team','from '+D(d.week_start));
o+='<div class="tw"><table><tr><th>Consultant</th>'+m.map(function(x){return '<th class="num">'+x[0]+'</th>'}).join('')+'</tr>'+cs.map(function(c){return '<tr><td>'+who(c)+'</td>'+m.map(function(x){var v=c[x[1]]||{},a=v.actual||0,t=v.target;return '<td class="num'+(t!=null&&a>=t?' met':'')+'">'+N(a)+(t!=null?'<span style="color:var(--o-text-3)">/'+N(t)+'</span>':'')+'</td>'}).join('')+'</tr>'}).join('')+'</table></div>';
o+='<div class="note">Green = target met. '+(d.has_targets===false?'Targets not loaded. ':'')+'BD and client calls count categorised Devyce calls only, so can undercount.</div>';return o}
function billOne(d,c){var tg=c.quarterly_target,wq=c.won_qtr||0,left=tg!=null?Math.max(0,tg-wq):null;
var o=head('Billing this quarter','from '+D(d.quarter_start));
o+='<div class="big">'+GBP(wq)+(tg!=null?' <small>of '+GBP(tg)+'</small>':'')+'</div>';
if(tg!=null)o+='<div class="bar" style="margin-top:10px" role="img" aria-label="'+pct(wq,tg)+'% of target"><i style="width:'+pct(wq,tg)+'%"></i></div>';
o+='<dl class="rows">'+(tg!=null?'<dt>Of target</dt><dd>'+(tg?Math.round(100*wq/tg):0)+'%</dd><dt>Still to bill</dt><dd'+(left===0?' class="ok"':'')+'>'+GBP(left)+'</dd>':'')+'<dt>Open pipeline</dt><dd>'+GBP(c.pipeline_open)+'</dd></dl>';
o+='<div class="note">Billing is Won deal value. Pipeline is the forward indicator.</div>';return o}
function billTeam(d,cs){cs=rank(cs,function(c){return c.won_qtr||0});
var o=head('Billing this quarter — team','from '+D(d.quarter_start));
o+='<div class="tw"><table><tr><th>Consultant</th><th class="num">Won</th><th class="num">Target</th><th class="num">%</th><th class="num">Pipeline</th></tr>'+cs.map(function(c){var tg=c.quarterly_target,wq=c.won_qtr||0;return '<tr><td>'+who(c)+'</td><td class="num'+(tg!=null&&wq>=tg?' met':'')+'">'+GBP(wq)+'</td><td class="num">'+(tg!=null?GBP(tg):'—')+'</td><td class="num">'+(tg?Math.round(100*wq/tg)+'%':'—')+'</td><td class="num">'+GBP(c.pipeline_open)+'</td></tr>'}).join('')+'</table></div>';
o+='<div class="note">Billing is Won deal value. Pipeline is the forward indicator.</div>';return o}
window.OCT={name:'octagon-scorecard',title:'Scorecard',full:false,
accept:function(d){return !!(d&&d.consultants&&(d.week_start||d.quarter_start))},
render:function(d){var cs=d.consultants||[];
if(!cs.length)return head(d.week_start?'This week':'Billing this quarter')+'<div class="note">No data for you yet.</div>';
if(d.week_start)return cs.length===1?weekOne(d,cs[0]):weekTeam(d,cs);
return cs.length===1?billOne(d,cs[0]):billTeam(d,cs)}};
`;

// ---- Dashboard: get_dashboard -------------------------------------------------------------------
// Inline: a summary card (at most four figures and one action). Fullscreen: the full desk / firm
// view — same content as before, restyled. If the host has no fullscreen, the full view renders inline.
const DASHBOARD_JS = String.raw`
function sync(h){h=h||{};if(h.overall==='ok')return '';var fe=(h.entities||[]).filter(function(e){return e.status!=='ok'}).map(function(e){return esc(e.entity)+(e.reason?' ('+esc(e.reason)+')':'')}).join(', ');return '<div class="warn">Sync not OK, so figures may be stale: '+(fe||'unknown feed')+'.</div>'}
function tiles(t){return '<div class="tiles">'+t.map(function(x){return '<div class="tile"><div class="l">'+x[0]+'</div><div class="v">'+x[1]+'</div>'+(x[2]?'<div class="s">'+x[2]+'</div>':'')+'</div>'}).join('')+'</div>'}
function funnel(st){var mx=Math.max.apply(null,st.map(function(s){return s[1]||0}).concat([1]));return '<div class="fun">'+st.map(function(s){return '<span class="l">'+s[0]+'</span><span class="t"><i style="width:'+Math.round(100*(s[1]||0)/mx)+'%"></i></span><span class="n">'+N(s[1]||0)+'</span>'}).join('')+'</div>'}
function table(cols,rows){return '<div class="tw"><table><tr>'+cols.map(function(c){return '<th'+(c[1]?' class="num"':'')+'>'+c[0]+'</th>'}).join('')+'</tr>'+rows.join('')+'</table></div>'}
function foot(ctx){if(!ctx.canFull)return '';return ctx.mode==='fullscreen'?'<div class="foot"><span class="hint">Live from RecruitCRM</span><button class="btn btn-g" data-mode="inline">Back to chat</button></div>':'<div class="foot"><span class="hint">Live from RecruitCRM</span><button class="btn btn-p" data-mode="fullscreen">Open dashboard</button></div>'}
var WK=[['CV sends','cv_sent'],['Interview requests','interview_request'],['Interviews','first_interview'],['BD calls','bd_calls'],['Client calls','client_calls']];
function behindLine(w){var g=WK.map(function(r){var m=w[r[1]]||{};return (m.target!=null&&(m.actual||0)<m.target)?lc(r[0])+' '+(m.actual||0)+'/'+m.target:null}).filter(Boolean);return g.length?'Behind this week on '+g.join(', ')+'.':'All weekly targets met.'}
function meSummary(d,v,ctx){var b=v.my_billing||{},md=v.my_day||{};
var o=head('Your desk',v.name?esc(v.name):'')+sync(d.health);
o+=tiles([['Won this quarter',GBP(b.won_qtr),b.quarterly_target!=null?'of '+GBP(b.quarterly_target):''],['Open pipeline',GBP(b.pipeline_open)],['Aging offers',N((md.aging_offers||[]).length)],['Stalled',N((md.stalled||[]).length)]]);
if(v.my_weekly)o+='<div class="note">'+behindLine(v.my_weekly)+'</div>';
return o+foot(ctx)}
function meFull(d,v,ctx){var h=d.health||{},k=d.kpis||{},w=v.my_weekly||{},b=v.my_billing||{},md=v.my_day||{},y=v.my_2026||{};
var o=head('Your desk',v.name?esc(v.name):'')+sync(h);
o+=tiles([['Placed 2026',N(y.placed)],['Won this quarter',GBP(b.won_qtr)],['Open pipeline',GBP(b.pipeline_open)],['Active in play',N(md.active_in_play)],['Aging offers',N(md.aging_offers?md.aging_offers.length:null)],['Cold open roles',N(md.cold_open_roles)]]);
if(v.my_weekly){o+='<div class="sec">Your week'+(v.week_start?' <span class="cap" style="font-weight:400">from '+D(v.week_start)+'</span>':'')+'</div><div class="kpis">'+WK.map(function(r){var m=w[r[1]]||{},a=m.actual||0,t=m.target,met=t!=null&&a>=t;return '<div class="kpi'+(met?' met':'')+'"><span class="l">'+r[0]+'</span><span class="v"><b>'+N(a)+'</b>'+(t!=null?' / '+N(t):'')+'</span>'+(t!=null?'<div class="bar"><i style="width:'+pct(a,t)+'%"></i></div>':'')+'</div>'}).join('')+'</div>';
o+='<div class="note">BD and client calls count categorised Devyce calls only, so can undercount.'+(v.my_calls&&v.my_calls.logged?' You logged '+N(v.my_calls.logged)+' call'+(v.my_calls.logged===1?'':'s')+' this week and tagged '+N(v.my_calls.tagged)+' ('+Math.round(100*v.my_calls.tagged/v.my_calls.logged)+'%). Untagged calls cannot count toward these targets.':'')+'</div>'}
if(v.my_billing){var tg=b.quarterly_target,wq=b.won_qtr||0,sh=(tg!=null?tg-wq:null);
o+='<div class="sec">Your billing'+(v.quarter_start?' <span class="cap" style="font-weight:400">quarter from '+D(v.quarter_start)+'</span>':'')+'</div>';
o+='<div class="big">'+GBP(wq)+(tg!=null?' <small>of '+GBP(tg)+(tg?' · '+Math.round(100*wq/tg)+'%':'')+'</small>':'')+'</div>'+(tg!=null?'<div class="bar" style="margin-top:10px"><i style="width:'+pct(wq,tg)+'%"></i></div>':'');
o+='<dl class="rows">'+(sh!=null&&sh>0?'<dt>Still to bill</dt><dd>'+GBP(sh)+'</dd>':'')+'<dt>Open pipeline</dt><dd>'+GBP(b.pipeline_open)+'</dd></dl>'}
var ao=md.aging_offers||[],sl=md.stalled||[];
if(ao.length)o+='<div class="sec">Aging offers — chase today</div>'+table([['Candidate'],['Role'],['Days',1]],ao.map(function(x){return '<tr><td>'+esc(x.candidate)+'</td><td>'+esc(x.job_title)+'</td><td class="num">'+N(x.days)+'</td></tr>'}));
if(sl.length){var top=sl.slice(0,10);o+='<div class="sec">Stalled candidates'+(sl.length>10?' <span class="cap" style="font-weight:400">top 10 of '+sl.length+'</span>':'')+'</div>'+table([['Candidate'],['Role'],['Stage'],['Days',1]],top.map(function(x){return '<tr><td>'+esc(x.candidate)+'</td><td>'+esc(x.job_title)+'</td><td>'+esc(x.stage)+'</td><td class="num">'+N(x.days)+'</td></tr>'}))}
if(v.my_day&&!ao.length&&!sl.length)o+='<div class="sec">Needs attention</div><div class="note">Nothing aging or stalled on your open roles. '+N(md.cold_open_roles)+' cold role(s), '+N(md.placed_last_7d)+' placed in the last 7 days.</div>';
if(v.my_2026)o+='<div class="sec">Your 2026 funnel</div>'+funnel([['Shortlist',y.shortlist],['CV Sent',y.cv_sent],['Interview Request',y.interview_request],['1st Interview',y.first_interview],['Offered',y.offered],['Placed',y.placed]])+'<div class="note">2nd and 3rd interviews are not broken out per consultant here. Ask for your funnel report for those.</div>';
o+='<div class="sec">Firm — 2026</div><div class="note" style="margin-top:0">'+N(k.cv_2026)+' CV sent · '+N(k.placed_2026)+' placed · '+N(k.open_jobs)+' open jobs · '+GBP(k.open_pipeline)+' open pipeline</div>';
if(d.consultants&&d.consultants.length)o+=team(d);
return o+foot(ctx)}
function team(d){var cs=rank(d.consultants,function(c){return c.placed||0});return '<div class="sec">Team — by job owner</div>'+table([['Consultant'],['CV',1],['1st Int',1],['Placed',1]],cs.map(function(c){return '<tr><td>'+who(c)+'</td><td class="num">'+N(c.cv_sent)+'</td><td class="num">'+N(c.first_interview)+'</td><td class="num">'+N(c.placed)+'</td></tr>'}))}
function firmSummary(d,ctx){var k=d.kpis||{};return head('Octagon dashboard','2026')+sync(d.health)+tiles([['Placed 2026',N(k.placed_2026)],['Open jobs',N(k.open_jobs)],['Open pipeline',GBP(k.open_pipeline)],['Won',GBP(k.won)]])+foot(ctx)}
function firmFull(d,ctx){var k=d.kpis||{},f=d.funnel||{},pl=d.pipeline||[];
var o=head('Octagon dashboard','2026')+sync(d.health);
o+=tiles([['Placed 2026',N(k.placed_2026)],['Placed all-time',N(k.placed_all)],['Open jobs',N(k.open_jobs)],['Open pipeline',GBP(k.open_pipeline)],['Won',GBP(k.won)],['Candidates in pipeline',N(k.candidates_in_pipeline!=null?k.candidates_in_pipeline:k.candidates)],['Candidates on CRM',N(k.candidates_total)],['Clients',N(k.clients)],['Consultants',N(k.consultants)]]);
if(k.jobs_no_client)o+='<div class="note">'+N(k.jobs_no_client)+' of '+N(k.jobs)+' jobs have no resolved client and are left out of client reporting.</div>';
o+='<div class="sec">2026 funnel</div>'+funnel([['Shortlist',f.shortlist],['CV Sent',f.cv_sent],['Interview Request',f.interview_request],['1st Interview',f.first_interview],['2nd Interview',f.second_interview],['3rd Interview',f.third_interview],['Offered',f.offered],['Placed',f.placed]])+'<div class="note">Shortlist is only partly adopted, so it is not a valid top-of-funnel denominator.</div>';
if(pl.length)o+='<div class="sec">Deal pipeline</div>'+table([['Stage'],['Deals',1],['Value',1]],pl.map(function(p){return '<tr><td>'+esc(p.stage)+'</td><td class="num">'+N(p.deals)+'</td><td class="num">'+GBP(p.value)+'</td></tr>'}));
if(d.consultants&&d.consultants.length)o+=team(d);
return o+foot(ctx)}
window.OCT={name:'octagon-dashboard',title:'Octagon dashboard',full:true,
accept:function(d){return !!(d&&d.kpis)},
render:function(d,ctx){var v=d.viewer||{},me=!!(v.name&&!v.is_admin),full=ctx.mode==='fullscreen'||!ctx.canFull;
return me?(full?meFull(d,v,ctx):meSummary(d,v,ctx)):(full?firmFull(d,ctx):firmSummary(d,ctx))}};
`;

// ---- Confirm card: preview → confirm for the two-step write tools -------------------------------
const CONFIRM_JS = String.raw`
// Preview card for the two-step write tools. The server wraps every preview / result of these
// tools as { ...the tool's own JSON, _card: { tool, kind, confirm_args, draft_args } }.
var T={update_hiring_stage:['Move stage','Move stage'],assign_candidate:['Assign candidate','Assign'],manage_assignment:['Change assignment','Apply'],
add_note:['Add note','Add note'],create_candidate:['New candidate','Create candidate'],update_candidate:['Edit candidate','Save changes'],
create_job:['New job','Create job'],update_job:['Edit job','Save changes'],create_deal:['New deal','Create deal'],update_deal:['Edit deal','Save changes'],
log_activity:['Log activity','Log it'],manage_client:['Client record','Save'],pitch_candidate:['Record pitch','Record pitch'],
job_dpe:['Record DPE','Record DPE'],post_digest:['Post digest','Post to Slack'],delete_record:['Delete record',''],
send_email:['Email','Save draft'],push_tell:['Push & Tell email','Save to Outlook Drafts'],eow_email:['End-of-week email','Save to Outlook Drafts'],off_limit:['Off-limit status','Apply'],hotlist:['Hotlist','Apply'],inbox:['Inbox','Apply'],manage_tokens:['Revoke access','Revoke'],webhook_subscriptions:['Webhook','Apply'],draft_reply:['Reply draft','Save to Outlook Drafts'],dpe_email:['DPE email','Save to Outlook Drafts']};
var HIDE=/^(mode|action|instruction|acting_as|preview|_card|card_note|carried_forward|untouched|what_happens|reason_prompt|note|opted_out_check|changing|identifier|deal_id|job_id|target_type)$|(_slug|^slug|status_id|stage_id)$/;
var MONEY=/(^|_)(value|fee|salary|amount|salary_min|salary_max)$/;
var LONG=/^(body|email_text|note_preview|would_post|summary)$/;
var WARN=/^(warning|caution|billing_note)$/;
function lab(k){k=String(k).replace(/_/g,' ');return k.charAt(0).toUpperCase()+k.slice(1)}
function val(v,k){if(v==null||v==='')return '<span style="color:var(--o-text-3)">—</span>';if(typeof v==='boolean')return v?'Yes':'No';
if(k&&MONEY.test(k)&&!isNaN(Number(v))&&String(v).trim()!=='')return GBP(v);
if(typeof v==='string'&&/^\d{4}-\d{2}-\d{2}(T|$)/.test(v))return D(v);
if(Array.isArray(v))return esc(v.map(function(x){return typeof x==='object'?Object.values(x).join(' '):x}).join(', '));
if(typeof v==='object'){if('name' in v||'label' in v||'title' in v)return esc(v.name||v.label||v.title);return Object.keys(v).filter(function(j){return !HIDE.test(j)}).map(function(j){return esc(lab(j))+': '+val(v[j],j)}).join(' · ')}
return esc(v)}
function diff(b,a){var ks=Object.keys(a||{});return ks.filter(function(k){return !HIDE.test(k)}).map(function(k){var o=b&&b[k],n=a[k],same=JSON.stringify(o)===JSON.stringify(n);return '<dt>'+esc(lab(k))+'</dt><dd>'+(same?val(n,k):'<span class="from">'+val(o,k)+'</span><span class="arrow">→</span><span class="to">'+val(n,k)+'</span>')+'</dd>'}).join('')}
function fields(d){var o='',longs='',warns='';
if(d.current_stage||d.proposed_stage)o+='<dt>Stage</dt><dd><span class="from">'+val(d.current_stage&&(d.current_stage.label||d.current_stage.name))+'</span><span class="arrow">→</span><span class="to">'+val(d.proposed_stage&&d.proposed_stage.name)+'</span></dd>';
if(d.before&&d.after)o+=diff(d.before,d.after);
Object.keys(d).forEach(function(k){var v=d[k];if(v==null||HIDE.test(k)||k==='before'||k==='after'||k==='current_stage'||k==='proposed_stage')return;
if(WARN.test(k)){warns+='<div class="'+(d._card&&d._card.tool==='delete_record'?'danger':'warn')+'">'+esc(v)+'</div>';return}
if(LONG.test(k)&&typeof v==='string'){longs+='<div class="sec" style="margin:14px 0 8px;font-size:13px">'+esc(lab(k==='note_preview'?'note':k==='email_text'?'email':k))+'</div><div class="body" id="b-'+k+'">'+esc(v)+'</div>'+(v.split('\n').length>6||v.length>420?'<button class="link" data-act="more:'+k+'">Show all</button>':'');return}
if(typeof v==='object'&&!Array.isArray(v)&&!('name' in v||'label' in v||'title' in v)&&(k==='will_create'||k==='fields'||k==='changes'||k==='job'||k==='dpe_sent_date')){Object.keys(v).forEach(function(j){if(!HIDE.test(j)&&v[j]!=null&&v[j]!=='')o+='<dt>'+esc(lab(j))+'</dt><dd>'+val(v[j],j)+'</dd>'});return}
o+='<dt>'+esc(lab(k))+'</dt><dd>'+val(v,k)+'</dd>'});
return warns+(o?'<dl class="kv">'+o+'</dl>':'')+longs}
function foot(c,d,ctx){var t=c.tool,st=c.state;
if(st==='busy')return '<div class="foot"><span class="hint">Applying…</span></div>';
if(st==='done')return '<div class="foot"><div class="state ok">✓ '+esc(c.done_msg||'Done. Applied in RecruitCRM.')+'</div></div>';
if(st==='cancel')return '<div class="foot"><div class="state">Cancelled. Nothing was changed.</div></div>';
if(st==='fail')return '<div class="foot"><div class="state bad">'+esc(c.fail_msg||'That did not go through.')+'</div></div>';
if(t==='delete_record')return '<div class="foot"><span class="hint">Deleting is permanent. To go ahead, type the record\'s name back in the chat.</span><button class="btn btn-g" data-act="cancel">Cancel</button></div>';
if(!ctx.canTools||!c.confirm_args)return '<div class="foot"><span class="hint">Reply in the chat to confirm or change this.</span></div>';
var label=(T[t]||[])[1]||'Confirm',hint='Nothing changes until you confirm';
if(t==='send_email'){if(d.action==='send_email'){label='Save as draft instead';hint='To send it, confirm in the chat'}else hint='Saves a draft in RecruitCRM. Nothing is sent'}
if(t==='update_deal'&&d.after&&String(d.after.stage||'').toLowerCase()==='won')label='Mark as Won';
if(t==='draft_reply'||t==='dpe_email'||t==='push_tell'||t==='eow_email')hint='Saved as a draft. Nothing is sent';
if(t==='manage_tokens')hint='Switches their connector access off';
if(t==='post_digest')hint='Posts to Slack and cannot be unsent';
return '<div class="foot"><span class="hint">'+hint+'</span><button class="btn btn-g" data-act="cancel">Cancel</button><button class="btn btn-p" data-act="'+(t==='send_email'?'draft':'confirm')+'">'+esc(label)+'</button></div>'}
window.OCT={name:'octagon-confirm',title:'Octagon',full:false,
accept:function(d){return !!(d&&d._card)},
render:function(d,ctx){var c=d._card,t=c.tool,title=(T[t]||[lab(t)])[0];
if(c.kind==='error'){var already=d.error==='already_applied';return head(title)+'<div class="'+(already?'note':'warn')+'" style="margin-top:0">'+esc(d.message||d.error||'Something went wrong.')+'</div>'}
if(c.kind==='done')return head(title,'<span class="ok">Done</span>')+fields(d)+'<div class="foot"><div class="state ok">✓ Applied in RecruitCRM.</div></div>';
var chip=c.state==='done'?'<span class="ok">Done</span>':c.state==='cancel'?'Cancelled':c.state==='fail'?'Not applied':'<span class="chip">Preview</span>';
return head(title,chip)+fields(d)+foot(c,d,ctx)},
act:function(name,d,api){var c=d._card;
if(name.indexOf('more:')===0){var el=document.getElementById('b-'+name.slice(5));if(el)el.classList.toggle('open');return}
if(c.state==='busy'||c.state==='done')return;
var tell=function(text){try{api.app.updateModelContext({content:[{type:'text',text:text}]})}catch(e){}};
if(name==='cancel'){c.state='cancel';api.set(d);tell('The recruiter pressed Cancel on the '+c.tool+' preview card. Nothing was applied. Do not apply this change unless they ask again.');return}
var args=name==='draft'?c.draft_args:c.confirm_args;if(!args)return;
c.state='busy';api.set(d);
api.app.callServerTool({name:c.tool,arguments:args}).then(function(r){var sc=r&&r.structuredContent,txt=r&&r.content&&r.content[0]&&r.content[0].text,res=sc||null;
if(!res&&txt){try{res=JSON.parse(txt)}catch(e){res={message:txt}}}
var err=r&&r.isError||(res&&res.error);
if(err){c.state='fail';c.fail_msg=(res&&(res.message||res.error))||'That did not go through.';api.set(d);tell('The recruiter pressed confirm on the '+c.tool+' preview card, but it failed: '+JSON.stringify(res||txt).slice(0,1200)+'. Nothing was applied.');return}
c.state='done';c.done_msg=name==='draft'?'Draft saved. Nothing was sent.':(c.tool==='post_digest'?'Posted to Slack.':(['draft_reply','dpe_email','push_tell','eow_email'].indexOf(c.tool)>=0)?'Saved to your Outlook Drafts.':'Done. Applied in RecruitCRM.');api.set(d);
tell('The recruiter confirmed the '+c.tool+' change with the preview card button and it has ALREADY BEEN APPLIED'+(name==='draft'?' (saved as a draft, not sent)':'')+'. Result: '+JSON.stringify(res).slice(0,1500)+'. Do not call '+c.tool+' with confirm=true again for this change.')})
.catch(function(e){c.state='fail';c.fail_msg='Could not reach the connector. Nothing was changed.';api.set(d)})}};
// DPE scoring screen (job_dpe): the consultant picks each score; the card shows the live total and
// banded grade, re-previews on the server after any change (so what is confirmed is always what
// the server previewed), then records it with the confirm button.
(function(){var B=window.OCT,baseRender=B.render,baseAct=B.act;
var SC=[['urgency','Urgency'],['cooperation','Cooperation'],['track_record','Track record'],['commitment','Commitment'],['process_quality','Process quality'],['positioning','Positioning']];
function band(t){return t>=25?'A':t>=19?'B':'C'}
function st(c){if(!c.dpe){var a=c.args||c.confirm_args||{};c.dpe={};SC.forEach(function(s){if(a[s[0]]!=null)c.dpe[s[0]]=Number(a[s[0]])});if(a.findability!=null)c.dpe.findability=Number(a.findability);if(a.grade)c.dpe.grade=String(a.grade).toUpperCase()}return c.dpe}
function seg(key,vals,cur){return '<div class="seg2">'+vals.map(function(v){return '<button class="'+(String(cur)===String(v)?'on':'')+'" data-act="dpe:'+key+':'+v+'" aria-pressed="'+(String(cur)===String(v))+'">'+v+'</button>'}).join('')+'</div>'}
B.render=function(d,ctx){var c=d._card;if(c.tool!=='job_dpe'||c.state==='done'||c.kind==='done'||(c.kind==='error'&&['grade_choice_needed','scores_needed'].indexOf(d.error)<0))return baseRender(d,ctx);
 var s=st(c),all=SC.every(function(x){return s[x[0]]>=1}),tot=all?SC.reduce(function(a,x){return a+s[x[0]]},0):null,sug=tot!=null?band(tot):null,gr=s.grade||(c.kind==='preview'&&!c.dirty?d.job_grade:null)||sug;
 var o=head('Record DPE'+(d.job&&d.job.title?' · '+esc(d.job.title):''),c.state==='busy'?'Checking…':'<span class="chip">'+(c.dirty||c.kind!=='preview'?'Draft':'Preview')+'</span>');
 if(c.kind==='error')o+='<div class="warn">'+esc(d.error==='grade_choice_needed'?'The scores suggest '+d.suggested_grade+' but the job is graded '+d.current_grade+'. Pick the grade it should be.':'Score every factor from 1 to 5.')+'</div>';
 o+='<div class="dpe">'+SC.map(function(x){return '<span class="l">'+x[1]+'</span>'+seg(x[0],[1,2,3,4,5],s[x[0]])}).join('')+'<span class="l">Findability <span class="m">(optional, not in total)</span></span>'+seg('findability',[1,2,3],s.findability)+'</div>';
 o+='<div class="tot"><div><div class="l">Total</div><div class="v">'+(tot!=null?tot:'—')+'<small> / 30</small></div></div><div><div class="l">Bands suggest</div><div class="v">'+(sug||'—')+'</div></div><div><div class="l">Grade</div>'+seg('grade',['A','B','C'],gr)+'</div></div><div class="note">A 25–30 · B 19–24 · C under 19. You decide the grade.</div>';
 if(c.kind==='preview'&&!c.dirty&&(d.changes||[]).length)o+='<div class="sec" style="font-size:13px">What will be written</div><dl class="kv">'+d.changes.map(function(r){return '<dt>'+esc(r.field)+'</dt><dd><span class="from">'+val(r.current)+'</span><span class="arrow">→</span><span class="to">'+val(r.new)+'</span></dd>'}).join('')+'</dl>';
 if(c.state==='fail')o+='<div class="foot"><div class="state bad">'+esc(c.fail_msg||'That did not go through.')+'</div></div>';
 else if(!ctx.canTools)o+='<div class="foot"><span class="hint">Reply in the chat to confirm or change the scores.</span></div>';
 else if(c.dirty||c.kind!=='preview')o+='<div class="foot"><span class="hint">Check the change before recording</span><button class="btn btn-p" data-act="dpe-preview"'+(all?'':' disabled')+'>Update preview</button></div>';
 else o+='<div class="foot"><span class="hint">Nothing changes until you confirm</span><button class="btn btn-g" data-act="cancel">Cancel</button><button class="btn btn-p" data-act="confirm">Record DPE</button></div>';
 return o};
B.act=function(name,d,api){var c=d._card;if(c.tool!=='job_dpe'||(name.indexOf('dpe')!==0))return baseAct(name,d,api);if(c.state==='busy')return;var s=st(c);
 if(name.indexOf('dpe:')===0){var p=name.split(':'),k=p[1],v=p[2];if(k==='grade')s.grade=v;else s[k]=Number(v);c.dirty=true;api.set(d);return}
 if(name==='dpe-preview'){var a={};var base=c.args||{};Object.keys(base).forEach(function(k){a[k]=base[k]});Object.keys(s).forEach(function(k){a[k]=s[k]});delete a.confirm;delete a.card_nonce;c.state='busy';api.set(d);
  api.app.callServerTool({name:'job_dpe',arguments:a}).then(function(r){var n=r&&r.structuredContent;if(!n){try{n=JSON.parse(r.content[0].text)}catch(e){}}
   if(n&&n._card){n._card.dpe=s;n._card.dirty=false;api.set(n)}else{c.state='fail';c.fail_msg='Could not refresh the preview.';api.set(d)}}).catch(function(){c.state='fail';c.fail_msg='Could not reach the connector. Nothing was changed.';api.set(d)})}};
})();

`;

// ---- Report views for the read tools -----------------------------------------------------------
const REPORT_JS = String.raw`// Report views for the read tools. The server wraps each result as { ...the tool's own JSON,
// _view: { tool } }. Each renderer gives an inline summary (at most a handful of figures) and,
// where there is more, a full view for fullscreen.
function P1(f){return f==null?'—':(Math.round(f*1000)/10).toFixed(1)+'%'}   // fraction 0-1
function PC(p){return p==null?'—':(Math.round(p*10)/10).toFixed(1)+'%'}     // already x100
function win(w){if(!w)return '';var f=w.from,t=w.to||w.to_exclusive;return (f?D(f):'')+(t?(String(t).indexOf('2100')===0?' – to date':' – '+D(t)+' excl.'):'')}
function UX(s){if(!s)return '';var d=new Date(Number(s)*1000);return isNaN(d)?'':d.toLocaleDateString('en-GB',{month:'short',year:'numeric'})}
function tiles(t){return '<div class="tiles">'+t.map(function(x){return '<div class="tile"><div class="l">'+x[0]+'</div><div class="v">'+x[1]+'</div>'+(x[2]?'<div class="s">'+x[2]+'</div>':'')+'</div>'}).join('')+'</div>'}
function bars(rows,fmt){var mx=Math.max.apply(null,rows.map(function(r){return r[1]||0}).concat([1]));fmt=fmt||N;
return '<div class="fun">'+rows.map(function(r){return '<span class="l">'+r[0]+'</span><span class="t"><i style="width:'+Math.round(100*(r[1]||0)/mx)+'%'+(r[2]?';background:'+r[2]:'')+'"></i></span><span class="n">'+fmt(r[1]||0)+'</span>'}).join('')+'</div>'}
function vbars(rows,hi){var mx=Math.max.apply(null,rows.map(function(r){return r[1]||0}).concat([1]));
return '<div class="vb">'+rows.map(function(r){return '<div class="c" title="'+esc(r[0])+': '+N(r[1])+'"><span class="n">'+N(r[1])+'</span><i style="height:'+Math.max(2,Math.round(100*(r[1]||0)/mx))+'%'+(hi&&hi(r)?';background:var(--o-action)':'')+'"></i><span class="l">'+esc(r[0])+'</span></div>'}).join('')+'</div>'}
function tbl(cols,rows,max){var rs=max?rows.slice(0,max):rows;return '<div class="tw"><table><tr>'+cols.map(function(c){return '<th'+(c[2]?' class="num"':'')+'>'+c[0]+'</th>'}).join('')+'</tr>'+rs.map(function(r){return '<tr>'+cols.map(function(c){return '<td'+(c[2]?' class="num"':'')+'>'+c[1](r)+'</td>'}).join('')+'</tr>'}).join('')+'</table></div>'+(max&&rows.length>max?'<div class="note">Top '+max+' of '+rows.length+'.</div>':'')}
function sec(t,cap){return '<div class="sec">'+t+(cap?' <span class="cap" style="font-weight:400">'+cap+'</span>':'')+'</div>'}
function more(rows,max,label){return rows.length>max?'<div class="note">'+(rows.length-max)+' more '+label+' in the full view.</div>':''}
function nm(r){return who(r)}
var ST=['Shortlist','CV Sent','Interview Request','1st Interview','2nd Interview','3rd Interview','Offered','Placed'];
function list(items,line,max){return '<div class="li">'+items.slice(0,max||items.length).map(function(x){return '<div class="row">'+line(x)+'</div>'}).join('')+'</div>'}
var R={
my_day:{title:function(d){return 'My day'},cap:function(d){return d.consultant?esc(d.consultant):''},
 sum:function(d){if(d.error)return '<div class="note" style="margin-top:0">'+(d.error==='consultant not found'?'This login has no recruiter desk, so there is no attention list.':esc(d.error))+(d.inbox_line?' '+esc(d.inbox_line):'')+'</div>';
  var ao=d.aging_offers||[],sl=(d.stalled||[]).slice().sort(function(a,b){return b.days-a.days});
  return tiles([['Aging offers',N(ao.length)],['Stalled',N(sl.length)],['Cold roles',N(d.cold_open_roles)],['Placed, last 7 days',N(d.placed_last_7d)]])
   +(ao.length||sl.length?'<div class="li" style="margin-top:12px">'+ao.slice(0,2).map(function(x){return '<div class="row"><span>'+esc(x.candidate)+' · '+esc(x.job_title)+'</span><span class="tag">Offer '+N(x.days)+'d</span></div>'}).join('')+sl.slice(0,3-Math.min(2,ao.length)).map(function(x){return '<div class="row"><span>'+esc(x.candidate)+' · '+esc(x.job_title)+'</span><span class="tag">'+esc(x.stage)+' '+N(x.days)+'d</span></div>'}).join('')+'</div>':'<div class="note">Nothing aging or stalled. '+N(d.active_in_play)+' in play.</div>')},
 full:function(d){if(d.error)return null;var ao=d.aging_offers||[],sl=(d.stalled||[]).slice().sort(function(a,b){return b.days-a.days});
  return tiles([['Aging offers',N(ao.length)],['Stalled',N(sl.length)],['Cold roles',N(d.cold_open_roles)],['Active in play',N(d.active_in_play)],['Placed, last 7 days',N(d.placed_last_7d)]])
   +(ao.length?sec('Aging offers — chase today')+tbl([['Candidate',function(x){return esc(x.candidate)}],['Role',function(x){return esc(x.job_title)}],['Days',function(x){return N(x.days)},1]],ao):'')
   +(sl.length?sec('Stalled candidates')+tbl([['Candidate',function(x){return esc(x.candidate)}],['Role',function(x){return esc(x.job_title)}],['Stage',function(x){return esc(x.stage)}],['Days',function(x){return N(x.days)},1]],sl):'')}},
stalled_report:{title:function(){return 'What is slipping'},cap:function(){return 'open roles'},
 sum:function(d){var ao=d.aging_offers||[],sl=d.stalled||[];return tiles([['Aging offers',N(ao.length)],['Stalled',N(sl.length)],['Longest stall',N(Math.max.apply(null,sl.map(function(x){return x.days_stalled}).concat([0])))+' days']])+list(ao.slice().sort(function(a,b){return b.days_since_offer-a.days_since_offer}).slice(0,3),function(x){return '<span>'+esc(x.candidate)+' · '+esc(x.job_title)+' <span style="color:var(--o-text-3)">'+esc(x.consultant)+'</span></span><span class="tag">Offer '+N(x.days_since_offer)+'d</span>'})},
 full:function(d){var ao=(d.aging_offers||[]).slice().sort(function(a,b){return b.days_since_offer-a.days_since_offer}),sl=(d.stalled||[]).slice().sort(function(a,b){return b.days_stalled-a.days_stalled});var t=d.thresholds||{};
  return tiles([['Aging offers',N(ao.length),'out '+N(t.offer_days)+'+ days'],['Stalled',N(sl.length),'no move '+N(t.stall_days)+'+ days']])+(ao.length?sec('Aging offers')+tbl([['Candidate',function(x){return esc(x.candidate)}],['Role',function(x){return esc(x.job_title)}],['Owner',function(x){return esc(x.consultant)}],['Days',function(x){return N(x.days_since_offer)},1]],ao):'')
  +(sl.length?sec('Stalled candidates')+tbl([['Candidate',function(x){return esc(x.candidate)}],['Role',function(x){return esc(x.job_title)}],['Stage',function(x){return esc(x.stage)}],['Owner',function(x){return esc(x.consultant)}],['Days',function(x){return N(x.days_stalled)},1]],sl):'')}},
cold_jobs:{title:function(){return 'Cold roles'},cap:function(d){return 'no activity '+N(d.threshold_days)+'+ days'},
 sum:function(d){var j=d.jobs||[];return tiles([['Cold open roles',N(d.cold_count!=null?d.cold_count:j.length)],['Never had activity',N(j.filter(function(x){return x.last_activity==null}).length)]])+list(j.slice(0,3),function(x){return '<span>'+esc(x.job_title)+' · '+esc(x.client)+'</span><span class="tag">'+(x.days_since_activity==null?'no activity':N(x.days_since_activity)+'d')+'</span>'})},
 full:function(d){var j=d.jobs||[];return tbl([['Role',function(x){return esc(x.job_title)}],['Client',function(x){return esc(x.client)}],['Owner',function(x){return esc(x.consultant)}],['Opened',function(x){return D(x.opened)}],['Last activity',function(x){return x.last_activity?D(x.last_activity):'never'}],['Days',function(x){return x.days_since_activity==null?'—':N(x.days_since_activity)},1]],j)+(d.cold_count>j.length?'<div class="note">Showing '+j.length+' of '+N(d.cold_count)+'.</div>':'')}},
awaiting_feedback_report:{title:function(){return 'No feedback logged'},cap:function(d){return 'interviewed '+N(d.window&&d.window.min_days)+'+ days ago'},
 sum:function(d){var c=(d.candidates||[]).slice().sort(function(a,b){return b.days_since-a.days_since});return tiles([['Waiting',N(d.total!=null?d.total:c.length)],['Longest',N(c[0]&&c[0].days_since)+' days']])+list(c.slice(0,3),function(x){return '<span>'+esc(x.candidate)+' · '+esc(x.job)+'</span><span class="tag">'+N(x.days_since)+'d</span>'})+'<div class="note">Nothing logged since the interview. That is silence in the system, not proof feedback was not given.</div>'},
 full:function(d){var c=(d.candidates||[]).slice().sort(function(a,b){return b.days_since-a.days_since});return tbl([['Candidate',function(x){return esc(x.candidate)}],['Role',function(x){return esc(x.job)}],['Owner',function(x){return esc(x.consultant)}],['Interviewed',function(x){return D(x.interviewed)}],['Days',function(x){return N(x.days_since)},1]],c)+'<div class="note">Nothing logged since the interview. That is silence in the system, not proof feedback was not given.</div>'}},
interview_requests_unbooked:{title:function(){return 'Interview requests not booked'},cap:function(d){return 'last '+N(d.window&&d.window.within_days)+' days'},
 sum:function(d){var r=(d.requests||[]).slice().sort(function(a,b){return b.days_waiting-a.days_waiting});return tiles([['Waiting on a date',N(d.total!=null?d.total:r.length)],['Longest wait',N(r[0]&&r[0].days_waiting)+' days']])+list(r.slice(0,3),function(x){return '<span>'+esc(x.candidate)+' · '+esc(x.job)+'</span><span class="tag">'+N(x.days_waiting)+'d</span>'})},
 full:function(d){var r=(d.requests||[]).slice().sort(function(a,b){return b.days_waiting-a.days_waiting});return tbl([['Candidate',function(x){return esc(x.candidate)}],['Role',function(x){return esc(x.job)}],['Owner',function(x){return esc(x.consultant)}],['Requested',function(x){return D(x.requested)}],['Days',function(x){return N(x.days_waiting)},1]],r)}},
new_jobs_report:{title:function(){return 'New jobs'},cap:function(d){return win(d.window)},
 sum:function(d){var t=d.totals||{},j=d.jobs||[];return tiles([['New jobs',N(t.new_jobs)],['Job order form logged',PC(t.form_completion_pct),N(t.with_job_order_form)+' of '+N(t.new_jobs)],['Missing a form',N(t.missing_job_order_form)]])+list(j.filter(function(x){return !x.job_order_form}).slice(0,3),function(x){return '<span>'+esc(x.title)+' <span style="color:var(--o-text-3)">'+esc(x.owner)+'</span></span><span class="tag">no form</span>'})+'<div class="note">A missing form means the note was not logged. Chase it; it does not prove the call did not happen.</div>'},
 full:function(d){var j=d.jobs||[];return tbl([['Role',function(x){return esc(x.title)}],['Owner',function(x){return esc(x.owner)}],['Created',function(x){return D(x.created)}],['Status',function(x){return esc(x.status)}],['Form',function(x){return x.job_order_form?'<span class="ok">Logged</span>':'Missing'}]],j)+sec('By consultant')+tbl([['Consultant',nm],['New',function(x){return N(x.new_jobs)},1],['With form',function(x){return N(x.with_form)},1],['Missing',function(x){return N(x.missing_form)},1]],d.by_consultant||[])}},
activity_report:{title:function(d){return d.kind==='tasks'?'Tasks':'Meetings and visits'},cap:function(d){return win(d.window)},
 sum:function(d){var it=d.items||[];return tiles([[d.kind==='tasks'?'Tasks':'Meetings',N(d.count)+(d.count_is_capped?'+':'')],['Typed',N(it.filter(function(x){return x.type}).length)]])+list(it.slice(0,3),function(x){return '<span>'+esc(x.title)+'</span><span class="tag">'+(x.start?D(x.start)+' '+esc(String(x.start).slice(11,16)):'')+'</span>'})},
 full:function(d){var it=d.items||[];return tbl([['When',function(x){return x.start?D(x.start)+' '+esc(String(x.start).slice(11,16)):''}],['What',function(x){return esc(x.title)}],['Type',function(x){return x.type?esc(x.type):'—'}]],it)+(d.count_is_capped?'<div class="note">RecruitCRM returns at most '+N(it.length)+', so there may be more.</div>':'')}},
funnel_report:{title:function(){return 'Funnel'},cap:function(d){return win(d.window)+(d.filters&&d.filters.consultant?' · '+esc(d.filters.consultant):'')+(d.filters&&d.filters.team?' · '+esc(d.filters.team):'')},
 sum:function(d){var t=d.totals||{};return bars([['CV Sent',t.cv_sent],['Interview Request',t.interview_request],['1st Interview',t.first_interview],['2nd Interview',t.second_interview],['3rd Interview',t.third_interview],['Offered',t.offered],['Placed',t.placed]])+'<div class="note">CV→placed '+P1(t.cv_to_placed_pct)+' · CV→1st interview '+P1(t.cv_to_first_interview_pct)+' · 1st interview→offer '+P1(t.first_interview_to_offer_pct)+'</div>'},
 full:function(d){var t=d.totals||{},cs=rank(d.consultants||[],function(c){return c.placed||0});return R.funnel_report.sum(d)+tiles([['CV→placed',P1(t.cv_to_placed_pct)],['CV→interview',P1(t.cv_to_interview_pct)],['CV→1st interview',P1(t.cv_to_first_interview_pct)],['1st interview→offer',P1(t.first_interview_to_offer_pct)]])
  +(cs.length?sec('By consultant')+tbl([['Consultant',nm],['CV',function(c){return N(c.cv_sent)},1],['Int req',function(c){return N(c.interview_request)},1],['1st',function(c){return N(c.first_interview)},1],['2nd',function(c){return N(c.second_interview)},1],['3rd',function(c){return N(c.third_interview)},1],['Offered',function(c){return N(c.offered)},1],['Placed',function(c){return N(c.placed)},1],['CV→placed',function(c){return P1(c.cv_to_placed_pct)},1]],cs):'')}},
consultant_leaderboard:{title:function(d){return 'Leaderboard'},cap:function(d){return 'by '+esc(String(d.ranked_by||'placed').replace(/_/g,' '))+' · '+win(d.window)},
 sum:function(d){var k=d.ranked_by||'placed',l=d.leaderboard||[];return bars(l.slice(0,6).map(function(r){return [esc(r.name),r[k]]}))+more(l,6,'consultants')},
 full:function(d){var k=d.ranked_by||'placed',l=d.leaderboard||[];return bars(l.map(function(r){return [esc(r.name),r[k]]}))+sec('Detail')+tbl([['Consultant',nm],['Placed',function(c){return N(c.placed)},1],['CV sent',function(c){return N(c.cv_sent)},1],['1st interview',function(c){return N(c.first_interview)},1],['CV→placed',function(c){return P1(c.cv_to_placed_pct)},1]],l)}},
client_report:{title:function(){return 'Accounts'},cap:function(d){return win(d.window)},
 sum:function(d){var c=d.clients||[];return bars(c.slice(0,5).map(function(r){return [esc(r.client),r.cv_sent]}))+'<div class="note">CVs sent. '+(c[0]?esc(c[0].client)+': '+N(c[0].placed)+' placed, CV→placed '+PC(c[0].cv_to_placed_pct)+'.':'')+'</div>'+more(c,5,'accounts')},
 full:function(d){return tbl([['Client',function(r){return esc(r.client)}],['CV sent',function(r){return N(r.cv_sent)},1],['1st interview',function(r){return N(r.first_interview)},1],['Placed',function(r){return N(r.placed)},1],['CV→placed',function(r){return PC(r.cv_to_placed_pct)},1],['Open / total jobs',function(r){return N(r.open_jobs)+' / '+N(r.total_jobs)},1]],d.clients||[])}},
bd_report:{title:function(){return 'BD pipeline'},cap:function(){return 'company status'},
 sum:function(d){var o=['Prospect','Engaged','Client','Passive','Blocklisted','Do not contact'],b=(d.by_status||[]).slice().sort(function(a,c){var i=o.indexOf(a.status),j=o.indexOf(c.status);return (i<0?9:i)-(j<0?9:j)});return bars(b.map(function(r){return [esc(r.status),r.companies]}))+'<div class="note">'+N(d.classified)+' of '+N(d.total_companies)+' companies have a status.</div>'}},
rejection_report:{title:function(){return 'Rejections'},cap:function(d){return win(d.window)},
 sum:function(d){var t=d.totals||{};return tiles([['CVs sent',N(t.cv_sent)],['Rejected by client',N(t.rejected_by_client),PC(t.client_rejection_rate_pct)+' of CVs sent'],['Screened out by us',N(t.rejected_by_consultant)]])},
 full:function(d){return R.rejection_report.sum(d)+sec('By client')+tbl([['Client',function(r){return esc(r.client)}],['CV sent',function(r){return N(r.cv_sent)},1],['Rejected',function(r){return N(r.rejected_by_client)},1],['Rate',function(r){return PC(r.client_rejection_rate_pct)},1]],d.by_client||[])+sec('By consultant')+tbl([['Consultant',nm],['CV sent',function(r){return N(r.cv_sent)},1],['Client rejected',function(r){return N(r.rejected_by_client)},1],['We screened',function(r){return N(r.rejected_by_consultant)},1],['Client rate',function(r){return PC(r.client_rejection_rate_pct)},1]],d.by_consultant||[])}},
call_activity:{title:function(){return 'Calls'},cap:function(d){return win(d.window)},
 sum:function(d){var t=d.totals||{};return tiles([['Calls',N(t.calls),N(t.outgoing)+' out · '+N(t.incoming)+' in'],['Connect rate',P1(t.connect_rate)],['Talk time',N(Math.round(t.talk_minutes||0))+' min']])},
 full:function(d){var c=(d.by_category||[]).slice().sort(function(a,b){return b.calls-a.calls});return R.call_activity.sum(d)+sec('By category')+bars(c.map(function(r){return [esc(r.category),r.calls,r.category==='(uncategorised)'?'var(--o-text-3)':null]}))+'<div class="note">BD and client call KPIs count categorised calls only.</div>'+sec('By consultant')+tbl([['Consultant',nm],['Calls',function(r){return N(r.calls)},1],['Connected',function(r){return N(r.connected)},1],['Connect rate',function(r){return P1(r.connect_rate)},1],['Talk min',function(r){return N(Math.round(r.talk_minutes||0))},1]],rank(d.by_consultant||[],function(r){return r.calls}))}},
call_hours_report:{title:function(){return 'Calls by hour'},cap:function(d){return win(d.window)},
 sum:function(d){var t=d.totals||{},e=(d.window&&d.window.evening_from_hour)||17,h={};(d.by_hour||[]).forEach(function(r){h[r.hour]=r.calls});var rows=[];for(var i=8;i<=21;i++)rows.push([String(i),h[i]||0,i]);
  return vbars(rows,function(r){return r[2]>=e})+'<div class="note">'+N(t.evening_calls)+' calls from '+e+':00 ('+PC(t.evening_pct)+' of '+N(t.calls)+'). Counts every call, tagged or not.</div>'},
 full:function(d){return R.call_hours_report.sum(d)+sec('Evening calls by consultant')+tbl([['Consultant',nm],['All calls',function(r){return N(r.calls)},1],['Evening',function(r){return N(r.evening_calls)},1],['Evening connected',function(r){return N(r.evening_connected)},1]],rank(d.by_consultant||[],function(r){return r.evening_calls}))}},
fee_analysis:{title:function(){return 'Fees'},cap:function(d){return win(d.window)},
 sum:function(d){var t=d.totals||{},f=d.fee_percentage||{};return tiles([['Median fee',GBP(t.fee_median),N(t.won_deals)+' Won deals'],['Fee % (median)',PC(f.median),'middle half '+PC(f.p25)+'–'+PC(f.p75)],['Forecast, open roles',GBP(d.forecast_open_roles)]])},
 full:function(d){var t=d.totals||{},s=d.annual_salary||{};return R.fee_analysis.sum(d)+tiles([['Total fees',GBP(t.fee_total)],['Average fee',GBP(t.fee_avg)],['Median salary placed',GBP(s.median),GBP(s.p25)+'–'+GBP(s.p75)]])+sec('By consultant')+tbl([['Consultant',nm],['Won deals',function(r){return N(r.won_deals)},1],['Total',function(r){return GBP(r.fee_total)},1],['Median fee',function(r){return GBP(r.fee_median)},1],['Median fee %',function(r){return PC(r.fee_pct_median)},1]],rank(d.by_consultant||[],function(r){return r.fee_total}))+'<div class="note">Median, not mean: a few deals carry a mistyped percentage.</div>'}},
placements_report:{title:function(){return 'Placements'},cap:function(d){return win(d.window)},
 sum:function(d){return tiles([['Placed',N(d.placed_total)],['Won deals closing in window',GBP(d.won_revenue)]])+bars((d.by_consultant||[]).slice(0,5).map(function(r){return [esc(r.name),r.placed]}))+'<div class="note">Not billing. For what the placements are worth, ask for placements with fees.</div>'},
 full:function(d){return R.placements_report.sum(d)+sec('By client')+tbl([['Client',function(r){return esc(r.client)}],['Placed',function(r){return N(r.placed)},1]],d.by_client||[])}},
placements_with_fees:{title:function(){return 'Placements and fees'},cap:function(d){return win(d.window)},
 sum:function(d){var t=d.totals||{};return tiles([['Placed',N(t.placed)],['Value of placements',GBP(t.total_value)],['Missing a Won deal',N(t.missing_won_deal)]])+'<div class="note">Valued from each job\'s Won deal. Not confirmed billing.</div>'},
 full:function(d){return R.placements_with_fees.sum(d)+tbl([['Placed',function(r){return D(r.placed_on)}],['Role',function(r){return esc(r.candidate_job)}],['Consultant',function(r){return esc(r.consultant)}],['Fee',function(r){return r.deal_value==null?'—':GBP(r.deal_value)},1],['Fee %',function(r){return r.fee_pct==null?'—':PC(r.fee_pct)},1]],d.placements||[])+sec('By consultant')+tbl([['Consultant',nm],['Placed',function(r){return N(r.placed)},1],['Value',function(r){return GBP(r.value)},1]],d.by_consultant||[])}},
invoices_report:{title:function(){return 'Invoices'},cap:function(d){return win(d.window)},
 sum:function(d){var iv=d.invoices||[];return tiles([['Invoices',N(d.count)],['Total',GBP(d.total_value)]])+(iv.length?'':'<div class="note">'+esc(d.note||'No invoices in this window.')+'</div>')},
 full:function(d){var iv=d.invoices||[];if(!iv.length)return null;var ks=Object.keys(iv[0]).filter(function(k){return !/slug|_id$|^id$/.test(k)}).slice(0,6);return R.invoices_report.sum(d)+tbl(ks.map(function(k){return [esc(k.replace(/_/g,' ')),function(r){var v=r[k];return /total|amount|value/.test(k)?GBP(v):/date/.test(k)?D(v):esc(v)},/total|amount|value/.test(k)]}),iv)}},
notes_kpi:{title:function(){return 'Notes KPIs'},cap:function(d){return win(d.window)},
 sum:function(d){var h=d.headline||{};return tiles([['Leads',N(h.leads)],['Internal interviews',N(h.internal_interviews)],['Job order forms',N(h.job_order_forms)]])+'<div class="note">Counts only notes logged with that type. '+N(h.all_notes)+' notes in all.</div>'},
 full:function(d){return R.notes_kpi.sum(d)+sec('By consultant')+tbl([['Consultant',nm],['Leads',function(r){return N(r.leads)},1],['Internal interviews',function(r){return N(r.internal_interviews)},1],['Job order forms',function(r){return N(r.job_order_forms)},1],['All notes',function(r){return N(r.all_notes)},1]],rank(d.by_consultant||[],function(r){return r.leads}))+sec('By note type')+bars((d.by_type||[]).map(function(r){return [esc(String(r.type).trim()),r.count]}))}},
time_to_fill:{title:function(){return 'Time to fill'},cap:function(d){return win(d.window)},
 sum:function(d){var x=d.days||{};return tiles([['Median',N(x.median)+' days'],['Average',N(x.avg)+' days'],['Range',N(x.min)+'–'+N(x.max)+' days'],['Placements',N(d.placements_measured)]])},
 full:function(d){return R.time_to_fill.sum(d)+sec('By consultant')+tbl([['Consultant',nm],['Placements',function(r){return N(r.placements)},1],['Median days',function(r){return N(r.median_days)},1],['Average days',function(r){return N(r.avg_days)},1]],rank(d.by_consultant||[],function(r){return -(r.median_days||0)}))}},
match_candidates:{title:function(){return 'Matches'},cap:function(d){return (d.skills_searched||[]).map(esc).join(', ')},
 sum:function(d){var c=d.candidates||[];if(!c.length)return '<div class="note" style="margin-top:0">No matches.</div>';
  return '<div class="car">'+c.slice(0,8).map(function(x){var loc=[x.city,x.country].filter(Boolean).join(', ');return '<div class="cc"><div class="t">'+esc(x.name)+'</div><div class="m">'+esc((x.recent_roles||[])[0]||'Role not recorded')+'</div><div class="m">'+esc(loc||'Location not recorded')+'</div><div class="chips">'+(x.matched_skills||[]).slice(0,5).map(function(s){return '<span class="chip">'+esc(s)+'</span>'}).join('')+'</div><button class="btn btn-g" data-act="ask:'+esc(x.name)+'">Next step</button></div>'}).join('')+'</div>'
  +'<div class="note">'+N(d.match_count)+' candidates match at least one skill'+(d.off_limit_excluded?'. '+N(d.off_limit_excluded)+' off-limit candidates left out':'')+'.</div>'}},
job_pipeline:{title:function(d){var j=d.jobs||[];return j.length===1?esc(j[0].job_title):'Jobs matching "'+esc(d.query)+'"'},cap:function(d){var j=d.jobs||[];return j.length===1?esc(j[0].status)+(j[0].job_id?' · job '+esc(j[0].job_id):''):N(d.matched)+' found'},
 sum:function(d){var j=d.jobs||[];if(!j.length)return '<div class="note" style="margin-top:0">No job found.</div>';
  if(j.length>1)return list(j.slice(0,5),function(x){return '<span>'+esc(x.job_title)+' <span style="color:var(--o-text-3)">'+esc(x.status)+'</span></span><span class="tag">'+N(x.candidates_in_play)+' in play</span>'})+more(j,5,'jobs');
  var c=j[0].candidates||[],by={};c.forEach(function(x){by[x.current_stage]=(by[x.current_stage]||0)+1});var rows=ST.filter(function(s){return by[s]}).map(function(s){return [s,by[s]]});
  return tiles([['In play',N(j[0].candidates_in_play)],['Furthest stage',rows.length?rows[rows.length-1][0]:'—']])+(rows.length?bars(rows):'<div class="note">No candidates on it yet.</div>')},
 full:function(d){var j=d.jobs||[];if(j.length!==1)return null;var c=j[0].candidates||[],cols=ST.concat(['Other']),by={};c.forEach(function(x){var k=ST.indexOf(x.current_stage)>=0?x.current_stage:'Other';(by[k]=by[k]||[]).push(x)});
  return '<div class="board">'+cols.filter(function(s){return by[s]}).map(function(s){return '<div class="col"><div class="ch">'+s+' <span>'+by[s].length+'</span></div>'+by[s].map(function(x){return '<div class="bc"><div>'+esc(x.name)+'</div><div class="m">'+(s==='Other'?esc(x.current_stage)+' · ':'')+D(x.last_activity)+'</div></div>'}).join('')+'</div>'}).join('')+'</div>'+(j[0].candidates_in_play>c.length?'<div class="note">Showing '+c.length+' of '+N(j[0].candidates_in_play)+'. Ask for more if needed.</div>':'')+'<div class="note">To move someone, ask Claude. You will see a preview first.</div>'}},
find_candidate:{title:function(d){return 'Candidates matching "'+esc(d.query)+'"'},cap:function(d){return N(d.match_count)+' found'},
 sum:function(d){var c=d.candidates||[];return list(c.slice(0,6),function(x){var j=x.jobs||[];return '<span>'+esc(x.name)+(j[0]?' <span style="color:var(--o-text-3)">'+esc(j[0].job_title)+' · '+esc(j[0].current_stage)+'</span>':'')+'</span><button class="btn btn-g" data-act="ask:'+esc(x.name)+'">This one</button>'})+(c.length>1?'<div class="note">More than one match. Pick the right person before making any change.</div>':'')}},
candidate_profile:{title:function(d){return esc(d.candidate||'Candidate')},cap:function(){return 'internal only'},
 sum:function(d){var w=(d.work_history||[]).slice().sort(function(a,b){return (b.work_start_date||0)-(a.work_start_date||0)}),cur=w.filter(function(x){return x.is_currently_working})[0]||w[0],ip=d.in_play_on||[];
  return '<dl class="kv"><dt>Now</dt><dd>'+(cur?esc(cur.title||'—')+(cur.work_company_name?' · '+esc(cur.work_company_name):''):'—')+'</dd><dt>Roles on record</dt><dd>'+N(w.length)+'</dd><dt>Education</dt><dd>'+N((d.education||[]).length)+((d.education||[]).length===1?' entry':' entries')+'</dd></dl>'
  +(ip.length?sec('On jobs')+list(ip,function(x){return '<span>'+esc(x.job)+'</span><span class="tag">'+esc(x.stage)+' · '+D(x.updated)+'</span>'}):'')},
 full:function(d){var w=(d.work_history||[]).slice().sort(function(a,b){return (b.work_start_date||0)-(a.work_start_date||0)});return R.candidate_profile.sum(d)+sec('Work history')+'<div class="li">'+w.map(function(x){return '<div class="row" style="display:block"><div>'+esc(x.title||'—')+(x.work_company_name?' · '+esc(x.work_company_name):'')+'</div><div class="m">'+UX(x.work_start_date)+' – '+(x.is_currently_working?'now':UX(x.work_end_date))+(x.work_location?' · '+esc(x.work_location):'')+'</div></div>'}).join('')+'</div>'
  +sec('Education')+'<div class="li">'+(d.education||[]).map(function(x){return '<div class="row" style="display:block"><div>'+esc([x.educational_qualification,x.educational_specialization].filter(Boolean).join(', ')||'—')+'</div><div class="m">'+esc(x.institute_name||'')+' · '+UX(x.education_start_date)+' – '+UX(x.education_end_date)+'</div></div>'}).join('')+'</div>'}},
cv_pack:{title:function(d){return 'Formatted CV'},cap:function(d){return d.redacted===false?'<span style="color:var(--color-text-danger,#7F2C28)">Not redacted · internal only</span>':'<span class="chip">Redacted</span>'},
 sum:function(d){var c=d.cover||{},v=d.cv||{},r=d.redaction||{};return '<dl class="kv"><dt>Candidate</dt><dd>'+esc(c.candidate_name)+'</dd><dt>Title</dt><dd>'+esc(v.current_title||'—')+'</dd><dt>Location</dt><dd>'+esc(c.current_location||'—')+'</dd><dt>Relocate</dt><dd>'+esc(c.willing_to_relocate||'—')+'</dd><dt>Notice</dt><dd>'+(c.notice_period_days!=null?N(c.notice_period_days)+' days':'—')+'</dd></dl>'+(d.redacted!==false?'<div class="note">'+N(r.roles_removed)+' most recent roles removed, '+N(r.roles_kept)+' kept. Check older roles for employer names before sending.</div>':'')},
 full:function(d){var v=d.cv||{},c=d.cover||{};return R.cv_pack.sum(d)+(c.education_summary?sec('Education summary')+'<div class="body open">'+esc(c.education_summary)+'</div>':'')+(v.skills?sec('Skills')+'<div class="body open">'+esc(v.skills)+'</div>':'')+sec('Work history')+'<div class="li">'+(v.work_history||[]).map(function(x){return '<div class="row" style="display:block"><div>'+esc(x.title||'—')+' · '+esc(x.company||'')+'</div><div class="m">'+UX(x.start)+' – '+(x.current?'now':UX(x.end))+(x.location?' · '+esc(x.location):'')+'</div></div>'}).join('')+'</div>'}},
job_spec:{title:function(d){return esc(d.title||'Job spec')},cap:function(d){return esc(d.status||'')+(d.job_id?' · job '+esc(d.job_id):'')},
 sum:function(d){var s=d.salary||{};return '<dl class="kv"><dt>Client</dt><dd>'+esc(d.company||'—')+'</dd><dt>Location</dt><dd>'+esc(d.location||'—')+'</dd><dt>Type</dt><dd>'+esc(d.job_type||'—')+'</dd><dt>Salary</dt><dd>'+(s.min||s.max?GBP(s.min)+' – '+GBP(s.max):'not set')+'</dd>'+(d.skills?'<dt>Skills</dt><dd>'+esc(d.skills)+'</dd>':'')+'</dl>'+'<div class="note">'+N((d.briefing||[]).filter(function(b){return b.answer}).length)+' briefing answers recorded.</div>'},
 full:function(d){return R.job_spec.sum(d)+(d.description?sec('Description')+'<div class="body open">'+esc(d.description)+'</div>':'')+((d.briefing||[]).length?sec('Client briefing')+'<dl class="kv">'+d.briefing.filter(function(b){return b.answer}).map(function(b){return '<dt>'+esc(b.question)+'</dt><dd>'+esc(b.answer)+'</dd>'}).join('')+'</dl>':'')}},
notes_read:{title:function(){return 'Notes'},cap:function(d){return N(d.count)+' notes'},
 sum:function(d){var n=d.notes||[];return list(n.slice(0,3),function(x){return '<span style="display:block"><span class="m">'+D(x.when)+(x.type?' · '+esc(x.type):'')+'</span><br>'+esc(String(x.text||'').slice(0,160))+(String(x.text||'').length>160?'…':'')+'</span>'})+more(n,3,'notes')},
 full:function(d){return list(d.notes||[],function(x){return '<span style="display:block"><span class="m">'+D(x.when)+(x.type?' · '+esc(x.type):'')+'</span><br>'+esc(x.text)+'</span>'})}},
pitch_history:{title:function(){return 'Pitch history'},cap:function(d){return N(d.count)+' pitches'},
 sum:function(d){var h=d.history||[],c=d.currently_pitched_to||[];if(!h.length&&!c.length)return '<div class="note" style="margin-top:0">'+esc(d.note||'No pitches recorded.')+'</div>';
  var line=function(x){var ks=Object.keys(x).filter(function(k){return !/slug|_id$|^id$/.test(k)});return '<span>'+ks.map(function(k){var v=x[k];return typeof v==='string'&&/^\d{4}-\d{2}-\d{2}/.test(v)?D(v):esc(v)}).join(' · ')+'</span>'};
  return (c.length?sec('Currently pitched to')+list(c,line):'')+(h.length?sec('History')+list(h.slice(0,8),line):'')}},
files_list:{title:function(){return 'Files'},cap:function(d){return N(d.count)+' files · internal only'},
 sum:function(d){return list(d.files||[],function(x){return '<span>'+esc(x.name)+' <span style="color:var(--o-text-3)">'+D(x.added)+'</span></span><button class="btn btn-g" data-act="open:'+esc(x.link)+'">Open</button>'})}},
platform_health:{title:function(){return 'Platform health'},cap:function(d){return d.sync&&d.sync.generated_at?D(d.sync.generated_at):''},
 sum:function(d){var s=d.sync||{},bad=(s.entities||[]).filter(function(e){return e.status!=='ok'}),ib=(d.inboxes||[]).filter(function(i){return !/^ok/.test(i.status||'')}),te=(d.tool_errors_7d||[]).reduce(function(a,t){return a+(t.errors||0)},0);
  return tiles([['Sync',s.overall==='ok'?'<span class="ok">OK</span>':esc(s.overall),bad.length?N(bad.length)+' feed(s) not ok':'all feeds fresh'],['Scheduled jobs',(d.cron&&d.cron.problems)?N(d.cron.problems)+' problem(s)':'<span class="ok">OK</span>'],['Inboxes with errors',N(ib.length)],['Tool errors, 7 days',N(te),'of '+N(d.tool_calls_7d)+' calls']])},
 full:function(d){var s=d.sync||{};return R.platform_health.sum(d)+sec('Sync feeds')+tbl([['Feed',function(e){return esc(e.entity)}],['Status',function(e){return e.status==='ok'?'<span class="ok">ok</span>':esc(e.status)}],['Why',function(e){return esc(e.reason)}],['Minutes since',function(e){return N(e.minutes_stale)},1]],s.entities||[])+sec('Inboxes')+tbl([['Who',function(i){return esc(i.who)}],['Last check',function(i){return D(i.last_check)+' '+esc(String(i.last_check||'').slice(11,16))}],['Status',function(i){return esc(i.status)}]],d.inboxes||[])+sec('Tool errors, last 7 days')+tbl([['Tool',function(t){return esc(t.tool)}],['Calls',function(t){return N(t.calls)},1],['Errors',function(t){return N(t.errors)},1]],(d.tool_errors_7d||[]).slice().sort(function(a,b){return b.errors-a.errors}))}},
usage_report:{title:function(){return 'Platform usage'},cap:function(d){return win(d.window)},
 sum:function(d){var p=d.people||[];var by=function(s){return p.filter(function(x){return x.status===s&&!x.left}).length};return tiles([['Active',N(by('active'))],['Connected, no tools yet',N(by('connected, never used a tool'))],['Never connected',N(by('never connected'))],['Tool calls',N(p.reduce(function(a,x){return a+(x.tool_calls||0)},0))]])},
 full:function(d){return R.usage_report.sum(d)+tbl([['Person',nm],['Status',function(x){return esc(x.status)}],['Calls',function(x){return N(x.tool_calls)},1],['Changes',function(x){return N(x.writes)},1],['Active days',function(x){return N(x.active_days)},1],['Errors',function(x){return N(x.errors)},1],['Last used',function(x){return x.last_tool_call?D(x.last_tool_call):'—'}]],rank(d.people||[],function(x){return x.tool_calls||0}))}},
team_insights:{title:function(){return 'Team insights'},cap:function(d){return win(d.window)},
 sum:function(d){var h=d.headline||{};return tiles([['Active, last 7 days',N(h.active_last_7d),'prior 7 days '+N(h.active_prior_7d)],['With access',N(h.with_access)],['Never started',N(h.never_started)],['Dropped off',N(h.dropped_off)]])},
 full:function(d){var fm=d.feature_map||{},ar=fm.areas||[],o=R.team_insights.sum(d);
  if(ar.length)o+=sec('Feature map')+'<div class="tw"><table><tr><th>Person</th>'+ar.map(function(a){return '<th class="num">'+esc(a)+'</th>'}).join('')+'</tr>'+rank(fm.people||[],function(p){return ar.filter(function(a){return p.areas&&p.areas[a]==='used'}).length}).map(function(p){return '<tr><td>'+who(p)+'</td>'+ar.map(function(a){var v=p.areas&&p.areas[a];return '<td class="num">'+(v==='used'?'<span class="dot u" title="used"></span>':v==='tried'?'<span class="dot t" title="tried"></span>':'<span class="dot n" title="never"></span>')+'</td>'}).join('')+'</tr>'}).join('')+'</table></div><div class="note"><span class="dot u"></span> used · <span class="dot t"></span> tried · <span class="dot n"></span> never</div>';
  if((d.coach||[]).length)o+=sec('Coaching')+list(d.coach,function(c){return '<span style="display:block"><b style="font-weight:500">'+esc(c.name)+'</b>'+(c.behind&&c.behind.length?' <span class="m">behind on '+c.behind.map(function(x){return esc(String(x).replace(/_/g,' '))}).join(', ')+'</span>':'')+'<br><span class="m">'+(c.suggestions||[]).slice(0,3).map(esc).join(' · ')+'</span></span>'});
  if((d.onboarding||[]).length)o+=sec('Onboarding')+tbl([['Person',function(x){return esc(x.name)}],['Steps done',function(x){return N(x.done)+' / 7'},1],['Next step',function(x){return esc(x.next_step)}]],d.onboarding);
  return o}}
};
window.OCT={name:'octagon-report',title:'Octagon',full:true,
accept:function(d){return !!(d&&d._view&&R[d._view.tool])},
render:function(d,ctx){var r=R[d._view.tool],full=ctx.mode==='fullscreen',body;
 if(d.error&&d._view.tool!=='my_day')return head(r.title(d))+'<div class="note" style="margin-top:0">'+esc(d.message||d.error)+'</div>';
 var f=r.full?r.full(d):null;body=(full||(!ctx.canFull&&f))&&f?f:r.sum(d);
 var o=head(r.title(d),r.cap?r.cap(d):'')+body;
 if(f&&ctx.canFull)o+=full?'<div class="foot"><span class="hint">Live from RecruitCRM</span><button class="btn btn-g" data-mode="inline">Back to chat</button></div>':'<div class="foot"><span class="hint">Live from RecruitCRM</span><button class="btn btn-p" data-mode="fullscreen">Open full view</button></div>';
 return o},
act:function(name,d,api){
 if(name.indexOf('ask:')===0){var who=name.slice(4),t=d._view.tool;var text=t==='match_candidates'?'What next with '+who+' from these matches?':'It is '+who+'.';
  try{api.app.sendMessage({role:'user',content:[{type:'text',text:text}]})}catch(e){}return}
 if(name.indexOf('open:')===0){try{api.app.openLink({url:name.slice(5)})}catch(e){}return}}};
`;

// ---- Mixed read/write tools: read views + the confirm card in one widget ----------------------
const MIXED_JS = String.raw`// Read views for the mixed read/write tools. Their previews go to the confirm card instead.
function ISO(s){return s?D(String(s).slice(0,10)):'—'}
function lab(k){k=String(k).replace(/_/g,' ');return k.charAt(0).toUpperCase()+k.slice(1)}
function HM(s){var m=/T(\d{2}:\d{2})/.exec(String(s||''));return m?m[1]:''}
R.off_limit={title:function(d){return d.off_limit?'Off-limit candidates':esc(d.candidate||'Off-limit check')},cap:function(d){return d.off_limit?N(d.count)+' do not approach':''},
 sum:function(d){if(d.off_limit){var l=d.off_limit.slice().sort(function(a,b){return String(a.until||'9').localeCompare(String(b.until||'9'))});return tiles([['Off limit now',N(d.count)],['With an end date',N(l.filter(function(x){return x.until&&String(x.until).indexOf('2038')!==0}).length)]])+list(l.slice(0,4),function(x){return '<span>'+esc(x.name)+'</span><span class="tag">'+(x.until&&String(x.until).indexOf('2038')!==0?'until '+ISO(x.until):'no end date')+'</span>'})}
  var on=!!d.currently_off_limit;return '<div class="badge '+(on?'stop':'go')+'">'+(on?'Off limit: do not approach or pitch':'Available to approach')+'</div><dl class="kv">'+(on?'<dt>Until</dt><dd>'+(d.until&&String(d.until).indexOf('2038')!==0?ISO(d.until):'no end date')+'</dd>':'')+(d.reason?'<dt>Reason</dt><dd>'+esc(d.reason)+'</dd>':'')+'</dl>'},
 full:function(d){if(!d.off_limit){var h=d.history||[];return h.length?R.off_limit.sum(d)+sec('History')+tbl([['Status',function(x){return esc(x.status_label)}],['Reason',function(x){return esc(x.reason||'—')}],['Ends',function(x){return x.end_date?ISO(x.end_date):'—'}],['Updated',function(x){return ISO(x.updated_on)}]],h):null}
  return tbl([['Candidate',function(x){return esc(x.name)}],['Until',function(x){return x.until&&String(x.until).indexOf('2038')!==0?ISO(x.until):'no end date'}],['Reason',function(x){return esc(x.reason||'—')}]],d.off_limit)}},
R.hotlist={title:function(){return 'Hotlists'},cap:function(d){return N(d.count)+' lists'},
 sum:function(d){var h=d.hotlists||[];if(!h.length)return '<div class="note" style="margin-top:0">'+esc(d.message||'No hotlists.')+'</div>';var by={};h.forEach(function(x){by[x.type]=(by[x.type]||0)+1});
  return tiles(Object.keys(by).map(function(k){return [esc(lab(k))+'s',N(by[k])]}))+list(h.slice(0,5),function(x){return '<span>'+esc(x.name)+'</span><span class="tag">'+esc(x.type)+(x.shared?' · shared':'')+'</span>'})},
 full:function(d){return tbl([['Hotlist',function(x){return esc(x.name)}],['Of',function(x){return esc(x.type)}],['Shared',function(x){return x.shared?'Yes':'No'}]],d.hotlists||[])}},
R.inbox={title:function(d){return d.body!=null?esc(d.subject||'Email'):'Inbox'},cap:function(d){return d.body!=null?ISO(d.received)+' '+HM(d.received):(d.since?'since '+ISO(d.since):'')},
 sum:function(d){
  if(d.body!=null)return '<dl class="kv"><dt>From</dt><dd>'+esc(d.from)+'</dd><dt>To</dt><dd>'+esc((d.to||[]).join(', '))+'</dd>'+((d.cc||[]).length?'<dt>Cc</dt><dd>'+esc(d.cc.join(', '))+'</dd>':'')+((d.attachments||[]).length?'<dt>Attachments</dt><dd>'+d.attachments.map(function(a){return esc(a.name||a.filename||'file')}).join(', ')+'</dd>':'')+'</dl>'+(d.category==='never'?'<div class="warn" style="margin-top:12px">Flagged '+esc(d.reason)+': a topic to handle yourself.</div>':'')+'<div class="body" id="b-body" style="margin-top:12px">'+esc(d.body)+'</div><button class="link" data-act="more:body">Show all</button>';
  if(d.emails){var e=d.emails,o=['never','other','routine'];return tiles([['New',N(d.count)],['Handle yourself',N(e.filter(function(x){return x.category==='never'}).length)],['Routine',N(e.filter(function(x){return x.category==='routine'}).length)]])
   +list(e.slice().sort(function(a,b){return o.indexOf(a.category)-o.indexOf(b.category)}).slice(0,5),function(x){return '<span>'+(x.is_read?'':'<b style="font-weight:500">')+esc(x.from_name||x.from_address)+(x.is_read?'':'</b>')+' <span style="color:var(--o-text-3)">'+esc(x.subject)+'</span></span><span class="tag">'+(x.category==='never'?'yourself':esc(x.category))+'</span>'})}
  if(d.connected===false)return '<div class="note" style="margin-top:0">'+esc(d.message||'Your inbox is not connected.')+'</div>';
  return tiles([['New',N(d.new_total)],['Handle yourself',N(d.never)],['Routine',N(d.routine)],['Other',N(d.other)]])+'<div class="note">Last checked '+ISO(d.last_checked)+' '+HM(d.last_checked)+'. '+N(d.automated)+' automated emails counted, not listed.</div>'},
 full:function(d){if(!d.emails)return null;return tbl([['From',function(x){return esc(x.from_name||x.from_address)}],['Subject',function(x){return esc(x.subject)}],['Received',function(x){return ISO(x.received_at)+' '+HM(x.received_at)}],['Type',function(x){return x.category==='never'?'Handle yourself ('+esc(x.reason)+')':esc(x.category)}]],d.emails)}},
R.push_tell={title:function(){return 'Push & Tell'},cap:function(d){return esc(d.consultant||'')+(d.window?' · '+esc(d.window).replace(/(\d{4})-(\d{2})-(\d{2})/g,'$3/$2/$1'):'')},
 sum:function(d){var c=d.clients||[];if(!c.length)return '<div class="note" style="margin-top:0">No A or B grade open jobs to report on.</div>';
  return list(c.slice(0,5),function(x){return '<span>'+esc(x.client)+' <span style="color:var(--o-text-3)">'+N(x.included.length)+' job'+(x.included.length===1?'':'s')+'</span></span><button class="btn btn-g" data-act="pt:'+esc(x.client)+'">Draft email</button>'})+more(c,5,'clients')+'<div class="note">A and B grade jobs are included. Open the full view to change which jobs go in.</div>'},
 full:function(d){var c=d.clients||[];return c.map(function(x,ci){return sec(esc(x.client))+'<div class="li">'+x.included.map(function(j){var on=!(x._off&&x._off[j.job_id]);var act=Object.keys(j.last_7_days||{}).map(function(k){return N(j.last_7_days[k])+' '+esc(({cv_sent:'CV sent',interview_request:'interview request',first_interview:'1st interview',second_interview:'2nd interview',third_interview:'3rd interview',offered:'offered',placed:'placed',rejected_client:'rejected by client'})[k]||k.replace(/_/g,' '))}).join(', ');
   return '<div class="row"><span><button class="chk'+(on?' on':'')+'" data-act="ptj:'+ci+':'+esc(j.job_id)+'" aria-pressed="'+on+'">'+(on?'✓':'')+'</button> '+esc(j.title)+' <span class="tag">'+esc(j.grade||'—')+'</span> <span class="m">'+(act||'no client-visible activity this week')+'</span></span><span class="m">'+(j.last_push_tell?'last sent '+ISO(j.last_push_tell):'never sent')+'</span></div>'}).join('')+'</div><div style="margin-top:8px"><button class="btn btn-p" data-act="pt:'+esc(x.client)+'">Draft email for '+esc(x.client)+'</button></div>'}).join('')+((d.other_open_jobs||[]).length?'<div class="note">'+N(d.other_open_jobs.length)+' C-grade or ungraded open jobs are left out. Ask to add any.</div>':'')}},
R.eow_email={title:function(){return 'End of week'},cap:function(d){return win({from:d.window&&d.window.from,to:d.window&&d.window.to_exclusive})},
 sum:function(d){var t=d.totals||{};return tiles([['CVs sent',N(t.cv_sent)],['Interview requests',N(t.interview_requests)],['Interviews',N(t.interviews)],['Offers',N(t.offers)],['BD calls',N(t.bd_calls)],['Jobs added',N(t.jobs_added)]])},
 full:function(d){var so=d.shout_outs||{},sh=Object.keys(so).filter(function(k){return (so[k]||[]).length});return R.eow_email.sum(d)+(sh.length?sec('Shout-outs')+'<dl class="kv">'+sh.map(function(k){return '<dt>'+esc(lab(k))+'</dt><dd>'+so[k].map(function(x){return esc(typeof x==='object'?(x.name||JSON.stringify(x)):x)}).join(', ')+'</dd>'}).join('')+'</dl>':'')
  +sec('Team')+tbl([['Consultant',nm],['Jobs',function(c){return N(c.jobs_added)},1],['Assigned',function(c){return N(c.candidates_assigned)},1],['CVs',function(c){return N(c.cv_sent)},1],['Int req',function(c){return N(c.interview_requests)},1],['Interviews',function(c){return N(c.interviews)},1],['Offers',function(c){return N(c.offers)},1],['BD calls',function(c){return N(c.bd_calls)},1]],rank(d.consultants||[],function(c){return c.cv_sent||0}))
  +((d.jobs||[]).length?sec('New jobs')+tbl([['Role',function(j){return esc(j.title)}],['Client',function(j){return esc(j.company)}],['Contact',function(j){return esc(j.contact)}],['Owner',function(j){return esc(j.owner)}],['Added',function(j){return D(j.date_added)}]],d.jobs):'')+'<div class="note">Shout-outs: '+esc(d.thresholds||'')+'.</div>'}},
R.manage_tokens={title:function(){return 'Connector access'},cap:function(d){return N(d.active_tokens)+' active tokens'},
 sum:function(d){var t=d.tokens||[],lv=d.leavers_with_access||[];return tiles([['Active tokens',N(d.active_tokens)],['People',N(Object.keys(t.reduce(function(a,x){a[x.name]=1;return a},{})).length)],['Leavers still with access',N(lv.length)]])+(lv.length?'<div class="warn" style="margin-top:12px">'+N(lv.length)+' leaver(s) still hold access: '+lv.map(function(x){return esc(x.name)}).join(', ')+'. Ask Claude to revoke.</div>':'')},
 full:function(d){return R.manage_tokens.sum(d)+tbl([['Person',nm],['Can write',function(x){return x.can_write?'Yes':'No'}],['Admin',function(x){return x.is_admin?'Yes':'No'}],['Created',function(x){return ISO(x.created)}],['Last used',function(x){return x.last_used?ISO(x.last_used):'never'}]],d.tokens||[])}},
R.webhook_subscriptions={title:function(){return 'RecruitCRM webhooks'},cap:function(d){return N(d.count)+' subscriptions'},
 sum:function(d){var s=d.subscriptions||[],by={};s.forEach(function(x){var k=String(x.event).split('.')[0];by[k]=(by[k]||0)+1});return tiles(Object.keys(by).sort().map(function(k){return [esc(lab(k)),N(by[k])]}))},
 full:function(d){return tbl([['Event',function(x){return esc(x.event)}],['ID',function(x){return esc(x.id)},1]],(d.subscriptions||[]).slice().sort(function(a,b){return String(a.event).localeCompare(String(b.event))}))+'<div class="note">Target URLs are hidden.</div>'}};
(function(){var B=window.OCT,ba=B.act;B.act=function(name,d,api){
 if(name.indexOf('more:')===0){var el=document.getElementById('b-'+name.slice(5));if(el)el.classList.toggle('open');return}
 if(name.indexOf('ptj:')===0){var p=name.split(':'),c=(d.clients||[])[Number(p[1])];if(c){c._off=c._off||{};c._off[p[2]]=!c._off[p[2]];api.set(d)}return}
 if(name.indexOf('pt:')===0){var cl=name.slice(3),c2=(d.clients||[]).filter(function(x){return x.client===cl})[0];if(!c2)return;var ids=c2.included.filter(function(j){return !(c2._off&&c2._off[j.job_id])}).map(function(j){return j.job_id});
  if(!ids.length)return;try{api.app.sendMessage({role:'user',content:[{type:'text',text:'Draft the Push & Tell email for '+cl+' covering job'+(ids.length===1?' ':'s ')+ids.join(', ')+'.'}]})}catch(e){}return}
 return ba(name,d,api)}})();
`;
const MIXED_APP_JS = '(function(){' + CONFIRM_JS + '\nwindow.OCT_C=window.OCT;})();\n(function(){' + REPORT_JS + MIXED_JS + '\nwindow.OCT_R=window.OCT;})();\n' + String.raw`window.OCT={name:'octagon-mixed',title:'Octagon',full:true,
accept:function(d){return !!(d&&(d._card?window.OCT_C.accept(d):window.OCT_R.accept(d)))},
render:function(d,ctx){return d._card?window.OCT_C.render(d,ctx):window.OCT_R.render(d,ctx)},
act:function(n,d,api){return d._card?window.OCT_C.act(n,d,api):window.OCT_R.act(n,d,api)}};`;

function page(title: string, appJs: string): string {
  return '<!doctype html><html lang="en-GB"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><title>' + title + '</title><style>' + THEME_CSS + '</style></head><body><div id="app" aria-live="polite"></div>'
    + '<script>(function(){' + EXT_APPS_JS + '\n})();</script>'
    + '<script>var OCT_LOGO_L="' + LOGO_LIGHT + '",OCT_LOGO_D="' + LOGO_DARK + '";' + appJs + '</script>'
    + '<script>' + RUNTIME_JS + '</script></body></html>';
}

export const SCORECARD_WIDGET_HTML = page("Octagon scorecard", SCORECARD_JS);
export const DASHBOARD_WIDGET_HTML = page("Octagon dashboard", DASHBOARD_JS);
export const CONFIRM_WIDGET_HTML = page("Octagon preview", CONFIRM_JS);
export const REPORT_WIDGET_HTML = page("Octagon report", REPORT_JS);
export const MIXED_WIDGET_HTML = page("Octagon", MIXED_APP_JS);
