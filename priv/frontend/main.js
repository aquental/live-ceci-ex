// live-ceci — minimal test client.
// Enough to RUN the de-risk: talk to Ceci, hear her back, interrupt her mid-sentence,
// and watch an operational tool call land in the activity panel.

const $ = (id) => document.getElementById(id);
const orb = $("orb"), statusEl = $("status"), actEl = $("activity"), txEl = $("transcript");

// Measured: room noise crossed the old 0.02 gate at 0.021-0.023 and cut Ceci off mid
// word; a deliberate interruption read 0.054. 0.04 sits between them.
const BARGE_RMS = 0.04;
// Roughly a second of 16 kHz PCM in flight. Past that the link is not keeping up.
const MAX_BUFFERED = 32000;
let dropped = 0;
let ws, audioCtx, workletNode, micStream;
// Server-owned settings, fetched once from /config.json. Null until then; go() waits
// for it, because the worklet takes its batch size at construction and never re-reads it.
let serverConfig = null;
let nextStart = 0;
let activeSources = [];
let speaking = false;

function setOrb(state) { orb.className = "orb " + state; }       // idle | listening | thinking | speaking
function setStatus(t) { statusEl.textContent = t; }
// The transcript pane shows ~4 lines and scrolls. Nothing ever read the older ones,
// but every line stayed in the DOM for the life of the session — and a long chat with
// Ceci is thousands of turns. Keep a scrollback, drop the rest.
const MAX_LINES = 60;
function addLine(role, text) {
  const p = document.createElement("div");
  p.className = "line " + role;
  p.textContent = (role === "ceci" ? "ceci  " : "você  ") + text;
  txEl.appendChild(p);
  while (txEl.childElementCount > MAX_LINES) txEl.removeChild(txEl.firstElementChild);
  txEl.scrollTop = txEl.scrollHeight;
}

// ---------- activity panel (driven by Ceci's tool calls) ----------
// Every tool she calls lands here as one line. It is the only proof from the browser
// side that the round trip happened: her voice says she booked it, this says the call
// actually came back. Nothing is persisted — these are stubs on the server too.
const ACTIONS = {
  agendar:  "agendou",
  presenca: "registrou presença",
  recibo:   "emitiu recibo",
  resumo:   "fechou o resumo",
};
const MAX_ACTIONS = 20;
function handleAction(cmd) {
  const row = document.createElement("div");
  row.className = "act";
  const label = ACTIONS[cmd.action] || cmd.action;
  row.textContent = cmd.detail ? `${label} · ${cmd.detail}` : label;
  actEl.appendChild(row);
  while (actEl.childElementCount > MAX_ACTIONS) actEl.removeChild(actEl.firstElementChild);
  actEl.scrollTop = actEl.scrollHeight;
}

// ---------- voice playback (24k PCM from the server) ----------
function playVoice(buf) {
  const int16 = new Int16Array(buf);
  const f32 = new Float32Array(int16.length);
  for (let i = 0; i < int16.length; i++) f32[i] = int16[i] / 0x8000;
  const ab = audioCtx.createBuffer(1, f32.length, 24000);
  ab.getChannelData(0).set(f32);
  const src = audioCtx.createBufferSource();
  src.buffer = ab; src.connect(audioCtx.destination);
  const now = audioCtx.currentTime;
  if (nextStart < now) nextStart = now;
  src.start(nextStart); nextStart += ab.duration;
  activeSources.push(src);
  src.onended = () => { activeSources = activeSources.filter((s) => s !== src); if (!activeSources.length) { speaking = false; setOrb("listening"); } };
  speaking = true; setOrb("speaking");
}
function stopVoice() {                                                     // barge-in
  activeSources.forEach((s) => { try { s.stop(); } catch {} });
  activeSources = []; nextStart = 0; speaking = false; setOrb("listening");
}

// ---------- the live socket ----------
function connect() {
  const proto = location.protocol === "https:" ? "wss" : "ws";
  ws = new WebSocket(`${proto}://${location.host}/ws`);
  ws.binaryType = "arraybuffer";
  ws.onopen = () => { dropped = 0; setStatus("ouvindo…"); setOrb("listening"); };
  ws.onclose = () => {
    if (dropped) console.warn(`${dropped} mic frames dropped — the socket stopped draining`);
    setStatus("a linha caiu — toque para reconectar");
    setOrb("idle");
    stopVoice();                                                          // drop whatever was still queued
    $("talk").disabled = false;                                           // ...the status line said this all along
    $("talk").textContent = "↻ reconectar";
  };
  ws.onmessage = (evt) => {
    if (typeof evt.data !== "string") { playVoice(evt.data); return; }     // binary = voice
    const m = JSON.parse(evt.data);
    if (m.type === "transcript") { if (m.role === "user") setOrb("thinking"); addLine(m.role, m.text); }
    else if (m.type === "action") handleAction(m);
    else if (m.type === "interrupted") stopVoice();
    else if (m.type === "error") { setStatus("erro: " + m.message); console.error(m.message); }
  };
}

// A failed fetch must not cost the microphone, so this falls back rather than throwing.
// The worklet carries the same default, and disagreeing with it here would be worse
// than having no value at all.
async function loadConfig() {
  try { serverConfig = await (await fetch("/config.json")).json(); } catch { serverConfig = {}; }
}

async function startMic() {
  audioCtx = new (window.AudioContext || window.webkitAudioContext)();
  await audioCtx.audioWorklet.addModule("/pcm-processor.js");
  micStream = await navigator.mediaDevices.getUserMedia({
    audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true },
  });
  const source = audioCtx.createMediaStreamSource(micStream);
  workletNode = new AudioWorkletNode(audioCtx, "pcm-processor", {
    // bargeRms is the browser's alone; frameSamples comes from .env via /config.json.
    // Undefined is fine — the worklet falls back to the same default this does.
    processorOptions: { bargeRms: BARGE_RMS, frameSamples: serverConfig.frameSamples },
  });
  workletNode.port.onmessage = (e) => {
    // pcm arrives in ~100 ms batches; rms-only messages come between them for barge-in
    // bufferedAmount, not just readyState. A socket can be OPEN and not draining — bad
    // wifi, a stalled server — and the mic never stops producing, so send() would grow
    // the browser's own buffer without limit. Dropping the oldest frames is the right
    // trade for live audio: stale mic is worth nothing, and the VAD recovers.
    if (e.data.pcm && ws && ws.readyState === WebSocket.OPEN) {
      if (ws.bufferedAmount > MAX_BUFFERED) dropped++;
      else ws.send(e.data.pcm);
    }
    if (e.data.barge && speaking) stopVoice();                             // client-side barge-in
  };
  source.connect(workletNode);
  workletNode.connect(audioCtx.destination);                              // keeps the graph alive (silent)
}

async function go() {
  $("talk").disabled = true;
  setStatus("conectando…"); setOrb("thinking");
  // Both guards make this re-entrant. A dropped socket leaves the mic, the AudioContext
  // and the worklet perfectly alive — only the socket needs rebuilding — and running
  // startMic twice would strand the old graph and re-prompt for the microphone.
  if (!serverConfig) await loadConfig();
  if (!audioCtx) await startMic();
  connect();
  $("talk").textContent = "● ao vivo";
}
$("talk").addEventListener("click", go);
