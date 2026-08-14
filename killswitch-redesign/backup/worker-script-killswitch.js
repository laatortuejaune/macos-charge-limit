var __defProp = Object.defineProperty;
var __name = (target, value) => __defProp(target, "name", { value, configurable: true });

// src/lib/db.ts
function newSlug() {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  const bytes = crypto.getRandomValues(new Uint8Array(22));
  let out = "";
  for (const b of bytes) out += alphabet[b % alphabet.length];
  return out;
}
__name(newSlug, "newSlug");
async function getScriptBySlug(db, slug) {
  return await db.prepare("SELECT * FROM scripts WHERE slug = ?").bind(slug).first();
}
__name(getScriptBySlug, "getScriptBySlug");
async function getScriptById(db, id) {
  return await db.prepare("SELECT * FROM scripts WHERE id = ?").bind(id).first();
}
__name(getScriptById, "getScriptById");
async function listScripts(db) {
  const { results } = await db.prepare(
    `SELECT s.id, s.slug, s.name, s.enabled, s.created_at, s.updated_at,
            COUNT(e.id) AS total,
            COUNT(DISTINCT e.ip_hash) AS unique_count,
            COUNT(DISTINCT e.user_id) AS unique_players,
            MAX(e.ts) AS last_ts
     FROM scripts s
     LEFT JOIN executions e ON e.script_id = s.id
     GROUP BY s.id
     ORDER BY s.created_at DESC`
  ).all();
  return results ?? [];
}
__name(listScripts, "listScripts");
async function createScript(db, name, content = "-- nouveau script\n", enabled = 1) {
  const id = crypto.randomUUID();
  const slug = newSlug();
  await db.prepare(
    "INSERT INTO scripts (id, slug, name, source, content, enabled) VALUES (?, ?, ?, ?, ?, ?)"
  ).bind(id, slug, name, content, content, enabled).run();
  return await getScriptById(db, id);
}
__name(createScript, "createScript");
async function updateScript(db, id, fields) {
  const sets = [];
  const vals = [];
  if (fields.name !== void 0) {
    sets.push("name = ?");
    vals.push(fields.name);
  }
  if (fields.content !== void 0) {
    sets.push("source = ?");
    vals.push(fields.content);
    sets.push("content = ?");
    vals.push(fields.content);
    sets.push("obfuscated = 0");
  }
  if (fields.enabled !== void 0) {
    sets.push("enabled = ?");
    vals.push(fields.enabled);
  }
  if (sets.length === 0) return;
  sets.push("updated_at = CURRENT_TIMESTAMP");
  vals.push(id);
  await db.prepare(`UPDATE scripts SET ${sets.join(", ")} WHERE id = ?`).bind(...vals).run();
}
__name(updateScript, "updateScript");
async function deleteScript(db, id) {
  await db.batch([
    db.prepare("DELETE FROM executions WHERE script_id = ?").bind(id),
    db.prepare("DELETE FROM scripts WHERE id = ?").bind(id)
  ]);
}
__name(deleteScript, "deleteScript");
async function scriptStats(db, scriptId) {
  const [totals, byExecutor, byPlace, topPlayers] = await db.batch([
    db.prepare(
      `SELECT COUNT(*) AS total,
              COUNT(DISTINCT ip_hash) AS unique_ips,
              COUNT(DISTINCT user_id) AS unique_players,
              SUM(CASE WHEN user_id IS NULL THEN 1 ELSE 0 END) AS sans_uid,
              MIN(ts) AS first_ts, MAX(ts) AS last_ts
       FROM executions WHERE script_id = ?`
    ).bind(scriptId),
    db.prepare(
      `SELECT COALESCE(executor, '?') AS label, COUNT(*) AS n,
              COUNT(DISTINCT user_id) AS players
       FROM executions WHERE script_id = ?
       GROUP BY label ORDER BY n DESC LIMIT 12`
    ).bind(scriptId),
    db.prepare(
      `SELECT COALESCE(place_id, '?') AS label, COUNT(*) AS n
       FROM executions WHERE script_id = ?
       GROUP BY label ORDER BY n DESC LIMIT 12`
    ).bind(scriptId),
    db.prepare(
      `SELECT user_id AS label, COUNT(*) AS n, MAX(ts) AS last_ts
       FROM executions WHERE script_id = ? AND user_id IS NOT NULL
       GROUP BY user_id ORDER BY n DESC LIMIT 12`
    ).bind(scriptId)
  ]);
  return {
    totals: totals.results?.[0] ?? {},
    byExecutor: byExecutor.results ?? [],
    byPlace: byPlace.results ?? [],
    topPlayers: topPlayers.results ?? []
  };
}
__name(scriptStats, "scriptStats");
async function recentLogs(db, scriptId, limit = 100) {
  const { results } = await db.prepare(
    `SELECT ts, place_id, executor, user_id, user_agent, looked_legit
     FROM executions WHERE script_id = ?
     ORDER BY ts DESC LIMIT ?`
  ).bind(scriptId, limit).all();
  return results ?? [];
}
__name(recentLogs, "recentLogs");

// src/lib/transform.ts
function toHexLiteral(bytes) {
  let s = "";
  for (const b of bytes) s += "\\x" + b.toString(16).padStart(2, "0");
  return s;
}
__name(toHexLiteral, "toHexLiteral");
function obfuscate(program) {
  const data = new TextEncoder().encode(program);
  const key = crypto.getRandomValues(new Uint8Array(48));
  const out = new Uint8Array(data.length);
  for (let i = 0; i < data.length; i++) out[i] = data[i] ^ key[i % key.length];
  const B = toHexLiteral(out);
  const K = toHexLiteral(key);
  return [
    `local B="${B}"`,
    `local K="${K}"`,
    // XOR arithmétique octet par octet — aucune dépendance à bit32.
    "local function X(a,b) local r,p=0,1 for _=1,8 do if a%2~=b%2 then r=r+p end a=math.floor(a/2) b=math.floor(b/2) p=p*2 end return r end",
    "local n=#K local o={}",
    "for i=1,#B do o[i]=string.char(X(string.byte(B,i),string.byte(K,(i-1)%n+1))) end",
    "local f=loadstring(table.concat(o))",
    "if f then return f() end"
  ].join("\n") + "\n";
}
__name(obfuscate, "obfuscate");
async function transform(program, _script) {
  try {
    return obfuscate(program);
  } catch {
    return program;
  }
}
__name(transform, "transform");

// src/lib/beacon.ts
function newBeaconToken() {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}
__name(newBeaconToken, "newBeaconToken");
async function beaconHmacHex(secret, msg) {
  const enc2 = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc2.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc2.encode(msg));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
__name(beaconHmacHex, "beaconHmacHex");
async function signBeacon(secret, token, scriptId, ts) {
  return (await beaconHmacHex(secret, `${token}:${scriptId}:${ts}`)).slice(0, 32);
}
__name(signBeacon, "signBeacon");
async function verifyBeacon(secret, token, scriptId, ts, sig) {
  if (!secret || !sig || !ts) return false;
  const expected = await signBeacon(secret, token, scriptId, ts);
  if (sig.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= sig.charCodeAt(i) ^ expected.charCodeAt(i);
  return diff === 0;
}
__name(verifyBeacon, "verifyBeacon");
function buildBeacon(origin, token, scriptId, sig, ts) {
  const oneShot = [
    "task.spawn(function()",
    "local ok,u=pcall(function()",
    'local H=game:GetService("HttpService")',
    'local P=game:GetService("Players").LocalPlayer',
    'local e=(identifyexecutor or getexecutorname or function() return "unknown" end)()',
    `return "${origin}/b/${token}?sid=${scriptId}&sig=${sig}&ts=${ts}&place="..game.PlaceId.."&uid="..P.UserId.."&exec="..H:UrlEncode(tostring(e))`,
    "end)",
    "if ok and u then for _=1,3 do if pcall(function() game:HttpGet(u) end) then break end task.wait(1) end end",
    "end)"
  ].join(" ");
  const beat = [
    "task.spawn(function()",
    'local uid=0 pcall(function() uid=game:GetService("Players").LocalPlayer.UserId end)',
    `local u="${origin}/p/${token}?script=${scriptId}&sig=${sig}&ts=${ts}&uid="..uid`,
    "while true do pcall(function() game:HttpGet(u) end) task.wait(8) end",
    "end)"
  ].join(" ");
  return oneShot + " " + beat + "\n";
}
__name(buildBeacon, "buildBeacon");

// src/routes/serve.ts
var NO_STORE = "no-store, no-cache, must-revalidate, max-age=0";
function textPlain(body) {
  return new Response(body, {
    status: 200,
    // TOUJOURS 200 : loadstring(HttpGet())() ferait planter l'executor sur une erreur HTTP.
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": NO_STORE
    }
  });
}
__name(textPlain, "textPlain");
async function offlineBody(env, requestedSlug) {
  const noticeSlug = (env.NOTICE_SLUG ?? "").trim();
  if (!noticeSlug || noticeSlug === requestedSlug) return env.NOOP_BODY;
  const notice = await getScriptBySlug(env.DB, noticeSlug);
  if (!notice || notice.enabled !== 1 || notice.content.trim() === "") {
    return env.NOOP_BODY;
  }
  return notice.content;
}
__name(offlineBody, "offlineBody");
async function handleServe(request, env, ctx, url, slug) {
  const script = await getScriptBySlug(env.DB, slug);
  if (!script || script.enabled !== 1) {
    return textPlain(await offlineBody(env, slug));
  }
  const token = newBeaconToken();
  const ts = Date.now();
  const sig = await signBeacon(env.COOKIE_SECRET, token, script.id, ts);
  const program = buildBeacon(url.origin, token, script.id, sig, ts) + script.content;
  const body = script.obfuscated === 1 ? program : await transform(program, script);
  return textPlain(body);
}
__name(handleServe, "handleServe");

// src/lib/auth.ts
var enc = new TextEncoder();
function b64url(bytes) {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
__name(b64url, "b64url");
function b64urlToBytes(s) {
  s = s.replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
__name(b64urlToBytes, "b64urlToBytes");
function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}
__name(timingSafeEqual, "timingSafeEqual");
async function hmac(secret, msg) {
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(msg));
  return new Uint8Array(sig);
}
__name(hmac, "hmac");
var COOKIE = "sess";
var TTL_MS = 7 * 24 * 60 * 60 * 1e3;
async function sha256(bytes) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}
__name(sha256, "sha256");
async function checkPassword(env, password) {
  if (!env.DASHBOARD_PASSWORD) return false;
  const a = await sha256(enc.encode(password));
  const b = await sha256(enc.encode(env.DASHBOARD_PASSWORD));
  return timingSafeEqual(a, b);
}
__name(checkPassword, "checkPassword");
async function makeSessionCookie(env) {
  const payload = b64url(enc.encode(JSON.stringify({ exp: Date.now() + TTL_MS })));
  const sig = b64url(await hmac(env.COOKIE_SECRET, payload));
  const token = `${payload}.${sig}`;
  return `${COOKIE}=${token}; HttpOnly; Secure; SameSite=Lax; Path=/admin; Max-Age=${TTL_MS / 1e3}`;
}
__name(makeSessionCookie, "makeSessionCookie");
function clearSessionCookie() {
  return `${COOKIE}=; HttpOnly; Secure; SameSite=Lax; Path=/admin; Max-Age=0`;
}
__name(clearSessionCookie, "clearSessionCookie");
async function isAuthed(env, request) {
  if (!env.COOKIE_SECRET) return false;
  const cookie = request.headers.get("Cookie") ?? "";
  const m = cookie.match(/(?:^|;\s*)sess=([^;]+)/);
  if (!m) return false;
  const token = m[1];
  const dot = token.lastIndexOf(".");
  if (dot < 0) return false;
  const payload = token.slice(0, dot);
  const sig = token.slice(dot + 1);
  try {
    const expected = await hmac(env.COOKIE_SECRET, payload);
    if (!timingSafeEqual(b64urlToBytes(sig), expected)) return false;
    const parsed = JSON.parse(new TextDecoder().decode(b64urlToBytes(payload)));
    return typeof parsed.exp === "number" && Date.now() < parsed.exp;
  } catch {
    return false;
  }
}
__name(isAuthed, "isAuthed");

