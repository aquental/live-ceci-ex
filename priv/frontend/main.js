// live-ceci — minimal test client (Phase 1).
// The polished UI is aniradio's Next.js room (next step). This is enough to RUN the de-risk:
// talk to Mira, hear her back, interrupt her, and ask her to play music.

const $ = (id) => document.getElementById(id);
const orb = $("orb"), statusEl = $("status"), nowEl = $("nowplaying"), txEl = $("transcript");
const music = $("music");

// Measured: room noise crossed the old 0.02 gate at 0.021-0.023 and cut Mira off mid
// word; a deliberate interruption read 0.054. 0.04 sits between them.
const BARGE_RMS = 0.04;
let ws, audioCtx, workletNode, micStream;
// Server-owned settings, fetched once from /config.json. Null until then; go() waits
// for it, because the worklet takes its batch size at construction and never re-reads it.
let serverConfig = null;
let nextStart = 0;
let activeSources = [];
let speaking = false;
let duckTimer = null;
let tracks = [];
let queue = [];
let qi = 0;

function setOrb(state) { orb.className = "orb " + state; }       // idle | listening | thinking | speaking
function setStatus(t) { statusEl.textContent = t; }
// The transcript pane shows ~4 lines and scrolls. Nothing ever read the older ones,
// but every line stayed in the DOM for the life of the session — and a long chat with
// Mira is thousands of turns. Keep a scrollback, drop the rest.
const MAX_LINES = 60;
function addLine(role, text) {
  const p = document.createElement("div");
  p.className = "line " + role;
  p.textContent = (role === "mira" ? "mira  " : "you  ") + text;
  txEl.appendChild(p);
  while (txEl.childElementCount > MAX_LINES) txEl.removeChild(txEl.firstElementChild);
  txEl.scrollTop = txEl.scrollHeight;
}

// ---------- music player (driven by Mira's tool calls) ----------
async function loadTracks() {
  try { tracks = await (await fetch("/assets/tracks.json")).json(); } catch { tracks = []; }
}
function startQueue(list) {
  queue = list.length ? list : tracks;
  qi = 0;
  if (queue.length) { music.src = "/assets/" + queue[0].file; music.volume = 1; music.play().catch(() => {}); setNow(queue[0]); }
}
function setNow(t) { nowEl.textContent = t ? `now playing · ${t.title} — ${t.artist || ""}` : ""; }
function handlePlay(cmd) {
  if (cmd.action === "playlist") startQueue(tracks);                       // one vibe (all dream pop here)
  else if (cmd.action === "track") {
    const t = tracks.find((x) => x.title.toLowerCase().includes((cmd.value || "").toLowerCase()));
    startQueue(t ? [t] : tracks);
  } else if (cmd.action === "skip") { qi = (qi + 1) % Math.max(1, queue.length); if (queue[qi]) { music.src = "/assets/" + queue[qi].file; music.play().catch(() => {}); setNow(queue[qi]); } }
  else if (cmd.action === "pause") { music.paused ? music.play().catch(() => {}) : music.pause(); }
}
function duck() {                                                          // music down while Mira talks
  music.volume = 0.12;
  if (duckTimer) clearTimeout(duckTimer);
  duckTimer = setTimeout(() => { music.volume = 1; }, 450);
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
  speaking = true; setOrb("speaking"); duck();
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
  ws.onopen = () => { setStatus("listening…"); setOrb("listening"); };
  ws.onclose = () => {
    setStatus("the line dropped — tap to reconnect");
    setOrb("idle");
    stopVoice();                                                          // drop whatever was still queued
    $("talk").disabled = false;                                           // ...the status line said this all along
    $("talk").textContent = "↻ reconnect";
  };
  ws.onmessage = (evt) => {
    if (typeof evt.data !== "string") { playVoice(evt.data); return; }     // binary = voice
    const m = JSON.parse(evt.data);
    if (m.type === "transcript") { if (m.role === "user") setOrb("thinking"); addLine(m.role, m.text); }
    else if (m.type === "play") handlePlay(m);
    else if (m.type === "interrupted") stopVoice();
    else if (m.type === "error") { setStatus("error: " + m.message); console.error(m.message); }
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
    if (e.data.pcm && ws && ws.readyState === WebSocket.OPEN) ws.send(e.data.pcm);
    if (e.data.barge && speaking) stopVoice();                             // client-side barge-in
  };
  source.connect(workletNode);
  workletNode.connect(audioCtx.destination);                              // keeps the graph alive (silent)
}

async function go() {
  $("talk").disabled = true;
  setStatus("waking mira up…"); setOrb("thinking");
  // Both guards make this re-entrant. A dropped socket leaves the mic, the AudioContext
  // and the worklet perfectly alive — only the socket needs rebuilding — and running
  // startMic twice would strand the old graph and re-prompt for the microphone.
  if (!tracks.length) await loadTracks();
  if (!serverConfig) await loadConfig();
  if (!audioCtx) await startMic();
  connect();
  $("talk").textContent = "● live";
}
$("talk").addEventListener("click", go);
