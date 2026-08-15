// ============================================================
//  Script Kill Switch — page Prototype (redesign)
//  DROP-IN pour src/prototype-ui.ts du worker Cloudflare.
//
//  Le chrome de la page (en-tête, contrôle segmenté, encart) est
//  redessiné aux principes Apple. Les quatre panneaux in-game sont
//  CONSERVÉS tels quels : ils reproduisent l'UI réellement affichée
//  en jeu, les redessiner « façon Apple » les rendrait faux.
//
//  Réutilise STYLE depuis admin-ui.js — importe-le côté worker.
// ============================================================
import { STYLE } from "./admin-ui.js";

const PROTO_JS = `
var stage=document.getElementById('stage');
var btns=document.querySelectorAll('.seg button');
for (var i=0;i<btns.length;i++){
  btns[i].addEventListener('click', function(){
    for (var j=0;j<btns.length;j++) btns[j].classList.remove('on');
    this.classList.add('on');
    stage.setAttribute('data-theme', this.getAttribute('data-theme'));
  });
}
`;

const SWATCHES = [
  ["#150F1E","fond"],["#1F1730","carte"],["#2C2142","carte 2"],["#443159","bordure"],
  ["#A855F7","améthyste"],["#C9A7FF","lilas"],["#5EE9B5","valeur"],["#FB7185","alerte"]
];

function panelA() {
  return `<div class="win winA"><div class="top"></div>
  <div class="abs accent-bar" style="left:18px;top:14px;width:4px;height:22px"></div>
  <div class="abs" style="left:32px;top:10px;font-size:13px;font-weight:700;letter-spacing:.02em">DRAIN SIMULATOR</div>
  <div class="abs pmuted" style="left:32px;top:28px;font-size:11px">By @LaaTortueJaune</div>
  <button class="pclose abs" style="right:12px;top:11px;width:28px;height:26px">X</button>
  <div class="bodyA">
    <div class="toggle on"><div class="t">GENERATE MONEY</div><div class="sw-track on"><div class="sw-knob"></div></div></div>
    <div class="pcard total"><div class="lbl-mini">TOTAL GENERATED</div><div class="v">$128,400</div><div class="r">Server pays $250 per report</div></div>
    <div class="pcard speed"><div class="pmuted" style="font-size:11px">Speed: 85 reports / sec</div><div class="track"><div class="fill"></div><div class="knob2"></div></div></div>
  </div></div>`;
}
function panelB() {
  const row = (n,d,on,err=false) => `<div class="pcard row"><div class="n">${n}</div><div class="d${err?" err":""}">${d}</div><div class="sw-track${on?" on":""}"><div class="sw-knob" style="${on?"left:22px":""}"></div></div></div>`;
  const stat = (k,v,color) => `<div class="pcard stat"><div class="lbl-mini">${k}</div><div class="v"${color?` style="color:${color}"`:""}>${v}</div></div>`;
  return `<div class="win winB">
  <div class="abs accent-bar" style="left:22px;top:18px;width:4px;height:24px"></div>
  <div class="abs" style="left:34px;top:13px;font-size:16px;font-weight:700;letter-spacing:-.01em">Work as a Loan Officer Remastered</div>
  <div class="abs pmuted" style="left:34px;top:34px;font-size:11px">By @LaaTortueJaune</div>
  <button class="pclose abs" style="right:18px;top:16px;width:28px;height:26px">X</button>
  <div class="bodyB">
    <div class="pcard client"><div class="lbl-mini">CUSTOMER AT THE DESK</div><div class="name">Marcus Webb</div><div class="badge">WAITING</div><div class="divider"></div><div class="reason">Credit score below threshold — recommendation is to deny.</div></div>
    ${row("Automatic decision","Approves or denies on its own, reading nothing",true)}
    ${row("Refusal handling","Ejects customers who refuse to leave",false)}
    ${row("Automatic dialogue","fireclickdetector unavailable on this executor",false,true)}
    <div class="stats2">${stat("DECISIONS","47")}${stat("CITATIONS","2","var(--pdanger)")}${stat("ACCURACY","96%","var(--pok)")}</div>
    <div class="pcard logc"><div class="g">Automatic decision enabled</div><div>Customer approved, score 812</div><div class="a">Narrative choice resolved automatically, option 2</div><div>Customer denied, score 340</div><div>Waiting for a customer...</div></div>
  </div></div>`;
}
function panelC() {
  return `<div class="win winC">
  <div class="abs accent-bar" style="left:20px;top:22px;width:4px;height:48px"></div>
  <div class="abs title" style="left:36px;top:20px">Script temporarily offline</div>
  <div class="abs sub" style="left:36px;top:44px;width:344px">Maintenance in progress. It will be back online as soon as possible.</div>
  <div class="abs sig" style="left:36px;top:90px"><i></i>By @LaaTortueJaune</div>
  <button class="pclose abs" style="right:12px;top:18px;width:26px;height:26px">X</button>
  <div class="pbar" style="width:56%"></div></div>`;
}
function panelD() {
  const card = (title,on,extra="") => `<div class="rvcard"><div class="rvhead"><span class="rvtitle">${title}</span><div class="sw-track${on?" on":""}"><div class="sw-knob"></div></div></div>${extra}</div>`;
  return `<div class="win winD"><div class="top"></div>
  <div class="abs accent-bar" style="left:16px;top:14px;width:4px;height:22px"></div>
  <div class="abs" style="left:28px;top:9px;font-size:15px;font-weight:700;letter-spacing:-.01em">RV Cooked?</div>
  <div class="abs pmuted" style="left:28px;top:29px;font-size:11px">By @LaaTortueJaune</div>
  <button class="pclose abs" style="right:12px;top:12px;width:30px;height:26px">X</button>
  <div class="bodyD">
    ${card("Infinite Hunger",true)}
    ${card("No Fall Damage",false)}
    ${card("Super Speed",true,`<div class="rslider"><div class="rtrack"><div class="rfill" style="width:34%"></div><div class="rknob" style="left:34%"></div></div><div class="rval">90</div></div>`)}
    <div class="rvcard"><div class="rvhead"><span class="rvtitle">Telekinesis Grab</span></div>
      <div class="tkrow"><div class="tkdd">12 found - pick one</div><div class="tkref">Refresh</div></div>
      <div class="tkbtns"><div class="tkgrab">Grab selected</div><div class="tkrel">Release</div></div></div>
    <div class="rvcard"><div class="rvhead"><span class="rvtitle">Teleport</span></div>
      <div class="tpgrid"><div class="tpbtn">L1</div><div class="tpbtn">L2</div><div class="tpbtn">L3</div><div class="tpbtn">L4</div><div class="tpbtn">L5</div><div class="tpbtn">L6</div></div>
      <div class="endbtn">End  (skip straight to the finish)</div></div>
  </div><div class="scrollbar"></div></div>`;
}