// src/lib/stub.ts
function buildStub(origin, slug) {
  return `loadstring(game:HttpGet("${origin}/s/${slug}"))()`;
}
__name(buildStub, "buildStub");

// src/admin-ui.ts
var STYLE = `
  :root {
    color-scheme: light;
    --bg:      #f7f7f8;
    --card:    #ffffff;
    --text:    #18181b;
    --muted:   #71717a;
    --faint:   #a1a1aa;
    --line:    #e4e4e7;
    --line2:   #d4d4d8;
    --accent:  #2563eb;
    --accent2: #1d4ed8;
    --accentbg:#eff6ff;
    --green:   #16a34a;
    --greenbg: #f0fdf4;
    --red:     #dc2626;
    --redbg:   #fef2f2;
    --shadow:  0 1px 2px rgba(24,24,27,.05), 0 1px 3px rgba(24,24,27,.06);
    --shadow2: 0 4px 12px rgba(24,24,27,.08);
    --shadow3: 0 20px 50px rgba(24,24,27,.22);
    --mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: var(--bg);
    color: var(--text);
    -webkit-font-smoothing: antialiased;
  }
  body.modal-open { overflow: hidden; }

  /* ---------- chrome ---------- */
  header {
    background: var(--card);
    border-bottom: 1px solid var(--line);
    padding: 0 24px;
    position: sticky; top: 0; z-index: 10;
  }
  .head-inner {
    max-width: 1080px; margin: 0 auto; height: 60px;
    display: flex; align-items: center; justify-content: space-between; gap: 16px;
  }
  .brand { display: flex; align-items: center; gap: 10px; font-weight: 600; font-size: 15px; letter-spacing: -.01em; }
  .brand .dot { width: 8px; height: 8px; border-radius: 999px; background: var(--green); flex: none; }
  .head-actions { display: flex; align-items: center; gap: 8px; }
  main { max-width: 1080px; margin: 0 auto; padding: 28px 24px 80px; }

  /* ---------- controls ---------- */
  input, textarea, button, select { font: inherit; color: inherit; }
  input[type=text], input[type=password], textarea {
    background: var(--card); border: 1px solid var(--line2); border-radius: 8px;
    padding: 9px 12px; width: 100%;
    transition: border-color .12s, box-shadow .12s;
  }
  input::placeholder, textarea::placeholder { color: var(--faint); }
  input[type=text]:focus, input[type=password]:focus, textarea:focus {
    outline: none; border-color: var(--accent); box-shadow: 0 0 0 3px rgba(37,99,235,.12);
  }
  button {
    cursor: pointer; border-radius: 8px; border: 1px solid var(--line2);
    background: var(--card); padding: 9px 14px; font-size: 14px; font-weight: 500;
    transition: background .12s, border-color .12s, color .12s;
    white-space: nowrap; display: inline-flex; align-items: center; gap: 7px;
  }
  button:hover { background: #f4f4f5; }
  button:active { background: #ebebed; }
  button.primary { background: var(--accent); border-color: var(--accent); color: #fff; }
  button.primary:hover { background: var(--accent2); border-color: var(--accent2); }
  button.danger { color: var(--red); }
  button.danger:hover { background: var(--redbg); border-color: #fecaca; }
  button.small { padding: 6px 11px; font-size: 13px; }
  button.big { padding: 13px 26px; font-size: 15px; }
  button:disabled { opacity: .5; cursor: default; }

  .ico { width: 15px; height: 15px; flex: none; }
  #refreshBtn.spinning .ico { animation: spin .7s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }

  /* ---------- create ---------- */
  .create-zone {
    display: flex; justify-content: center;
    padding: 6px 0 26px;
  }

  .section-label {
    font-size: 12px; font-weight: 600; text-transform: uppercase; letter-spacing: .06em;
    color: var(--faint); margin: 0 0 12px 2px;
  }

  /* ---------- script cards ---------- */
  .cards { display: flex; flex-direction: column; gap: 12px; }
  .card {
    background: var(--card); border: 1px solid var(--line); border-radius: 12px;
    box-shadow: var(--shadow); padding: 18px 20px;
    transition: box-shadow .15s, border-color .15s;
  }
  .card:hover { box-shadow: var(--shadow2); }
  .card.is-off { background: #fcfcfd; }
  .card-top { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
  .card-name { font-weight: 600; font-size: 16px; letter-spacing: -.01em; flex: 1; min-width: 140px; word-break: break-word; }

  .pill {
    font-size: 12px; font-weight: 600; padding: 3px 10px; border-radius: 999px;
    border: 1px solid transparent; white-space: nowrap;
    display: inline-flex; align-items: center; gap: 6px;
  }
  .pill .dot { width: 6px; height: 6px; border-radius: 999px; flex: none; }
  .pill.on  { color: var(--green); background: var(--greenbg); border-color: #bbf7d0; }
  .pill.on .dot  { background: var(--green); }
  .pill.off { color: var(--red);   background: var(--redbg);   border-color: #fecaca; }
  .pill.off .dot { background: var(--red); }

  /* compteur d'utilisateurs actifs en temps r\xE9el (\xE0 gauche de la pastille) */
  .live {
    display: inline-flex; align-items: center; gap: 6px; white-space: nowrap;
    font-size: 12px; font-weight: 500; color: var(--muted);
    padding: 3px 9px; border-radius: 999px; border: 1px solid var(--line); background: #fafafa;
    transition: color .2s, background .2s, border-color .2s;
  }
  .live b { color: var(--text); font-weight: 600; font-variant-numeric: tabular-nums; }
  .live .ld { width: 6px; height: 6px; border-radius: 999px; background: var(--line2); flex: none; }
  .live.on { color: var(--green); background: var(--greenbg); border-color: #bbf7d0; }
  .live.on b { color: var(--green); }
  .live.on .ld { background: var(--green); animation: livepulse 1.6s ease-out infinite; }
  @keyframes livepulse {
    0%   { box-shadow: 0 0 0 0 rgba(22,163,74,.5); }
    70%  { box-shadow: 0 0 0 5px rgba(22,163,74,0); }
    100% { box-shadow: 0 0 0 0 rgba(22,163,74,0); }
  }

  /* indicateur global temps r\xE9el dans l'en-t\xEAte */
  .head-live {
    display: inline-flex; align-items: center; gap: 6px; white-space: nowrap;
    font-size: 12.5px; color: var(--muted); padding: 5px 11px;
    border-radius: 999px; border: 1px solid #bbf7d0; background: var(--greenbg);
  }
  .head-live b { color: var(--green); font-weight: 600; font-variant-numeric: tabular-nums; }
  .head-live .ld { width: 7px; height: 7px; border-radius: 999px; background: var(--green); flex: none; animation: livepulse 1.6s ease-out infinite; }

  .switch {
    position: relative; width: 44px; height: 25px; border-radius: 999px;
    border: 1px solid var(--line2); background: #e4e4e7; padding: 0; flex: none;
    transition: background .16s, border-color .16s;
  }
  .switch:hover { background: #d8d8dc; }
  .switch .knob {
    position: absolute; top: 2px; left: 2px; width: 19px; height: 19px; border-radius: 999px;
    background: #fff; box-shadow: 0 1px 2px rgba(0,0,0,.2);
    transition: transform .16s ease;
  }
  .switch[data-on="1"] { background: var(--green); border-color: var(--green); }
  .switch[data-on="1"]:hover { background: #15803d; }
  .switch[data-on="1"] .knob { transform: translateX(19px); }

  .stub-row { display: flex; align-items: stretch; gap: 8px; margin-top: 14px; }
  .stub {
    flex: 1; min-width: 0; font-family: var(--mono); font-size: 12.5px; line-height: 1.5;
    background: #fafafa; border: 1px solid var(--line); border-radius: 8px;
    padding: 9px 12px; color: #3f3f46; overflow-x: auto; white-space: nowrap;
  }
  .stub::-webkit-scrollbar { height: 6px; }
  .stub::-webkit-scrollbar-thumb { background: var(--line2); border-radius: 999px; }

  .card-bottom {
    display: flex; align-items: center; justify-content: space-between; gap: 12px;
    margin-top: 14px; padding-top: 14px; border-top: 1px solid var(--line); flex-wrap: wrap;
  }
  .stats { display: flex; gap: 18px; font-size: 13px; color: var(--muted); flex-wrap: wrap; }
  .stats b { color: var(--text); font-weight: 600; font-variant-numeric: tabular-nums; }
  .stats .sep { color: var(--line2); }
  .actions { display: flex; gap: 8px; }

  .empty {
    background: var(--card); border: 1px dashed var(--line2); border-radius: 12px;
    padding: 44px 24px; text-align: center; color: var(--muted);
  }
  .empty strong { display: block; color: var(--text); font-size: 15px; margin-bottom: 6px; }

  /* ---------- modale ---------- */
  .overlay {
    position: fixed; inset: 0; z-index: 100;
    background: rgba(24,24,27,.5);
    -webkit-backdrop-filter: blur(4px); backdrop-filter: blur(4px);
    display: none; align-items: center; justify-content: center; padding: 24px;
    opacity: 0; transition: opacity .16s;
  }
  .overlay.open { display: flex; opacity: 1; }
  .modal {
    width: 100%; max-width: 620px; max-height: calc(100vh - 48px);
    background: var(--card); border-radius: 16px; box-shadow: var(--shadow3);
    display: flex; flex-direction: column; overflow: hidden;
    transform: translateY(8px) scale(.99); transition: transform .16s;
  }
  .overlay.open .modal { transform: none; }
  .modal-head {
    padding: 18px 22px; border-bottom: 1px solid var(--line);
    display: flex; align-items: center; justify-content: space-between; gap: 12px;
  }
  .modal-head h2 { margin: 0; font-size: 16px; font-weight: 600; letter-spacing: -.01em; }
  .modal-body { padding: 20px 22px; overflow-y: auto; }
  .modal-foot {
    padding: 14px 22px; border-top: 1px solid var(--line); background: #fcfcfd;
    display: flex; justify-content: flex-end; gap: 10px;
  }
  .field { margin-bottom: 16px; }
  .field:last-child { margin-bottom: 0; }
  .field label {
    display: block; font-size: 12.5px; font-weight: 600; color: var(--muted); margin-bottom: 6px;
  }
  .field .hint { font-weight: 400; color: var(--faint); }
  #mContent {
    font-family: var(--mono); font-size: 13px; line-height: 1.6; height: 240px;
    resize: vertical; tab-size: 2; white-space: pre; overflow-wrap: normal; overflow-x: auto;
  }
  .check { display: flex; align-items: center; gap: 9px; font-size: 14px; cursor: pointer; }
  .check input { width: 16px; height: 16px; accent-color: var(--accent); cursor: pointer; }
  .iconbtn { border: none; background: transparent; padding: 6px; border-radius: 8px; color: var(--muted); }
  .iconbtn:hover { background: #f4f4f5; color: var(--text); }

  /* ---------- modale de details ---------- */
  /* Reutilise .overlay/.modal : header + footer colles, corps qui defile. */
  .modal--wide { max-width: 940px; }
  .modal--wide .modal-body { padding: 0; }
  .ed-block { padding: 20px 22px; border-bottom: 1px solid var(--line); }
  .ed-block:last-child { border-bottom: none; }
  .ed-name {
    flex: 1; min-width: 0; font-size: 15px; font-weight: 600; color: var(--text);
    background: transparent; border: 1px solid transparent; border-radius: 8px; padding: 7px 10px;
    transition: border-color .12s, box-shadow .12s;
  }
  .ed-name:hover { border-color: var(--line2); }
  .ed-name:focus { outline: none; border-color: var(--accent); box-shadow: 0 0 0 3px rgba(37,99,235,.12); }
  #edContent {
    font-family: var(--mono); font-size: 13px; line-height: 1.6; height: 270px; width: 100%;
    resize: vertical; tab-size: 2; white-space: pre; overflow-wrap: normal; overflow-x: auto;
  }

  /* ---------- stats detaillees ---------- */
  .hint {
    display: none; gap: 10px; align-items: flex-start; margin-top: 16px;
    border-radius: 10px; padding: 12px 14px; font-size: 13px; line-height: 1.5;
  }
  .hint.show { display: flex; }
  .hint.warn { background: #fffbeb; border: 1px solid #fde68a; color: #92400e; }
  .hint.warn b { color: #78350f; }
  .hint.info { background: #f8fafc; border: 1px solid #e2e8f0; color: #64748b; }

  .kpis { display: grid; grid-template-columns: repeat(4, 1fr); gap: 10px; margin: 12px 0 4px; }
  .kpi { background: #fafafa; border: 1px solid var(--line); border-radius: 10px; padding: 12px 14px; }
  .kpi .v { font-size: 22px; font-weight: 650; letter-spacing: -.02em; font-variant-numeric: tabular-nums; }
  .kpi .k { font-size: 11.5px; color: var(--muted); margin-top: 1px; }
  .kpi.accent .v { color: var(--accent); }

  .panels { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-top: 18px; }
  .panel { border: 1px solid var(--line); border-radius: 10px; overflow: hidden; }
  .panel h3 {
    margin: 0; padding: 10px 14px; font-size: 11.5px; font-weight: 600; text-transform: uppercase;
    letter-spacing: .05em; color: var(--muted); background: #fafafa; border-bottom: 1px solid var(--line);
  }
  .panel .rows { padding: 6px 0; }
  .brow { display: flex; align-items: center; gap: 10px; padding: 6px 14px; font-size: 13px; position: relative; }
  .brow .bar {
    position: absolute; left: 0; top: 3px; bottom: 3px; background: var(--accentbg);
    border-radius: 0 6px 6px 0; z-index: 0;
  }
  .brow .lbl, .brow .n { position: relative; z-index: 1; }
  .brow .lbl { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-family: var(--mono); font-size: 12.5px; }
  .brow .n { font-variant-numeric: tabular-nums; font-weight: 600; }
  .brow .sub { position: relative; z-index: 1; color: var(--faint); font-size: 12px; }
  .panel .none { padding: 14px; color: var(--faint); font-size: 13px; }

  .logs table { width: 100%; border-collapse: collapse; font-size: 13px; }
  .logs th {
    text-align: left; font-size: 11px; font-weight: 600; text-transform: uppercase;
    letter-spacing: .05em; color: var(--faint); padding: 0 10px 8px; border-bottom: 1px solid var(--line);
  }
  .logs td { padding: 8px 10px; border-bottom: 1px solid #f4f4f5; color: var(--muted); vertical-align: top; }
  .logs td.ts { font-family: var(--mono); font-size: 12px; color: var(--text); white-space: nowrap; }
  .logs td.id { font-family: var(--mono); font-size: 12.5px; color: var(--text); }
  .logs .chip {
    display: inline-block; font-size: 12px; font-weight: 600; padding: 2px 8px; border-radius: 6px;
    background: var(--accentbg); color: var(--accent2); border: 1px solid #dbeafe;
  }
  .logs .ua { font-size: 12px; color: var(--faint); word-break: break-all; }
  .logs-scroll { overflow-x: auto; }
  .nil { color: #d4d4d8; }

  /* ---------- toast ---------- */
  .toast {
    position: fixed; bottom: 26px; left: 50%; transform: translateX(-50%) translateY(8px);
    background: var(--text); color: #fff; padding: 10px 18px; border-radius: 999px;
    font-size: 13.5px; font-weight: 500; box-shadow: var(--shadow2); z-index: 200;
    opacity: 0; pointer-events: none; transition: opacity .18s, transform .18s;
  }
  .toast.show { opacity: 1; transform: translateX(-50%) translateY(0); }

  /* ---------- mobile ---------- */
  @media (max-width: 720px) {
    .panels { grid-template-columns: 1fr; }
    .kpis { grid-template-columns: repeat(2, 1fr); }
  }
  @media (max-width: 640px) {
    main { padding: 20px 16px 60px; }
    header { padding: 0 16px; }
    .head-actions .lbl-txt { display: none; }
    .stub-row { flex-direction: column; }
    .card-bottom { flex-direction: column; align-items: flex-start; }
    .actions { width: 100%; }
    .actions button { flex: 1; justify-content: center; }
    .overlay { padding: 0; align-items: flex-end; }
    .modal { max-width: none; border-radius: 16px 16px 0 0; max-height: 92vh; }
  }
  @media (prefers-reduced-motion: reduce) {
    *, #refreshBtn.spinning .ico { transition: none !important; animation: none !important; }
  }
`;
var ICON_REFRESH = '<svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-2.64-6.36"/><path d="M21 3v6h-6"/></svg>';
var ICON_PROTO = '<svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"/><path d="M3 9h18M9 21V9"/></svg>';
var ICON_PLUS = '<svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg>';
var CLIENT_JS = `
var editingId = null;

function toast(msg) {
  var t = document.getElementById('toast');
  t.textContent = msg;
  t.classList.add('show');
  clearTimeout(t._timer);
  t._timer = setTimeout(function(){ t.classList.remove('show'); }, 1700);
}
function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}
function nil(v) {
  return (v == null || v === '') ? '<span class="nil">\u2014</span>' : esc(v);
}
function plural(n, mot) { return n + ' ' + mot + (n > 1 ? 's' : ''); }

async function api(method, url, body) {
  var opt = { method: method, headers: {} };
  if (body !== undefined) { opt.headers['Content-Type'] = 'application/json'; opt.body = JSON.stringify(body); }
  var r = await fetch(url, opt);
  if (r.status === 401) { location.href = '/admin'; throw new Error('unauth'); }
  return r.json();
}

/* ---------- liste ---------- */
async function load() {
  var data = await api('GET', '/admin/api/scripts');
  var box = document.getElementById('cards');
  if (!data.scripts.length) {
    box.innerHTML = '<div class="empty"><strong>Aucun script pour le moment</strong>'
      + 'Clique sur \xAB Creer un script \xBB pour demarrer.</div>';
    return;
  }
  var html = '';
  for (var i = 0; i < data.scripts.length; i++) {
    var s = data.scripts[i];
    var on = !!s.enabled;
    html += '<div class="card' + (on ? '' : ' is-off') + '">'
      + '<div class="card-top">'
        + '<div class="card-name">' + esc(s.name) + '</div>'
        + '<span class="live off" data-live="' + s.id + '" title="Utilisateurs actifs (temps reel)">'
          + '<span class="ld"></span><b>0</b> <span class="lw">actif</span></span>'
        + '<span class="pill ' + (on ? 'on' : 'off') + '"><span class="dot"></span>'
          + (on ? 'En ligne' : 'Coupe') + '</span>'
        + '<button class="switch" data-toggle="' + s.id + '" data-on="' + (on ? '1' : '0') + '"'
          + ' role="switch" aria-checked="' + (on ? 'true' : 'false') + '"'
          + ' aria-label="' + (on ? 'Couper' : 'Activer') + ' ' + esc(s.name) + '">'
          + '<span class="knob"></span></button>'
      + '</div>'
      + '<div class="stub-row">'
        + '<code class="stub">' + esc(s.stub) + '</code>'
        + '<button class="small" data-copy="' + esc(s.stub) + '">Copier</button>'
      + '</div>'
      + '<div class="card-bottom">'
        + '<div class="stats">'
          + '<span><b>' + s.total + '</b> ' + (s.total > 1 ? 'executions' : 'execution') + '</span>'
          + '<span class="sep">|</span>'
          + '<span><b>' + s.unique_players + '</b> ' + (s.unique_players > 1 ? 'joueurs' : 'joueur') + ' identifie' + (s.unique_players > 1 ? 's' : '') + '</span>'
          + '<span class="sep">|</span>'
          + '<span><b>' + s.unique_count + '</b> IP unique' + (s.unique_count > 1 ? 's' : '') + '</span>'
        + '</div>'
        + '<div class="actions">'
          + '<button class="small" data-edit="' + s.id + '">Details</button>'
          + '<button class="small danger" data-del="' + s.id + '" data-name="' + esc(s.name) + '">Supprimer</button>'
        + '</div>'
      + '</div></div>';
  }
  box.innerHTML = html;
  pollPresence(); // repeuple les compteurs live juste apres un re-rendu
}

/* ---------- presence temps reel ---------- */
async function pollPresence() {
  var data;
  try {
    data = await api('GET', '/admin/api/presence');
  } catch (e) {
    return; // silencieux : la presence ne doit jamais casser le dashboard
  }
  var per = (data && data.perScript) || {};
  var chips = document.querySelectorAll('.live[data-live]');
  for (var i = 0; i < chips.length; i++) {
    var el = chips[i];
    var p = per[el.getAttribute('data-live')];
    var n = (p && p.users) || 0;
    el.querySelector('b').textContent = n;
    el.querySelector('.lw').textContent = n > 1 ? 'actifs' : 'actif';
    el.classList.toggle('on', n > 0);
    el.classList.toggle('off', n === 0);
  }
  var t = (data && data.totals) || { users: 0, scripts: 0 };
  var hl = document.getElementById('headLive');
  document.getElementById('headUsers').textContent = t.users;
  document.getElementById('headUsersW').textContent = t.users > 1 ? 'actifs' : 'actif';
  document.getElementById('headScripts').textContent = t.scripts;
  document.getElementById('headScriptsW').textContent = t.scripts > 1 ? 'en cours' : 'en cours';
  hl.style.display = t.users > 0 ? '' : 'none';
}

/* ---------- stats detaillees ---------- */
function breakdown(rows, total, withPlayers) {
  if (!rows || !rows.length) return '<div class="none">Aucune donnee.</div>';
  var h = '';
  for (var i = 0; i < rows.length; i++) {
    var r = rows[i];
    var pct = total > 0 ? Math.round((r.n / total) * 100) : 0;
    var label = (r.label == null || r.label === '?') ? 'non renseigne' : r.label;
    h += '<div class="brow">'
      + '<span class="bar" style="width:' + pct + '%"></span>'
      + '<span class="lbl">' + esc(label) + '</span>'
      + (withPlayers && r.players != null ? '<span class="sub">' + r.players + ' j.</span>' : '')
      + '<span class="n">' + r.n + '</span>'
      + '</div>';
  }
  return h;
}

function renderStats(st) {
  var t = st.totals || {};
  var total = Number(t.total || 0);
  var players = Number(t.unique_players || 0);

  // Une colonne vide n'est pas forcement un bug : elle veut dire que le stub
  // utilise ne transmettait rien. On le dit, au lieu d'afficher du vide muet.
  var hint = document.getElementById('statsHint');
  hint.className = 'hint';
  if (total === 0) {
    hint.className = 'hint show info';
    hint.innerHTML = '<span>\u25CB</span><div>Aucune execution enregistree pour ce script. '
      + 'Le stub ci-dessus n\\'a pas encore ete lance, ou le script etait coupe a ce moment-la '
      + '(un script OFF ne compte pas d\\'execution).</div>';
  } else if (players === 0) {
    hint.className = 'hint show warn';
    var s = total > 1 ? 's' : '';
    hint.innerHTML = '<span>\u26A0\uFE0F</span><div><b>' + (total > 1 ? 'Ces ' : 'Cette ') + total
      + ' execution' + s + ' ne porte' + (total > 1 ? 'nt' : '') + ' aucune identification.</b> '
      + (total > 1 ? 'Elles viennent' : 'Elle vient') + ' d\\'un stub distribue avant la mise en place de la telemetrie : '
      + 'l\\'ancien stub ne transmettait ni executor, ni UserId, ni PlaceId. '
      + 'Re-copie le stub depuis la carte du script et redonne-le a tes clients \u2014 '
      + 'les prochaines executions rempliront ces colonnes.</div>';
  }

  document.getElementById('kpis').innerHTML =
      kpi(total, 'executions', false)
    + kpi(Number(t.unique_players || 0), 'joueurs uniques (UserId)', true)
    + kpi(Number(t.unique_ips || 0), 'IP uniques', false)
    + kpi(Number(t.sans_uid || 0), 'sans identification', false);

  document.getElementById('byExecutor').innerHTML = breakdown(st.byExecutor, total, true);
  document.getElementById('byPlace').innerHTML = breakdown(st.byPlace, total, false);
  document.getElementById('topPlayers').innerHTML = breakdown(st.topPlayers, total, false);
}
function kpi(v, label, accent) {
  return '<div class="kpi' + (accent ? ' accent' : '') + '"><div class="v">' + v + '</div>'
    + '<div class="k">' + label + '</div></div>';
}

/* ---------- editeur / details ---------- */
async function openEditor(id) {
  var data = await api('GET', '/admin/api/scripts/' + id);
  editingId = id;
  document.getElementById('edName').value = data.script.name;
  document.getElementById('edContent').value = data.script.content;

  var on = !!data.script.enabled;
  var pill = document.getElementById('edStatus');
  pill.className = 'pill ' + (on ? 'on' : 'off');
  pill.style.display = '';
  pill.querySelector('.txt').textContent = on ? 'En ligne' : 'Coupe';

  renderStats(data.stats || {});

  var lr = document.getElementById('logRows');
  if (!data.logs.length) {
    lr.innerHTML = '<tr><td colspan="5" style="padding:18px 10px;color:#a1a1aa">Aucune execution enregistree.</td></tr>';
  } else {
    var h = '';
    for (var i = 0; i < data.logs.length; i++) {
      var l = data.logs[i];
      h += '<tr>'
        + '<td class="ts">' + esc(l.ts) + '</td>'
        + '<td>' + (l.executor ? '<span class="chip">' + esc(l.executor) + '</span>' : '<span class="nil">\u2014</span>') + '</td>'
        + '<td class="id">' + nil(l.user_id) + '</td>'
        + '<td class="id">' + nil(l.place_id) + '</td>'
        + '<td class="ua">' + nil((l.user_agent || '').slice(0, 48)) + '</td></tr>';
    }
    lr.innerHTML = h;
  }
  document.getElementById('editorOverlay').classList.add('open');
  document.body.classList.add('modal-open');
}

function closeEditor() {
  document.getElementById('editorOverlay').classList.remove('open');
  document.body.classList.remove('modal-open');
  editingId = null;
}

/* ---------- modale de creation ---------- */
function openModal() {
  document.getElementById('mName').value = '';
  document.getElementById('mContent').value = '-- code Luau\\n';
  document.getElementById('mEnabled').checked = true;
  document.getElementById('overlay').classList.add('open');
  document.body.classList.add('modal-open');
  setTimeout(function(){ document.getElementById('mName').focus(); }, 30);
}
function closeModal() {
  document.getElementById('overlay').classList.remove('open');
  document.body.classList.remove('modal-open');
}
async function submitModal() {
  var name = document.getElementById('mName').value.trim();
  if (!name) { document.getElementById('mName').focus(); toast('Il faut un nom'); return; }
  var btn = document.getElementById('mCreate');
  btn.disabled = true;
  try {
    var res = await api('POST', '/admin/api/scripts', {
      name: name,
      content: document.getElementById('mContent').value,
      enabled: document.getElementById('mEnabled').checked
    });
    closeModal();
    await load();
    openEditor(res.script.id);
    toast('Script cree');
  } finally {
    btn.disabled = false;
  }
}

/* ---------- evenements ---------- */
document.addEventListener('click', async function(e) {
  var t = e.target;
  if (!t || !t.closest) return;

  var copyBtn = t.closest('[data-copy]');
  if (copyBtn) {
    var txt = copyBtn.getAttribute('data-copy');
    try { await navigator.clipboard.writeText(txt); }
    catch (err) {
      var ta = document.createElement('textarea');
      ta.value = txt; document.body.appendChild(ta); ta.select();
      document.execCommand('copy'); document.body.removeChild(ta);
    }
    var old = copyBtn.textContent;
    copyBtn.textContent = 'Copie !';
    setTimeout(function(){ copyBtn.textContent = old; }, 1200);
    toast('Stub copie dans le presse-papiers');
    return;
  }

  var sw = t.closest('[data-toggle]');
  if (sw) {
    var turningOn = sw.getAttribute('data-on') !== '1';
    sw.setAttribute('data-on', turningOn ? '1' : '0');
    await api('PUT', '/admin/api/scripts/' + sw.getAttribute('data-toggle'), { enabled: turningOn });
    await load();
    toast(turningOn ? 'Script remis en ligne' : 'Script coupe');
    return;
  }

  var ed = t.closest('[data-edit]');
  if (ed) { openEditor(ed.getAttribute('data-edit')); return; }

  var del = t.closest('[data-del]');
  if (del) {
    var id = del.getAttribute('data-del');
    if (confirm('Supprimer "' + del.getAttribute('data-name') + '" et tous ses logs ?')) {
      await api('DELETE', '/admin/api/scripts/' + id);
      if (editingId === id) closeEditor();
      await load();
      toast('Script supprime');
    }
  }
});

document.getElementById('refreshBtn').addEventListener('click', refresh);
async function refresh() {
  var btn = document.getElementById('refreshBtn');
  btn.classList.add('spinning');
  btn.disabled = true;
  try {
    await load();
    if (editingId) await openEditor(editingId);  // recharge aussi stats + logs ouverts
    toast('Compteurs a jour');
  } finally {
    btn.classList.remove('spinning');
    btn.disabled = false;
  }
}

document.getElementById('openModalBtn').addEventListener('click', openModal);
document.getElementById('mCreate').addEventListener('click', submitModal);
document.getElementById('mCancel').addEventListener('click', closeModal);
document.getElementById('mClose').addEventListener('click', closeModal);
document.getElementById('overlay').addEventListener('mousedown', function(e) {
  if (e.target === this) closeModal();   // clic sur le fond assombri seulement
});
document.getElementById('mName').addEventListener('keydown', function(e) {
  if (e.key === 'Enter') { e.preventDefault(); document.getElementById('mContent').focus(); }
});

document.getElementById('saveBtn').addEventListener('click', async function() {
  if (!editingId) return;
  await api('PUT', '/admin/api/scripts/' + editingId, {
    name: document.getElementById('edName').value,
    content: document.getElementById('edContent').value
  });
  await load();
  toast('Modifications enregistrees');
});
document.getElementById('closeBtn').addEventListener('click', closeEditor);
document.getElementById('edCloseX').addEventListener('click', closeEditor);
// Pas de fermeture au clic sur le fond pour le detail : evite de perdre des
// modifs de code par un clic a cote. On ferme via Echap, la croix ou Fermer.

// Tab insere une indentation dans les deux zones de code.
function tabHandler(e) {
  if (e.key !== 'Tab') return;
  e.preventDefault();
  var el = this, start = el.selectionStart, end = el.selectionEnd;
  el.value = el.value.slice(0, start) + '\\t' + el.value.slice(end);
  el.selectionStart = el.selectionEnd = start + 1;
}
document.getElementById('edContent').addEventListener('keydown', tabHandler);
document.getElementById('mContent').addEventListener('keydown', tabHandler);

document.addEventListener('keydown', function(e) {
  var creationOpen = document.getElementById('overlay').classList.contains('open');
  var detailsOpen = document.getElementById('editorOverlay').classList.contains('open');
  if (e.key === 'Escape') {
    if (creationOpen) closeModal();
    else if (detailsOpen) closeEditor();
    return;
  }
  if ((e.metaKey || e.ctrlKey) && e.key === 'Enter' && creationOpen) { e.preventDefault(); submitModal(); return; }
  if ((e.metaKey || e.ctrlKey) && e.key === 's' && detailsOpen) {
    e.preventDefault();
    document.getElementById('saveBtn').click();
  }
});

load();

// Presence temps reel : poll toutes les 10 s, en pause quand l'onglet est cache
// (economise des requetes). Reprise immediate au retour sur l'onglet.
setInterval(function () { if (!document.hidden) pollPresence(); }, 10000);
document.addEventListener('visibilitychange', function () { if (!document.hidden) pollPresence(); });
`;
function loginPage(error) {
  return `<!doctype html><html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Kill switch \u2014 connexion</title><style>${STYLE}
  body { display: flex; align-items: center; justify-content: center; min-height: 100vh; padding: 24px; }
  .login { width: 100%; max-width: 360px; }
  .login-card {
    background: var(--card); border: 1px solid var(--line); border-radius: 14px;
    box-shadow: var(--shadow2); padding: 28px;
  }
  .login h1 {
    margin: 0 0 4px; font-size: 18px; font-weight: 600; letter-spacing: -.02em;
    display: flex; align-items: center; gap: 9px;
  }
  .login h1 .dot { width: 8px; height: 8px; border-radius: 999px; background: var(--green); }
  .login p.sub { margin: 0 0 22px; color: var(--muted); font-size: 13.5px; }
  .login form { display: flex; flex-direction: column; gap: 12px; }
  .login button { justify-content: center; }
  .err {
    color: var(--red); background: var(--redbg); border: 1px solid #fecaca;
    border-radius: 8px; padding: 9px 12px; font-size: 13px;
  }
</style></head><body>
<div class="login">
  <div class="login-card">
    <h1><span class="dot"></span>Script kill switch</h1>
    <p class="sub">Acces reserve.</p>
    <form method="POST" action="/admin/login">
      <input type="password" name="password" placeholder="Mot de passe" autofocus required>
      <button class="primary" type="submit">Se connecter</button>
      ${error ? '<div class="err">Mot de passe incorrect.</div>' : ""}
    </form>
  </div>
</div></body></html>`;
}
__name(loginPage, "loginPage");
function dashboardPage() {
  return `<!doctype html><html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Kill switch</title><style>${STYLE}</style></head><body>
<header>
  <div class="head-inner">
    <div class="brand"><span class="dot"></span>Script kill switch</div>
    <div class="head-actions">
      <span class="head-live" id="headLive" style="display:none" title="En temps reel (~10 s)">
        <span class="ld"></span><b id="headUsers">0</b>&nbsp;<span id="headUsersW">actif</span>
        <span style="color:var(--line2)">\xB7</span>
        <b id="headScripts">0</b>&nbsp;<span id="headScriptsW">en cours</span>
      </span>
      <button class="small" id="refreshBtn" title="Recharger les compteurs">
        ${ICON_REFRESH}<span class="lbl-txt">Actualiser</span>
      </button>
      <a href="/admin/prototype"><button class="small" title="Apercu des panneaux in-game">
        ${ICON_PROTO}<span class="lbl-txt">Prototype</span>
      </button></a>
      <form method="POST" action="/admin/logout" style="display:inline">
        <button class="small" type="submit">Deconnexion</button>
      </form>
    </div>
  </div>
</header>
<main>
  <div class="create-zone">
    <button class="primary big" id="openModalBtn">${ICON_PLUS}Creer un script</button>
  </div>

  <div class="section-label">Scripts</div>
  <div class="cards" id="cards">
    <div class="empty">Chargement\u2026</div>
  </div>

</main>

<div class="overlay" id="overlay">
  <div class="modal" role="dialog" aria-modal="true" aria-labelledby="mTitle">
    <div class="modal-head">
      <h2 id="mTitle">Nouveau script</h2>
      <button class="iconbtn" id="mClose" aria-label="Fermer">\u2715</button>
    </div>
    <div class="modal-body">
      <div class="field">
        <label for="mName">Nom</label>
        <input type="text" id="mName" placeholder="ex. Drain Simulator" autocomplete="off">
      </div>
      <div class="field">
        <label for="mContent">Code Luau <span class="hint">\u2014 modifiable ensuite a tout moment</span></label>
        <textarea id="mContent" spellcheck="false"></textarea>
      </div>
      <div class="field">
        <label class="check"><input type="checkbox" id="mEnabled" checked> Mettre en ligne des la creation</label>
      </div>
    </div>
    <div class="modal-foot">
      <button id="mCancel">Annuler</button>
      <button class="primary" id="mCreate">Creer le script</button>
    </div>
  </div>
</div>

<div class="overlay" id="editorOverlay">
  <div class="modal modal--wide" role="dialog" aria-modal="true" aria-labelledby="edName">
    <div class="modal-head">
      <input type="text" id="edName" class="ed-name" placeholder="Nom du script" aria-label="Nom du script">
      <span class="pill" id="edStatus" style="display:none"><span class="dot"></span><span class="txt"></span></span>
      <button class="iconbtn" id="edCloseX" aria-label="Fermer">\u2715</button>
    </div>
    <div class="modal-body">
      <div class="ed-block">
        <div class="section-label">Code Luau</div>
        <textarea id="edContent" spellcheck="false" placeholder="-- code Luau"></textarea>
      </div>

      <div class="ed-block">
        <div class="section-label">Statistiques</div>
        <div class="hint" id="statsHint"></div>
        <div class="kpis" id="kpis"></div>
        <div class="panels">
          <div class="panel">
            <h3>Par executor</h3>
            <div class="rows" id="byExecutor"></div>
          </div>
          <div class="panel">
            <h3>Par PlaceId</h3>
            <div class="rows" id="byPlace"></div>
          </div>
        </div>
        <div class="panels" style="grid-template-columns:1fr">
          <div class="panel">
            <h3>Joueurs les plus actifs (UserId)</h3>
            <div class="rows" id="topPlayers"></div>
          </div>
        </div>
      </div>

      <div class="ed-block logs">
        <div class="section-label">Dernieres executions (UTC)</div>
        <div class="logs-scroll">
          <table>
            <thead><tr><th>Quand</th><th>Executor</th><th>UserId</th><th>PlaceId</th><th>User-agent</th></tr></thead>
            <tbody id="logRows"></tbody>
          </table>
        </div>
      </div>
    </div>
    <div class="modal-foot">
      <button id="closeBtn">Fermer</button>
      <button class="primary" id="saveBtn">Enregistrer</button>
    </div>
  </div>
</div>

<div class="toast" id="toast"></div>
<script>
${CLIENT_JS}
<\/script>
</body></html>`;
}
__name(dashboardPage, "dashboardPage");

