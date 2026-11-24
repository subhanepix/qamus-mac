// Qamus Desk — a reading-first front end over the existing engine.
// Reuses ../engine.js and ../data unchanged. Its own state lives in localStorage under KEY,
// separate from the main app's IndexedDB, so trying it never touches real vocab.
import {
  initEngine, onEngineUpdate, state, resolveQuery, suggestions, glossFor, loadHw,
  uniqParses, rootLabel, stripHead, defHtml, arHtml, esc, plain, norm, isAr,
  laneKey, loadLaneEntries, arKeysFor, arShard, arHead, AR_IDS, AR_DICTS, VERB_PATTERNS,
  searchEnglish, shortGloss, hasTashkeel, nearestMatches,
} from '../engine.js';

// engine.js fetches `data/…` relative to the page. This page lives one folder down,
// so resolve those requests against engine.js's own folder instead.
const ENGINE_BASE = new URL('../', import.meta.url);
const nativeFetch = window.fetch.bind(window);
window.fetch = (u, o) => nativeFetch(typeof u === 'string' && u.startsWith('data/') ? new URL(u, ENGINE_BASE).href : u, o);

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const view = $('#view'), insp = $('#insp'), desk = $('#desk'), grammarTray = $('#grammar-tray');
const native = () => !!window.webkit?.messageHandlers?.qamusNative;
const post = msg => { try { window.webkit?.messageHandlers?.qamusNative?.postMessage(msg); } catch {} };

// ---------- Live Shared Store & Sync (reuses root ../merge.js & ../sync.js) ----------
const Store = window.QamusStore;
const Sync = window.QamusSync;
const QM = window.QamusMerge;
const lsGet = k => { try { return localStorage.getItem(k); } catch { return null; } };
const lsSet = (k, v) => { try { localStorage.setItem(k, v); } catch {} };
const SYNC_URL = lsGet('qamus.syncUrl') ?? 'https://qamus-sync.subhansajid360.workers.dev';
const INBOX = 'f_inbox';
const VALID_SOURCES = new Set(['hw', 'wikt', 'lane', 'lexicon', 'mufradat', 'mukhtar', 'custom']);
const clip = (s, max = 2048) => String(s || '').trim().slice(0, max);

// Desk-only state (reading texts & Desk appearance) stays in localStorage;
// vocabulary cards, folders, SRS reviews, and lookup history live in shared QamusStore + QamusSync.
const KEY = 'qamus.desk.v1';
const SAMPLES = [
  {
    title: 'في المكتبة',
    note: 'Sample · Modern Standard Arabic',
    body: 'كانَ الطالبُ يقرأُ كتابًا قديمًا في المكتبةِ، فلمّا وجدَ كلمةً لا يعرفُها فتحَ القاموسَ وبحثَ عن جذرِها. ثمّ كتبَ معناها في دفترِه حتّى لا ينساها.\n\nوقالَ لصديقِه وهما يخرجانِ من المكتبةِ: إنّ معرفةَ الكلماتِ مفتاحُ الفهمِ، ومن صبرَ على القراءةِ وجدَ فيها كنوزًا لا تنتهي.',
  },
  {
    title: 'سورة الفاتحة',
    note: 'Sample · Qur’an 1',
    body: 'بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ ﴿١﴾ الْحَمْدُ لِلَّهِ رَبِّ الْعَالَمِينَ ﴿٢﴾ الرَّحْمَٰنِ الرَّحِيمِ ﴿٣﴾ مَالِكِ يَوْمِ الدِّينِ ﴿٤﴾ إِيَّاكَ نَعْبُدُ وَإِيَّاكَ نَسْتَعِينُ ﴿٥﴾ اهْدِنَا الصِّرَاطَ الْمُسْتَقِيمَ ﴿٦﴾ صِرَاطَ الَّذِينَ أَنْعَمْتَ عَلَيْهِمْ غَيْرِ الْمَغْضُوبِ عَلَيْهِمْ وَلَا الضَّالِّينَ ﴿٧﴾',
  },
];

const uid = (p = '') => (p ? p + '_' : '') + Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
function loadDb() {
  try {
    const d = JSON.parse(localStorage.getItem(KEY) || 'null');
    if (d && Array.isArray(d.texts)) {
      d.settings ||= { theme: 'system', arFont: 'amiri', size: 'm' };
      return d;
    }
  } catch {}
  const now = Date.now();
  return {
    texts: SAMPLES.map((s, i) => ({ id: uid() + i, title: s.title, note: s.note, body: s.body, source: 'sample', created: now - i, opened: now - i, looked: [] })),
    cards: [],
    history: [],
    settings: { theme: 'system', arFont: 'amiri', size: 'm' },
  };
}
const db = loadDb();
try { if (!localStorage.getItem(KEY)) localStorage.setItem(KEY, JSON.stringify(db)); } catch {}
let saveTimer = 0;
function flush() {
  clearTimeout(saveTimer);
  saveTimer = 0;
  try { localStorage.setItem(KEY, JSON.stringify(db)); } catch {}
}
function persist() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(flush, 150);
}
// Never lose a grade or a save to the debounce when the window closes or reloads.
window.addEventListener('pagehide', () => { if (saveTimer) flush(); });
document.addEventListener('visibilitychange', () => { if (document.hidden && saveTimer) flush(); });

// ---------- Shared QamusStore Helpers (100% compatible with alqamus.pages.dev & phone sync) ----------
function mapSource(src) {
  if (src === 'form') return 'hw';
  return VALID_SOURCES.has(src) ? src : 'custom';
}
function ensureInbox(d) {
  if (d.folders.some(f => f.id === INBOX && !f.deleted)) return;
  const now = Date.now();
  const rec = { id: INBOX, name: 'Inbox', parent: null, createdAt: now, updatedAt: now, deleted: false };
  const i = d.folders.findIndex(f => f.id === INBOX);
  if (i >= 0) d.folders[i] = rec;
  else d.folders.push(rec);
}
function liveFolders() {
  if (!Store) return [{ id: INBOX, name: 'Inbox', parent: null }];
  const fs = (Store.doc.folders || []).filter(f => !f.deleted);
  if (!fs.some(f => f.id === INBOX)) fs.unshift({ id: INBOX, name: 'Inbox', parent: null });
  return fs.sort((a, b) => (a.id === INBOX ? -1 : b.id === INBOX ? 1 : a.name.localeCompare(b.name, ['ar', 'en'])));
}
function folderName(id) {
  return liveFolders().find(f => f.id === id)?.name || 'Inbox';
}
function targetSaveFolder() {
  const saved = lsGet('qamus.lastFolder');
  return saved && liveFolders().some(f => f.id === saved) ? saved : INBOX;
}
function liveCards() {
  if (!Store) return db.cards || [];
  const revs = Store.doc.reviews || {};
  return (Store.doc.cards || [])
    .filter(c => !c.deleted)
    .map(c => {
      const r = revs[c.id] || null;
      return {
        id: c.id,
        folder: c.folder || INBOX,
        key: c.key || norm(c.word || ''),
        ref: c.ref || '',
        w: c.highlight || c.word || '',
        head: c.word || '',
        gloss: c.gloss || c.arGloss || '',
        tr: c.translit || '',
        root: c.root || '',
        ctx: c.context || '',
        src: c.source || 'custom',
        created: c.createdAt || c.updatedAt || 0,
        due: r ? (r.due || 0) : 0,
        ivl: r ? (r.interval || 0) : 0,
        ease: r ? (r.ease || 2.5) : 2.5,
        reps: r ? (r.reps || 0) : 0,
        lapses: r ? (r.lapses || 0) : 0,
        last: r ? (r.last || 0) : 0,
      };
    })
    .sort((a, b) => b.created - a.created);
}

// ---------- Folders (same tree rules as alqamus.pages.dev: parents, inherited pause) ----------
function folderTree() {
  const list = liveFolders();
  const byId = new Map(list.map(f => [f.id, f]));
  const parent = f => (f.parent && f.parent !== f.id && byId.has(f.parent) ? f.parent : null);
  const rows = [], seen = new Set();
  const walk = (id, depth) => {
    for (const f of list) {
      if (parent(f) !== id || seen.has(f.id)) continue;
      seen.add(f.id);
      rows.push({ f, depth });
      walk(f.id, depth + 1);
    }
  };
  walk(null, 0);
  for (const f of list) if (!seen.has(f.id)) rows.push({ f, depth: 0 });   // anything caught in a parent loop
  const path = id => {
    const out = [], hop = new Set();
    let f = byId.get(id);
    while (f && !hop.has(f.id)) { hop.add(f.id); out.unshift(f); const p = parent(f); f = p ? byId.get(p) : null; }
    return out;
  };
  const deepIds = id => {
    const out = new Set([id]), stack = [id];
    while (stack.length) {
      const c = stack.pop();
      for (const f of list) if (parent(f) === c && !out.has(f.id)) { out.add(f.id); stack.push(f.id); }
    }
    return out;
  };
  const pausedSet = new Set(list.filter(f => path(f.id).some(x => x.paused)).map(f => f.id));
  const of = c => (byId.has(c.folder) ? c.folder : INBOX);
  return { list, byId, rows, parent, path, deepIds, of, paused: id => pausedSet.has(id) };
}
// new → never reviewed; due → due now; later → scheduled; paused → its folder (or a parent) is paused.
function cardState(c, T) {
  if (T.paused(T.of(c))) return { k: 'paused', label: 'Paused' };
  if (!c.last && !c.reps) return { k: 'new', label: 'New' };
  if (c.due <= Date.now()) return { k: 'due', label: 'Due' };
  return { k: 'later', label: dueLabel(c) };
}
const isDueNow = (c, T) => { const k = cardState(c, T).k; return k === 'new' || k === 'due'; };
function cardsInFolder(id, T, cards = liveCards()) {
  const ids = T.deepIds(id);
  return cards.filter(c => ids.has(T.of(c)));
}
function folderStats(cards, T) {
  let mastered = 0, due = 0, fresh = 0, ready = 0;
  for (const c of cards) {
    const k = cardState(c, T).k;
    if (k === 'new' || k === 'due') ready++;
    // The bar shows how well a folder is known, paused or not.
    if (!c.last && !c.reps) fresh++;
    else if (c.due <= Date.now()) due++;
    else mastered++;
  }
  return { total: cards.length, mastered, due, fresh, ready };
}
function createFolder(name) {
  name = clip(name, 100);
  if (!Store || !name) return null;
  const id = uid('f'), now = Date.now();
  Store.mutate(d => { d.folders.push({ id, name, parent: null, createdAt: now, updatedAt: now, deleted: false }); });
  return id;
}
function moveCards(ids, folder) {
  if (!Store || !ids.length) return;
  const set = new Set(ids);
  Store.mutate(d => {
    const now = Date.now();
    if (folder === INBOX) ensureInbox(d);
    for (const c of d.cards) if (set.has(c.id) && !c.deleted) { c.folder = folder; c.updatedAt = now; }
  });
}
function deleteCards(ids) {
  if (!Store || !ids.length) return;
  const set = new Set(ids);
  const snaps = Store.doc.cards.filter(c => set.has(c.id) && !c.deleted).map(c => ({ ...c }));
  const revs = Object.fromEntries(ids.filter(id => Store.doc.reviews[id]).map(id => [id, { ...Store.doc.reviews[id] }]));
  Store.mutate(d => {
    const now = Date.now();
    d.cards = d.cards.map(c => (set.has(c.id) && !c.deleted ? { id: c.id, folder: c.folder, word: '', updatedAt: now, deleted: true } : c));
    for (const id of set) delete d.reviews[id];
  });
  refreshKnown(); rerenderSaves();
  toast(`Deleted ${plural(snaps.length, 'card')}`, {
    label: 'Undo',
    run: () => {
      Store.mutate(d => {
        const now = Date.now();
        for (const s of snaps) {
          const restored = { ...s, deleted: false, updatedAt: now };
          const i = d.cards.findIndex(c => c.id === s.id);
          if (i >= 0) d.cards[i] = restored; else d.cards.push(restored);
          if (revs[s.id]) d.reviews[s.id] = { ...revs[s.id], updatedAt: now };
        }
      });
      refreshKnown(); rerenderSaves();
    },
  });
}
function liveHistory() {
  if (!Store) return db.history || [];
  return (Store.doc.history || [])
    .filter(h => !h.deleted)
    .sort((a, b) => b.t - a.t)
    .map(h => ({ q: h.q, g: '', t: h.t }));
}
function migrateLegacyDeskCards() {
  if (!Store || !Array.isArray(db.cards) || !db.cards.length) return;
  const existingKeys = new Set(liveCards().map(c => c.key));
  const toMove = db.cards.filter(c => {
    const k = norm(c.head || c.w || '');
    return k && !existingKeys.has(k);
  });
  if (toMove.length) {
    Store.mutate(d => {
      ensureInbox(d);
      const now = Date.now();
      for (const old of toMove) {
        const word = clip(old.head || old.w || '');
        if (!word) continue;
        const src = mapSource(old.src);
        const id = uid('c');
        d.cards.push({
          id,
          folder: INBOX,
          word,
          key: clip(norm(word)),
          root: clip(old.root || ''),
          source: src,
          ref: '',
          gloss: clip(old.gloss || ''),
          arGloss: '',
          translit: clip(old.tr || ''),
          context: clip(old.ctx || ''),
          highlight: clip(old.w || ''),
          note: '',
          tags: [],
          createdAt: old.created || now,
          updatedAt: now,
          deleted: false,
        });
        if (old.reps || old.lapses) {
          d.reviews[id] = {
            due: old.due || now,
            interval: old.ivl || 0,
            ease: old.ease || 2.5,
            reps: old.reps || 0,
            lapses: old.lapses || 0,
            last: now,
            updatedAt: now,
          };
        }
      }
    });
  }
  db.cards = [];
  flush();
}

// ---------- Helpers ----------
const WORD_RE = /[ء-غـ-ٰٟٱ]+/g;
const STOP_RE = /[.!؟?؛\n﴾﴿]/;
const EDGE_RE = /^[\s﴾﴿٠-٩]+|[\s﴾﴿٠-٩]+$/g;
const PREFIXES = ['وال', 'فال', 'بال', 'كال', 'لل', 'ال', 'و', 'ف', 'ب', 'ل', 'ك'];
const plural = (n, w) => `${n} ${w}${n === 1 ? '' : 's'}`;
const DAY = 864e5;
function ago(t) {
  const s = (Date.now() - t) / 1000;
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  if (s < 86400 * 7) return `${Math.floor(s / 86400)}d ago`;
  return new Date(t).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}
function dueLabel(c) {
  const d = c.due - Date.now();
  if (d <= 0) return 'due now';
  if (d < DAY) return `in ${Math.max(1, Math.round(d / 36e5))}h`;
  return `in ${Math.round(d / DAY)}d`;
}
const markWord = (sentence, w) => {
  if (!sentence) return '';
  const i = w ? sentence.indexOf(w) : -1;
  return i < 0 ? esc(sentence) : esc(sentence.slice(0, i)) + `<mark>${esc(w)}</mark>` + esc(sentence.slice(i + w.length));
};
const spaced = w => [...norm(w)].join(' ');
function toast(msg, action) {
  const t = $('#toast');
  t.innerHTML = `<span>${esc(msg)}</span>${action ? `<button type="button">${esc(action.label)}</button>` : ''}`;
  t.hidden = false;
  if (action) t.querySelector('button').onclick = () => { action.run(); t.hidden = true; };
  clearTimeout(toast.t);
  toast.t = setTimeout(() => { t.hidden = true; }, 3800);
}

