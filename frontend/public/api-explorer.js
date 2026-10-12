function getBase() {
  return document.getElementById('base-url-input').value.trim().replace(/\/$/, '');
}

function onBaseUrlChange() {
  const v = getBase();
  document.getElementById('url-dot').className =
    'w-1.5 h-1.5 rounded-full inline-block ' + (v ? 'bg-emerald-400' : 'bg-amber-400');
}

function timingClass(ms) {
  if (ms < 400) return 'timing-fast';
  if (ms < 1200) return 'timing-mid';
  return 'timing-slow';
}

function metaBar(ms, status, label) {
  const cls = timingClass(ms);
  const sc  = status < 300 ? 'http-code-2' : 'http-code-4';
  return `<div class="flex items-center gap-3 mb-3 flex-wrap">
    <span class="chip ${cls} text-[11px] px-2 py-0.5">⚡ ${ms}ms</span>
    <span class="font-mono text-[11px] ${sc}">${status}</span>
    <span class="text-xs text-zinc-500">${label}</span>
  </div>`;
}

function rawJson(data) {
  return `<details><summary>View raw JSON</summary><pre class="raw-json mt-2">${JSON.stringify(data, null, 2)}</pre></details>`;
}

function setLoading(id, extra) {
  document.getElementById(id).innerHTML =
    `<div class="flex items-center gap-2 text-xs text-zinc-600"><div class="spinner"></div> Sending…</div>`
    + (extra ? `<p class="cold-note">${extra}</p>` : '');
}

function requireBase(id) {
  if (!getBase()) {
    document.getElementById(id).innerHTML =
      `<div class="error-msg">Enter the backend base URL above first.</div>`;
    return false;
  }
  return true;
}

function renderError(err, status) {
  const sp = status ? `<span class="font-mono text-[11px] http-code-4 mr-2">${status}</span>` : '';
  return `<div class="error-msg">${sp}${err.message || JSON.stringify(err)}</div>`;
}

function toggleCard(id) {
  const body    = document.getElementById('body-' + id);
  const chevron = document.getElementById('chevron-' + id);
  const isOpen  = !body.classList.contains('hidden');
  body.classList.toggle('hidden', isOpen);
  chevron.style.transform = isOpen ? '' : 'rotate(180deg)';
}

async function runHealth() {
  if (!requireBase('result-health')) return;
  const el = document.getElementById('result-health');

  const setHealthLoading = (note) => {
    el.innerHTML =
      `<div id="health-loading" style="transition:opacity 0.25s ease">` +
      `<div class="flex items-center gap-2 text-xs text-zinc-600"><div class="spinner"></div> Sending…</div>` +
      (note ? `<p class="cold-note">${note}</p>` : '') +
      `</div>`;
  };
  setHealthLoading();

  const earlyTimer = setTimeout(() =>
    setHealthLoading('Connecting to Lambda…'), 250);

  const coldTimer = setTimeout(() =>
    setHealthLoading('Still waiting — Lambda may be cold-starting. First request typically takes 10–15 s; warm requests return in ~120 ms.'), 5000);

  const t0 = performance.now();
  let res, json;
  try {
    res  = await fetch(`${getBase()}/health`);
    json = await res.json();
  } catch (e) {
    clearTimeout(earlyTimer); clearTimeout(coldTimer);
    el.innerHTML = renderError(e);
    return;
  }
  clearTimeout(earlyTimer); clearTimeout(coldTimer);

  const loadEl = document.getElementById('health-loading');
  if (loadEl) { loadEl.style.opacity = '0'; await new Promise(r => setTimeout(r, 220)); }

  const ms = Math.round(performance.now() - t0);
  el.innerHTML =
    metaBar(ms, res.status, res.ok ? 'backend is up' : 'backend error') +
    (res.ok
      ? `<div class="success-msg">✓ ${json.status}</div>`
      : `<div class="error-msg">${JSON.stringify(json)}</div>`);
}

async function runWiki() {
  const slug = document.getElementById('wiki-slug').value.trim();
  if (!slug) {
    document.getElementById('result-wiki').innerHTML =
      `<div class="error-msg">Enter a Wikipedia slug.</div>`;
    return;
  }
  setLoading('result-wiki');
  const url = `https://en.wikipedia.org/w/api.php?action=query&titles=${encodeURIComponent(slug)}&prop=extracts&explaintext=true&format=json&origin=*`;
  const t0 = performance.now();
  let data;
  try {
    const res = await fetch(url);
    data = await res.json();
  } catch (e) {
    document.getElementById('result-wiki').innerHTML = renderError(e);
    return;
  }
  const ms = Math.round(performance.now() - t0);
  const pages   = data.query && data.query.pages;
  const page    = pages && Object.values(pages)[0];
  const extract = page && page.extract;
  if (!extract) {
    document.getElementById('result-wiki').innerHTML =
      renderError({ message: `No extract found for "${slug}". Check the slug.` });
    return;
  }
  const charCount = extract.length;
  const preview   = extract.slice(0, 400);
  document.getElementById('result-wiki').innerHTML =
    metaBar(ms, 200, `~${charCount.toLocaleString()} chars`) +
    `<pre class="raw-json">${preview.replace(/</g, '&lt;').replace(/>/g, '&gt;')}…</pre>` +
    `<p class="text-[11px] text-zinc-600 mt-2">${charCount.toLocaleString()} total chars — showing first 400</p>`;
}