// src/prototype-ui.ts
var PROTO_STYLE = `
  *, *::before, *::after { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100vh;
    font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: #f7f7f8; color: #18181b; -webkit-font-smoothing: antialiased;
  }
  header {
    background: #fff; border-bottom: 1px solid #e4e4e7; padding: 0 24px;
    position: sticky; top: 0; z-index: 10;
  }
  .head-inner {
    max-width: 1180px; margin: 0 auto; height: 60px;
    display: flex; align-items: center; justify-content: space-between; gap: 16px;
  }
  .brand { display: flex; align-items: center; gap: 10px; font-weight: 600; letter-spacing: -.01em; }
  .brand .dot { width: 8px; height: 8px; border-radius: 999px; background: #a855f7; }
  a.back {
    text-decoration: none; color: #18181b; border: 1px solid #d4d4d8; background: #fff;
    border-radius: 8px; padding: 6px 12px; font-size: 13px; font-weight: 500;
  }
  a.back:hover { background: #f4f4f5; }
  main { max-width: 1180px; margin: 0 auto; padding: 26px 24px 80px; }

  .notice {
    display: flex; gap: 11px; align-items: flex-start;
    background: #faf5ff; border: 1px solid #e9d5ff; border-radius: 10px;
    padding: 13px 16px; font-size: 13.5px; color: #6b21a8; margin-bottom: 24px;
  }
  .notice b { color: #581c87; }

  .bar {
    display: flex; align-items: center; justify-content: space-between;
    gap: 16px; flex-wrap: wrap; margin-bottom: 18px;
  }
  .seg { display: inline-flex; background: #efeff1; border-radius: 9px; padding: 3px; gap: 3px; }
  .seg button {
    border: none; background: transparent; border-radius: 7px; padding: 7px 15px;
    font: inherit; font-size: 13.5px; font-weight: 550; color: #71717a; cursor: pointer;
  }
  .seg button.on { background: #fff; color: #18181b; box-shadow: 0 1px 2px rgba(0,0,0,.08); }

  .swatches { display: flex; gap: 8px; flex-wrap: wrap; }
  .sw { display: flex; align-items: center; gap: 7px; font-size: 11.5px; color: #71717a; }
  .sw i {
    width: 17px; height: 17px; border-radius: 5px; display: block;
    border: 1px solid rgba(0,0,0,.12);
  }
  .sw code { font-family: ui-monospace, Menlo, monospace; font-size: 11px; color: #52525b; }

  /* ---------- scene ---------- */
  .stage {
    border-radius: 16px; padding: 40px 28px; display: flex; gap: 34px;
    align-items: flex-start; justify-content: center; flex-wrap: wrap;
    background:
      radial-gradient(900px 380px at 30% -10%, rgba(168,85,247,.16), transparent 70%),
      linear-gradient(160deg, #2a2438 0%, #17141f 55%, #100e16 100%);
    border: 1px solid #d4d4d8;
    overflow-x: auto;
  }
  .stage[data-theme="actuel"] {
    background:
      radial-gradient(900px 380px at 30% -10%, rgba(88,166,255,.12), transparent 70%),
      linear-gradient(160deg, #23262e 0%, #15171c 55%, #101216 100%);
  }
  .shot { display: flex; flex-direction: column; align-items: center; gap: 12px; }
  .shot .cap { color: #d8d2e6; font-size: 12.5px; font-weight: 500; letter-spacing: .01em; }
  .shot .cap span { color: #8f86a4; }

  /* ---------- palettes ---------- */
  .stage[data-theme="amethyste"] {
    --bg:     #150F1E;
    --card:   #1F1730;
    --card2:  #2C2142;
    --line:   #443159;
    --text:   #F2ECFB;
    --muted:  #A896C4;
    --accent: #A855F7;
    --accent-soft: #C9A7FF;
    --ok:     #5EE9B5;
    --warn:   #F0B429;
    --danger: #FB7185;
    --glow:   0 0 0 1px rgba(168,85,247,.35), 0 6px 22px rgba(168,85,247,.28);
    --winshadow: 0 26px 60px rgba(10,4,20,.62), 0 0 0 1px rgba(168,85,247,.16);
  }
  .stage[data-theme="actuel"] {
    --bg:     #121317;
    --card:   #1B1D23;
    --card2:  #24272F;
    --line:   #343842;
    --text:   #EEEFF3;
    --muted:  #8B909E;
    --accent: #58A6FF;
    --accent-soft: #58A6FF;
    --ok:     #3FB950;
    --warn:   #E2A836;
    --danger: #F85149;
    --glow:   none;
    --winshadow: 0 20px 46px rgba(0,0,0,.5);
  }

  /* ---------- fenetre commune ---------- */
  .win {
    position: relative; background: var(--bg); border: 1px solid var(--line);
    box-shadow: var(--winshadow); overflow: hidden; flex: none;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    color: var(--text);
  }
  .stage[data-theme="amethyste"] .win::before {
    content: ""; position: absolute; inset: 0; pointer-events: none;
    background: radial-gradient(120% 60% at 50% 0%, rgba(168,85,247,.10), transparent 60%);
  }
  .abs { position: absolute; }
  .accent-bar { background: var(--accent); border-radius: 1px; }
  .stage[data-theme="amethyste"] .accent-bar {
    background: linear-gradient(180deg, var(--accent-soft), var(--accent));
    box-shadow: 0 0 10px rgba(168,85,247,.7);
  }
  .close {
    background: var(--card2); border: none; border-radius: 7px; color: var(--muted);
    font-size: 13px; font-weight: 700; display: flex; align-items: center; justify-content: center;
  }
  .card {
    background: var(--card); border: 1px solid var(--line); border-radius: 12px; position: relative;
  }
  .lbl-mini { font-size: 10px; font-weight: 700; color: var(--muted); letter-spacing: .04em; }
  .muted { color: var(--muted); }

  /* switch */
  .sw-track {
    background: var(--card2); border: 1px solid var(--line); border-radius: 13px; position: relative;
  }
  .sw-knob { position: absolute; background: var(--muted); border-radius: 999px; }
  .sw-track.on { background: var(--accent); border-color: var(--accent); }
  .stage[data-theme="amethyste"] .sw-track.on { box-shadow: var(--glow); }
  .sw-track.on .sw-knob { background: #fff; }

  /* ---------- panneau A : Drain Simulator (380x324, aere) ---------- */
  .winA { width: 380px; height: 324px; border-radius: 14px; }
  .winA .top { position: absolute; inset: 0 0 auto 0; height: 48px; background: var(--card); }
  .winA .bodyA { position: absolute; left: 18px; top: 58px; width: 344px;
                 display: flex; flex-direction: column; gap: 14px; }
  /* space-between plutot qu'un positionnement absolu : .sw-track declare
     position:relative et, a specificite egale, l'emporte sur .abs par ordre
     source \u2014 le switch resterait dans le flux et chevaucherait le libelle. */
  .winA .toggle {
    height: 62px; background: var(--card2); border: 1px solid var(--line); border-radius: 12px;
    display: flex; align-items: center; justify-content: space-between;
    padding: 0 18px; position: relative;
  }
  .winA .toggle .sw-track { width: 50px; height: 26px; flex: none; }
  .winA .toggle .sw-knob { width: 20px; height: 20px; top: 2px; left: 2px; }
  .winA .toggle .sw-track.on .sw-knob { left: 26px; }
  .winA .toggle.on { background: rgba(168,85,247,.14); border-color: rgba(168,85,247,.45); }
  .stage[data-theme="actuel"] .winA .toggle.on { background: #1E362A; border-color: #2C5A3F; }
  .winA .toggle .t { font-size: 16px; font-weight: 700; }
  .winA .total { height: 94px; padding: 14px 16px 0; }
  .winA .total .v { font-size: 32px; font-weight: 700; color: var(--ok); line-height: 1.12; letter-spacing: -.02em; margin-top: 2px; }
  .winA .total .r { font-size: 11px; color: var(--warn); margin-top: 3px; }
  .winA .speed { height: 70px; padding: 14px 16px 0; }
  .winA .track {
    position: absolute; left: 16px; right: 16px; top: 34px; height: 8px;
    background: var(--bg); border: 1px solid var(--line); border-radius: 4px;
  }
  .winA .fill { position: absolute; inset: 0 auto 0 0; width: 34%; background: var(--accent); border-radius: 4px; }
  .stage[data-theme="amethyste"] .winA .fill {
    background: linear-gradient(90deg, var(--accent), var(--accent-soft));
    box-shadow: 0 0 12px rgba(168,85,247,.55);
  }
  .winA .knob2 {
    position: absolute; top: 50%; left: 34%; width: 16px; height: 16px; margin: -8px 0 0 -8px;
    background: var(--text); border-radius: 999px;
  }
  .stage[data-theme="amethyste"] .winA .knob2 { box-shadow: 0 0 0 3px rgba(168,85,247,.28); }

  /* ---------- panneau B : Loan Officer (466x650, aere) ---------- */
  .winB { width: 466px; height: 650px; border-radius: 14px; }
  .winB .bodyB { position: absolute; left: 20px; top: 60px; width: 426px;
                 display: flex; flex-direction: column; gap: 14px; }
  .winB .client { height: 142px; padding: 16px 18px; }
  .winB .client .name { font-size: 24px; font-weight: 700; letter-spacing: -.01em; margin-top: 6px; }
  .winB .badge {
    position: absolute; right: 18px; top: 16px; width: 112px; height: 28px; border-radius: 8px;
    background: var(--card2); display: flex; align-items: center; justify-content: center;
    font-size: 12px; font-weight: 700; color: var(--muted); letter-spacing: .04em;
  }
  .winB .divider { position: absolute; left: 18px; right: 18px; top: 66px; height: 1px; background: var(--line); }
  .winB .reason { font-size: 12px; color: var(--muted); margin-top: 30px; }
  .winB .row { height: 60px; padding: 14px 18px; }
  .winB .row .n { font-size: 14px; font-weight: 600; }
  .winB .row .d { font-size: 11px; color: var(--muted); margin-top: 3px; }
  .winB .row .d.err { color: var(--danger); }
  .winB .row .sw-track { position: absolute; right: 18px; top: 50%; margin-top: -13px; width: 46px; height: 26px; }
  .winB .row .sw-knob { width: 20px; height: 20px; top: 2px; left: 2px; }
  .winB .row .sw-track.on .sw-knob { left: 22px; }
  .winB .stats { height: 64px; display: flex; gap: 12px; }
  .winB .stat { flex: 1; padding: 12px 14px; }
  .winB .stat .v { font-size: 20px; font-weight: 700; margin-top: 3px; letter-spacing: -.01em; }
  .winB .logc { height: 124px; padding: 12px 16px; overflow: hidden; }
  .winB .logc div { font-size: 11px; color: var(--muted); margin-bottom: 4px; }
  .winB .logc .a { color: var(--accent-soft); }
  .winB .logc .g { color: var(--ok); }

  /* ---------- panneau C : Offline notice (410x124, aere) ---------- */
  .winC { width: 410px; height: 124px; border-radius: 16px; }
  .winC .title { font-size: 15px; font-weight: 700; letter-spacing: -.01em; }
  .winC .sub { font-size: 12px; color: var(--muted); line-height: 1.4; }
  .winC .sig {
    display: flex; align-items: center; gap: 8px;
    font-size: 12px; font-weight: 600; color: var(--accent-soft);
  }
  .winC .sig i { width: 6px; height: 6px; border-radius: 3px; background: var(--accent); flex: none; }
  .winC .pbar { position: absolute; left: 0; bottom: 0; height: 3px; background: var(--accent); border-radius: 0 2px 2px 0; }
  .stage[data-theme="amethyste"] .winC .pbar {
    background: linear-gradient(90deg, var(--accent), var(--accent-soft));
    box-shadow: 0 0 10px rgba(168,85,247,.6);
  }

  /* ---------- panneau D : RV Cooked (380x480) ---------- */
  .winD { width: 380px; height: 480px; border-radius: 14px; }
  .winD .top { position: absolute; inset: 0 0 auto 0; height: 50px; background: var(--card); }
  .winD .bodyD {
    position: absolute; left: 10px; right: 10px; top: 56px; bottom: 10px;
    display: flex; flex-direction: column; gap: 12px; overflow: hidden;
  }
  .winD .rvcard {
    background: var(--card); border: 1px solid var(--line); border-radius: 12px;
    padding: 14px; display: flex; flex-direction: column; gap: 10px;
  }
  .winD .rvhead { display: flex; align-items: center; justify-content: space-between; gap: 10px; }
  .winD .rvtitle { font-size: 14px; font-weight: 700; color: var(--text); }
  .winD .sw-track { width: 46px; height: 24px; flex: none; border-radius: 12px; }
  .winD .sw-knob { width: 18px; height: 18px; top: 2px; left: 2px; }
  .winD .sw-track.on .sw-knob { left: 25px; }
  .winD .rslider { display: flex; align-items: center; gap: 10px; }
  .winD .rtrack { flex: 1; height: 8px; background: var(--bg); border: 1px solid var(--line); border-radius: 4px; position: relative; }
  .winD .rfill { position: absolute; inset: 0 auto 0 0; background: var(--accent); border-radius: 4px; }
  .stage[data-theme="amethyste"] .winD .rfill {
    background: linear-gradient(90deg, var(--accent), var(--accent-soft)); box-shadow: 0 0 10px rgba(168,85,247,.5);
  }
  .winD .rknob { position: absolute; top: 50%; width: 18px; height: 18px; margin: -9px 0 0 -9px; background: var(--text); border-radius: 999px; }
  .winD .rval { font-family: ui-monospace, Menlo, monospace; font-size: 13px; color: var(--text); min-width: 34px; text-align: right; }
  .winD .tpgrid { display: flex; gap: 8px; flex-wrap: wrap; }
  .winD .tpbtn {
    width: 50px; height: 34px; display: flex; align-items: center; justify-content: center;
    background: var(--card2); border-radius: 7px; font-size: 12px; font-weight: 700; color: var(--text);
  }
  .winD .endbtn {
    height: 36px; display: flex; align-items: center; justify-content: center;
    background: var(--accent); border-radius: 8px; font-size: 13px; font-weight: 700; color: #fff;
  }
  .stage[data-theme="amethyste"] .winD .endbtn { box-shadow: var(--glow); }
  /* affordance de scroll : degrade de fondu en bas + barre laterale visible */
  .winD .bodyD::after {
    content: ""; position: absolute; left: 0; right: 0; bottom: 0; height: 40px;
    background: linear-gradient(to top, var(--bg), transparent); pointer-events: none;
  }
  .winD .scrollbar { position: absolute; right: 4px; top: 60px; width: 5px; height: 120px; border-radius: 3px; background: var(--accent-soft); opacity: .5; }
  .winD .tkrow { display: flex; gap: 8px; }
  .winD .tkdd {
    flex: 1; height: 34px; display: flex; align-items: center; padding: 0 10px;
    background: var(--card2); border: 1px solid var(--line); border-radius: 7px;
    font-family: ui-monospace, Menlo, monospace; font-size: 12px; color: var(--muted);
  }
  .winD .tkref { width: 60px; height: 34px; display: flex; align-items: center; justify-content: center; background: var(--accent); border-radius: 7px; font-size: 12px; font-weight: 700; color: #fff; }
  .winD .tkbtns { display: flex; gap: 10px; }
  .winD .tkgrab { width: 130px; height: 34px; display: flex; align-items: center; justify-content: center; background: var(--accent); border-radius: 8px; font-size: 13px; font-weight: 700; color: #fff; }
  .winD .tkrel { width: 100px; height: 34px; display: flex; align-items: center; justify-content: center; background: var(--card2); border-radius: 8px; font-size: 13px; font-weight: 700; color: var(--text); }

  @media (max-width: 900px) { .stage { padding: 26px 14px; gap: 26px; } }
`;
var PROTO_JS = `
var stage = document.getElementById('stage');
var btns = document.querySelectorAll('.seg button');
for (var i = 0; i < btns.length; i++) {
  btns[i].addEventListener('click', function() {
    for (var j = 0; j < btns.length; j++) btns[j].classList.remove('on');
    this.classList.add('on');
    stage.setAttribute('data-theme', this.getAttribute('data-theme'));
  });
}
`;
var SWATCHES = [
  ["#150F1E", "background"],
  ["#1F1730", "card"],
  ["#2C2142", "card 2"],
  ["#443159", "border"],
  ["#A855F7", "amethyst"],
  ["#C9A7FF", "lilac"],
  ["#5EE9B5", "value"],
  ["#FB7185", "alert"]
];
function panelA() {
  return `<div class="win winA">
  <div class="top"></div>
  <div class="abs accent-bar" style="left:18px;top:14px;width:4px;height:22px"></div>
  <div class="abs" style="left:32px;top:10px;font-size:13px;font-weight:700;letter-spacing:.02em">DRAIN SIMULATOR</div>
  <div class="abs muted" style="left:32px;top:28px;font-size:11px">By @LaaTortueJaune</div>
  <button class="close abs" style="right:12px;top:11px;width:28px;height:26px">X</button>

  <div class="bodyA">
    <div class="toggle on">
      <div class="t">GENERATE MONEY</div>
      <div class="sw-track on"><div class="sw-knob"></div></div>
    </div>

    <div class="card total">
      <div class="lbl-mini">TOTAL GENERATED</div>
      <div class="v">$128,400</div>
      <div class="r">Server pays $250 per report</div>
    </div>

    <div class="card speed">
      <div class="muted" style="font-size:11px">Speed: 85 reports / sec</div>
      <div class="track"><div class="fill"></div><div class="knob2"></div></div>
    </div>
  </div>
</div>`;
}
__name(panelA, "panelA");
function panelB() {
  const row = /* @__PURE__ */ __name((n, d, on, err = false) => `<div class="card row">
      <div class="n">${n}</div>
      <div class="d${err ? " err" : ""}">${d}</div>
      <div class="sw-track${on ? " on" : ""}"><div class="sw-knob" style="${on ? "left:22px" : ""}"></div></div>
    </div>`, "row");
  const stat = /* @__PURE__ */ __name((k, v, color) => `<div class="card stat">
        <div class="lbl-mini">${k}</div>
        <div class="v"${color ? ` style="color:${color}"` : ""}>${v}</div>
      </div>`, "stat");
  return `<div class="win winB">
  <div class="abs accent-bar" style="left:22px;top:18px;width:4px;height:24px"></div>
  <div class="abs" style="left:34px;top:13px;font-size:16px;font-weight:700;letter-spacing:-.01em">Work as a Loan Officer Remastered</div>
  <div class="abs muted" style="left:34px;top:34px;font-size:11px">By @LaaTortueJaune</div>
  <button class="close abs" style="right:18px;top:16px;width:28px;height:26px">X</button>

  <div class="bodyB">
    <div class="card client">
      <div class="lbl-mini">CUSTOMER AT THE DESK</div>
      <div class="name">Marcus Webb</div>
      <div class="badge">WAITING</div>
      <div class="divider"></div>
      <div class="reason">Credit score below threshold \u2014 recommendation is to deny.</div>
    </div>

    ${row("Automatic decision", "Approves or denies on its own, reading nothing", true)}
    ${row("Refusal handling", "Ejects customers who refuse to leave", false)}
    ${row("Automatic dialogue", "fireclickdetector unavailable on this executor", false, true)}

    <div class="stats">
      ${stat("DECISIONS", "47")}
      ${stat("CITATIONS", "2", "var(--danger)")}
      ${stat("ACCURACY", "96%", "var(--ok)")}
    </div>

    <div class="card logc">
      <div class="g">Automatic decision enabled</div>
      <div>Customer approved, score 812</div>
      <div class="a">Narrative choice resolved automatically, option 2</div>
      <div>Customer denied, score 340</div>
      <div>Waiting for a customer...</div>
    </div>
  </div>
</div>`;
}
__name(panelB, "panelB");
function panelC() {
  return `<div class="win winC">
  <div class="abs accent-bar" style="left:20px;top:22px;width:4px;height:48px"></div>
  <div class="abs title" style="left:36px;top:20px">Script temporarily offline</div>
  <div class="abs sub" style="left:36px;top:44px;width:344px">Maintenance in progress. It will be back online as soon as possible.</div>
  <div class="abs sig" style="left:36px;top:90px"><i></i>By @LaaTortueJaune</div>
  <button class="close abs" style="right:12px;top:18px;width:26px;height:26px">X</button>
  <div class="pbar" style="width:56%"></div>
</div>`;
}
__name(panelC, "panelC");
function panelD() {
  const card = /* @__PURE__ */ __name((title, on, extra = "") => `<div class="rvcard">
      <div class="rvhead"><span class="rvtitle">${title}</span>
        <div class="sw-track${on ? " on" : ""}"><div class="sw-knob"></div></div></div>${extra}
    </div>`, "card");
  return `<div class="win winD">
  <div class="top"></div>
  <div class="abs accent-bar" style="left:16px;top:14px;width:4px;height:22px"></div>
  <div class="abs" style="left:28px;top:9px;font-size:15px;font-weight:700;letter-spacing:-.01em">RV Cooked?</div>
  <div class="abs muted" style="left:28px;top:29px;font-size:11px">By @LaaTortueJaune</div>
  <button class="close abs" style="right:12px;top:12px;width:30px;height:26px">X</button>

  <div class="bodyD">
    ${card("Infinite Hunger", true)}
    ${card("No Fall Damage", false)}
    ${card("Super Speed", true, `
      <div class="rslider">
        <div class="rtrack"><div class="rfill" style="width:34%"></div><div class="rknob" style="left:34%"></div></div>
        <div class="rval">90</div>
      </div>`)}
    <div class="rvcard">
      <div class="rvhead"><span class="rvtitle">Telekinesis Grab</span></div>
      <div class="tkrow">
        <div class="tkdd">12 found - pick one</div>
        <div class="tkref">Refresh</div>
      </div>
      <div class="tkbtns">
        <div class="tkgrab">Grab selected</div>
        <div class="tkrel">Release</div>
      </div>
    </div>
    <div class="rvcard">
      <div class="rvhead"><span class="rvtitle">Teleport</span></div>
      <div class="tpgrid">
        <div class="tpbtn">L1</div><div class="tpbtn">L2</div><div class="tpbtn">L3</div>
        <div class="tpbtn">L4</div><div class="tpbtn">L5</div><div class="tpbtn">L6</div>
      </div>
      <div class="endbtn">End  (skip straight to the finish)</div>
    </div>
  </div>
  <div class="scrollbar"></div>
</div>`;
}
__name(panelD, "panelD");
function prototypePage() {
  const swatches = SWATCHES.map(
    ([hex, name]) => `<div class="sw"><i style="background:${hex}"></i><code>${hex}</code> ${name}</div>`
  ).join("");
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Prototype \u2014 in-game panels</title><style>${PROTO_STYLE}</style></head><body>
<header>
  <div class="head-inner">
    <div class="brand"><span class="dot"></span>Prototype \u2014 in-game panels</div>
    <a class="back" href="/admin">\u2190 Back to dashboard</a>
  </div>
</header>
<main>
  <div class="notice">
    <span>\u26A0\uFE0F</span>
    <div><b>Preview only.</b> Nothing is deployed here: the Luau code served to your
    clients is untouched. This is a pixel-accurate HTML reproduction of the four panels,
    at the same sizes and positions as in your scripts.</div>
  </div>

  <div class="bar">
    <div class="seg">
      <button data-theme="amethyste" class="on">Amethyst</button>
      <button data-theme="actuel">Previous</button>
    </div>
    <div class="swatches">${swatches}</div>
  </div>

  <div class="stage" id="stage" data-theme="amethyste">
    <div class="shot">
      ${panelA()}
      <div class="cap">Drain Simulator <span>\u2014 380 \xD7 324</span></div>
    </div>
    <div class="shot">
      ${panelB()}
      <div class="cap">Work as a Loan Officer Remastered <span>\u2014 466 \xD7 650</span></div>
    </div>
    <div class="shot">
      ${panelC()}
      <div class="cap">Offline notice <span>\u2014 410 \xD7 124</span></div>
    </div>
    <div class="shot">
      ${panelD()}
      <div class="cap">RV Cooked? <span>\u2014 380 \xD7 480</span></div>
    </div>
  </div>
</main>
<script>
${PROTO_JS}
<\/script>
</body></html>`;
}
__name(prototypePage, "prototypePage");

// src/routes/admin.ts
function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" }
  });
}
__name(json, "json");
function html(body, status = 200, extra = {}) {
  return new Response(body, {
    status,
    headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", ...extra }
  });
}
__name(html, "html");
var stub = buildStub;
function isCrossOrigin(request, url) {
  const origin = request.headers.get("Origin");
  if (origin && origin !== "null") {
    try {
      return new URL(origin).origin !== url.origin;
    } catch {
      return false;
    }
  }
  const ref = request.headers.get("Referer");
  if (ref) {
    try {
      return new URL(ref).origin !== url.origin;
    } catch {
      return false;
    }
  }
  return false;
}
__name(isCrossOrigin, "isCrossOrigin");
async function handleAdmin(request, env, url) {
  const path = url.pathname.replace(/\/+$/, "") || "/admin";
  const method = request.method;
  if (path === "/admin/login" && method === "POST") {
    if (isCrossOrigin(request, url)) return html(loginPage(true), 403);
    const ip = request.headers.get("CF-Connecting-IP") || "unknown";
    const limiter = env.LOGIN_RATE.get(env.LOGIN_RATE.idFromName("global"));
    const verdict = await (await limiter.fetch("https://rl/hit?ip=" + encodeURIComponent(ip))).json();
    if (!verdict.allowed) {
      return html(loginPage(true), 429, { "Retry-After": String(verdict.retryAfter ?? 60) });
    }
    const form = await request.formData();
    const pw = String(form.get("password") ?? "");
    if (await checkPassword(env, pw)) {
      await limiter.fetch("https://rl/reset?ip=" + encodeURIComponent(ip));
      return new Response(null, {
        status: 303,
        headers: { Location: "/admin", "Set-Cookie": await makeSessionCookie(env) }
      });
    }
    return html(loginPage(true), 401);
  }
  if (path === "/admin/logout") {
    if (method !== "POST" || isCrossOrigin(request, url)) {
      return json({ error: "method not allowed" }, 405);
    }
    return new Response(null, {
      status: 303,
      headers: { Location: "/admin", "Set-Cookie": clearSessionCookie() }
    });
  }
  const authed = await isAuthed(env, request);
  if (path === "/admin" && method === "GET") {
    return authed ? html(dashboardPage()) : html(loginPage(false));
  }
  if (path === "/admin/prototype" && method === "GET") {
    return authed ? html(prototypePage()) : html(loginPage(false), 401);
  }
  if (path.startsWith("/admin/api/")) {
    if (!authed) return json({ error: "unauthorized" }, 401);
    if (method !== "GET" && isCrossOrigin(request, url)) {
      return json({ error: "forbidden" }, 403);
    }
    if (path === "/admin/api/presence" && method === "GET") {
      const stubDO = env.PRESENCE.get(env.PRESENCE.idFromName("global"));
      const r = await stubDO.fetch("https://presence/stats");
      return json(await r.json(), r.status);
    }
    if (path === "/admin/api/scripts") {
      if (method === "GET") {
        const scripts = await listScripts(env.DB);
        return json({
          scripts: scripts.map((s) => ({ ...s, stub: stub(url.origin, s.slug) })),
          base: url.origin
        });
      }
      if (method === "POST") {
        const { name, content, enabled } = await request.json();
        if (!name || !name.trim()) return json({ error: "name requis" }, 400);
        const s = await createScript(
          env.DB,
          name.trim(),
          content === void 0 ? void 0 : content,
          enabled === false ? 0 : 1
        );
        return json({ script: s, stub: stub(url.origin, s.slug) }, 201);
      }
    }
    const m = path.match(/^\/admin\/api\/scripts\/([^/]+)$/);
    if (m) {
      const id = m[1];
      const script = await getScriptById(env.DB, id);
      if (!script) return json({ error: "introuvable" }, 404);
      if (method === "GET") {
        return json({
          script: { ...script, content: script.source ?? script.content },
          stub: stub(url.origin, script.slug),
          logs: await recentLogs(env.DB, id),
          stats: await scriptStats(env.DB, id)
        });
      }
      if (method === "PUT") {
        const body = await request.json();
        await updateScript(env.DB, id, {
          name: body.name,
          content: body.content,
          enabled: body.enabled === void 0 ? void 0 : body.enabled ? 1 : 0
        });
        return json({ ok: true });
      }
      if (method === "DELETE") {
        await deleteScript(env.DB, id);
        return json({ ok: true });
      }
    }
    return json({ error: "not found" }, 404);
  }
  return html(loginPage(false), 404);
}
__name(handleAdmin, "handleAdmin");

// src/lib/ua.ts
function lookedLegit(_ua) {
  return null;
}
__name(lookedLegit, "lookedLegit");

// src/lib/log.ts
async function sha256Hex(input) {
  const data = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
__name(sha256Hex, "sha256Hex");
async function recordExecution(env, request, url, token) {
  const scriptId = (url.searchParams.get("sid") || "").trim();
  const sig = (url.searchParams.get("sig") || "").trim();
  const ts = parseInt(url.searchParams.get("ts") || "0", 10);
  if (!scriptId || !await verifyBeacon(env.COOKIE_SECRET, token, scriptId, ts, sig)) {
    return false;
  }
  const BEACON_TTL_MS = 60 * 1e3;
  if (Date.now() - ts > BEACON_TTL_MS) return false;
  const place = (url.searchParams.get(env.QP_PLACE) || "").trim();
  const exec = (url.searchParams.get(env.QP_EXEC) || "").trim();
  const uid = (url.searchParams.get(env.QP_UID) || "").trim();
  if (!/^[0-9]{1,20}$/.test(place) || !/^[0-9]{1,20}$/.test(uid) || !/^[^\u0000-\u001f]{1,80}$/.test(exec) || exec.toLowerCase() === "unknown") {
    return false;
  }
  const ip = request.headers.get("CF-Connecting-IP") ?? "";
  const ipHash = await sha256Hex(env.IP_SALT + "|" + ip);
  const ua = request.headers.get("User-Agent") ?? "";
  const legit = lookedLegit(ua);
  try {
    const res = await env.DB.prepare(
      `INSERT OR IGNORE INTO executions
         (script_id, place_id, executor, user_id, ip_hash, user_agent, looked_legit, beacon_token)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
    ).bind(
      scriptId,
      place,
      exec,
      uid,
      ipHash,
      ua || null,
      legit === null ? null : legit ? 1 : 0,
      token
    ).run();
    return (res.meta?.changes ?? 0) > 0;
  } catch {
    return false;
  }
}
__name(recordExecution, "recordExecution");