const ICON = {
  save: '<svg viewBox="0 0 20 20"><path d="M5.5 3h9a.5.5 0 0 1 .5.5v13.3a.3.3 0 0 1-.47.25L10 14l-4.53 3.05a.3.3 0 0 1-.47-.25V3.5a.5.5 0 0 1 .5-.5z"/></svg>',
  expand: '<svg viewBox="0 0 20 20"><path d="M11.5 3.5h5v5M8.5 16.5h-5v-5M16.5 3.5 11 9M3.5 16.5 9 11"/></svg>',
  copy: '<svg viewBox="0 0 20 20"><rect x="7" y="7" width="9.5" height="9.5" rx="1.5"/><path d="M13 7V4.5A1.5 1.5 0 0 0 11.5 3h-7A1.5 1.5 0 0 0 3 4.5v7A1.5 1.5 0 0 0 4.5 13H7"/></svg>',
  plus: '<svg viewBox="0 0 20 20"><path d="M10 4.5v11M4.5 10h11"/></svg>',
  text: '<svg viewBox="0 0 20 20"><path d="M5 3.5h7l3 3v10H5z"/><path d="M8 9.5h5M8 12.5h5"/></svg>',
  review: '<svg viewBox="0 0 20 20"><rect x="3.5" y="5" width="13" height="10" rx="1.5"/><path d="M6.5 3h7"/></svg>',
  vocab: ICON_VOCAB(),
  moon: '<svg viewBox="0 0 20 20"><path d="M15.5 12.5A6 6 0 0 1 7.5 4.5a6 6 0 1 0 8 8z"/></svg>',
  search: '<svg viewBox="0 0 20 20"><circle cx="8.5" cy="8.5" r="5.5"/><path d="m13 13 4 4"/></svg>',
  trash: '<svg viewBox="0 0 20 20"><path d="M4.5 6h11M8 6V4.5h4V6M6 6l.7 10h6.6L14 6"/></svg>',
  back: '<svg viewBox="0 0 20 20"><path d="M12 4.5 6.5 10l5.5 5.5"/></svg>',
  next: '<svg viewBox="0 0 20 20"><path d="M8 4.5 13.5 10 8 15.5"/></svg>',
  download: '<svg viewBox="0 0 20 20"><path d="M10 3.5v9M6.5 9 10 12.5 13.5 9M4 16h12"/></svg>',
  edit: '<svg viewBox="0 0 20 20"><path d="M12.5 4.5l3 3L8 15H5v-3z"/></svg>',
  folder: '<svg viewBox="0 0 20 20"><path d="M3 6.5A1.5 1.5 0 0 1 4.5 5H8l1.5 1.5h6A1.5 1.5 0 0 1 17 8v6.5a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 3 14.5z"/></svg>',
};
function ICON_VOCAB() { return '<svg viewBox="0 0 20 20"><path d="M5.5 3h9a.5.5 0 0 1 .5.5v13.3a.3.3 0 0 1-.47.25L10 14l-4.53 3.05a.3.3 0 0 1-.47-.25V3.5a.5.5 0 0 1 .5-.5z"/></svg>'; }

// ---------- Settings ----------
function applySettings() {
  const s = db.settings, root = document.documentElement;
  if (s.theme === 'system') delete root.dataset.theme; else root.dataset.theme = s.theme;
  root.dataset.arFont = s.arFont;
  root.dataset.size = s.size;
  $$('#settings .seg').forEach(seg => {
    const k = seg.dataset.setting;
    $$('button', seg).forEach(b => b.setAttribute('aria-pressed', String(b.dataset.v === s[k])));
  });
}

// ---------- Engine readiness ----------
const ORDER = ['boot', 'index', 'hw', 'morph', 'full'];
const atLeast = s => ORDER.indexOf(state.readyStage) >= ORDER.indexOf(s);
function ready(stage) {
  return new Promise(res => {
    if (atLeast(stage)) return res();
    const off = onEngineUpdate(() => { if (atLeast(stage)) { off(); res(); } });
  });
}
const STAGE_LABEL = { boot: 'Starting…', index: 'Loading Hans Wehr…', hw: 'Loading morphology…', morph: 'Loading Wiktionary…', full: 'All lexicons ready' };
onEngineUpdate(stage => {
  const el = $('#engine-status');
  el.classList.toggle('ready', stage === 'full');
  el.lastElementChild.textContent = STAGE_LABEL[stage] || stage;
  // A lookup made before Wiktionary arrived may be missing entries: refresh it quietly.
  if (stage === 'full' && cur?.stage && cur.stage !== 'full') lookup(cur.q, cur.ctx, { quiet: true, keepStack: true });
});

// ---------- Lookup model ----------
// One structured model feeds the inspector, the full entry view, and the native bridge (window.qamus.current()).
let cur = null;           // { q, ctx, model, stage, loading, analysis }
let lookSeq = 0;
let inspStack = [];       // for "back" after following a link inside a definition
const saveables = new Map();
let saveSeq = 0;

function formICut(e) {
  const s = stripHead(e);
  const cut = s.search(/<b>\s*(I{1,3}|IV|VI{0,3}|IX|X)\s*<\/b>/);
  return cut >= 0 ? s.slice(0, cut).trim() : s;
}

function buildModel(q, res) {
  const m = { query: q, kind: res.kind, word: q, tr: '', parses: [], roots: [], answers: [], sources: {}, retry: null };
  if (res.kind === 'english') {
    const r = searchEnglish(q);
    m.english = [...r.tr, ...r.scored.map(x => x[1]).filter(e => !r.tr.includes(e))].slice(0, 40);
    m.total = r.total || 0;
    return m;
  }
  if (res.kind === 'fallback') {
    m.near = nearestMatches(res.n).slice(0, 14);
    return m;
  }
  if (res.kind === 'passage') return m;

  const roots = res.roots || [];
  const o = res.opt || {};
  const particles = o.particles || [];
  // The engine marks و/ف + particle readings (فلمّا = فَ + لَمَّا) with `_prefix`.
  const particlePrefix = particles[0]?._prefix || '';
  const hits = o.exactHits?.size ? o.exactHits : (o.hits || new Set());
  m.retry = o.retry || null;

  // Parses (prefix + stem + suffix)
  m.parses = uniqParses(o.parses || []).slice(0, 3).map(a => ({
    segments: [
      a.pre[0] && { role: 'prefix', ar: a.pre[0], gloss: a.pre[2] || 'prefix' },
      { role: 'stem', ar: a.stem[0], gloss: (a.stem[2] || '').split(';')[0] },
      a.suf[0] && { role: 'suffix', ar: a.suf[0], gloss: a.suf[2] || 'suffix' },
    ].filter(Boolean),
    root: rootLabel(a.stem),
    gloss: [a.pre[2], (a.stem[2] || '').replace(/;/g, '; '), a.suf[2]].filter(Boolean).join(' + '),
  }));

  m.roots = roots.map(rid => {
    const r = state.byId.get(rid);
    return r && { id: rid, letters: [...r[1]].join(' '), quran: r[5] || 0, words: (state.kids.get(rid)?.length || 0) + 1, forms: state.formsBy.get(rid)?.length || 0 };
  }).filter(Boolean);

  // Lead answers: what the word means, before any wall of entries.
  for (const p of particles.slice(0, 2)) {
    m.answers.push({ source: 'particle', key: 'p:' + p.ar, head: p.ar, tr: p.tr, label: particlePrefix ? `${particlePrefix} + ${p.enCat}` : p.enCat, html: esc(p.meaning) + (p.effect ? `<div class="muted" style="margin-top:4px;font-size:12.5px">عمل · ${esc(p.effect)}</div>` : ''), gloss: `${p.enCat}: ${p.meaning}` });
  }
  // Keep the engine's hit order: it already leads with the reading the parse supports.
  const topParse = (o.parses || [])[0];
  const verbal = !!topParse && /^(PV|IV|CV)/.test(topParse.stem[1]);
  const hitEntries = [...hits].map(id => state.byId.get(id)).filter(Boolean);
  for (const e of hitEntries.slice(0, 3)) {
    const html = e[3] ? formICut(e) : stripHead(e);
    m.answers.push({ source: 'hw', key: 'hw:' + e[0], head: e[1], tr: e[6] || '', label: e[3] && verbal ? 'Form I' : 'Hans Wehr', html: defHtml(html), gloss: shortGloss(html, 140), root: rootLetters(e[4]) });
  }
  for (const f of (o.forms || []).slice(0, 2)) {
    if (!f[3]) continue;
    m.answers.push({ source: 'form', key: `form:${f[0]}:${f[1]}`, head: f[2] || '', tr: '', label: `Form ${f[1]}`, html: defHtml(f[3]), gloss: shortGloss(f[3], 140), root: rootLetters(f[0]) });
  }
  if (!m.answers.length && state.W) {
    for (const k of (o.wikt || []).slice(0, 2)) {
      const e = state.W.entries[k];
      m.answers.push({ source: 'wikt', key: 'wikt:' + k, head: e[0], tr: e[1] || '', label: 'Wiktionary', html: defHtml(e[2], ['i', 'br', 'ol', 'li']), gloss: shortGloss(e[2], 140) });
    }
  }
  if (!m.answers.length) {
    for (const a of uniqParses(o.bwOnly || []).slice(0, 2)) {
      const w = a.stem[4] || a.stem[0];
      m.answers.push({ source: 'lexicon', key: 'lex:' + w, head: w, tr: '', label: 'Lexicon', html: esc(a.stem[2].replace(/;/g, '; ')), gloss: a.stem[2].replace(/;/g, '; '), root: rootLabel(a.stem) });
    }
  }
  if (!m.answers.length && roots.length) {
    const r = state.byId.get(roots[0]);
    if (r) m.answers.push({ source: 'hw', key: 'hw:' + r[0], head: r[1], tr: r[6] || '', label: 'Root', html: defHtml(formICut(r)), gloss: shortGloss(formICut(r), 140), root: rootLetters(r[0]) });
  }
  // Two roots can share one entry (قاموس under ق م س and ق ا م و س): show it once.
  const seenAnswers = new Set();
  m.answers = m.answers.filter(a => {
    const k = norm(a.head) + '|' + plain(a.html).slice(0, 120);
    if (seenAnswers.has(k)) return false;
    seenAnswers.add(k);
    return true;
  });

  // Harakat & compound-parse sanity check:
  // Prevent unvocalized collisions like إِنَّا (indeed we) ranking انا (ana = "I") at #1.
  if (hasTashkeel(q) && m.answers.length) {
    const scoreAnswer = a => {
      let pen = 0;
      const head = a.head || '';
      const tr = (a.tr || '').trim().toLowerCase();
      if (q.startsWith('إ') && (head.startsWith('أ') || head.startsWith('آ') || /^[aāuū]/.test(tr))) pen += 2;
      if (q.startsWith('أ') && (head.startsWith('إ') || /^[iī]/.test(tr))) pen += 2;
      if (/ّ/.test(q) && tr && !/(.)\1/.test(tr)) pen += 1;
      if (a.source === 'particle') pen -= 1;
      return pen;
    };
    const p0 = m.parses[0];
    const isCompoundParse = p0 && p0.segments.length > 1 && p0.gloss;
    const leadPen = scoreAnswer(m.answers[0]);
    if (leadPen > 0) {
      m.answers = [...m.answers].sort((a, b) => scoreAnswer(a) - scoreAnswer(b));
      // If even the best remaining dictionary entry still clashes and Buckwalter parsed a compound (e.g. إنَّ + ا),
      // surface the parsed reading at the top so 1-click Save is right even before AI finishes.
      if (isCompoundParse && scoreAnswer(m.answers[0]) > 0) {
        m.answers.unshift({
          source: 'lexicon',
          key: 'parse:' + q,
          head: q,
          tr: '',
          label: 'Parsed',
          html: esc(p0.gloss),
          gloss: p0.gloss,
          root: p0.root || '',
        });
      }
    }
  }

  // Headword shown big: the dictionary form, unless the user typed harakat
  const lead = m.answers[0];
  m.word = particles[0] ? (particles[0]._exact || particlePrefix ? particles[0].ar : q) : hasTashkeel(q) ? q : (lead?.head || q);
  m.tr = lead?.tr || '';
  m.exactHarakat = hasTashkeel(q) && ((o.exactHits?.size || 0) > 0 || particles.some(p => p._exact));

  // Secondary sources, rendered lazily
  const laneKeys = [...new Set([...roots.map(rid => laneKey(norm(state.byId.get(rid)?.[1] || ''))), ...(o.laneOnly || []).map(lr => laneKey(lr))].filter(Boolean))];
  const arKeys = arKeysFor(roots, [...(o.laneOnly || []), o.arWord || '']);
  m.sources = { roots, hits: new Set([...hits, ...(o.hits || [])]), particles, wikt: o.wikt || [], laneKeys, laneWant: o.laneWord || norm(q), arKeys, arWant: norm(q).replace(/^ال/, '') };
  return m;
}
function rootLetters(rid) {
  const r = state.byId.get(rid);
  return r ? [...r[1]].join(' ') : '';
}

async function lookup(q, ctx = {}, opts = {}) {
  q = String(q || '').trim();
  if (!q) return;
  if (!opts.keepStack && !opts.fromLink) inspStack = [];
  if (opts.fromLink && cur?.model) inspStack.push({ q: cur.q, ctx: cur.ctx });
  const seq = ++lookSeq;
  if (!opts.quiet) {
    cur = { q, ctx, loading: true };
    renderInspector();
  }
  await ready('morph');
  const res = resolveQuery(q);
  if (res.kind === 'roots' && res.roots.length) {
    try { await loadHw(res.roots); } catch {}
  }
  if (seq !== lookSeq) return;
  const model = buildModel(res.q || q, res);
  cur = { q, ctx, model, stage: state.readyStage, loading: false, analysis: opts.quiet ? cur?.analysis : null };
  if (!opts.quiet && model.kind === 'roots') pushHistory(q, model.answers[0]?.gloss || '');
  renderInspector();
  if (route().name === 'entry' && route().arg === q) renderEntry(q);
  post({ type: 'lookup', lookup: window.qamus.current() });
}

function pushHistory(q) {
  const clean = clip(q, 200);
  if (!clean) return;
  if (Store) {
    if (Store.doc.settings?.pauseHistory) return;
    if (liveHistory()[0]?.q === clean) return;
    Store.mutate(d => {
      const maxT = d.history.reduce((m, h) => (h.q === clean && h.t > m ? h.t : m), 0);
      const t = Math.max(Date.now(), (d.settings.historyClearedAt || 0) + 1, maxT + 1);
      d.history = [{ q: clean, t }, ...d.history.filter(h => h.q !== clean)];
      let live = 0;
      d.history = d.history.filter(h => h.deleted || ++live <= 500);
    }, { quiet: true });
    return;
  }
  const n = norm(clean);
  db.history = (db.history || []).filter(h => norm(h.q) !== n);
  db.history.unshift({ q: clean, g: '', t: Date.now() });
  db.history.length = Math.min(db.history.length, 300);
  persist();
}

// ---------- Cards / SRS (backed by live QamusStore + QamusSync) ----------
function primarySaveTarget() {
  if (!cur?.model) return null;
  const a = cur.analysis;
  const ctx = cur.ctx || {};
  const answers = cur.model.answers || [];
  // When Grammar-in-Context has analyzed this word in its sentence, 1-click Save uses
  // the exact contextual reading & meaning (preserving the sentence example) instead of blindly
  // grabbing dictionary row #1 (which breaks on homographs like إِنَّا vs أَنَا).
  if (a && typeof a === 'object' && !a.error && a.meaningHere) {
    const word = (a.vocalized && a.vocalized !== '—') ? a.vocalized : (ctx.word || cur.q || cur.model.word);
    const posEn = (a.partOfSpeech || '').toLowerCase();
    const posAr = a.arabicTag || '';
    const isParticle = /particle|conjunction|preposition|pronoun|interjection/.test(posEn) || /حرف|أداة|ضمير/.test(posAr);
    const aRoot = (a.root || '').trim();
    const aRootNorm = norm(aRoot);
    const matched = answers.find(x => {
      if (aRootNorm && x.root && norm(x.root) === aRootNorm) return true;
      if (isParticle && x.source === 'particle' && norm(x.head) === norm(word)) return true;
      return false;
    });
    return {
      _contextual: true,
      source: 'custom',
      key: '',
      head: word,
      tr: matched?.tr || '',
      gloss: a.meaningHere.trim(),
      root: isParticle ? '' : (aRoot || matched?.root || ''),
    };
  }
  return answers[0] || null;
}

