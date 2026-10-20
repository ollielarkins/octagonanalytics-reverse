// ---- MCP Apps (SEP-1865) widgets --------------------------------------------------------------
// Inline UI that Claude renders for tools whose definition carries _meta.ui.resourceUri.
//
// Each widget is one self-contained HTML document:
//   1. the MCP Apps SDK browser client, inlined (ext_apps_bundle.ts, exposed as window.McpApps) —
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
#app{padding:16px 18px}
.full #app{padding:24px;max-width:960px;margin:0 auto}
.head{display:flex;align-items:center;gap:8px;margin-bottom:14px;min-height:20px}
.logo{width:20px;height:20px;flex:none}
.logo.dk{display:none}:root[data-theme=dark] .logo.lt{display:none}:root[data-theme=dark] .logo.dk{display:block}
.title{font-weight:600}
.cap{margin-left:auto;font-size:12px;color:var(--o-text-3);text-align:right}
.note{font-size:12px;color:var(--o-text-3);margin-top:12px}
.sec{font-weight:600;margin:22px 0 10px}
.chip{display:inline-block;font-size:12px;font-weight:500;padding:2px 8px;border-radius:var(--o-r-full);background:var(--o-chip);color:var(--o-on-chip)}
.warn{margin:0 0 14px;padding:8px 12px;border-radius:var(--o-r-md);background:var(--o-warn-bg);color:var(--o-warn);font-size:13px}
.ok{color:var(--o-success)}
.kpis{display:grid;gap:12px}
.kpi{display:grid;grid-template-columns:1fr auto;gap:6px 12px}
.kpi .l{color:var(--o-text-2)}
.kpi .v{font-variant-numeric:tabular-nums;color:var(--o-text-3);white-space:nowrap}
.kpi .v b{color:var(--o-text);font-weight:600}
.kpi.met .v b{color:var(--o-success)}
.bar{grid-column:1/-1;height:6px;border-radius:var(--o-r-full);background:var(--o-track);overflow:hidden}
.bar i{display:block;height:100%;background:var(--o-bar);border-radius:inherit}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:10px}
.tile{background:var(--o-bg-2);border-radius:var(--o-r-md);padding:10px 12px}
.tile .l{font-size:12px;color:var(--o-text-3)}
.tile .v{font-size:20px;font-weight:600;font-variant-numeric:tabular-nums;margin-top:2px}
.tile .s{font-size:12px;color:var(--o-text-3);margin-top:2px}
.big{font-size:28px;font-weight:600;font-variant-numeric:tabular-nums;line-height:1.1}
.big small{font-size:14px;font-weight:400;color:var(--o-text-3)}
.rows{display:grid;grid-template-columns:1fr auto;gap:8px 12px;margin-top:14px}
.rows dt{color:var(--o-text-3)}.rows dd{margin:0;text-align:right;font-variant-numeric:tabular-nums}
.tw{overflow-x:auto;margin:0 -2px}
table{width:100%;border-collapse:collapse;font-size:13px}
th{font-weight:500;color:var(--o-text-3);text-align:left;padding:6px 8px;border-bottom:var(--o-bw) solid var(--o-border-2);white-space:nowrap}
td{padding:7px 8px;border-bottom:var(--o-bw) solid var(--o-border)}
tr:last-child td{border-bottom:0}
.num{text-align:right;font-variant-numeric:tabular-nums}
td.met{color:var(--o-success);font-weight:600}
.fun{display:grid;grid-template-columns:minmax(96px,auto) 1fr auto;gap:8px 12px;align-items:center}
.fun .l{color:var(--o-text-2);font-size:13px}.fun .n{font-variant-numeric:tabular-nums;font-size:13px;text-align:right}
.fun .t{height:8px;border-radius:var(--o-r-full);background:var(--o-track);overflow:hidden}.fun .t i{display:block;height:100%;background:var(--o-bar);border-radius:inherit}
.foot{display:flex;align-items:center;gap:8px;margin-top:16px;padding-top:14px;border-top:var(--o-bw) solid var(--o-border)}
.foot .hint{font-size:12px;color:var(--o-text-3);margin-right:auto}
.btn{font:inherit;font-weight:500;min-height:36px;padding:0 14px;border-radius:var(--o-r-md);cursor:pointer}
.btn-p{background:var(--o-action);color:var(--o-on-action);border:0}
.btn-g{background:transparent;color:var(--o-text);border:var(--o-bw) solid var(--o-border-2)}
.btn:focus-visible{outline:2px solid var(--o-bar);outline-offset:2px}
@media (pointer:coarse){.btn{min-height:44px}}
.sk{background:var(--o-track);border-radius:var(--o-r-sm);height:12px;animation:pulse 1.4s ease-in-out infinite}
@keyframes pulse{50%{opacity:.5}}
@media (prefers-reduced-motion:reduce){.sk{animation:none}}
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
function pct(a,t){return t?Math.max(0,Math.min(100,Math.round(100*(a||0)/t))):0}
function head(title,cap){return '<div class="head"><img class="logo lt" src="data:image/png;base64,'+OCT_LOGO_L+'" alt=""><img class="logo dk" src="data:image/png;base64,'+OCT_LOGO_D+'" alt=""><span class="title">'+esc(title)+'</span>'+(cap?'<span class="cap">'+cap+'</span>':'')+'</div>'}
function skeleton(){return '<div class="head"><div class="sk" style="width:20px;height:20px;border-radius:6px"></div><div class="sk" style="width:120px"></div></div><div class="kpis">'+[70,55,62,40,48].map(function(w){return '<div><div class="sk" style="width:'+w+'%;margin-bottom:8px"></div><div class="sk" style="height:6px"></div></div>'}).join('')+'</div>'}
(function(){
var M=window.McpApps,O=window.OCT,root=document.getElementById('app');
var DATA=null,MODE='inline',FULL=false,FAILED=false;
root.innerHTML=skeleton();
function fail(msg){if(DATA)return;FAILED=true;root.innerHTML=head(O.title||'Octagon')+'<div class="note">'+esc(msg)+'</div>'}
if(!M||!M.App){fail('The widget could not start. Ask again, and if it keeps happening, ping Ollie on Slack.');return}
var app=new M.App({name:O.name,version:'2.0.0'},{availableDisplayModes:O.full?['inline','fullscreen']:['inline']},{autoResize:true});
function draw(){if(!DATA)return;document.documentElement.classList.toggle('full',MODE==='fullscreen');
try{root.innerHTML=O.render(DATA,{mode:MODE,canFull:FULL})}catch(e){root.innerHTML=head(O.title||'Octagon')+'<div class="note">Could not draw this view: '+esc(e&&e.message)+'</div>'}}
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
document.addEventListener('click',function(ev){var b=ev.target.closest&&ev.target.closest('[data-mode]');if(!b)return;
app.requestDisplayMode({mode:b.getAttribute('data-mode')}).then(function(r){if(r&&r.mode){MODE=r.mode;draw()}}).catch(function(){})});
app.connect().then(function(){applyCtx(app.getHostContext())}).catch(function(){fail('Could not connect to Claude. Reconnect the Octagon Analytics connector and ask again.')});
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
cs=cs.slice().sort(function(a,b){return ((b.cv_sent||{}).actual||0)-((a.cv_sent||{}).actual||0)});
var o=head('This week — team','from '+D(d.week_start));
o+='<div class="tw"><table><tr><th>Consultant</th>'+m.map(function(x){return '<th class="num">'+x[0]+'</th>'}).join('')+'</tr>'+cs.map(function(c){return '<tr><td>'+esc(c.name)+'</td>'+m.map(function(x){var v=c[x[1]]||{},a=v.actual||0,t=v.target;return '<td class="num'+(t!=null&&a>=t?' met':'')+'">'+N(a)+(t!=null?'<span style="color:var(--o-text-3)">/'+N(t)+'</span>':'')+'</td>'}).join('')+'</tr>'}).join('')+'</table></div>';
o+='<div class="note">Green = target met. '+(d.has_targets===false?'Targets not loaded. ':'')+'BD and client calls count categorised Devyce calls only, so can undercount.</div>';return o}
function billOne(d,c){var tg=c.quarterly_target,wq=c.won_qtr||0,left=tg!=null?Math.max(0,tg-wq):null;
var o=head('Billing this quarter','from '+D(d.quarter_start));
o+='<div class="big">'+GBP(wq)+(tg!=null?' <small>of '+GBP(tg)+'</small>':'')+'</div>';
if(tg!=null)o+='<div class="bar" style="margin-top:10px" role="img" aria-label="'+pct(wq,tg)+'% of target"><i style="width:'+pct(wq,tg)+'%"></i></div>';
o+='<dl class="rows">'+(tg!=null?'<dt>Of target</dt><dd>'+(tg?Math.round(100*wq/tg):0)+'%</dd><dt>Still to bill</dt><dd'+(left===0?' class="ok"':'')+'>'+GBP(left)+'</dd>':'')+'<dt>Open pipeline</dt><dd>'+GBP(c.pipeline_open)+'</dd></dl>';
o+='<div class="note">Billing is Won deal value. Pipeline is the forward indicator.</div>';return o}
function billTeam(d,cs){cs=cs.slice().sort(function(a,b){return (b.won_qtr||0)-(a.won_qtr||0)});
var o=head('Billing this quarter — team','from '+D(d.quarter_start));
o+='<div class="tw"><table><tr><th>Consultant</th><th class="num">Won</th><th class="num">Target</th><th class="num">%</th><th class="num">Pipeline</th></tr>'+cs.map(function(c){var tg=c.quarterly_target,wq=c.won_qtr||0;return '<tr><td>'+esc(c.name)+'</td><td class="num'+(tg!=null&&wq>=tg?' met':'')+'">'+GBP(wq)+'</td><td class="num">'+(tg!=null?GBP(tg):'—')+'</td><td class="num">'+(tg?Math.round(100*wq/tg)+'%':'—')+'</td><td class="num">'+GBP(c.pipeline_open)+'</td></tr>'}).join('')+'</table></div>';
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
function team(d){var cs=d.consultants.slice().sort(function(a,b){return (b.placed||0)-(a.placed||0)});return '<div class="sec">Team — by job owner</div>'+table([['Consultant'],['CV',1],['1st Int',1],['Placed',1]],cs.map(function(c){return '<tr><td>'+esc(c.name)+'</td><td class="num">'+N(c.cv_sent)+'</td><td class="num">'+N(c.first_interview)+'</td><td class="num">'+N(c.placed)+'</td></tr>'}))}
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

function page(title: string, appJs: string): string {
  return '<!doctype html><html lang="en-GB"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><title>' + title + '</title><style>' + THEME_CSS + '</style></head><body><div id="app" aria-live="polite"></div>'
    + '<script>' + EXT_APPS_JS + '</script>'
    + '<script>var OCT_LOGO_L="' + LOGO_LIGHT + '",OCT_LOGO_D="' + LOGO_DARK + '";' + appJs + '</script>'
    + '<script>' + RUNTIME_JS + '</script></body></html>';
}

export const SCORECARD_WIDGET_HTML = page("Octagon scorecard", SCORECARD_JS);
export const DASHBOARD_WIDGET_HTML = page("Octagon dashboard", DASHBOARD_JS);