// src/routes/beacon.ts
function ok() {
  return new Response("", {
    status: 200,
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0"
    }
  });
}
__name(ok, "ok");
async function handleBeacon(request, env, ctx, url, token) {
  ctx.waitUntil(recordExecution(env, request, url, token));
  return ok();
}
__name(handleBeacon, "handleBeacon");

// src/routes/beat.ts
function ok2() {
  return new Response("", {
    status: 200,
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0"
    }
  });
}
__name(ok2, "ok");
async function handleBeat(env, ctx, url, token) {
  const script = url.searchParams.get("script") || "";
  const uid = url.searchParams.get("uid") || "";
  const sig = url.searchParams.get("sig") || "";
  const ts = parseInt(url.searchParams.get("ts") || "0", 10);
  if (script && /^[0-9]{1,20}$/.test(uid) && await verifyBeacon(env.COOKIE_SECRET, token, script, ts, sig)) {
    const stub2 = env.PRESENCE.get(env.PRESENCE.idFromName("global"));
    const doUrl = new URL("https://presence/beat");
    doUrl.searchParams.set("sid", token);
    doUrl.searchParams.set("script", script);
    if (uid) doUrl.searchParams.set("uid", uid);
    ctx.waitUntil(stub2.fetch(doUrl.toString()));
  }
  return ok2();
}
__name(handleBeat, "handleBeat");

