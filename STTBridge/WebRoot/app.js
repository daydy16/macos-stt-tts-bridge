let ws, mediaStream, audioCtx, sttT0 = 0, gotFirstPartial = false;
const log = (m) => { const el = document.getElementById('sttOut'); el.textContent += m + "\n"; el.scrollTop = el.scrollHeight; };
const setMetric = (id, ms) => { document.getElementById(id).textContent = ms == null ? '–' : `${ms.toFixed(0)} ms`; };
const now = () => performance.now();

// ---- WebSocket STT (streaming) ----
const start = async () => {
  document.getElementById('sttOut').textContent = '';
  setMetric('mPartial', null); setMetric('mFinal', null);
  gotFirstPartial = false; sttT0 = 0;

  const lang = document.getElementById('lang').value || 'de-DE';
  const offline = document.getElementById('offline').checked;
  const partials = document.getElementById('partials').checked;
  mediaStream = await navigator.mediaDevices.getUserMedia({ audio: true });
  const ctx = new AudioContext({ sampleRate: 16000 });
  const source = ctx.createMediaStreamSource(mediaStream);
  const proc = ctx.createScriptProcessor(2048, 1, 1); // ~128ms @16k; small frames reduce buffering latency
  source.connect(proc); proc.connect(ctx.destination);

  ws = new WebSocket(`ws://${location.host}/stt/stream?lang=${encodeURIComponent(lang)}&offline=${offline}&partials=${partials}`);
  ws.onopen = () => log('WS verbunden');
  ws.onmessage = ev => {
    try {
      const o = JSON.parse(ev.data);
      if (o.type === 'partial') {
        if (!gotFirstPartial && sttT0) { gotFirstPartial = true; setMetric('mPartial', now() - sttT0); }
        log('· ' + o.text);
      }
      if (o.type === 'final') {
        if (sttT0) setMetric('mFinal', now() - sttT0);
        log('✔ ' + o.text + (o.confidence != null ? ` (conf=${o.confidence.toFixed(2)})` : ''));
        if (ws) ws.close();
      }
      if (o.type === 'error') log('⚠ Fehler: ' + o.error);
    } catch {}
  };
  ws.onclose = () => log('WS geschlossen');

  proc.onaudioprocess = e => {
    if (!ws || ws.readyState !== 1) return;
    const input = e.inputBuffer.getChannelData(0);
    const buf = new ArrayBuffer(input.length * 2), view = new DataView(buf);
    for (let i = 0; i < input.length; i++) { let s = Math.max(-1, Math.min(1, input[i])); view.setInt16(i * 2, s < 0 ? s * 0x8000 : s * 0x7FFF, true); }
    if (!sttT0) sttT0 = now(); // first audio sent → start of round-trip clock
    ws.send(buf);
  };
  document.getElementById('startBtn').disabled = true;
  document.getElementById('stopBtn').disabled = false;
};

const stop = () => {
  // Signal end-of-speech for instant finalization, then let the final close the socket.
  if (ws && ws.readyState === 1) ws.send(JSON.stringify({ type: 'end' }));
  if (mediaStream) mediaStream.getTracks().forEach(t => t.stop());
  document.getElementById('startBtn').disabled = false;
  document.getElementById('stopBtn').disabled = true;
};
document.getElementById('startBtn').onclick = start;
document.getElementById('stopBtn').onclick = stop;

// ---- Voices ----
const initVoices = async () => {
  try {
    const res = await fetch('/voices');
    const voices = await res.json();
    const sel = document.getElementById('voiceId');
    const qLabel = q => q === 3 ? 'Premium' : q === 2 ? 'Enhanced' : 'Default';
    const lang = (document.getElementById('lang').value || 'de').slice(0, 2).toLowerCase();

    voices.sort((a, b) => (b.quality - a.quality) || a.name.localeCompare(b.name)).forEach(v => {
      const opt = document.createElement('option');
      opt.value = v.identifier;
      opt.textContent = `${v.name} (${v.language}) – ${qLabel(v.quality)}`;
      sel.appendChild(opt);
    });

    // Pre-select the highest-quality voice for the chosen language.
    const best = voices
      .filter(v => v.language.toLowerCase().startsWith(lang))
      .sort((a, b) => b.quality - a.quality)[0];
    if (best) sel.value = best.identifier;
  } catch (e) { console.error('Failed to load voices', e); }
};

const initHealth = async () => {
  try {
    const h = await (await fetch('/healthz')).json();
    document.getElementById('engineLine').textContent = `Engine: ${h.engine} · Sprache: ${h.lang} · On-Device: ${h.onDeviceSTT ? 'ja' : 'nein'}`;
  } catch {}
};

// ---- TTS one-shot ----
document.getElementById('ttsBtn').onclick = async () => {
  setMetric('mTtsFirst', null); setMetric('mTtsDone', null);
  const text = document.getElementById('ttsText').value;
  const voiceId = document.getElementById('voiceId').value || null;
  const rate = parseFloat(document.getElementById('rate').value);
  const pitch = parseFloat(document.getElementById('pitch').value);
  const speakLocal = document.getElementById('speakLocal').checked;
  const t0 = now();
  const res = await fetch('/tts', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ text, voiceId, rate, pitch, speakLocal }) });
  if (speakLocal) { await res.json(); return; }
  const blob = await res.blob();
  setMetric('mTtsDone', now() - t0);
  const url = URL.createObjectURL(blob);
  const player = document.getElementById('player'); player.src = url; player.play();
};

// ---- TTS streaming (sentence-by-sentence PCM over chunked HTTP) ----
document.getElementById('ttsStreamBtn').onclick = async () => {
  setMetric('mTtsFirst', null); setMetric('mTtsDone', null);
  const text = document.getElementById('ttsText').value;
  const voiceId = document.getElementById('voiceId').value || '';
  const rate = document.getElementById('rate').value;
  const lang = document.getElementById('lang').value || 'de-DE';
  const t0 = now();

  const params = new URLSearchParams({ text, lang });
  if (voiceId) params.set('voiceId', voiceId);
  if (rate) params.set('rate', rate);
  const res = await fetch(`/tts/stream?${params.toString()}`);
  const sr = parseInt(res.headers.get('X-Sample-Rate') || '22050', 10);

  if (!audioCtx) audioCtx = new AudioContext();
  let nextTime = audioCtx.currentTime;
  let firstByte = false, leftover = new Uint8Array(0);
  const reader = res.body.getReader();

  const schedule = (bytes) => {
    // Carry over an odd trailing byte between chunks.
    let merged = new Uint8Array(leftover.length + bytes.length);
    merged.set(leftover, 0); merged.set(bytes, leftover.length);
    const usable = merged.length - (merged.length % 2);
    leftover = merged.slice(usable);
    if (usable < 2) return;
    const samples = usable / 2;
    const view = new DataView(merged.buffer, 0, usable);
    const audioBuf = audioCtx.createBuffer(1, samples, sr);
    const ch = audioBuf.getChannelData(0);
    for (let i = 0; i < samples; i++) ch[i] = view.getInt16(i * 2, true) / 32768;
    const node = audioCtx.createBufferSource();
    node.buffer = audioBuf; node.connect(audioCtx.destination);
    nextTime = Math.max(audioCtx.currentTime, nextTime);
    node.start(nextTime);
    nextTime += audioBuf.duration;
  };

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (!firstByte) { firstByte = true; setMetric('mTtsFirst', now() - t0); }
    schedule(value);
  }
  setMetric('mTtsDone', now() - t0);
};

window.onload = () => { initVoices(); initHealth(); };