export function prototypePage() {
  const swatches = SWATCHES.map(([hex,name]) => `<div class="sw"><i style="background:${hex}"></i><code>${hex}</code> ${name}</div>`).join("");
  return `<!doctype html><html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Prototype — panneaux in-game</title><style>${STYLE}</style></head>
<body>
<header>
  <div class="head-inner">
    <div class="brand"><span class="glyph"><i></i></span>Prototype — panneaux in-game</div>
    <a href="/admin"><button class="btn small">← Tableau de bord</button></a>
  </div>
</header>
<main>
  <div class="page-head"><div><h1>Prototype</h1><p class="lede">Aperçu des panneaux affichés en jeu.</p></div></div>
  <div class="proto-notice">
    <svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" style="flex:none;margin-top:1px"><circle cx="12" cy="12" r="9"/><path d="M12 8v5M12 16h.01"/></svg>
    <div><b>Aperçu seulement.</b> Rien n'est déployé ici : le code Luau servi à tes clients n'est pas modifié. Reproduction fidèle des quatre panneaux, aux mêmes tailles qu'en jeu.</div>
  </div>
  <div class="proto-head">
    <div class="seg">
      <button data-theme="amethyste" class="on">Améthyste</button>
      <button data-theme="actuel">Précédent</button>
    </div>
    <div class="swatches">${swatches}</div>
  </div>
  <div class="stage" id="stage" data-theme="amethyste">
    <div class="shot">${panelA()}<div class="cap">Drain Simulator <span>— 380 × 324</span></div></div>
    <div class="shot">${panelB()}<div class="cap">Work as a Loan Officer Remastered <span>— 466 × 650</span></div></div>
    <div class="shot">${panelC()}<div class="cap">Offline notice <span>— 410 × 124</span></div></div>
    <div class="shot">${panelD()}<div class="cap">RV Cooked? <span>— 380 × 480</span></div></div>
  </div>
</main>
<script>
${PROTO_JS}
<\/script>
</body></html>`;
}