// src/lib/security.ts
var SECURITY_HEADERS = {
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
  "Referrer-Policy": "no-referrer",
  "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
  "Permissions-Policy": "geolocation=(), microphone=(), camera=()",
  "Content-Security-Policy": "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
};
function harden(resp) {
  const h = new Headers(resp.headers);
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) {
    if (!h.has(k)) h.set(k, v);
  }
  return new Response(resp.body, { status: resp.status, statusText: resp.statusText, headers: h });
}
__name(harden, "harden");

// src/do/presence.ts
var WINDOW_MS = 15e3;
var PRUNE_MS = 2e4;
var Presence = class {
  static {
    __name(this, "Presence");
  }
  sql;
  state;
  constructor(state) {
    this.state = state;
    this.sql = state.storage.sql;
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS sessions (sid TEXT PRIMARY KEY, script TEXT NOT NULL, uid TEXT, last INTEGER NOT NULL)"
    );
  }
  async fetch(request) {
    const url = new URL(request.url);
    const now = Date.now();
    if (url.pathname === "/beat") {
      const sid = url.searchParams.get("sid") || "";
      const script = url.searchParams.get("script") || "";
      const uid = url.searchParams.get("uid") || null;
      if (sid && script) {
        this.sql.exec(
          "INSERT INTO sessions (sid, script, uid, last) VALUES (?, ?, ?, ?) ON CONFLICT(sid) DO UPDATE SET script=excluded.script, uid=excluded.uid, last=excluded.last",
          sid,
          script,
          uid,
          now
        );
        await this.state.storage.setAlarm(now + PRUNE_MS + 5e3);
      }
      return new Response("", { status: 200 });
    }
    if (url.pathname === "/stats") {
      this.prune(now);
      const cutoff = now - WINDOW_MS;
      const rows = this.sql.exec(
        "SELECT script, COUNT(*) AS sessions, COUNT(DISTINCT COALESCE(uid, sid)) AS users FROM sessions WHERE last > ? GROUP BY script",
        cutoff
      ).toArray();
      const global = this.sql.exec(
        "SELECT COUNT(*) AS sessions, COUNT(DISTINCT COALESCE(uid, sid)) AS users FROM sessions WHERE last > ?",
        cutoff
      ).one();
      const perScript = {};
      for (const r of rows) perScript[r.script] = { sessions: r.sessions, users: r.users };
      return Response.json({
        perScript,
        totals: { sessions: global.sessions, users: global.users, scripts: rows.length }
      });
    }
    return new Response("not found", { status: 404 });
  }
  prune(now) {
    this.sql.exec("DELETE FROM sessions WHERE last < ?", now - PRUNE_MS);
  }
  // Filet : purge periodique meme sans trafic, pour ne pas garder des sessions
  // mortes si les heartbeats s'arretent net.
  async alarm() {
    const now = Date.now();
    this.prune(now);
    const left = this.sql.exec("SELECT COUNT(*) AS n FROM sessions").one().n;
    if (left > 0) await this.state.storage.setAlarm(now + PRUNE_MS + 5e3);
  }
};