function findSavedCard(a, asWritten) {
  const cards = liveCards();
  const headKey = norm(a?.head || '');
  const writKey = norm(asWritten || '');
  const ref = a?.key || '';
  if (a?._contextual) {
    const sent = cur?.ctx?.sentence || '';
    return cards.find(c =>
      (c.head === a.head && c.gloss === a.gloss) ||
      (sent && c.ctx === sent && norm(c.w || c.head) === (writKey || headKey))
    ) || null;
  }
  // A card that knows its entry matches only that entry: saving قرأ "to read" must not mark (or let
  // a second tap remove) قرء "menses" just because both came from the same written word يقرأ.
  // Cards without a ref (older or website-made) fall back to matching by word.
  return cards.find(c => (ref && c.ref)
    ? c.ref === ref
    : (headKey && c.key === headKey && (!hasTashkeel(a?.head || '') || !hasTashkeel(c.head || '') || c.head === a.head))
      || (writKey && c.key === writKey && (!hasTashkeel(asWritten || '') || !hasTashkeel(c.head || '') || c.head === asWritten))
  ) || null;
}
const isSaved = (a, asWritten) => !!findSavedCard(a, asWritten);
let knownSet = new Set();
function refreshKnown() {
  const cards = liveCards();
  knownSet = new Set(cards.flatMap(c => [norm(c.w), norm(c.head), c.key]).filter(Boolean));
  const T = folderTree();
  const due = cards.filter(c => isDueNow(c, T)).length;
  const dc = $('#due-count'), vc = $('#vocab-count');
  dc.hidden = !due; dc.textContent = due;
  vc.hidden = !cards.length; vc.textContent = cards.length;
  const td = $('#tab-due');
  if (td) { td.hidden = !due; td.textContent = due; }
}
function isKnown(tok) {
  const n = norm(tok);
  if (knownSet.has(n)) return true;
  return PREFIXES.some(p => n.length > p.length + 1 && n.startsWith(p) && knownSet.has(n.slice(p.length)));
}

function saveAnswer(a, ctx = cur?.ctx || {}) {
  if (!a) return;
  const asWritten = ctx.word || cur?.q || a.head;
  const existing = findSavedCard(a, asWritten);
  if (existing) {
    deleteCardById(existing.id, existing.head);
    return;
  }
  const word = clip(a.head || asWritten);
  const src = mapSource(a.source);
  const folder = targetSaveFolder();
  const gloss = clip(plain(a.gloss || ''), 2048);
  const now = Date.now();
  let newId = '';
  if (Store) {
    newId = uid('c');
    Store.mutate(d => {
      ensureInbox(d);
      d.cards.push({
        id: newId,
        folder,
        word,
        key: clip(norm(word)),
        root: clip(a.root || ''),
        source: src,
        ref: src === 'custom' ? '' : clip(a.key || '', 200),
        gloss,
        arGloss: '',
        translit: clip(a.tr || ''),
        context: clip(ctx.sentence || ''),
        highlight: clip(asWritten || ''),
        note: '',
        tags: [],
        createdAt: now,
        updatedAt: now,
        deleted: false,
      });
    });
    lsSet('qamus.lastFolder', folder);
  }
  refreshKnown(); rerenderSaves();
  const dest = folder !== INBOX ? ` → ${folderName(folder)}` : '';
  const shortG = gloss ? ` (“${gloss.length > 42 ? gloss.slice(0, 41) + '…' : gloss}”)` : '';
  toast(
    ctx.sentence ? `Saved ${word}${shortG} with sentence${dest}` : `Saved ${word}${shortG}${dest}`,
    newId ? { label: 'Undo', run: () => deleteCardById(newId, word) } : undefined
  );
}

function deleteCardById(id, label = '') {
  if (!Store) return;
  const snapCard = Store.doc.cards.find(c => c.id === id && !c.deleted);
  const snapRev = Store.doc.reviews[id] ? { ...Store.doc.reviews[id] } : null;
  if (!snapCard) return;
  const copyCard = { ...snapCard };
  Store.mutate(d => {
    const now = Date.now();
    d.cards = d.cards.map(c => (c.id === id && !c.deleted
      ? { id: c.id, folder: c.folder, word: '', updatedAt: now, deleted: true }
      : c));
    delete d.reviews[id];
  });
  refreshKnown(); rerenderSaves();
  toast(`Removed ${label || copyCard.word} from vocabulary`, {
    label: 'Undo',
    run: () => {
      Store.mutate(d => {
        const now = Date.now();
        const restored = { ...copyCard, deleted: false, updatedAt: now };
        const i = d.cards.findIndex(c => c.id === id);
        if (i >= 0) d.cards[i] = restored; else d.cards.push(restored);
        if (snapRev) d.reviews[id] = { ...snapRev, updatedAt: now };
      });
      refreshKnown(); rerenderSaves();
    },
  });
}

function syncPrimarySaveBtn() {
  const target = primarySaveTarget();
  $$('[data-act="save-primary"]').forEach(b => {
    const on = target ? isSaved(target, cur?.ctx?.word || cur?.q || target.head) : false;
    b.classList.toggle('on', on);
    b.classList.toggle('saved', on);
    const lbl = b.querySelector('.lbl');
    if (lbl) lbl.textContent = on ? 'Saved' : 'Save';
    if (target) {
      const g = plain(target.gloss || '').slice(0, 60);
      b.title = g ? `Save ${target.head} (“${g}”) (S)` : 'Save to vocabulary (S)';
    }
  });
}

function rerenderSaves() {
  syncPrimarySaveBtn();
  $$('[data-save]').forEach(b => {
    const a = saveables.get(b.dataset.save);
    if (!a) return;
    const on = isSaved(a, cur?.ctx?.word || cur?.q || a.head);
    b.classList.toggle('on', on);
    b.classList.toggle('saved', on && b.classList.contains('btn'));
    if (b.classList.contains('btn')) b.querySelector('.lbl').textContent = on ? 'Saved' : 'Save';
  });
  $$('.passage .w').forEach(w => w.classList.toggle('known', isKnown(w.textContent)));
  if (route().name === 'vocab') renderVocab();
  if (route().name === 'desk') renderDesk();
}

function preview(c, g) {
  const x = { ...c };
  schedule(x, g, true);
  const d = x.due - Date.now();
  return d < 36e5 ? `${Math.round(d / 6e4)}m` : d < DAY ? `${Math.round(d / 36e5)}h` : `${Math.round(d / DAY)}d`;
}
function schedule(c, g, dry = false) {
  const now = Date.now();
  if (g === 1) {
    c.reps = 0; c.lapses = (c.lapses || 0) + (dry ? 0 : 1); c.ivl = 0; c.due = now + 10 * 6e4; c.ease = Math.round(Math.max(1.3, c.ease - 0.2) * 100) / 100;
    return;
  }
  c.reps = (c.reps || 0) + 1;
  let ivl;
  if (c.reps === 1) ivl = g === 4 ? 3 : 1;
  else if (c.reps === 2) ivl = g === 2 ? 2 : g === 3 ? 4 : 7;
  else ivl = Math.round(c.ivl * (g === 2 ? 1.2 : g === 3 ? c.ease : c.ease * 1.35));
  c.ease = Math.round(Math.max(1.3, c.ease + (g === 2 ? -0.15 : g === 4 ? 0.15 : 0)) * 100) / 100;
  c.ivl = Math.max(1, ivl);
  c.due = now + c.ivl * DAY;
}

// ---------- Inspector ----------
function saveBtn(a, big = false) {
  if (saveables.size > 4000) saveables.clear();
  const k = 's' + (saveSeq++);
  saveables.set(k, a);
  const on = isSaved(a, cur?.ctx?.word || cur?.q || a.head);
  return big
    ? `<button type="button" class="btn sm${on ? ' saved' : ''}" data-save="${k}" title="Save to vocabulary (S)">${ICON.save}<span class="lbl">${on ? 'Saved' : 'Save'}</span></button>`
    : `<button type="button" class="save-mini${on ? ' on' : ''}" data-save="${k}" title="Save to vocabulary" aria-label="Save ${esc(a.head)}">${ICON.save}</button>`;
}

function renderInspector() {
  if (!cur) {
    insp.innerHTML = `<div class="insp-empty">
      <div class="big-ar" lang="ar">قاموس</div>
      <p><strong>Click any word</strong> in a text to look it up.</p>
      <p>Or press <kbd>⌘K</kbd> to search.</p>
      <div class="keys">
        <span>Next / previous word <span><kbd>←</kbd> <kbd>→</kbd></span></span>
        <span>Save with sentence <kbd>S</kbd></span>
        <span>Open full entry <kbd>↵</kbd></span>
      </div>
    </div>`;
    return;
  }
  if (cur.loading) {
    insp.innerHTML = `<div class="hw-head"><h2 class="hw-word" lang="ar">${esc(cur.q)}</h2></div>
      <p class="muted">${atLeast('morph') ? 'Looking up…' : 'Loading lexicons…'}</p>`;
    return;
  }
  insp.innerHTML = entryHtml(cur.model, { full: false });
  openDefaultSources(insp);
  renderGrammarTray();
}

let trayCollapsed = false;
function analysisBadgeHtml(a) {
  if (!a || typeof a !== 'object') return '';
  const pct = typeof a.camelConfidence === 'number' ? Math.round(a.camelConfidence * 100) : null;
  if (a.camelAgreement === 'agreed') {
    return `<span class="pill good" style="height:20px">CAMeL verified${pct != null ? ` ${pct}%` : ''}</span>`;
  }
  if (a.camelAgreement === 'check') {
    return `<span class="pill" style="height:20px;border-color:var(--accent);color:var(--accent)">check parse · CAMeL vs AI</span>`;
  }
  if (a.camelAgreement === 'split') {
    return `<span class="pill" style="height:20px;border-color:var(--accent);color:var(--accent)">CAMeL split${pct != null ? ` ${pct}%` : ''}</span>`;
  }
  if (a.morphVerified) {
    return `<span class="pill good" style="height:20px">morphology verified</span>`;
  }
  return '';
}

function renderGrammarTray() {
  if (!grammarTray) return;
  const inReader = route().name === 'text';
  const ctx = cur?.ctx || {};
  if (!inReader || !ctx.sentence) {
    grammarTray.hidden = true;
    grammarTray.innerHTML = '';
    return;
  }

  grammarTray.hidden = false;
  grammarTray.classList.toggle('collapsed', trayCollapsed);
  const a = cur?.analysis;
  const word = ctx.word || cur?.q || '';
  const chev = trayCollapsed ? '▴' : '▾';

  if (a === 'pending') {
    grammarTray.innerHTML = `<div class="gt-inner">
      <div class="gt-bar" data-act="toggle-tray">
        <span class="gt-title">Grammar in context</span>
        <span class="gt-word" lang="ar">${esc(word)}</span>
        <span class="gt-pos muted">Analyzing with CAMeL + local AI…</span>
        <div class="gt-bar-right"><span class="muted" style="font-size:12px">${chev}</span></div>
      </div>
    </div>`;
    return;
  }

  if (a && a.error) {
    grammarTray.innerHTML = `<div class="gt-inner">
      <div class="gt-bar" data-act="toggle-tray">
        <span class="gt-title">Grammar in context</span>
        <span class="gt-word" lang="ar">${esc(word)}</span>
        <div class="gt-bar-right">
          <button type="button" class="btn sm" data-act="analyze">Retry</button>
          <span class="muted" style="font-size:12px">${chev}</span>
        </div>
      </div>
      ${trayCollapsed ? '' : `<div class="gt-body"><p class="gt-warn">Couldn’t analyze: ${esc(a.error)}</p></div>`}
    </div>`;
    return;
  }

  if (a && typeof a === 'object') {
    const posLine = [a.partOfSpeech && esc(a.partOfSpeech), a.arabicTag && `<span class="ar" style="font-size:15px">${esc(a.arabicTag)}</span>`].filter(Boolean).join(' · ');
    const mods = (a.actingOnIt || []).map(g => `<div class="gt-item">
      ${g.particle ? `<span class="gt-ar" lang="ar">${esc(g.particle)}</span>` : ''}
      <span class="gt-rel">${esc(g.role || '')}</span>
      <span class="gt-eff">${esc(g.effect || '')}</span>
    </div>`).join('');
    const args = (a.arguments || []).map(g => `<div class="gt-item">
      <span class="gt-rel">${esc(g.relation || '')}</span>
      <span class="gt-ar" lang="ar">${esc(g.arabic || '')}</span>
      ${g.note ? `<span class="gt-eff">${esc(g.note)}</span>` : ''}
    </div>`).join('');

    grammarTray.innerHTML = `<div class="gt-inner">
      <div class="gt-bar" data-act="toggle-tray">
        <span class="gt-title">Grammar</span>
        <span class="gt-word" lang="ar">${esc(a.vocalized || word)}</span>
        ${posLine ? `<span class="gt-pos">${posLine}</span>` : ''}
        ${analysisBadgeHtml(a)}
        <div class="gt-bar-right">
          <button type="button" class="btn ghost sm" data-act="analyze" title="Re-analyze this word">Re-run</button>
          <span class="muted" style="font-size:13px">${chev}</span>
        </div>
      </div>
      ${trayCollapsed ? '' : `<div class="gt-body">
        ${(a.diacritizedLine || a.clauseTranslation) ? `<div class="gt-band">
          ${a.diacritizedLine ? `<p class="gt-diac" lang="ar">${esc(a.diacritizedLine)}</p>` : ''}
          ${a.clauseTranslation ? `<p class="gt-clause">“${esc(a.clauseTranslation)}”</p>` : ''}
        </div>` : ''}
        <div class="gt-grid">
          <div class="gt-col">
            <div>
              <p class="gt-sec-lbl">Meaning here</p>
              <p class="gt-meaning">${esc(a.meaningHere || '—')}</p>
            </div>
            ${mods ? `<div><p class="gt-sec-lbl">Acting on it · العوامل</p><div class="gt-chips">${mods}</div></div>` : ''}
          </div>
          <div class="gt-col">
            <div>
              <p class="gt-sec-lbl">Iʿrāb &amp; role · الإعراب</p>
              ${a.syntaxRole ? `<p class="gt-role">${esc(a.syntaxRole)}</p>` : ''}
              ${args ? `<div class="gt-chips">${args}</div>` : ''}
            </div>
          </div>
        </div>
        ${a.camelAlternative ? `<p class="gt-warn">⚠ ${esc(a.camelAlternative)}</p>` : ''}
        ${a.ambiguityNote ? `<p class="gt-note">${esc(a.ambiguityNote)}</p>` : ''}
      </div>`}
    </div>`;
    return;
  }

  grammarTray.innerHTML = `<div class="gt-inner">
    <div class="gt-bar" data-act="toggle-tray">
      <span class="gt-title">Grammar in context</span>
      <span class="gt-word" lang="ar">${esc(word)}</span>
      <div class="gt-bar-right">
        ${native() ? `<button type="button" class="btn sm primary" data-act="analyze">Explain</button>` : ''}
        <span class="muted" style="font-size:12px">${chev}</span>
      </div>
    </div>
  </div>`;
}

