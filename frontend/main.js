const endpointEl = document.getElementById("endpoint");
const apiKeyEl = document.getElementById("apiKey");
const langEl = document.getElementById("language");
const liveEl = document.getElementById("live");
const liveIntervalEl = document.getElementById("liveInterval");
const deviceEl = document.getElementById("device");
const startBtn = document.getElementById("start");
const stopBtn = document.getElementById("stop");
const resultEl = document.getElementById("result");
const statusEl = document.getElementById("status");
const debugLogEl = document.getElementById("debugLog");
const debugCopyBtn = document.getElementById("debugCopy");
const debugClearBtn = document.getElementById("debugClear");

const STORAGE_KEY = "wispr_local_frontend";

let stream = null;
let recorder = null;
let chunks = [];
let liveTimer = null;
let inFlight = false;
let lastSentChunkCount = 0;

function dbg(line) {
  const ts = new Date().toLocaleTimeString();
  const text = `[${ts}] ${line}`;
  if (debugLogEl) {
    debugLogEl.textContent = (debugLogEl.textContent ? debugLogEl.textContent + "\n" : "") + text;
    debugLogEl.scrollTop = debugLogEl.scrollHeight;
  }
  // Still useful when devtools are open.
  console.debug(text);
}

debugCopyBtn?.addEventListener("click", async () => {
  const text = debugLogEl?.textContent || "";
  if (!text) return;
  try {
    await navigator.clipboard.writeText(text);
    dbg("Debug log copied to clipboard.");
  } catch {
    dbg("Failed to copy debug log (clipboard permission?).");
  }
});

debugClearBtn?.addEventListener("click", () => {
  if (debugLogEl) debugLogEl.textContent = "";
});

window.addEventListener("error", (e) => {
  dbg(`window.error: ${e.message}`);
});
window.addEventListener("unhandledrejection", (e) => {
  const msg = e?.reason?.message || String(e.reason || "unknown");
  dbg(`unhandledrejection: ${msg}`);
});

function setStatus(text) {
  statusEl.textContent = text;
}

function loadPrefs() {
  const raw = localStorage.getItem(STORAGE_KEY);
  if (raw) {
    try {
      const p = JSON.parse(raw);
      if (p.endpoint) endpointEl.value = p.endpoint;
      if (p.apiKey) apiKeyEl.value = p.apiKey;
      if (p.language !== undefined) langEl.value = p.language;
      if (p.live !== undefined) liveEl.checked = !!p.live;
      if (p.liveInterval !== undefined) liveIntervalEl.value = String(p.liveInterval);
    } catch {
      // ignore invalid localStorage
    }
  }
  if (!raw && !langEl.value) {
    // Default to French for this setup.
    langEl.value = "fr";
  }
}

function savePrefs() {
  localStorage.setItem(
    STORAGE_KEY,
    JSON.stringify({
      endpoint: endpointEl.value.trim(),
      apiKey: apiKeyEl.value,
      language: langEl.value,
      live: liveEl.checked,
      liveInterval: Number(liveIntervalEl.value || "1200"),
    }),
  );
}

async function loadMicrophones() {
  try {
    const warmup = await navigator.mediaDevices.getUserMedia({ audio: true });
    warmup.getTracks().forEach((t) => t.stop());
    const devices = await navigator.mediaDevices.enumerateDevices();
    const mics = devices.filter((d) => d.kind === "audioinput");
    deviceEl.innerHTML = "";
    for (const [index, mic] of mics.entries()) {
      const opt = document.createElement("option");
      opt.value = mic.deviceId;
      opt.textContent = mic.label || `Microphone ${index + 1}`;
      deviceEl.appendChild(opt);
    }
    if (!mics.length) {
      const opt = document.createElement("option");
      opt.value = "";
      opt.textContent = "Aucun micro detecte";
      deviceEl.appendChild(opt);
    }
    dbg(`Loaded microphones: ${mics.length}`);
  } catch (err) {
    setStatus(`Erreur micro: ${err.message}`);
    dbg(`Micro error: ${err.message}`);
  }
}

function pickMime() {
  const choices = [
    "audio/webm;codecs=opus",
    "audio/webm",
    "audio/mp4",
    "audio/ogg;codecs=opus",
  ];
  for (const c of choices) {
    if (MediaRecorder.isTypeSupported(c)) return c;
  }
  return "";
}