// src/do/login-rate.ts
var WINDOW_MS2 = 10 * 60 * 1e3;
var MAX_ATTEMPTS = 10;
var LoginRate = class {
  static {
    __name(this, "LoginRate");
  }
  sql;
  state;
  constructor(state) {
    this.state = state;
    this.sql = state.storage.sql;
    this.sql.exec("CREATE TABLE IF NOT EXISTS attempts (ip TEXT NOT NULL, ts INTEGER NOT NULL)");
    this.sql.exec("CREATE INDEX IF NOT EXISTS idx_attempts_ip ON attempts(ip)");
  }
  async fetch(request) {
    const url = new URL(request.url);
    const now = Date.now();
    const ip = url.searchParams.get("ip") || "unknown";
    if (url.pathname === "/reset") {
      this.sql.exec("DELETE FROM attempts WHERE ip = ?", ip);
      return Response.json({ ok: true });
    }
    this.sql.exec("DELETE FROM attempts WHERE ts < ?", now - WINDOW_MS2);
    const n = this.sql.exec("SELECT COUNT(*) AS n FROM attempts WHERE ip = ?", ip).one().n;
    if (n >= MAX_ATTEMPTS) {
      const oldest = this.sql.exec("SELECT MIN(ts) AS t FROM attempts WHERE ip = ?", ip).one().t;
      const retryAfter = Math.max(1, Math.ceil((oldest + WINDOW_MS2 - now) / 1e3));
      return Response.json({ allowed: false, retryAfter });
    }
    this.sql.exec("INSERT INTO attempts (ip, ts) VALUES (?, ?)", ip, now);
    await this.state.storage.setAlarm(now + WINDOW_MS2 + 5e3);
    return Response.json({ allowed: true });
  }
  // Purge périodique même sans trafic.
  async alarm() {
    const now = Date.now();
    this.sql.exec("DELETE FROM attempts WHERE ts < ?", now - WINDOW_MS2);
    const left = this.sql.exec("SELECT COUNT(*) AS n FROM attempts").one().n;
    if (left > 0) await this.state.storage.setAlarm(now + WINDOW_MS2 + 5e3);
  }
};