let _ingestFile = null;

function handleFileSelect(e) {
  _ingestFile = e.target.files[0] || null;
  document.getElementById('file-label').textContent =
    _ingestFile ? _ingestFile.name : 'Click or drag .txt/.md';
}

function handleFileDrop(e) {
  e.preventDefault();
  document.getElementById('file-drop-zone').classList.remove('drag');
  _ingestFile = e.dataTransfer.files[0] || null;
  document.getElementById('file-label').textContent =
    _ingestFile ? _ingestFile.name : 'Click or drag .txt/.md';
}

async function runIngest() {
  if (!requireBase('result-ingest')) return;
  const text   = document.getElementById('ingest-text').value.trim();
  const source = document.getElementById('ingest-source').value.trim() || 'manual';
  if (!text && !_ingestFile) {
    document.getElementById('result-ingest').innerHTML =
      `<div class="error-msg">Enter text or upload a file.</div>`;
    return;
  }
  setLoading('result-ingest');
  const fd = new FormData();
  if (_ingestFile) { fd.append('file', _ingestFile); }
  else             { fd.append('text', text); }
  fd.append('source', source);

  const t0 = performance.now();
  let res, json;
  try {
    res  = await fetch(`${getBase()}/api/ingest`, { method: 'POST', body: fd });
    json = await res.json();
  } catch (e) {
    document.getElementById('result-ingest').innerHTML = renderError(e);
    return;
  }
  const ms = Math.round(performance.now() - t0);

  if (!res.ok) {
    document.getElementById('result-ingest').innerHTML =
      metaBar(ms, res.status, 'error') +
      `<div class="error-msg">${json.detail || JSON.stringify(json)}</div>`;
    return;
  }
  document.getElementById('result-ingest').innerHTML =
    metaBar(ms, res.status, `${json.chunks} chunks stored`) +
    `<div class="success-msg">✓ Ingested <strong>${json.chunks}</strong> chunks from <code class="font-mono text-sm">${json.source}</code></div>` +
    rawJson(json);
}

async function runRetrieve() {
  if (!requireBase('result-retrieve')) return;
  const query = document.getElementById('retrieve-query').value.trim();
  const k     = parseInt(document.getElementById('retrieve-k').value) || 5;
  if (!query) {
    document.getElementById('result-retrieve').innerHTML =
      `<div class="error-msg">Enter a query.</div>`;
    return;
  }
  setLoading('result-retrieve');
  const t0 = performance.now();
  let res, json;
  try {
    res  = await fetch(`${getBase()}/api/retrieve`, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ query, k }),
    });
    json = await res.json();
  } catch (e) {
    document.getElementById('result-retrieve').innerHTML = renderError(e);
    return;
  }
  const ms = Math.round(performance.now() - t0);

  if (!res.ok) {
    document.getElementById('result-retrieve').innerHTML =
      metaBar(ms, res.status, 'error') +
      `<div class="error-msg">${json.detail || JSON.stringify(json)}</div>`;
    return;
  }

  const chunks = json.chunks || [];
  const rows = chunks.map((c, i) => {
    const pct = Math.round(c.score * 100);
    return `<tr>
      <td class="text-zinc-500 pr-2 text-[11px] font-mono align-top pt-1.5">${i + 1}</td>
      <td class="align-top pt-1.5">
        <div class="score-bar-wrap mb-1">
          <div class="score-bar" style="width:${Math.max(pct, 4)}px"></div>
          <span class="text-[11px] font-mono text-violet-400">${c.score.toFixed(4)}</span>
          <span class="text-[10px] text-zinc-600">${c.source}</span>
        </div>
        <div class="chunk-content">${c.content}</div>
      </td>
    </tr>`;
  }).join('');

  document.getElementById('result-retrieve').innerHTML =
    metaBar(ms, res.status, `${chunks.length} chunk${chunks.length !== 1 ? 's' : ''} returned`) +
    (chunks.length
      ? `<div class="overflow-x-auto rounded-xl mb-2" style="border:1px solid rgba(255,255,255,0.06)">
           <table class="result-table"><tbody>${rows}</tbody></table>
         </div>`
      : `<div class="error-msg">No chunks matched — ingest some text first.</div>`) +
    rawJson(json);
}

async function runReset() {
  if (!requireBase('result-reset')) return;
  setLoading('result-reset');
  const t0 = performance.now();
  let res, json;
  try {
    res  = await fetch(`${getBase()}/api/reset`, { method: 'DELETE' });
    json = await res.json();
  } catch (e) {
    document.getElementById('result-reset').innerHTML = renderError(e);
    return;
  }
  const ms = Math.round(performance.now() - t0);
  document.getElementById('result-reset').innerHTML =
    metaBar(ms, res.status, res.ok ? 'vector store cleared' : 'error') +
    (res.ok
      ? `<div class="success-msg">✓ ${json.status} — collection dropped and recreated</div>`
      : `<div class="error-msg">${JSON.stringify(json)}</div>`);
}

onBaseUrlChange();

document.getElementById('retrieve-query').addEventListener('keydown', e => {
  if (e.key === 'Enter') runRetrieve();
});