function entryHtml(m, { full }) {
  const ctx = cur?.q === m.query || cur?.model === m ? (cur.ctx || {}) : {};
  const back = !full && inspStack.length
    ? `<button type="button" class="btn ghost sm" data-act="insp-back" style="margin:-4px 0 8px -8px">${ICON.back}<span>${esc(inspStack[inspStack.length - 1].q)}</span></button>` : '';

  if (m.kind === 'english') {
    return `${back}<p class="kicker">English · ${plural(m.total, 'match')}</p>
      <h2 style="margin:0 0 14px;font-size:22px">“${esc(m.query)}”</h2>
      ${m.english.length ? `<div>${m.english.map(e => `<div class="entry">
        <div class="entry-h"><span class="ar lk" data-q="${esc(e[1])}">${esc(e[1])}</span>${e[6] ? `<span class="tr">${esc(e[6])}</span>` : ''}</div>
        <div class="def">${esc(shortGloss(stripHead(e), 160))}</div></div>`).join('')}</div>` : `<p class="empty">No Hans Wehr definitions mention that.</p>`}`;
  }
  if (m.kind === 'fallback') {
    return `${back}<div class="hw-head"><h2 class="hw-word" lang="ar">${esc(m.query)}</h2></div>
      <p class="muted">No entry found. Closest spellings:</p>
      <div class="chips">${m.near.map(r => `<button type="button" class="chip" data-q="${esc(r[1])}"><span class="ar">${esc(r[1])}</span></button>`).join('') || '<span class="muted">None</span>'}</div>`;
  }
  if (m.kind === 'passage') {
    return `${back}<p class="kicker">That’s a passage</p>
      <p class="context-quote">${esc(m.query)}</p>
      <div class="insp-foot"><button type="button" class="btn primary" data-act="passage-to-text">${ICON.text}<span>Open as a text</span></button></div>`;
  }

  const primaryTarget = primarySaveTarget() || m.answers[0];
  const primarySaved = primaryTarget ? isSaved(primaryTarget, cur?.ctx?.word || cur?.q || primaryTarget.head) : false;
  const primaryTip = primaryTarget?.gloss ? `Save ${primaryTarget.head} (“${plain(primaryTarget.gloss).slice(0, 60)}”) (S)` : 'Save to vocabulary (S)';
  const asWritten = ctx.word && norm(ctx.word) !== norm(m.word) ? ctx.word : '';
  const parts = [];
  parts.push(`${back}<div class="hw-head">
    <div>
      <h2 class="hw-word" lang="ar">${esc(m.word)}</h2>
      ${m.tr ? `<div class="hw-tr">${esc(m.tr)}</div>` : ''}
    </div>
    <div class="hw-actions">
      ${primaryTarget ? `<button type="button" class="btn sm${primarySaved ? ' saved on' : ''}" data-act="save-primary" title="${esc(primaryTip)}">${ICON.save}<span class="lbl">${primarySaved ? 'Saved' : 'Save'}</span></button>` : ''}
      ${!full ? `<button type="button" class="btn sm ghost" data-act="open-entry" title="Open full entry (↵)" aria-label="Open full entry">${ICON.expand}</button>` : `<button type="button" class="btn sm ghost" data-copy="${esc(m.word)}" title="Copy">${ICON.copy}</button>`}
    </div>
  </div>`);

  const pills = [];
  if (asWritten) pills.push(`<span class="pill">as written <span class="ar">${esc(asWritten)}</span></span>`);
  for (const r of m.roots) pills.push(`<button type="button" class="pill accent" data-q="${esc(r.letters)}" title="Open root">root <span class="ar">${esc(r.letters)}</span></button>`);
  if (m.roots[0]?.quran) pills.push(`<span class="pill gold">Qur’an ${m.roots[0].quran}×</span>`);
  if (m.exactHarakat) pills.push(`<span class="pill good">exact harakat</span>`);
  if (m.sources.particles?.[0]) pills.push(`<span class="pill gold"><span class="ar">${esc(m.sources.particles[0].arCat)}</span></span>`);
  if (pills.length) parts.push(`<div class="hw-meta">${pills.join('')}</div>`);
  if (m.retry) parts.push(`<p class="muted" style="font-size:12.5px;margin:8px 0 0">No direct match for <span class="ar">${esc(m.retry.from)}</span>; showing <span class="ar">${esc(m.retry.word)}</span> ${m.retry.why === 'al' ? 'without the leading ال' : 'without the emphatic نّ'}.</p>`);

  if (m.parses.length) {
    const [p0, ...rest] = m.parses;
    parts.push(`<div class="block"><p class="block-title">Parsed</p><div class="parse">
      <div class="parse-row">${p0.segments.map(s => `<span class="mseg${s.role === 'stem' ? ' stem' : ''}"><span class="ar">${esc(s.ar)}</span><span class="gl">${esc(s.gloss)}</span></span>`).join('')}</div>
      ${rest.length ? `<div class="parse-alt">Also: ${rest.map(p => `<span class="ar" style="font-size:16px">${esc(p.segments.map(s => s.ar).join('+'))}</span> <span>${esc(p.gloss.slice(0, 60))}</span>`).join(' · ')}</div>` : ''}
    </div></div>`);
  }

  if (ctx.sentence) {
    parts.push(`<div class="block"><p class="block-title">In this sentence</p><p class="context-quote" lang="ar">${markWord(ctx.sentence, ctx.word)}</p></div>`);
  }

  // While reading a text, Grammar in Context lives in the wide pinned tray under the reader
  // so the right inspector stays focused purely on Qamus's dictionary entries.
  if (full || route().name !== 'text') {
    parts.push(aiBlock(ctx));
  }

  if (m.answers.length) {
    parts.push(`<div class="block"><p class="block-title">Meaning</p>${m.answers.map((a, i) => `<div class="answer${i === 0 ? ' lead' : ''}${full ? '' : ' clamp'}">
      <div class="answer-head"><span class="ar">${esc(a.head)}</span>${a.tr ? `<span class="tr">${esc(a.tr)}</span>` : ''}<span class="pill" style="height:20px;font-size:11px">${esc(a.label)}</span><span style="margin-left:auto">${saveBtn(a)}</span></div>
      <div class="def">${a.html}</div></div>`).join('')}</div>`);
  }

  parts.push(`<div class="block">${sourcesHtml(m, full)}</div>`);
  return full ? `<div class="entry-view">${parts.join('')}</div>` : parts.join('');
}

function aiBlock(ctx) {
  const a = cur?.analysis;
  if (a === 'pending') return `<div class="block"><p class="block-title">Grammar in context</p><div class="ai-card"><p>Analyzing on-device…</p></div></div>`;
  if (a && a.error) return `<div class="block"><p class="block-title">Grammar in context</p><div class="ai-card"><p>Couldn’t analyze: ${esc(a.error)}</p><button type="button" class="btn sm" data-act="analyze">Retry</button></div></div>`;
  if (a && typeof a === 'object') {
    const row = (k, v) => v ? `<dt>${k}</dt><dd>${v}</dd>` : '';
    const pct = typeof a.camelConfidence === 'number' ? Math.round(a.camelConfidence * 100) : null;
    let badge = '';
    if (a.camelAgreement === 'agreed') {
      badge = ` <span class="pill good" style="height:18px">CAMeL verified${pct != null ? ` ${pct}%` : ''}</span>`;
    } else if (a.camelAgreement === 'check') {
      badge = ` <span class="pill" style="height:18px;border-color:var(--accent);color:var(--accent)">check parse · CAMeL vs AI</span>`;
    } else if (a.camelAgreement === 'split') {
      badge = ` <span class="pill" style="height:18px;border-color:var(--accent);color:var(--accent)">CAMeL split${pct != null ? ` ${pct}%` : ''}</span>`;
    } else if (a.morphVerified) {
      badge = ' <span class="pill good" style="height:18px">morphology verified</span>';
    }
    return `<div class="block"><p class="block-title">Grammar in context${badge}</p><div class="ai-result"><dl>
      ${row('Reading', a.vocalized && `<span class="ar" style="font-size:19px">${esc(a.vocalized)}</span>`)}
      ${row('Form', [a.partOfSpeech && esc(a.partOfSpeech), a.arabicTag && `<span class="ar">${esc(a.arabicTag)}</span>`].filter(Boolean).join(' · '))}
      ${row('Here', esc(a.meaningHere || ''))}
      ${row('Iʿrāb', esc(a.syntaxRole || ''))}
      ${(a.arguments || []).map(g => row(esc(g.relation), `<span class="ar">${esc(g.arabic)}</span>${g.note ? ` — ${esc(g.note)}` : ''}`)).join('')}
      ${(a.actingOnIt || []).map(g => row(esc(g.role), `<span class="ar">${esc(g.particle)}</span> ${esc(g.effect)}`)).join('')}
      ${row('Vocalized', a.diacritizedLine && `<span class="ar" style="font-size:16px">${esc(a.diacritizedLine)}</span>`)}
    </dl>${a.clauseTranslation ? `<p class="clause">“${esc(a.clauseTranslation)}”</p>` : ''}${a.camelAlternative ? `<p style="font-size:12px;margin:6px 0 0;color:var(--accent)">⚠ ${esc(a.camelAlternative)}</p>` : ''}${a.ambiguityNote ? `<p class="muted" style="font-size:12px;margin:6px 0 0">${esc(a.ambiguityNote)}</p>` : ''}</div></div>`;
  }
  if (!ctx.sentence) return '';
  return native()
    ? `<div class="block"><div class="ai-card"><p>Explain this word’s grammar in its sentence.</p><button type="button" class="btn sm" data-act="analyze">Explain</button></div></div>`
    : `<div class="block"><div class="ai-card"><p><strong>Grammar in context</strong> runs on-device in the Mac app, grounded in these entries.</p></div></div>`;
}

function sourcesHtml(m, full) {
  const s = m.sources, out = [];
  if (s.particles?.length > 2 || (s.particles?.length && m.answers[0]?.source !== 'particle')) {
    out.push(`<details class="src" data-src="particles"><summary>Particles <span class="n">${s.particles.length}</span></summary><div class="src-body"></div></details>`);
  }
  for (const rid of s.roots) {
    const r = state.byId.get(rid);
    if (!r) continue;
    out.push(`<details class="src" data-src="hw" data-rid="${rid}"><summary>Hans Wehr · <span class="ar" style="font-size:18px;font-weight:400">${esc([...r[1]].join(' '))}</span><span class="n">${(state.kids.get(rid)?.length || 0) + 1}</span></summary><div class="src-body"></div></details>`);
    const nf = state.formsBy.get(rid)?.length || 0;
    if (nf) out.push(`<details class="src" data-src="forms" data-rid="${rid}"><summary>Verb forms<span class="n">${nf}</span></summary><div class="src-body"></div></details>`);
  }
  if (s.wikt.length && state.W) out.push(`<details class="src" data-src="wikt"><summary>Wiktionary<span class="n">${s.wikt.length}</span></summary><div class="src-body"></div></details>`);
  for (const k of s.laneKeys) out.push(`<details class="src" data-src="lane" data-k="${esc(k)}"><summary>Lane’s Lexicon · <span class="ar" style="font-size:18px;font-weight:400">${esc([...k].join(' '))}</span></summary><div class="src-body"></div></details>`);
  for (const id of AR_IDS) {
    for (const k of s.arKeys[id] || []) out.push(`<details class="src" data-src="ar" data-dict="${id}" data-k="${esc(k)}"><summary>${esc(AR_DICTS[id].name)} · <span class="ar" style="font-size:18px;font-weight:400">${esc([...k].join(' '))}</span></summary><div class="src-body"></div></details>`);
  }
  return out.length ? `<p class="block-title">Dictionaries</p>${out.join('')}` : '';
}

function openDefaultSources(root) {
  // Nothing opens by default in the compact inspector: the lead answers are the point.
  // The full entry view opens the first Hans Wehr root.
  $$('details.src', root).forEach(d => d.addEventListener('toggle', () => { if (d.open) fillSource(d); }, { once: false }));
}

async function fillSource(d) {
  if (d.dataset.filled) return;
  d.dataset.filled = '1';
  const body = $('.src-body', d);
  const m = cur?.model;
  const S = m?.sources;
  if (!S) return;
  const kind = d.dataset.src;
  try {
    if (kind === 'particles') {
      body.innerHTML = S.particles.map(p => `<div class="entry"><div class="entry-h"><span class="ar">${esc(p.ar)}</span><span class="tr">${esc(p.tr)}</span>${saveBtnInline({ source: 'particle', key: 'p:' + p.ar, head: p.ar, tr: p.tr, gloss: `${p.enCat}: ${p.meaning}` })}</div>
        <div class="def"><strong>${esc(p.enCat)}</strong> · ${esc(p.meaning)}${p.effect ? `<br><span class="muted">عمل: ${esc(p.effect)}</span>` : ''}${p.example ? `<br>${defHtml(p.example)}` : ''}</div></div>`).join('');
    } else if (kind === 'hw') {
      const rid = +d.dataset.rid, r = state.byId.get(rid);
      const kids = state.kids.get(rid) || [];
      const rows = [r, ...kids];
      const hit = e => S.hits.has(e[0]);
      const ordered = [...rows.filter(hit), ...rows.filter(e => !hit(e))];
      const LIMIT = 14;
      const row = e => {
        const html = e === r ? formICut(e) : stripHead(e);
        return `<div class="entry${hit(e) ? ' hit' : ''}"><div class="entry-h"><span class="ar lk" data-q="${esc(e[1])}">${esc(e[1])}</span>${e[6] ? `<span class="tr">${esc(e[6])}</span>` : ''}${e === r ? '<span class="pill" style="height:18px;font-size:10.5px">root · form I</span>' : ''}
          ${saveBtnInline({ source: 'hw', key: 'hw:' + e[0], head: e[1], tr: e[6] || '', gloss: shortGloss(html, 140), root: [...r[1]].join(' ') })}</div>
          <div class="def">${defHtml(html)}</div></div>`;
      };
      body.innerHTML = ordered.slice(0, LIMIT).map(row).join('') +
        (ordered.length > LIMIT ? `<button type="button" class="btn sm more-btn" data-act="more">Show ${ordered.length - LIMIT} more</button>` : '');
      const more = $('[data-act="more"]', body);
      if (more) more.onclick = () => { more.insertAdjacentHTML('beforebegin', ordered.slice(LIMIT).map(row).join('')); more.remove(); rerenderSaves(); };
    } else if (kind === 'forms') {
      const rid = +d.dataset.rid;
      body.innerHTML = (state.formsBy.get(rid) || []).map(f => `<div class="entry"><div class="entry-h"><span class="form-num">${esc(f[1])}</span>${f[2] ? `<span class="ar lk" data-q="${esc(f[2])}">${esc(f[2])}</span>` : ''}<span class="tr">${esc(VERB_PATTERNS[f[1]]?.wazn || '')} · ${esc(VERB_PATTERNS[f[1]]?.sense || '')}</span>
        ${f[3] ? saveBtnInline({ source: 'form', key: `form:${f[0]}:${f[1]}`, head: f[2] || '', gloss: shortGloss(f[3], 140), root: rootLetters(rid) }) : ''}</div>
        <div class="def">${f[3] ? defHtml(f[3]) : ''}</div></div>`).join('');
    } else if (kind === 'wikt') {
      body.innerHTML = S.wikt.map(k => {
        const e = state.W.entries[k];
        return `<div class="entry"><div class="entry-h"><span class="ar">${esc(e[0])}</span>${e[1] ? `<span class="tr">${esc(e[1])}</span>` : ''}${saveBtnInline({ source: 'wikt', key: 'wikt:' + k, head: e[0], tr: e[1] || '', gloss: shortGloss(e[2], 140) })}</div>
          <div class="def">${defHtml(e[2], ['i', 'br', 'ol', 'li'])}</div></div>`;
      }).join('');
    } else if (kind === 'lane') {
      body.innerHTML = '<p class="muted">Loading…</p>';
      const k = d.dataset.k;
      const items = await loadLaneEntries(k);
      body.innerHTML = items.length ? items.map(([w, def], i) => {
        const hitRow = S.laneWant && norm(w) === S.laneWant;
        return `<div class="entry${hitRow ? ' hit' : ''}"><div class="entry-h"><span class="ar">${esc(w)}</span>${saveBtnInline({ source: 'lane', key: `lane:${k}:${i}`, head: w, gloss: shortGloss(def, 140) })}</div>
          <div class="def">${defHtml(def, ['i', 'br', 'table', 'tbody', 'tr', 'td', 'center'])}</div></div>`;
      }).join('') : '<p class="muted">No entries.</p>';
    } else if (kind === 'ar') {
      body.innerHTML = '<p class="muted">Loading…</p>';
      const id = d.dataset.dict, k = d.dataset.k;
      const items = (await arShard(id, k))[k] || [];
      body.innerHTML = items.map((html, i) => `<div class="entry"><div class="entry-h" style="justify-content:flex-end">${saveBtnInline({ source: id, key: `${id}:${k}:${i}`, head: arHead(id, html, k), gloss: plain(html).slice(0, 140) })}</div>
        <div class="ar-dict" lang="ar">${arHtml(html, S.arWant)}</div></div>`).join('') +
        `<p class="muted" style="font-size:11.5px;margin:8px 0 0">${esc(AR_DICTS[id].full)} · via al-Maktaba al-Shāmila</p>`;
    }
  } catch {
    delete d.dataset.filled;
    body.innerHTML = '<p class="muted">Couldn’t load this dictionary. Check your connection.</p>';
  }
}
function saveBtnInline(a) { return `<span class="save-mini-wrap" style="margin-left:auto">${saveBtn(a)}</span>`; }