// src/do/public-rate.ts
var WINDOW_MS3 = 60 * 1e3;
var MAX_HITS = 60;
var PublicRate = class {
  static {
    __name(this, "PublicRate");
  }
  sql;
  state;
  constructor(state) {
    this.state = state;
    this.sql = state.storage.sql;
    this.sql.exec("CREATE TABLE IF NOT EXISTS hits (ts INTEGER NOT NULL)");
  }
  async fetch() {
    const now = Date.now();
    this.sql.exec("DELETE FROM hits WHERE ts < ?", now - WINDOW_MS3);
    const n = this.sql.exec("SELECT COUNT(*) AS n FROM hits").one().n;
    if (n >= MAX_HITS) {
      return Response.json({ allowed: false });
    }
    this.sql.exec("INSERT INTO hits (ts) VALUES (?)", now);
    await this.state.storage.setAlarm(now + WINDOW_MS3 + 5e3);
    return Response.json({ allowed: true });
  }
  async alarm() {
    const now = Date.now();
    this.sql.exec("DELETE FROM hits WHERE ts < ?", now - WINDOW_MS3);
    const left = this.sql.exec("SELECT COUNT(*) AS n FROM hits").one().n;
    if (left > 0) await this.state.storage.setAlarm(now + WINDOW_MS3 + 5e3);
  }
};