async function transcribeBlob(audioBlob, blobType) {
  const endpoint = endpointEl.value.trim();
  const apiKey = apiKeyEl.value.trim();
  const language = langEl.value.trim();
  const ext = blobType.includes("mp4") ? "m4a" : "webm";

  const form = new FormData();
  form.append("file", audioBlob, `recording.${ext}`);
  const url = language ? `${endpoint}?language=${encodeURIComponent(language)}&task=transcribe` : `${endpoint}?task=transcribe`;

  const controller = new AbortController();
  const timeoutMs = 20_000;
  const t0 = performance.now();

  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    dbg(`POST ${url} bytes=${audioBlob.size} type=${blobType} apiKeySet=${!!apiKey} lang=${language || "auto"}`);
    const response = await fetch(url, {
      method: "POST",
      headers: apiKey ? { "X-API-Key": apiKey } : {},
      body: form,
      signal: controller.signal,
    });
    const payload = await response.json().catch(() => ({}));
    const dt = Math.round(performance.now() - t0);
    dbg(`Response status=${response.status} dt=${dt}ms elapsed_ms=${payload.elapsed_ms ?? "?"}`);
    if (!response.ok) {
      throw new Error(payload.detail || `HTTP ${response.status}`);
    }
    return payload;
  } catch (err) {
    const dt = Math.round(performance.now() - t0);
    if (err?.name === "AbortError") {
      dbg(`Fetch timeout after ${dt}ms`);
      throw new Error(`Timeout (${timeoutMs}ms)`);
    }
    dbg(`Fetch error after ${dt}ms: ${err.message || String(err)}`);
    throw err;
  } finally {
    clearTimeout(timeout);
  }
}

function startLiveLoop() {
  stopLiveLoop();
  if (!liveEl.checked) return;
  const interval = Math.max(500, Number(liveIntervalEl.value || "1200"));
  liveTimer = setInterval(async () => {
    if (!recorder) return;
    if (inFlight) return;
    if (chunks.length === 0) return;
    if (chunks.length === lastSentChunkCount) return;

    inFlight = true;
    try {
      const blobType = chunks[0]?.type || "audio/webm";
      const blob = new Blob(chunks, { type: blobType });
      const payload = await transcribeBlob(blob, blobType);
      lastSentChunkCount = chunks.length;

      resultEl.value = payload.text || "";
      setStatus(`Live - ${payload.elapsed_ms ?? "?"} ms`);
    } catch (err) {
      setStatus(`Live erreur: ${err.message}`);
    } finally {
      inFlight = false;
    }
  }, interval);
}

function stopLiveLoop() {
  if (liveTimer) clearInterval(liveTimer);
  liveTimer = null;
}

async function startRecording() {
  try {
    savePrefs();
    const deviceId = deviceEl.value;
    stream = await navigator.mediaDevices.getUserMedia({
      audio: deviceId ? { deviceId: { exact: deviceId } } : true,
    });
    chunks = [];
    const mimeType = pickMime();
    recorder = mimeType ? new MediaRecorder(stream, { mimeType }) : new MediaRecorder(stream);
    recorder.ondataavailable = (e) => {
      if (e.data && e.data.size > 0) chunks.push(e.data);
    };
    lastSentChunkCount = 0;
    // Timeslice enables "live" updates by producing periodic chunks.
    recorder.start(1000);
    startBtn.disabled = true;
    stopBtn.disabled = false;
    setStatus("Enregistrement...");
    dbg(`Recording started mime=${mimeType || recorder.mimeType || "default"} deviceId=${deviceId ? "custom" : "default"}`);
    startLiveLoop();
  } catch (err) {
    setStatus(`Erreur start: ${err.message}`);
    dbg(`Start error: ${err.message}`);
  }
}

async function stopRecording() {
  if (!recorder) return;
  stopBtn.disabled = true;
  setStatus("Arret...");
  stopLiveLoop();

  await new Promise((resolve) => {
    recorder.onstop = resolve;
    recorder.stop();
  });

  if (stream) {
    stream.getTracks().forEach((t) => t.stop());
    stream = null;
  }

  startBtn.disabled = false;

  if (!chunks.length) {
    setStatus("Aucun audio capture.");
    dbg("Stop: no chunks captured");
    return;
  }

  const blobType = chunks[0]?.type || "audio/webm";
  const blob = new Blob(chunks, { type: blobType });
  dbg(`Stop: chunks=${chunks.length} bytes=${blob.size} type=${blobType}`);

  setStatus("Transcription...");
  try {
    const payload = await transcribeBlob(blob, blobType);
    resultEl.value = payload.text || "";
    setStatus(`OK - ${payload.elapsed_ms ?? "?"} ms`);
  } catch (err) {
    setStatus(`Erreur: ${err.message}`);
  }
}

startBtn.addEventListener("click", startRecording);
stopBtn.addEventListener("click", stopRecording);

loadPrefs();
loadMicrophones();