// ---------- Router ----------
function route() {
  const h = location.hash.replace(/^#\/?/, '');
  const [name, ...rest] = h.split('/');
  return { name: name || 'desk', arg: decodeURIComponent(rest.join('/')) };
}
const go = h => { if (location.hash !== h) location.hash = h; else render(); };

function setBar(title, sub = '', actions = '', arTitle = false) {
  $('#crumbs').innerHTML = `<h1${arTitle ? ' lang="ar"' : ''}>${title}</h1>${sub ? `<span class="sub">${sub}</span>` : ''}`;
  $('#stage-actions').innerHTML = actions;
}

function render() {
  const r = route();
  // Browsing starts from the first card each time you come in from somewhere else.
  if (r.name === 'browse' && render.last !== 'browse') browse = null;
  render.last = r.name;
  const navName = { browse: 'vocab' }[r.name] || r.name;
  $$('.nav-item, .tab-item[data-route]').forEach(a => { if (a.dataset.route === navName) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current'); });
  // Three panes only while reading; elsewhere the full entry lives in the centre.
  desk.classList.toggle('reading', r.name === 'text');
  if (r.name !== 'text') closeInspector();
  renderTextList();
  desk.classList.remove('side-open');
  syncScrim();
  view.scrollTop = 0;
  if (r.name === 'text') { renderReader(r.arg); renderGrammarTray(); return; }
  renderGrammarTray();
  if (r.name === 'new') return renderComposer();
  if (r.name === 'entry') return renderEntry(r.arg);
  if (r.name === 'vocab') return renderVocab();
  if (r.name === 'review') return renderReview();
  if (r.name === 'browse') return renderBrowse();
  if (r.name === 'texts') return renderTexts();
  if (r.name === 'history') return renderHistory();
  return renderDesk();
}

// ---------- Texts: labels ----------
const RECENT_TEXTS = 5;
function fmtStamp(t) {
  const d = new Date(t);
  const opts = { day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit' };
  if (d.getFullYear() !== new Date().getFullYear()) opts.year = 'numeric';
  return d.toLocaleString(undefined, opts);
}
const textKind = t => (t.source === 'scan' ? 'scan' : t.source === 'sample' ? 'sample' : 'paste');
const KIND_LABEL = { scan: 'Scan', paste: 'Pasted', sample: 'Sample' };
// "Scan · 24 Nov, 3:12 pm". A note you wrote yourself wins; older scans saved "Scanned page" as their note.
function textStamp(t) {
  if (t.note && t.note !== 'Scanned page') return t.note;
  return `${KIND_LABEL[textKind(t)]} · ${fmtStamp(t.created)}`;
}
const textsByOpened = () => [...db.texts].sort((a, b) => b.opened - a.opened);

function renderTextList() {
  const r = route();
  const all = textsByOpened();
  const shown = all.slice(0, RECENT_TEXTS);
  // Reading an older text keeps it visible in the sidebar while it's open.
  const open = r.name === 'text' && all.find(t => t.id === r.arg);
  if (open && !shown.includes(open)) shown.push(open);
  $('#text-list').innerHTML = shown.map(t => {
    const ar = isAr(t.title);
    return `<li><a href="#/text/${t.id}" ${r.name === 'text' && r.arg === t.id ? 'aria-current="page"' : ''}>
      <span class="t-title"${ar ? ' lang="ar"' : ''}>${esc(t.title)}</span>
      <span class="t-meta">${esc(textStamp(t))}</span></a></li>`;
  }).join('') + (all.length > RECENT_TEXTS ? `<li><a class="t-all" href="#/texts" ${r.name === 'texts' ? 'aria-current="page"' : ''}>All texts (${all.length}) →</a></li>` : '')
    || `<li class="muted" style="padding:6px 9px;font-size:12.5px">No texts yet</li>`;
  const tc = $('#texts-count');
  if (tc) { tc.hidden = !all.length; tc.textContent = all.length; }
}

// ---------- Desk ----------
function renderDesk() {
  setBar('Desk', '', `<button type="button" class="btn" data-act="new-text">${ICON.plus}<span class="lbl">New text</span></button>`);
  const hour = new Date().getHours();
  const greet = hour < 5 ? 'Late night reading' : hour < 12 ? 'Good morning' : hour < 18 ? 'Good afternoon' : 'Good evening';
  const byOpened = textsByOpened();
  const last = byOpened[0];
  const cards = liveCards();
  const T = folderTree();
  const due = cards.filter(c => isDueNow(c, T)).length;
  const known = cards.filter(c => c.reps >= 2).length;
  const recent = liveHistory().slice(0, 14);
  view.innerHTML = `<div class="wrap">
    <div class="desk-hero">
      <h2>${greet}<span class="ar" lang="ar">مَرْحَبًا</span></h2>
      <button type="button" class="big-search" data-act="palette">${ICON.search}<span class="ph-long">Look up a word, a root like ك ت ب, or English…</span><span class="ph-short">Look up a word or root…</span><kbd>⌘K</kbd></button>
    </div>
    <div class="tiles">
      ${last ? `<a class="tile accent" href="#/text/${last.id}"><span class="lbl">Continue reading</span><span class="t-ar" lang="ar">${esc(last.body.slice(0, 140))}</span><span class="lbl"><bdi>${esc(last.title)}</bdi> · ${plural((last.looked || []).length, 'word')} looked up</span></a>` : ''}
      <a class="tile" href="#/review"><span class="num">${due}</span><span class="lbl">${due ? 'cards due for review' : 'nothing due, all caught up'}</span></a>
      <a class="tile" href="#/vocab"><span class="num">${cards.length}</span><span class="lbl">saved words · ${known} reviewed twice or more</span></a>
      <button type="button" class="tile tile-new" data-act="new-text"><span class="num" style="color:var(--accent)">+</span><span class="lbl">Paste a passage to read. Every word becomes clickable, and saving keeps the sentence.</span></button>
    </div>
    <div class="desk-texts">
      <p class="kicker" style="display:flex;justify-content:space-between;align-items:center">Your texts <button type="button" class="btn sm" data-act="new-text">${ICON.plus}<span>New</span></button></p>
      <div class="vocab-list">${byOpened.slice(0, RECENT_TEXTS).map(t => `<a class="dt-row" href="#/text/${t.id}">
        <span class="dt-title"${isAr(t.title) ? ' lang="ar"' : ''}>${esc(t.title)}</span>
        <span class="dt-meta">${esc(textStamp(t))} · ${plural((t.looked || []).length, 'word')} looked up</span></a>`).join('')}
        ${byOpened.length > RECENT_TEXTS ? `<a class="dt-row dt-all" href="#/texts">All texts (${byOpened.length}) →</a>` : ''}</div>
    </div>
    <p class="kicker">Recent lookups</p>
    ${recent.length ? `<div class="chips">${recent.map(h => `<button type="button" class="chip" data-q="${esc(h.q)}" data-full="1"><span class="ar">${esc(h.q)}</span>${h.g ? `<span class="g">${esc(h.g)}</span>` : ''}</button>`).join('')}</div>`
      : `<p class="muted">Nothing yet. Open <a href="#/text/${last?.id || ''}"><bdi>${esc(last?.title || 'a text')}</bdi></a> and click a word.</p>`}
  </div>`;
}

// ---------- Reader ----------
let tokens = [];          // [{ i, w, sentence, el }]
let selIndex = -1;
let curText = null;

function surroundingWindow(paras, pIdx, s, e) {
  const p = paras[pIdx];
  const MAX_LEN = 480;
  // Short paragraph or OCR-split line: join immediate neighboring lines so wrapped clauses stay intact.
  if (p.length < 150) {
    const parts = [];
    if (pIdx > 0) parts.push(paras[pIdx - 1]);
    parts.push(p);
    if (pIdx + 1 < paras.length) parts.push(paras[pIdx + 1]);
    const joined = parts.join('\n');
    if (joined.length <= MAX_LEN) return joined;
    // Keep current paragraph + nearest neighbor that fits.
    if (pIdx > 0 && (paras[pIdx - 1].length + p.length + 1) <= MAX_LEN) return `${paras[pIdx - 1]}\n${p}`;
    if (pIdx + 1 < paras.length && (p.length + paras[pIdx + 1].length + 1) <= MAX_LEN) return `${p}\n${paras[pIdx + 1]}`;
    return p;
  }
  if (p.length <= MAX_LEN) return p;

  // Long paragraph: expand one sentence backward and one sentence forward around [s, e].
  let winStart = s;
  let prev = s - 1;
  while (prev > 0 && (STOP_RE.test(p[prev]) || /\s/.test(p[prev]))) prev--;
  while (prev > 0 && !STOP_RE.test(p[prev - 1])) prev--;
  if (prev < s) winStart = prev;

  let winEnd = Math.min(p.length, e + 1);
  let next = winEnd;
  while (next < p.length && (STOP_RE.test(p[next]) || /\s/.test(p[next]))) next++;
  while (next < p.length && !STOP_RE.test(p[next])) next++;
  if (next > winEnd) winEnd = Math.min(p.length, next + 1);

  let snippet = p.slice(winStart, winEnd).replace(EDGE_RE, '');
  if (snippet.length > MAX_LEN) {
    // Fall back to current sentence + half-window padding around it so we never exceed MAX_LEN.
    const center = Math.floor((s + e) / 2);
    let lo = Math.max(0, center - Math.floor(MAX_LEN / 2));
    let hi = Math.min(p.length, lo + MAX_LEN);
    if (lo > 0) { const sp = p.indexOf(' ', lo); if (sp > 0 && sp < s) lo = sp + 1; }
    if (hi < p.length) { const sp = p.lastIndexOf(' ', hi); if (sp > e) hi = sp; }
    snippet = p.slice(lo, hi).replace(EDGE_RE, '');
  }
  return snippet;
}

function tokenize(body) {
  const paras = body.split(/\n\s*\n|\n/).map(s => s.trim()).filter(Boolean);
  const out = [];
  const html = paras.map((p, pIdx) => {
    let last = 0, h = '';
    const marks = [];
    p.replace(WORD_RE, (w, at) => { marks.push([w, at]); return w; });
    for (const [w, at] of marks) {
      let s = at, e = at + w.length;
      while (s > 0 && !STOP_RE.test(p[s - 1])) s--;
      while (e < p.length && !STOP_RE.test(p[e])) e++;
      const sentence = p.slice(s, Math.min(p.length, e + 1)).replace(EDGE_RE, '');
      const surrounding = surroundingWindow(paras, pIdx, s, e) || sentence;
      h += esc(p.slice(last, at)) + `<span class="w" data-i="${out.length}">${esc(w)}</span>`;
      out.push({ i: out.length, w, sentence, surrounding });
      last = at + w.length;
    }
    return `<p>${h}${esc(p.slice(last))}</p>`;
  }).join('');
  return { html, toks: out };
}

function renderReader(id) {
  const t = db.texts.find(x => x.id === id);
  if (!t) return go('#/desk');
  curText = t;
  t.opened = Date.now();
  t.looked ||= [];
  persist();
  const { html, toks } = tokenize(t.body);
  tokens = toks;
  selIndex = -1;
  const uniq = new Set(toks.map(x => norm(x.w)));
  const known = [...uniq].filter(n => isKnown(n)).length;
  setBar(esc(t.title), esc(textStamp(t)),
    `<button type="button" class="btn ghost" data-act="edit-text" title="Edit text">${ICON.edit}<span class="lbl">Edit</span></button>
     <button type="button" class="btn ghost" data-act="delete-text" title="Delete text">${ICON.trash}</button>`, isAr(t.title));
  view.innerHTML = `<div class="reader-wrap">
    <article class="page">
      <div class="page-meta"><span class="stats"><span>${plural(toks.length, 'word')}</span><span>${uniq.size} unique</span><span id="looked-stat">${t.looked.length} looked up</span><span>${known} saved</span></span><span>${ago(t.created)}</span></div>
      <div class="passage" lang="ar" dir="rtl">${html}</div>
    </article>
    <div class="reader-legend">
      <span><span class="sw on"></span>selected</span>
      <span><span class="sw known"></span>in your vocabulary</span>
      <span class="key-hint"><kbd>←</kbd> <kbd>→</kbd> step through words</span>
      <span class="key-hint"><kbd>S</kbd> save with sentence</span>
      <span class="touch-hint">Tap any word to look it up</span>
    </div>
  </div>`;
  const looked = new Set(t.looked);
  $$('.passage .w', view).forEach(el => {
    const tk = tokens[+el.dataset.i];
    tk.el = el;
    if (isKnown(tk.w)) el.classList.add('known');
    if (looked.has(norm(tk.w))) el.classList.add('seen');
  });
  // Keep the inspector if the current lookup came from this text.
  if (cur?.ctx?.textId === t.id && cur.ctx.index != null && tokens[cur.ctx.index]) {
    selIndex = cur.ctx.index;
    tokens[selIndex].el.classList.add('on');
  }
}

function selectToken(i, { scroll = false } = {}) {
  const tk = tokens[i];
  if (!tk) return;
  if (tokens[selIndex]?.el) tokens[selIndex].el.classList.remove('on');
  selIndex = i;
  tk.el.classList.add('on', 'seen');
  if (scroll) tk.el.scrollIntoView({ block: 'center', behavior: 'smooth' });
  if (curText) {
    const n = norm(tk.w);
    if (!curText.looked.includes(n)) { curText.looked.push(n); persist(); }
    const ls = $('#looked-stat'); if (ls) ls.textContent = `${curText.looked.length} looked up`;
  }
  openInspector();
  lookup(tk.w, { word: tk.w, sentence: tk.sentence, surrounding: tk.surrounding, textId: curText?.id, index: i });
}

// ---------- Composer ----------
function renderComposer(editing = null) {
  setBar(editing ? 'Edit text' : 'New text');
  view.innerHTML = `<div class="wrap composer">
    <p class="kicker">${editing ? 'Edit' : 'Paste a passage'}</p>
    <input type="text" id="c-title" placeholder="Title (optional)" value="${esc(editing?.title || '')}" dir="auto">
    <textarea id="c-body" placeholder="الصق النص العربي هنا…" lang="ar" dir="rtl">${esc(editing?.body || '')}</textarea>
    <div class="composer-actions">
      <span class="drop-note">In the Mac app, <kbd>⌘⇧V</kbd> scans a screenshot straight into a new text.</span>
      <span style="display:flex;gap:8px">
        <button type="button" class="btn ghost" data-act="cancel-compose">Cancel</button>
        <button type="button" class="btn primary" data-act="${editing ? 'save-edit' : 'create-text'}" ${editing ? `data-id="${editing.id}"` : ''}>${editing ? 'Save' : 'Open in reader'}</button>
      </span>
    </div>
  </div>`;
  $('#c-body').focus();
}
function addText(body, meta = {}) {
  body = String(body || '').trim();
  if (!body) return null;
  const words = body.match(WORD_RE) || [];
  const t = {
    id: uid(), title: (meta.title || '').trim() || words.slice(0, 4).join(' ') || 'Untitled', note: meta.note || '',
    body, source: meta.source || 'paste', created: Date.now(), opened: Date.now(), looked: [],
  };
  db.texts.unshift(t);
  persist();
  return t;
}

// ---------- Full entry ----------
function renderEntry(q) {
  setBar(esc(q), 'Entry', `<button type="button" class="btn ghost" data-act="back">${ICON.back}<span class="lbl">Back</span></button>`, isAr(q));
  if (!cur || cur.q !== q || cur.loading) {
    view.innerHTML = `<div class="wrap"><p class="muted">Looking up…</p></div>`;
    if (!cur || cur.q !== q) lookup(q);
    return;
  }
  view.innerHTML = `<div class="wrap">${entryHtml(cur.model, { full: true })}</div>`;
  openDefaultSources(view);
  const first = $('details.src[data-src="hw"]', view) || $('details.src', view);
  if (first) first.open = true;
}

// ---------- Vocab: folders, like alqamus.pages.dev (synced with live QamusStore) ----------
// #/vocab is the folder grid; #/vocab/<folder> is one folder's cards.
const vocabUi = { at: null, filter: '', select: false, picked: new Set(), newFolder: false };
function matchCard(c, q) {
  if (!q) return true;
  const n = norm(q), l = q.toLowerCase();
  return !!(n && (norm(c.w).includes(n) || norm(c.head).includes(n))) || c.gloss.toLowerCase().includes(l);
}
const pathName = (id, T) => T.path(id).map(x => x.name).join(' / ');
function renderVocab() {
  const id = route().arg;
  if (vocabUi.at !== id) { vocabUi.at = id; vocabUi.filter = ''; vocabUi.select = false; vocabUi.picked.clear(); vocabUi.newFolder = false; }
  // Sync can re-render while you type: keep the caret and a half-typed folder name.
  const was = document.activeElement?.id;
  const nfVal = $('#nf-name')?.value;
  if (id) renderFolder(id); else renderFolders();
  const fi = $('#v-filter');
  if (fi) fi.oninput = () => { vocabUi.filter = fi.value; renderVocab(); };
  const nf = $('#nf-form');
  if (nf) {
    const inp = $('#nf-name');
    if (nfVal != null) inp.value = nfVal;
    nf.onsubmit = e => {
      e.preventDefault();
      const name = inp.value.trim();
      if (!name) return inp.focus();
      if (liveFolders().some(f => f.name.toLowerCase() === name.toLowerCase())) { toast(`There’s already a folder called ${name}`); return inp.focus(); }
      const fid = createFolder(name);
      vocabUi.newFolder = false;
      toast(`Created ${name}`, fid ? { label: 'Open', run: () => go('#/vocab/' + encodeURIComponent(fid)) } : undefined);
      renderVocab();
    };
    inp.onkeydown = e => { if (e.key === 'Escape') { e.preventDefault(); vocabUi.newFolder = false; renderVocab(); } };
  }
  const el = (was === 'v-filter' || was === 'nf-name') && $('#' + was);
  if (el) { el.focus(); el.setSelectionRange(el.value.length, el.value.length); }
}

function folderCardHtml(f, T, cards, depth = 0) {
  const cs = cardsInFolder(f.id, T, cards);
  const st = folderStats(cs, T);
  const paused = T.paused(f.id);
  const pct = n => (st.total ? (n / st.total) * 100 : 0).toFixed(1);
  const pre = depth ? T.path(f.id).slice(0, -1).map(x => x.name).join(' / ') : '';
  const enc = encodeURIComponent(f.id);
  const badge = paused ? `<span class="pill">Paused</span>`
    : st.ready ? `<span class="pill accent">${st.ready} due</span>`
    : st.total ? `<span class="pill good">Done</span>` : '';
  const study = !st.total ? ''
    : st.ready && !paused ? `<a class="btn sm fc-study" href="#/review/${enc}">Review →</a>`
    : `<a class="btn sm ghost fc-study" href="#/browse/${enc}">Browse →</a>`;
  return `<div class="folder-card" data-go="#/vocab/${enc}" role="link" tabindex="0">
    <div class="fc-top">${pre ? `<span class="fc-path" dir="auto">${esc(pre)} /</span>` : ''}<span class="fc-name" dir="auto">${esc(f.name)}</span></div>
    <div class="mastery" title="${st.mastered} scheduled · ${st.due} due again · ${st.fresh} new"><i class="m-known" style="width:${pct(st.mastered)}%"></i><i class="m-due" style="width:${pct(st.due)}%"></i><i class="m-new" style="width:${pct(st.fresh)}%"></i></div>
    <div class="fc-stats"><span>${plural(st.total, 'card')}</span>${badge}${study}</div>
  </div>`;
}

function cardListHtml(list, T, { showFolder = false, select = false } = {}) {
  return `<div class="vocab-list">${list.map(c => {
    const st = cardState(c, T);
    const picked = select && vocabUi.picked.has(c.id);
    return `<div class="v-row${select ? ' selecting' : ''}${picked ? ' picked' : ''}"${select ? ` data-pick="${esc(c.id)}"` : ''}>
      ${select ? `<input type="checkbox" class="v-check" tabindex="-1" ${picked ? 'checked' : ''} aria-label="Select ${esc(c.head)}">` : ''}
      <div class="v-word" lang="ar"${select ? '' : ` data-q="${esc(c.head)}" data-full="1"`}>${esc(c.head)}</div>
      <div class="v-main"><div class="v-gloss">${esc(c.gloss || '(no meaning)')}${showFolder ? ` <span class="pill v-folder">${esc(pathName(T.of(c), T))}</span>` : ''}</div>${c.ctx ? `<div class="v-ctx" lang="ar">${markWord(c.ctx, c.w)}</div>` : ''}</div>
      <div class="v-side"><span class="st st-${st.k}">${esc(st.label)}</span>${select ? '' : `<button type="button" class="icon-btn" data-act="del-card" data-id="${esc(c.id)}" aria-label="Delete ${esc(c.head)}">${ICON.trash}</button>`}</div>
    </div>`;
  }).join('')}</div>`;
}

const newFolderFormHtml = () => `<form class="nf-form" id="nf-form">
  <span class="nf-icon">${ICON.folder}</span>
  <input type="text" class="field grow" id="nf-name" placeholder="New folder name" maxlength="100" dir="auto" autocomplete="off" spellcheck="false">
  <button type="submit" class="btn primary sm">Create</button>
  <button type="button" class="btn ghost sm" data-act="cancel-folder">Cancel</button>
</form>`;

function renderFolders() {
  const T = folderTree();
  const cards = liveCards();
  const due = cards.filter(c => isDueNow(c, T)).length;
  setBar('Vocabulary', `${plural(cards.length, 'word')} · ${due ? `${due} due` : 'all caught up'}`,
    `${Store ? `<button type="button" class="btn ghost" data-act="new-folder">${ICON.folder}<span class="lbl">New folder</span></button>` : ''}
     <button type="button" class="btn ghost" data-act="export" ${cards.length ? '' : 'disabled'}>${ICON.download}<span class="lbl">Export CSV</span></button>
     <a class="btn primary" href="#/review">${ICON.review}<span class="lbl">Review${due ? ` (${due})` : ''}</span></a>`);
  const q = vocabUi.filter.trim();
  const inInbox = cards.some(c => T.of(c) === INBOX);
  // Inbox always exists behind the scenes: show it once it holds something, or when it's the only folder.
  const rows = T.rows.filter(({ f }) => f.id !== INBOX || inInbox || T.rows.length === 1);
  const hits = q ? cards.filter(c => matchCard(c, q)) : [];
  view.innerHTML = `<div class="wrap">
    ${cards.length ? `<div class="toolbar">
      <input type="search" class="field grow" id="v-filter" placeholder="Search every saved word or meaning" value="${esc(vocabUi.filter)}" dir="auto">
    </div>` : ''}
    ${vocabUi.newFolder ? newFolderFormHtml() : ''}
    ${q ? (hits.length ? `<p class="kicker">${hits.length} ${hits.length === 1 ? 'match' : 'matches'} across your folders</p>${cardListHtml(hits, T, { showFolder: true })}` : `<div class="empty">No saved words match “${esc(q)}”.</div>`)
      : cards.length || rows.length > 1 ? `<div class="folder-grid">${rows.map(({ f, depth }) => folderCardHtml(f, T, cards, depth)).join('')}</div>
        <p class="mastery-key"><span><i class="m-known"></i>scheduled</span><span><i class="m-due"></i>due again</span><span><i class="m-new"></i>new</span></p>`
      : `<div class="empty">No saved words yet. Click a word in a text and press <kbd>S</kbd>, or sign in to Sync in the bottom-left to pull your phone vocabulary.</div>`}
  </div>`;
}

function renderFolder(id) {
  const T = folderTree();
  const f = T.byId.get(id);
  if (!f) return go('#/vocab');
  const all = liveCards();
  const deep = cardsInFolder(id, T, all);
  const direct = deep.filter(c => T.of(c) === id);
  const paused = T.paused(id);
  const due = paused ? 0 : deep.filter(c => isDueNow(c, T)).length;
  const subs = T.rows.filter(r => T.parent(r.f) === id);
  const q = vocabUi.filter.trim();
  const shown = direct.filter(c => matchCard(c, q));
  const enc = encodeURIComponent(id);
  const others = T.rows.filter(r => r.f.id !== id);
  const n = vocabUi.picked.size;
  setBar(esc(f.name), `${plural(deep.length, 'card')} · ${paused ? 'reviews paused' : due ? `${due} due` : 'all caught up'}`,
    `${deep.length ? `<button type="button" class="btn ghost" data-act="export-folder" data-id="${esc(id)}">${ICON.download}<span class="lbl">Export</span></button>
      <a class="btn" href="#/browse/${enc}">${ICON.vocab}<span class="lbl">Browse</span></a>` : ''}
     ${deep.length && !paused ? `<a class="btn primary" href="#/review/${enc}">${ICON.review}<span class="lbl">Review${due ? ` (${due})` : ''}</span></a>` : ''}`, isAr(f.name));
  view.innerHTML = `<div class="wrap">
    <a class="back-link" href="#/vocab">${ICON.back}<span>All folders</span></a>
    ${T.path(id).length > 1 ? `<p class="fc-crumb" dir="auto">in ${esc(T.path(id).slice(0, -1).map(x => x.name).join(' / '))}</p>` : ''}
    ${paused ? `<p class="note-bar">Reviews for this folder are paused (set on alqamus.pages.dev). You can still browse it.</p>` : ''}
    ${subs.length ? `<p class="kicker">Sub-folders</p><div class="folder-grid sub">${subs.map(r => folderCardHtml(r.f, T, all)).join('')}</div>` : ''}
    ${direct.length ? `${subs.length ? '<p class="kicker">Cards</p>' : ''}<div class="toolbar">
        <input type="search" class="field grow" id="v-filter" placeholder="Filter this folder" value="${esc(vocabUi.filter)}" dir="auto">
        ${Store ? `<button type="button" class="btn${vocabUi.select ? ' primary' : ''}" data-act="select-cards">${vocabUi.select ? 'Done' : 'Select'}</button>` : ''}
      </div>
      ${shown.length ? cardListHtml(shown, T, { select: vocabUi.select }) : `<div class="empty">No cards match “${esc(q)}”.</div>`}`
      : `<div class="empty">${subs.length ? 'The cards in this folder are in its sub-folders.' : 'No cards in this folder yet.'}</div>`}
    ${vocabUi.select ? `<div class="select-dock" role="toolbar" aria-label="Selected cards">
      <span class="sd-count">${n ? plural(n, 'card') + ' selected' : 'Click cards to select them'}</span>
      ${shown.length ? `<button type="button" class="btn sm ghost" data-act="select-all">${shown.every(c => vocabUi.picked.has(c.id)) ? 'Select none' : 'Select all'}</button>` : ''}
      ${others.length ? `<select class="field sm" id="v-move" ${n ? '' : 'disabled'} aria-label="Move selected cards"><option value="">Move to…</option>${others.map(r => `<option value="${esc(r.f.id)}">${esc(pathName(r.f.id, T))}</option>`).join('')}</select>` : ''}
      <button type="button" class="btn sm danger" data-act="bulk-del" ${n ? '' : 'disabled'}>${ICON.trash}<span>Delete</span></button>
    </div>` : ''}
  </div>`;
  const mv = $('#v-move');
  if (mv) mv.onchange = () => {
    const to = mv.value;
    if (!to) return;
    const ids = [...vocabUi.picked];
    vocabUi.picked.clear();
    vocabUi.select = false;
    moveCards(ids, to);
    toast(`Moved ${plural(ids.length, 'card')} to ${folderName(to)}`, { label: 'Open', run: () => go('#/vocab/' + encodeURIComponent(to)) });
    renderVocab();
  };
}

// ---------- Review (synced with live QamusStore; #/review/<folder> reviews just that folder) ----------
let session = null;
function cardFaceHtml(card, flipped, hint) {
  return `<div class="card" data-act="flip" role="button" tabindex="0" aria-label="Flip card">
      <div class="c-word" lang="ar">${esc(card.w || card.head)}</div>
      ${card.ctx ? `<div class="c-ctx" lang="ar">${markWord(card.ctx, card.w)}</div>` : ''}
      ${flipped ? `<div class="c-back">
        ${norm(card.head) !== norm(card.w) ? `<div class="ar" style="font-size:24px">${esc(card.head)}</div>` : ''}
        <div class="c-gloss">${esc(card.gloss)}</div>
        <div class="c-root">${[card.root ? `root <span class="ar" style="font-size:17px">${esc(card.root)}</span>` : '', card.tr ? `<em>${esc(card.tr)}</em>` : ''].filter(Boolean).join(' · ')}</div>
      </div>` : `<div class="c-hint">${hint}</div>`}
    </div>`;
}
function renderReview() {
  const allCards = liveCards();
  const T = folderTree();
  const scope = route().arg || '';
  const folder = scope ? T.byId.get(scope) : null;
  if (scope && !folder) return go('#/review');
  const pool = scope ? cardsInFolder(scope, T, allCards) : allCards;
  if (!session || session.done || session.scope !== scope) {
    const due = pool.filter(c => isDueNow(c, T)).sort((a, b) => a.due - b.due);
    session = { scope, queue: due.map(c => c.id), total: due.length, flipped: false, done: false, reviewed: 0 };
  }
  const title = folder ? `Review · <bdi>${esc(folder.name)}</bdi>` : 'Review';
  const back = folder ? `<a class="btn ghost" href="#/vocab/${encodeURIComponent(scope)}">${ICON.back}<span class="lbl">Folder</span></a>` : '';
  setBar(title, session.total ? `${Math.min(session.reviewed + 1, session.total)} of ${session.total}` : '', back);
  const card = allCards.find(c => c.id === session.queue[0]);
  if (!card) {
    session.done = true;
    const next = pool.filter(c => cardState(c, T).k === 'later').sort((a, b) => a.due - b.due)[0];
    const msg = session.reviewed ? `Reviewed ${plural(session.reviewed, 'card')}.`
      : folder && T.paused(scope) ? 'Reviews for this folder are paused.'
      : pool.length ? 'Nothing due right now.' : folder ? 'This folder has no cards yet.' : 'Save words from a text to start reviewing.';
    view.innerHTML = `<div class="review"><div class="done-card">
      <div class="num">${session.reviewed ? '✓' : '—'}</div>
      <p>${msg}</p>
      ${next ? `<p class="muted">Next card ${dueLabel(next)}.</p>` : ''}
      <div class="done-actions">${folder ? `<a class="btn" href="#/vocab/${encodeURIComponent(scope)}">Back to <bdi>${esc(folder.name)}</bdi></a>${pool.length ? `<a class="btn ghost" href="#/browse/${encodeURIComponent(scope)}">Browse the folder</a>` : ''}` : `<a class="btn" href="#/desk">Back to desk</a>`}</div>
    </div></div>`;
    return;
  }
  const pct = session.total ? (session.reviewed / session.total) * 100 : 0;
  view.innerHTML = `<div class="review">
    <div class="progress"><i style="width:${pct}%"></i></div>
    ${cardFaceHtml(card, session.flipped, 'Press Space to show the meaning')}
    ${session.flipped ? `<div class="grades">
      <button type="button" class="btn grade again" data-grade="1">Again <small>1 · ${preview(card, 1)}</small></button>
      <button type="button" class="btn grade" data-grade="2">Hard <small>2 · ${preview(card, 2)}</small></button>
      <button type="button" class="btn grade good" data-grade="3">Good <small>3 · ${preview(card, 3)}</small></button>
      <button type="button" class="btn grade" data-grade="4">Easy <small>4 · ${preview(card, 4)}</small></button>
    </div>` : ''}
  </div>`;
}

// ---------- Browse: flip through a folder without grading ----------
let browse = null;
function renderBrowse() {
  const all = liveCards();
  const T = folderTree();
  const scope = route().arg || '';
  const folder = scope ? T.byId.get(scope) : null;
  if (scope && !folder) return go('#/vocab');
  const pool = scope ? cardsInFolder(scope, T, all) : all;
  if (!browse || browse.scope !== scope) browse = { scope, i: 0, flipped: false };
  browse.i = Math.max(0, Math.min(browse.i, pool.length - 1));
  const backHref = folder ? `#/vocab/${encodeURIComponent(scope)}` : '#/vocab';
  setBar(folder ? `Browse · <bdi>${esc(folder.name)}</bdi>` : 'Browse', pool.length ? `${browse.i + 1} of ${pool.length}` : '',
    `<a class="btn ghost" href="${backHref}">${ICON.back}<span class="lbl">${folder ? 'Folder' : 'Vocabulary'}</span></a>`);
  if (!pool.length) {
    view.innerHTML = `<div class="review"><div class="done-card"><div class="num">—</div><p>No cards here yet.</p><a class="btn" href="${backHref}">Back</a></div></div>`;
    return;
  }
  const card = pool[browse.i];
  view.innerHTML = `<div class="review">
    <div class="progress"><i style="width:${((browse.i + 1) / pool.length) * 100}%"></i></div>
    ${cardFaceHtml(card, browse.flipped, 'Press Space to show the meaning · <kbd>←</kbd> <kbd>→</kbd> to move')}
    <div class="browse-nav">
      <button type="button" class="btn" data-act="browse-prev" ${browse.i ? '' : 'disabled'}>${ICON.back}<span>Previous</span></button>
      <span class="muted">${browse.i + 1} / ${pool.length}</span>
      <button type="button" class="btn" data-act="browse-next" ${browse.i < pool.length - 1 ? '' : 'disabled'}><span>Next</span>${ICON.next}</button>
    </div>
  </div>`;
}
function stepBrowse(d) {
  if (!browse) return;
  browse.i += d;
  browse.flipped = false;
  renderBrowse();
}

// ---------- Texts library ----------
const textsUi = { q: '', kind: 'all', sort: 'added', renaming: '' };
const KIND_TABS = { all: 'All', scan: 'Scans', paste: 'Pasted', sample: 'Samples' };
function dateGroup(t) {
  const d0 = new Date();
  d0.setHours(0, 0, 0, 0);
  const s = d0.getTime();
  if (t >= s) return 'Today';
  if (t >= s - DAY) return 'Yesterday';
  if (t >= s - 6 * DAY) return 'Earlier this week';
  return new Date(t).toLocaleDateString(undefined, { month: 'long', year: 'numeric' });
}
function textSnippet(body, q) {
  const flat = body.replace(/\s+/g, ' ').trim();
  const i = q ? flat.indexOf(q) : -1;
  if (i < 0) return esc(flat.slice(0, 220)) + (flat.length > 220 ? '…' : '');
  const s = Math.max(0, flat.lastIndexOf(' ', Math.max(0, i - 70)));
  return (s ? '…' : '') + esc(flat.slice(s, i)) + `<mark>${esc(flat.slice(i, i + q.length))}</mark>` + esc(flat.slice(i + q.length, i + q.length + 160)) + '…';
}
function textRowHtml(t, q) {
  const words = (t.body.match(WORD_RE) || []).length;
  const kind = textKind(t);
  const ar = isAr(t.title);
  const note = t.note && t.note !== 'Scanned page' ? t.note : '';
  return `<div class="tx-row" data-go="#/text/${t.id}" role="link" tabindex="0">
    <div class="tx-head">
      ${textsUi.renaming === t.id
        ? `<input type="text" class="field tx-rename" id="tx-rename" value="${esc(t.title)}" dir="auto" maxlength="120" aria-label="Rename text">`
        : `<span class="tx-title"${ar ? ' lang="ar"' : ''} dir="auto">${esc(t.title)}</span>`}
      <span class="tx-kind k-${kind}">${KIND_LABEL[kind]}</span>
      <span class="tx-actions">
        <button type="button" class="icon-btn" data-act="rename-text" data-id="${t.id}" title="Rename" aria-label="Rename ${esc(t.title)}">${ICON.edit}</button>
        <button type="button" class="icon-btn" data-act="del-text" data-id="${t.id}" title="Delete" aria-label="Delete ${esc(t.title)}">${ICON.trash}</button>
      </span>
    </div>
    <div class="tx-snippet" lang="ar" dir="rtl">${textSnippet(t.body, q)}</div>
    <div class="tx-meta">${esc(note || fmtStamp(t.created))} · ${plural(words, 'word')} · ${(t.looked || []).length} looked up${t.opened - t.created > 6e4 ? ` · opened ${ago(t.opened)}` : ''}</div>
  </div>`;
}
function renderTexts() {
  const all = db.texts;
  const kinds = { all: all.length, scan: 0, paste: 0, sample: 0 };
  for (const t of all) kinds[textKind(t)]++;
  if (!kinds[textsUi.kind]) textsUi.kind = 'all';
  const q = textsUi.q.trim(), nq = norm(q), lq = q.toLowerCase();
  const key = textsUi.sort === 'opened' ? 'opened' : 'created';
  const list = all
    .filter(t => (textsUi.kind === 'all' || textKind(t) === textsUi.kind)
      && (!q || t.title.toLowerCase().includes(lq) || !!(nq && (norm(t.title).includes(nq) || norm(t.body).includes(nq)))))
    .sort((a, b) => b[key] - a[key]);
  const was = document.activeElement?.id;
  setBar('Texts', plural(all.length, 'text'), `<button type="button" class="btn" data-act="new-text">${ICON.plus}<span class="lbl">New text</span></button>`);
  const groups = [];
  for (const t of list) {
    const g = dateGroup(t[key]);
    if (groups.at(-1)?.g !== g) groups.push({ g, items: [] });
    groups.at(-1).items.push(t);
  }
  view.innerHTML = `<div class="wrap">
    ${all.length ? `<div class="toolbar">
      <input type="search" class="field grow" id="t-filter" placeholder="Search titles and text" value="${esc(textsUi.q)}" dir="auto">
      <div class="segmented" role="group" aria-label="Show">${Object.keys(KIND_TABS).filter(k => k === 'all' || kinds[k]).map(k =>
        `<button type="button" data-tkind="${k}" aria-pressed="${textsUi.kind === k}">${KIND_TABS[k]} <span class="n">${kinds[k]}</span></button>`).join('')}</div>
      <select class="field" id="t-sort" aria-label="Sort">
        <option value="added" ${key === 'created' ? 'selected' : ''}>Date added</option>
        <option value="opened" ${key === 'opened' ? 'selected' : ''}>Last opened</option>
      </select>
    </div>` : ''}
    ${groups.length ? groups.map(({ g, items }) => `<p class="kicker tx-group">${esc(g)}</p><div class="tx-list">${items.map(t => textRowHtml(t, q)).join('')}</div>`).join('')
      : `<div class="empty">${all.length ? 'No texts match.' : 'No texts yet. Paste a passage, or press <kbd>⌘⇧V</kbd> in the Mac app to scan a screenshot.'}</div>`}
  </div>`;
  const fi = $('#t-filter');
  if (fi) {
    fi.oninput = () => { textsUi.q = fi.value; renderTexts(); };
    if (was === 't-filter') { fi.focus(); fi.setSelectionRange(fi.value.length, fi.value.length); }
  }
  const so = $('#t-sort');
  if (so) so.onchange = () => { textsUi.sort = so.value; renderTexts(); };
  $$('[data-tkind]', view).forEach(b => { b.onclick = () => { textsUi.kind = b.dataset.tkind; renderTexts(); }; });
  const rn = $('#tx-rename');
  if (rn) {
    rn.focus();
    rn.select();
    const done = save => {
      if (!textsUi.renaming) return;
      const tx = db.texts.find(x => x.id === textsUi.renaming);
      textsUi.renaming = '';
      const v = rn.value.trim().slice(0, 120);
      if (save && tx && v && v !== tx.title) { tx.title = v; persist(); toast('Renamed'); }
      renderTexts();
      renderTextList();
    };
    rn.onkeydown = e => {
      if (e.key === 'Enter') { e.preventDefault(); done(true); }
      else if (e.key === 'Escape') { e.preventDefault(); done(false); }
    };
    rn.onblur = () => done(true);
  }
}
function deleteText(tx, after, undo) {
  const idx = db.texts.indexOf(tx);
  if (idx < 0) return;
  db.texts.splice(idx, 1);
  persist();
  if (curText === tx) curText = null;
  after();
  toast(`Deleted “${tx.title}”`, { label: 'Undo', run: () => { db.texts.splice(Math.min(idx, db.texts.length), 0, tx); persist(); undo(); } });
}
function grade(g) {
  const card = liveCards().find(c => c.id === session?.queue[0]);
  if (!card || !session.flipped) return;
  const next = { ...card };
  schedule(next, g);
  const now = Date.now();
  if (Store) {
    Store.mutate(d => {
      d.reviews[card.id] = {
        due: next.due,
        interval: next.ivl,
        ease: next.ease,
        reps: next.reps,
        lapses: next.lapses,
        last: now,
        updatedAt: now,
      };
    });
  }
  session.queue.shift();
  if (g === 1) session.queue.push(card.id);
  else session.reviewed++;
  session.flipped = false;
  refreshKnown(); renderReview();
}

// ---------- History (synced with live QamusStore) ----------
function renderHistory() {
  const hist = liveHistory();
  setBar('History', plural(hist.length, 'lookup'), hist.length ? `<button type="button" class="btn ghost" data-act="clear-history">Clear</button>` : '');
  view.innerHTML = `<div class="wrap">${hist.length ? `<ul class="h-list">${hist.map(h => `<li data-q="${esc(h.q)}" data-full="1">
    <span class="ar">${esc(h.q)}</span><span class="g">${esc(h.g)}</span><span class="t">${ago(h.t)}</span></li>`).join('')}</ul>` : '<p class="empty">Words you look up appear here.</p>'}</div>`;
}

// ---------- Palette ----------
const COMMANDS = [
  { id: 'new-text', label: 'New text', hint: 'Paste a passage to read', icon: ICON.plus },
  { id: 'go-review', label: 'Review due cards', hint: 'Spaced repetition', icon: ICON.review },
  { id: 'go-vocab', label: 'Vocabulary', hint: 'Your saved words', icon: ICON.vocab },
  { id: 'go-texts', label: 'All texts', hint: 'Your scans and pasted passages', icon: ICON.text },
  { id: 'toggle-theme', label: 'Toggle dark mode', hint: 'Light / dark', icon: ICON.moon },
];
let palItems = [], palSel = 0;
function openPalette(prefill = '') {
  $('#palette').hidden = false;
  const inp = $('#palette-q');
  inp.value = prefill;
  inp.focus();
  updatePalette();
}
function closePalette() { $('#palette').hidden = true; }
function updatePalette() {
  const q = $('#palette-q').value.trim();
  const items = [];
  if (!q) {
    liveHistory().slice(0, 5).forEach(h => items.push({ type: 'word', q: h.q, ar: h.q, g: h.g, k: 'recent' }));
    COMMANDS.forEach(c => items.push({ type: 'cmd', ...c }));
  } else {
    const rows = atLeast('index') ? suggestions(q) : [];
    const K = { p: 'particle', h: 'Hans Wehr', f: 'verb form', b: 'lexicon', w: 'Wiktionary', l: 'Lane' };
    rows.forEach(r => items.push({ type: 'word', q: r[1], ar: r[1], g: glossFor(r, () => { if (!$('#palette').hidden) updatePalette(); }), k: K[r[2]] || '' }));
    if (!isAr(q)) items.push({ type: 'word', q, ar: '', g: `Search English definitions for “${q}”`, k: 'English', icon: ICON.search });
    else if (!items.length) items.push({ type: 'word', q, ar: q, g: 'Look up', k: '' });
    if (/\s/.test(q) && isAr(q)) items.push({ type: 'cmd', id: 'paste-as-text', label: 'Open as a text', hint: 'Read this passage word by word', icon: ICON.text, payload: q });
    const ql = q.toLowerCase();
    COMMANDS.filter(c => c.label.toLowerCase().includes(ql)).forEach(c => items.push({ type: 'cmd', ...c }));
  }
  palItems = items;
  palSel = 0;
  $('#palette-list').innerHTML = items.map((it, i) => it.type === 'cmd'
    ? `<li role="option" data-pi="${i}" aria-selected="${i === palSel}"><span class="p-icon">${it.icon}</span><span class="p-main"><span>${esc(it.label)}</span><span class="p-g">${esc(it.hint)}</span></span><span class="p-k">command</span></li>`
    : `<li role="option" data-pi="${i}" aria-selected="${i === palSel}">${it.ar ? `<span class="p-ar">${esc(it.ar)}</span>` : `<span class="p-icon">${it.icon || ICON.search}</span>`}<span class="p-main"><span class="p-g">${esc(it.g || '')}</span></span><span class="p-k">${esc(it.k || '')}</span></li>`).join('')
    || `<li class="p-head">${atLeast('index') ? 'No matches' : 'Loading the index…'}</li>`;
}
function movePal(d) {
  if (!palItems.length) return;
  palSel = (palSel + d + palItems.length) % palItems.length;
  $$('#palette-list li[data-pi]').forEach(li => li.setAttribute('aria-selected', String(+li.dataset.pi === palSel)));
  $(`#palette-list li[data-pi="${palSel}"]`)?.scrollIntoView({ block: 'nearest' });
}
function runPal(i) {
  const it = palItems[i];
  if (!it) return;
  closePalette();
  if (it.type === 'cmd') return command(it.id, it.payload);
  openWord(it.q);
}
function command(id, payload) {
  if (id === 'new-text') go('#/new');
  if (id === 'go-review') { session = null; go('#/review'); }
  if (id === 'go-vocab') go('#/vocab');
  if (id === 'go-texts') go('#/texts');
  if (id === 'toggle-theme') {
    const dark = document.documentElement.dataset.theme === 'dark' || (!document.documentElement.dataset.theme && matchMedia('(prefers-color-scheme: dark)').matches);
    db.settings.theme = dark ? 'light' : 'dark';
    applySettings(); persist();
  }
  if (id === 'paste-as-text') { const t = addText(payload); if (t) go('#/text/' + t.id); }
}
// In the reader, lookups go to the inspector; elsewhere they open the full entry.
function openWord(q, full = false) {
  if (!full && route().name === 'text') { openInspector(); lookup(q); }
  else go('#/entry/' + encodeURIComponent(q));
}

// ---------- Panels (narrow layouts) ----------
const narrowInsp = () => matchMedia('(max-width: 1100px)').matches;
function openInspector() { if (narrowInsp()) { desk.classList.add('insp-open'); syncScrim(); } }
function closeInspector() { desk.classList.remove('insp-open'); syncScrim(); }
function syncScrim() { $('#scrim').hidden = !(desk.classList.contains('insp-open') || desk.classList.contains('side-open')); }

// ---------- Events ----------
document.addEventListener('click', e => {
  const t = e.target;
  if (!$('#settings').hidden && !t.closest('#settings, #open-settings, #sync-status')) $('#settings').hidden = true;

  const w = t.closest('.passage .w');
  if (w) return selectToken(+w.dataset.i);

  const cl = t.closest('.answer.clamp .def');
  if (cl && !t.closest('[data-q]')) { cl.parentElement.classList.toggle('open'); return; }

  const sv = t.closest('[data-save]');
  if (sv) return saveAnswer(saveables.get(sv.dataset.save));

  const cp = t.closest('[data-copy]');
  if (cp) { navigator.clipboard?.writeText(cp.dataset.copy).then(() => toast('Copied')); return; }

  const pi = t.closest('#palette-list li[data-pi]');
  if (pi) return runPal(+pi.dataset.pi);
  if (t.id === 'palette') return closePalette();

  const gr = t.closest('[data-grade]');
  if (gr) return grade(+gr.dataset.grade);

  // Selecting cards in a folder: the whole row toggles.
  const pk = t.closest('[data-pick]');
  if (pk) {
    const id = pk.dataset.pick;
    if (vocabUi.picked.has(id)) vocabUi.picked.delete(id); else vocabUi.picked.add(id);
    renderVocab();
    return;
  }

  const q = t.closest('[data-q]');
  if (q) {
    e.preventDefault();
    const inInsp = !!q.closest('#inspector');
    if (inInsp) { lookup(q.dataset.q, {}, { fromLink: true }); return; }
    if (q.closest('.entry-view')) { go('#/entry/' + encodeURIComponent(q.dataset.q)); return; }
    return openWord(q.dataset.q, !!q.dataset.full);
  }

  const a = t.closest('[data-act]');
  // Folder cards and text rows open on a click anywhere that isn't one of their own controls.
  const dg = !a && t.closest('[data-go]');
  if (dg && !t.closest('a, button, input, select, textarea')) { go(dg.dataset.go); return; }
  if (!a) return;
  const act = a.dataset.act;
  if (act === 'palette') openPalette();
  else if (act === 'new-text') go('#/new');
  else if (act === 'cancel-compose') history.length > 1 ? history.back() : go('#/desk');
  else if (act === 'create-text') {
    const t2 = addText($('#c-body').value, { title: $('#c-title').value });
    if (t2) go('#/text/' + t2.id); else $('#c-body').focus();
  } else if (act === 'edit-text' && curText) renderComposer(curText);
  else if (act === 'save-edit') {
    const tx = db.texts.find(x => x.id === a.dataset.id);
    if (tx) { tx.body = $('#c-body').value.trim() || tx.body; tx.title = $('#c-title').value.trim() || tx.title; persist(); renderReader(tx.id); renderTextList(); }
  } else if (act === 'delete-text' && curText) {
    const tx = curText;
    deleteText(tx, () => go('#/texts'), () => go('#/text/' + tx.id));
  } else if (act === 'del-text') {
    const tx = db.texts.find(x => x.id === a.dataset.id);
    const redraw = () => { renderTexts(); renderTextList(); };
    if (tx) deleteText(tx, redraw, redraw);
  } else if (act === 'rename-text') {
    textsUi.renaming = a.dataset.id;
    renderTexts();
  } else if (act === 'new-folder') {
    vocabUi.newFolder = true;
    renderVocab();
    $('#nf-name')?.focus();
  } else if (act === 'cancel-folder') {
    vocabUi.newFolder = false;
    renderVocab();
  } else if (act === 'select-cards') {
    vocabUi.select = !vocabUi.select;
    vocabUi.picked.clear();
    renderVocab();
  } else if (act === 'select-all') {
    const T = folderTree();
    const shown = liveCards().filter(c => T.of(c) === vocabUi.at && matchCard(c, vocabUi.filter.trim()));
    const allOn = shown.every(c => vocabUi.picked.has(c.id));
    shown.forEach(c => (allOn ? vocabUi.picked.delete(c.id) : vocabUi.picked.add(c.id)));
    renderVocab();
  } else if (act === 'bulk-del') {
    const ids = [...vocabUi.picked];
    vocabUi.picked.clear();
    vocabUi.select = false;
    deleteCards(ids);
    renderVocab();
  } else if (act === 'export-folder') {
    const T = folderTree();
    const f = T.byId.get(a.dataset.id);
    if (f) exportCsv(cardsInFolder(f.id, T), 'qamus-' + f.name);
  } else if (act === 'browse-prev') stepBrowse(-1);
  else if (act === 'browse-next') stepBrowse(1);
  else if (act === 'open-entry' && cur) go('#/entry/' + encodeURIComponent(cur.q));
  else if (act === 'insp-back') { const p = inspStack.pop(); if (p) lookup(p.q, p.ctx, { keepStack: true }); }
  else if (act === 'back') history.length > 1 ? history.back() : go('#/desk');
  else if (act === 'passage-to-text' && cur) { const t2 = addText(cur.q); if (t2) go('#/text/' + t2.id); }
  else if (act === 'flip') {
    if (route().name === 'browse') { if (browse) { browse.flipped = !browse.flipped; renderBrowse(); } }
    else if (session) { session.flipped = !session.flipped; renderReview(); }
  }
  else if (act === 'del-card') {
    deleteCardById(a.dataset.id);
  } else if (act === 'export') exportCsv();
  else if (act === 'clear-history') {
    if (Store) {
      Store.mutate(d => {
        const now = Math.max(Date.now(), ...d.history.map(h => h.t + 1));
        d.history = [];
        d.settings = { ...d.settings, historyClearedAt: now, updatedAt: now };
      });
      renderHistory();
      toast('History cleared');
    }
  } else if (act === 'save-primary') {
    const target = primarySaveTarget();
    if (target) saveAnswer(target);
  } else if (act === 'toggle-tray') {
    trayCollapsed = !trayCollapsed;
    renderGrammarTray();
  } else if (act === 'analyze' && cur?.ctx?.sentence) {
    trayCollapsed = false;
    cur.analysis = 'pending'; renderGrammarTray(); renderInspector();
    post({
      type: 'analyze',
      word: cur.ctx.word,
      sentence: cur.ctx.sentence,
      surrounding: cur.ctx.surrounding || cur.ctx.sentence,
      force: true,
      lookup: window.qamus.current(),
    });
  } else if (act === 'sync-now' && Sync) {
    Sync.syncNow().then(() => toast('Synced with cloud'));
  } else if (act === 'sync-signout' && Sync) {
    Sync.signOut({ keepData: true }).then(() => { renderSyncUI(); toast('Signed out (local words kept)'); });
  }
});

$('#sync-status').onclick = () => {
  const pop = $('#settings');
  pop.hidden = false;
  renderSyncUI();
  $('#sync-user-input')?.focus();
};

function renderSyncUI() {
  const st = Sync ? Sync.state : { enabled: false, user: null, status: 'local', error: '' };
  const pill = $('#sync-status');
  if (pill) {
    pill.className = 'sync-pill ' + (st.user ? st.status : 'local');
    const lbl = pill.querySelector('.sync-lbl');
    if (st.user) {
      if (st.status === 'syncing') lbl.textContent = `Syncing @${st.user}…`;
      else if (st.status === 'synced') lbl.textContent = `Synced · @${st.user}`;
      else if (st.status === 'offline') lbl.textContent = `Offline · @${st.user}`;
      else if (st.status === 'error') lbl.textContent = `Sync error · @${st.user}`;
      else lbl.textContent = `@${st.user}`;
    } else {
      lbl.textContent = 'Sign in to sync phone';
    }
  }
  const box = $('#sync-settings-box');
  if (!box) return;
  if (!Sync) {
    box.innerHTML = `<span class="pop-label">Cloud Sync</span><div class="sync-meta">Sync script unavailable.</div>`;
    return;
  }
  if (st.user) {
    const folders = liveFolders();
    const saveF = targetSaveFolder();
    const when = st.lastSync ? `Last synced ${ago(st.lastSync)}` : 'Connected to alqamus.pages.dev';
    box.innerHTML = `<span class="pop-label">Cloud Sync (@${esc(st.user)})</span>
      <div class="sync-meta">${esc(st.error || when)} · ${plural(liveCards().length, 'saved word')}</div>
      ${folders.length > 1 ? `<div style="margin-top:6px"><label class="pop-label" style="display:block;margin-bottom:3px">Save new words to</label>
        <select id="sync-save-folder" class="field" style="width:100%;height:28px;font-size:12px">
          ${folders.map(f => `<option value="${esc(f.id)}" ${f.id === saveF ? 'selected' : ''}>${esc(f.name)}</option>`).join('')}
        </select></div>` : ''}
      <div class="sync-actions">
        <button type="button" class="btn sm" data-act="sync-now">Sync now</button>
        <button type="button" class="btn sm ghost" data-act="sync-signout">Sign out</button>
      </div>`;
    const sf = $('#sync-save-folder');
    if (sf) sf.onchange = e => { lsSet('qamus.lastFolder', e.target.value); toast(`Saving new words to ${folderName(e.target.value)}`); };
  } else {
    box.innerHTML = `<span class="pop-label">Sync with Phone</span>
      <form class="sync-form" id="sync-form">
        <input type="text" id="sync-user-input" placeholder="Your Qamus username" autocomplete="off" spellcheck="false">
        <button type="submit" class="btn sm primary">Connect</button>
      </form>
      <div class="sync-meta">Enter the same username you use on alqamus.pages.dev to share saved words &amp; reviews.</div>`;
    const form = $('#sync-form');
    if (form) form.onsubmit = async e => {
      e.preventDefault();
      const raw = $('#sync-user-input')?.value || '';
      const normU = QM?.normUsername(raw);
      if (!normU) { toast('Username must be 3–32 letters, numbers, _ or -'); return; }
      try {
        await Sync.signIn(normU);
        renderSyncUI();
        toast(`Synced with @${normU}`);
      } catch (err) {
        toast('Sync failed: ' + (err?.message || err));
      }
    };
  }
}

$('#open-palette').onclick = () => openPalette();
// The logo is the home button. go() re-renders even when you're already on the Desk, which also closes the phone drawer.
$('#home-link').onclick = e => { e.preventDefault(); closePalette(); go('#/desk'); };
$('#new-text').onclick = () => go('#/new');
$('#toggle-side').onclick = () => { desk.classList.toggle('side-open'); syncScrim(); };
$('#scrim').onclick = () => { desk.classList.remove('side-open'); closeInspector(); };
$('#open-settings').onclick = () => { const pop = $('#settings'); pop.hidden = !pop.hidden; if (!pop.hidden) renderSyncUI(); };
$$('#settings .seg button').forEach(b => b.onclick = () => {
  db.settings[b.closest('.seg').dataset.setting] = b.dataset.v;
  applySettings(); persist();
});
$('#palette-q').addEventListener('input', updatePalette);
$('#palette-q').addEventListener('keydown', e => {
  if (e.key === 'ArrowDown') { e.preventDefault(); movePal(1); }
  else if (e.key === 'ArrowUp') { e.preventDefault(); movePal(-1); }
  else if (e.key === 'Enter') { e.preventDefault(); runPal(palSel); }
  else if (e.key === 'Escape') { e.preventDefault(); closePalette(); }
});

document.addEventListener('keydown', e => {
  const typing = e.target.closest?.('input, textarea, select, [contenteditable]');
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); openPalette(); return; }
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'n' && !e.shiftKey) { e.preventDefault(); go('#/new'); return; }
  if ((e.metaKey || e.ctrlKey) && e.key === 'Enter' && route().name === 'new') { e.preventDefault(); $('[data-act="create-text"], [data-act="save-edit"]')?.click(); return; }
  if (typing || !$('#palette').hidden) return;
  if (e.key === 'Enter' && e.target.matches?.('[data-go]')) { e.preventDefault(); go(e.target.dataset.go); return; }
  if (e.key === 'Escape') {
    if (!$('#settings').hidden) { $('#settings').hidden = true; return; }
    if (desk.classList.contains('insp-open') || desk.classList.contains('side-open')) { desk.classList.remove('side-open'); closeInspector(); return; }
    if (route().name === 'entry') { history.back(); return; }
  }
  if (e.key === '/') { e.preventDefault(); openPalette(); return; }
  const r = route().name;
  if (r === 'text' && tokens.length && !e.metaKey && !e.ctrlKey && !e.altKey) {
    // RTL: left moves forward through the text, right moves back
    if (e.key === 'ArrowLeft') { e.preventDefault(); selectToken(Math.min(tokens.length - 1, selIndex + 1), { scroll: true }); }
    else if (e.key === 'ArrowRight') { e.preventDefault(); selectToken(Math.max(0, selIndex < 0 ? 0 : selIndex - 1), { scroll: true }); }
    else if (e.key === 'Enter' && cur && !cur.loading) { e.preventDefault(); go('#/entry/' + encodeURIComponent(cur.q)); }
    else if (e.key.toLowerCase() === 's') { const target = primarySaveTarget(); if (target) { e.preventDefault(); saveAnswer(target); } }
  }
  if (r === 'review' && session && !session.done) {
    if (e.key === ' ') { e.preventDefault(); session.flipped = !session.flipped; renderReview(); }
    else if (/^[1-4]$/.test(e.key)) grade(+e.key);
  }
  if (r === 'browse' && browse && !e.metaKey && !e.ctrlKey && !e.altKey) {
    if (e.key === ' ') { e.preventDefault(); browse.flipped = !browse.flipped; renderBrowse(); }
    else if (e.key === 'ArrowRight') { e.preventDefault(); stepBrowse(1); }
    else if (e.key === 'ArrowLeft') { e.preventDefault(); stepBrowse(-1); }
    else if (e.key === 'Escape') { e.preventDefault(); go(browse.scope ? '#/vocab/' + encodeURIComponent(browse.scope) : '#/vocab'); }
  }
  if (e.key === 'Escape' && r === 'vocab' && vocabUi.select) { vocabUi.select = false; vocabUi.picked.clear(); renderVocab(); }
});

function exportCsv(cards = liveCards(), name = 'qamus-vocabulary') {
  const q = s => `"${String(s || '').replace(/"/g, '""')}"`;
  const rows = [['word', 'headword', 'meaning', 'root', 'transliteration', 'sentence'], ...cards.map(c => [c.w, c.head, c.gloss, c.root, c.tr, c.ctx])];
  const blob = new Blob(['﻿' + rows.map(r => r.map(q).join(',')).join('\n')], { type: 'text/csv' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = name.replace(/[\\/:*?"<>|]+/g, '-') + '.csv';
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

// ---------- Native bridge ----------
// The Mac shell can drop OCR text straight into the reader and render AI analysis here,
// instead of scraping the DOM and keeping a second SwiftUI inspector.
window.qamus = {
  openPassage(text, meta = {}) { const t = addText(text, meta); if (t) go('#/text/' + t.id); return t?.id || null; },
  lookup(q, sentence = '') { openInspector(); lookup(q, sentence ? { word: q, sentence } : {}); },
  current() {
    const m = cur?.model;
    if (!m) return null;
    const { sources, ...rest } = m;
    return {
      ...rest,
      context: cur.ctx || {},
      answers: m.answers.map(a => ({ ...a, html: undefined, text: plain(a.html) })),
      sources: sources ? { roots: sources.roots, wiktionary: sources.wikt.length, lane: sources.laneKeys, arabic: sources.arKeys } : {},
    };
  },
  // a: a ContextualWordAnalysis, 'pending', { error }, or null. `word` drops results for a word you've moved past.
  showAnalysis(a, word = '') {
    if (!cur) return;
    if (word && norm(word) !== norm(cur.ctx?.word || cur.q)) return;
    cur.analysis = a || null;
    renderGrammarTray();
    syncPrimarySaveBtn();
    if (route().name !== 'text') renderInspector();
  },
};

// ---------- Boot ----------
applySettings();
if (Store && Sync) {
  Store.on('change', () => {
    refreshKnown();
    rerenderSaves();
    const r = route().name;
    if (r === 'history') renderHistory();
    else if (r === 'review' && (!session || session.done)) renderReview();
    renderSyncUI();
  });
  Sync.on('status', () => renderSyncUI());
  Store.init().then(() => {
    migrateLegacyDeskCards();
    Sync.init({ url: SYNC_URL });
    refreshKnown();
    rerenderSaves();
    renderSyncUI();
  });
}
refreshKnown();
renderSyncUI();
window.addEventListener('hashchange', render);
render();
renderInspector();
initEngine().catch(err => {
  console.error(err);
  $('#engine-status').lastElementChild.textContent = 'Couldn’t load the dictionary data';
});
post({ type: 'ready', ui: 'desk' });