// src/index.ts
var index_default = {
  async fetch(request, env, ctx) {
    return harden(await route(request, env, ctx));
  }
};
async function route(request, env, ctx) {
  {
    const url = new URL(request.url);
    const path = url.pathname;
    const serveMatch = path.match(/^\/s\/([^/]+)$/);
    if (serveMatch) {
      if (request.method !== "GET") {
        return new Response(env.NOOP_BODY, {
          status: 200,
          headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" }
        });
      }
      if (!await allowPublic(env, request)) {
        return new Response(env.NOOP_BODY, {
          status: 200,
          headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" }
        });
      }
      return handleServe(request, env, ctx, url, serveMatch[1]);
    }
    const beaconMatch = path.match(/^\/b\/([a-f0-9]{32})$/);
    if (beaconMatch && request.method === "GET") {
      if (!await allowPublic(env, request)) return emptyOk();
      return handleBeacon(request, env, ctx, url, beaconMatch[1]);
    }
    const beatMatch = path.match(/^\/p\/([a-f0-9]{32})$/);
    if (beatMatch && request.method === "GET") {
      if (!await allowPublic(env, request)) return emptyOk();
      return handleBeat(env, ctx, url, beatMatch[1]);
    }
    if (path === "/admin" || path.startsWith("/admin/")) {
      return handleAdmin(request, env, url);
    }
    if (path === "/") {
      return new Response(null, { status: 302, headers: { Location: "/admin" } });
    }
    return new Response("Not found", { status: 404, headers: { "Cache-Control": "no-store" } });
  }
}
__name(route, "route");
async function allowPublic(env, request) {
  const ip = request.headers.get("CF-Connecting-IP") || "unknown";
  const stub2 = env.PUBLIC_RATE.get(env.PUBLIC_RATE.idFromName(ip));
  const verdict = await (await stub2.fetch("https://rl/hit")).json();
  return verdict.allowed;
}
__name(allowPublic, "allowPublic");
function emptyOk() {
  return new Response("", {
    status: 200,
    headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" }
  });
}
__name(emptyOk, "emptyOk");
export {
  LoginRate,
  Presence,
  PublicRate,
  index_default as default
};
//# sourceMappingURL=index.js.map
