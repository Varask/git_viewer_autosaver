/* git viewer — logique de la page (L6, L7). Vanilla JS, aucune ressource externe.
   Rafraîchissement : ADR-10. Présence et bascule de projet : ADR-09 (flux /api/presence). */
(function () {
  'use strict';

  const TOKEN = document.querySelector('meta[name="gt-token"]').content;
  const $ = id => document.getElementById(id);
  const store = {
    get(k, d) { try { const v = localStorage.getItem('gt-' + k); return v == null ? d : v; } catch (e) { return d; } },
    set(k, v) { try { localStorage.setItem('gt-' + k, v); } catch (e) { /* stockage indisponible */ } }
  };

  const S = {
    state: null, seq: null, fingerprint: null, graph: null,
    sel: null,            // 'wip' | sha
    openFile: null,       // { path, mode, sha }
    commitCache: new Map(),
    showAuto: store.get('autosave', '1') === '1',
    limit: parseInt(store.get('limit', '400'), 10) || 400,
    offset: 0, offline: false, stopped: false
  };

  // ------------------------------------------------------------ outils
  function h(tag, attrs, ...kids) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v == null || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k === 'text') el.textContent = v;
      else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
      else el.setAttribute(k, v === true ? '' : v);
    }
    for (const kid of kids.flat()) {
      if (kid == null || kid === false) continue;
      el.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
    }
    return el;
  }

  async function api(path, opts) {
    const o = opts || {};
    const headers = { 'X-GitTools-Token': TOKEN };
    if (o.body) headers['Content-Type'] = 'application/json';
    const res = await fetch(path, { method: o.method || 'GET', headers, body: o.body ? JSON.stringify(o.body) : undefined, cache: 'no-store' });
    let data = null;
    try { data = await res.json(); } catch (e) { /* corps vide */ }
    if (!res.ok) {
      const err = new Error((data && data.message) || `Erreur ${res.status}`);
      err.status = res.status; err.data = data;
      throw err;
    }
    return data;
  }

  function toast(msg, isErr) {
    if (!msg) return;
    const t = h('div', { class: 'toast' + (isErr ? ' err' : ''), role: isErr ? 'alert' : 'status', text: msg });
    $('toasts').append(t);
    setTimeout(() => t.remove(), isErr ? 7000 : 3500);
  }

  const plural = (n, one, many) => `${n} ${n > 1 ? many : one}`;
  const fmtAbs = ts => new Date(ts * 1000).toLocaleString('fr-FR', { dateStyle: 'medium', timeStyle: 'short' });
  function fmtRel(ts) {
    const s = Math.max(0, Date.now() / 1000 - ts);
    if (s < 60) return "à l'instant";
    if (s < 3600) return `il y a ${Math.floor(s / 60)} min`;
    if (s < 86400) return `il y a ${Math.floor(s / 3600)} h`;
    if (s < 172800) return 'hier';
    if (s < 30 * 86400) return `il y a ${Math.floor(s / 86400)} j`;
    return new Date(ts * 1000).toLocaleDateString('fr-FR');
  }

  // ------------------------------------------------------------ confirmation (RG-20)
  function confirmDlg(title, text, opt) {
    const o = opt || {};
    const dlg = $('dlg-confirm');
    $('confirm-title').textContent = title;
    $('confirm-text').textContent = text;
    $('confirm-ok').textContent = o.ok || 'Confirmer';
    dlg.classList.toggle('danger', !!o.danger);
    return new Promise(resolve => {
      const done = () => { dlg.removeEventListener('close', done); resolve(dlg.returnValue === 'ok'); };
      dlg.returnValue = 'cancel';
      dlg.addEventListener('close', done);
      dlg.showModal();
      $('confirm-cancel').focus();
    });
  }

  // ------------------------------------------------------------ actions
  async function act(name, args, opt) {
    const o = opt || {};
    if (o.confirm && !(await confirmDlg(o.confirm[0], o.confirm[1], { danger: o.danger, ok: o.confirm[2] }))) return null;
    const btn = o.btn;
    if (btn) { btn.classList.add('busy'); btn.disabled = true; }
    try {
      const r = await api('/api/action', { method: 'POST', body: { name, args: args || {} } });
      if (!r.needsForce) toast(r.message, !r.ok);
      await poll();
      return r;
    } catch (e) {
      toast(e.message, true);
      return null;
    } finally {
      if (btn) { btn.classList.remove('busy'); btn.disabled = false; }
    }
  }

  // ------------------------------------------------------------ état et rafraîchissement (VI-08, ENF-04)
  let pollTimer = null, polling = null;
  function poll() {
    if (S.stopped) return Promise.resolve();
    if (polling) return polling;
    clearTimeout(pollTimer);
    polling = (async () => {
      try {
        const st = await api('/api/state');
        setOffline(false);
        await applyState(st);
      } catch (e) {
        if (!e.status) setOffline(true); else toast(e.message, true);
      } finally {
        polling = null;
        if (!S.stopped) pollTimer = setTimeout(poll, document.hidden ? 5000 : 1000);
      }
    })();
    return polling;
  }
  document.addEventListener('visibilitychange', () => { if (!document.hidden) poll(); });

  function presence() {
    if (!window.EventSource) return;
    const es = new EventSource('/api/presence?t=' + encodeURIComponent(TOKEN));
    es.addEventListener('project', ev => { if (S.seq !== null && Number(ev.data) !== S.seq) poll(); });
  }

  function setOffline(off) {
    if (off === S.offline) return;
    S.offline = off;
    banner(off ? 'Visualiseur injoignable. Relancez « git viewer » dans un terminal.' : null, true);
  }
  function banner(text, isErr) {
    const b = $('banner');
    b.hidden = !text;
    b.textContent = text || '';
    b.classList.toggle('error', !!isErr);
  }

  async function applyState(st) {
    if (st.projectSeq !== S.seq) {
      // RG-25 : changement de projet → tout est réinitialisé, dans tous les onglets.
      S.seq = st.projectSeq; S.sel = null; S.openFile = null; S.fingerprint = null; S.graph = null;
      S.commitCache.clear(); wipView = null; draft = ''; amendDraft = false;
      showPanel(null);
    }
    S.state = st;
    if (st.serverTime) S.offset = Date.parse(st.serverTime) - Date.now();
    if (!st.project) { renderNoProject(); return; }
    renderBar(st);
    if (st.fingerprint !== S.fingerprint) {
      S.fingerprint = st.fingerprint;
      await loadGraph();
      await refreshPanel();
    }
  }

  // ------------------------------------------------------------ barre d'état (VI-04, VI-07)
  function renderBar(st) {
    document.title = `${st.name} — git viewer`;
    $('project-name').textContent = st.name;
    $('project-path').textContent = st.project;
    $('btn-project').title = `${st.project}\nChanger de projet`;
    $('branch-name').textContent = st.branch || (st.empty ? 'aucun commit' : `détaché ${String(st.head).slice(0, 7)}`);
    const sync = $('sync');
    if (st.upstream) {
      sync.textContent = `↑${st.ahead} ↓${st.behind}`;
      sync.title = `Avance ${st.ahead} · retard ${st.behind} par rapport à ${st.upstream}`;
      sync.classList.toggle('warn', st.behind > 0);
    } else if (st.hasRemote && st.branch) {
      sync.textContent = 'non publiée'; sync.title = "Cette branche n'existe pas encore sur le distant"; sync.classList.remove('warn');
    } else sync.textContent = '';
    const n = st.changes.length;
    const cc = $('changes-count');
    cc.textContent = n ? plural(n, 'modification', 'modifications') : 'à jour';
    cc.classList.toggle('dirty', n > 0);
    $('stash-count').textContent = st.stashCount ? `${st.stashCount} de côté` : '';
    ['btn-fetch', 'btn-pull', 'btn-push'].forEach(id => { $(id).disabled = !st.hasRemote; });
    if (st.hasRemote && !st.branch) { $('btn-pull').disabled = true; $('btn-push').disabled = true; }
    $('btn-push').title = st.upstream ? `Pousser vers ${st.upstream}` : 'Publier la branche sur le distant';
    $('menu-stashpop').disabled = !st.stashCount;
    const a = st.autosave;
    $('menu-track').textContent = a.tracked ? 'Ne plus suivre ce projet' : 'Suivre ce projet';
    $('menu-track').dataset.act = a.tracked ? 'untrack' : 'track';
    $('menu-track').disabled = !a.installed;
    document.querySelector('[data-act="autosaveNow"]').disabled = !a.installed || !st.branch;
    if (st.busy) banner(`Opération git en cours : ${st.busy}. La sauvegarde automatique ignore ce projet jusqu'à la fin.`, false);
    else if (!S.offline) banner(null);
    const wip = $('wip-row');
    wip.hidden = n === 0;
    $('wip-count').textContent = plural(n, 'modification', 'modifications');
    wip.classList.toggle('sel', S.sel === 'wip');
    tick();
  }

  function tick() {
    const st = S.state, box = $('autosave'), cd = $('countdown'), ring = $('ring-fg');
    const label = box.querySelector('.label');
    const off = (t, title) => {
      box.classList.add('off'); cd.textContent = t; label.textContent = 'Sauvegarde auto.'; box.title = title || t;
      ring.style.strokeDashoffset = '94.25';
    };
    if (!st || !st.project) return off('—');
    const a = st.autosave;
    if (!a.installed) return off('non installée', "La sauvegarde automatique n'est pas installée sur ce poste.");
    if (!a.tracked) return off('non suivi', 'Ce projet n’est pas suivi. Menu ⋯ → Suivre ce projet.');
    if (!a.active || !a.nextRun) return off('inactive', 'La tâche planifiée est absente ou désactivée : relancez install.ps1.');
    box.classList.remove('off');
    label.textContent = 'Prochaine sauvegarde';
    const ms = Date.parse(a.nextRun) - (Date.now() + S.offset);
    const total = a.intervalMin * 60000;
    if (ms <= 0) { cd.textContent = 'en cours…'; ring.style.strokeDashoffset = '0'; return; }
    const s = Math.ceil(ms / 1000), hh = Math.floor(s / 3600), mm = Math.floor((s % 3600) / 60), ss = s % 60;
    cd.textContent = (hh ? `${hh}:${String(mm).padStart(2, '0')}` : `${mm}`) + `:${String(ss).padStart(2, '0')}`;
    ring.style.strokeDashoffset = String(94.25 * Math.min(1, ms / total));
    box.title = `Toutes les ${a.intervalMin} min · ${plural(a.points, 'point de reprise', 'points de reprise')} depuis le dernier commit`;
  }
  setInterval(tick, 1000);

  // ------------------------------------------------------------ graphe (VI-01, VI-02, VI-03)
  async function loadGraph() {
    try {
      S.graph = await api(`/api/graph?limit=${S.limit}&autosave=${S.showAuto ? 1 : 0}`);
    } catch (e) { toast(e.message, true); return; }
    renderGraph();
  }

  function refChip(r, st) {
    if (r.type === 'autosave') return h('span', { class: 'ref autosave', title: 'Série de points de reprise', text: `reprise · ${r.name}` });
    if (r.type === 'head') {
      const cur = r.name === st.branch;
      return h('span', { class: 'ref head' + (cur ? ' here' : ' other'), title: cur ? 'Branche courante' : 'Branche locale', text: r.name });
    }
    return h('span', { class: 'ref ' + r.type, text: r.name });
  }

  function renderGraph() {
    const g = S.graph, st = S.state, box = $('graph');
    box.textContent = '';
    $('graph-empty').hidden = g.commits.length > 0;
    $('graph-info').textContent = g.commits.length
      ? `${plural(g.commits.length, 'commit', 'commits')}${g.truncated ? ' les plus récents' : ''}` : '';
    if (!g.commits.length) return;
    const lay = window.GTGraph.layout(g.commits, g.main && g.main.sha);
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('class', 'lanes');
    svg.setAttribute('aria-hidden', 'true');
    box.append(svg);
    const w = window.GTGraph.draw(svg, g.commits, lay, st.head);
    document.documentElement.style.setProperty('--gw', `${w}px`);
    const frag = document.createDocumentFragment();
    g.commits.forEach(c => {
      const chips = c.refs.map(r => refChip(r, st));
      if (st.detached && c.h === st.head) chips.unshift(h('span', { class: 'ref head here', text: 'HEAD' }));
      const row = h('div', {
        class: 'row' + (c.auto ? ' auto' : '') + (c.h === st.head ? ' head' : '') + (S.sel === c.h ? ' sel' : ''),
        role: 'option', tabindex: '-1', 'data-sha': c.h, 'aria-selected': S.sel === c.h ? 'true' : 'false',
        title: c.auto ? 'Point de reprise automatique' : null
      },
        h('span', { class: 'g' }),
        h('span', { class: 'subject' }, chips, c.s),
        h('span', { class: 'who', text: c.an }),
        h('span', { class: 'when', title: fmtAbs(c.at), text: fmtRel(c.at) }));
      frag.append(row);
    });
    box.append(frag);
    if (S.sel && S.sel !== 'wip' && !g.commits.some(c => c.h === S.sel)) { S.sel = null; showPanel(null); }
  }

  function select(sel, focus) {
    S.sel = sel; S.openFile = null;
    document.querySelectorAll('#graph .row.sel').forEach(r => { r.classList.remove('sel'); r.setAttribute('aria-selected', 'false'); });
    $('wip-row').classList.toggle('sel', sel === 'wip');
    if (sel && sel !== 'wip') {
      const row = document.querySelector(`#graph .row[data-sha="${sel}"]`);
      if (row) { row.classList.add('sel'); row.setAttribute('aria-selected', 'true'); if (focus) row.focus(); }
    }
    refreshPanel();
  }

  $('graph').addEventListener('click', e => {
    const row = e.target.closest('.row');
    if (row) select(row.dataset.sha);
  });
  $('graph').addEventListener('keydown', e => {
    if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(e.key)) return;
    const rows = Array.from(document.querySelectorAll('#graph .row'));
    if (!rows.length) return;
    let i = rows.findIndex(r => r.dataset.sha === S.sel);
    if (e.key === 'ArrowDown') i = Math.min(rows.length - 1, i + 1);
    if (e.key === 'ArrowUp') i = Math.max(0, i - 1);
    if (e.key === 'Home') i = 0;
    if (e.key === 'End') i = rows.length - 1;
    e.preventDefault();
    select(rows[i].dataset.sha, true);
    rows[i].scrollIntoView({ block: 'nearest' });
  });
  $('wip-row').addEventListener('click', () => select('wip'));

  // ------------------------------------------------------------ panneau
  function showPanel(node) {
    $('panel-empty').hidden = !!node;
    const body = $('panel-body');
    body.hidden = !node;
    if (node && body.firstChild !== node) { body.textContent = ''; body.append(node); }
    if (!node) body.textContent = '';
  }

  async function refreshPanel() {
    if (!S.state || !S.state.project) return;
    if (S.sel === 'wip') renderWip();
    else if (S.sel) await renderCommit(S.sel);
    else showPanel(null);
  }

  // ---- travail en cours (VI-10 à VI-14)
  let wipView = null, draft = '', amendDraft = false;

  function statusLetter(c, staged) {
    if (c.conflict) return 'U';
    if (c.untracked) return 'N';
    return staged ? c.x : c.y;
  }
  const statusTitle = { M: 'Modifié', A: 'Ajouté', D: 'Supprimé', R: 'Renommé', C: 'Copié', N: 'Nouveau', U: 'En conflit', T: 'Type changé' };

  function fileItem(c, staged) {
    const letter = statusLetter(c, staged);
    const mode = staged ? 'staged' : 'worktree';
    const isOpen = S.openFile && S.openFile.path === c.path && S.openFile.mode === mode;
    const ops = h('span', { class: 'ops' });
    if (staged) {
      ops.append(h('button', { type: 'button', class: 'btn small', title: 'Retirer de l’index', onclick: ev => act('unstage', { paths: [c.path] }, { btn: ev.currentTarget }) }, 'Désindexer'));
    } else {
      ops.append(h('button', { type: 'button', class: 'btn small', title: 'Ajouter à l’index', onclick: ev => act('stage', { paths: [c.path] }, { btn: ev.currentTarget }) }, 'Indexer'));
      ops.append(h('button', {
        type: 'button', class: 'btn small danger', title: 'Annuler les modifications de ce fichier',
        onclick: ev => act('discard', { path: c.path }, {
          btn: ev.currentTarget, danger: true,
          confirm: c.untracked
            ? ['Supprimer le nouveau fichier ?', `${c.path}\n\nCe fichier n'a jamais été committé : il sera supprimé du disque.`, 'Supprimer']
            : ['Annuler les modifications ?', `${c.path}\n\nLe fichier reviendra à sa dernière version committée. Les modifications non sauvegardées seront perdues.`, 'Annuler les modifications']
        })
      }, 'Annuler'));
    }
    const li = h('li', { class: 'file' + (isOpen ? ' open' : '') },
      h('span', { class: `st ${letter}`, title: statusTitle[letter] || letter, text: letter }),
      h('button', { type: 'button', class: 'name', title: c.orig ? `${c.orig} → ${c.path}` : c.path, onclick: () => toggleDiff({ path: c.path, mode }) }, h('span', { text: c.path })),
      ops);
    const frag = [li];
    if (isOpen) frag.push(h('li', { class: 'diff-slot' }, diffBox()));
    return frag;
  }

  function buildWipView() {
    const staged = h('ul', { class: 'files' }), unstaged = h('ul', { class: 'files' });
    const ta = h('textarea', { id: 'commit-msg', placeholder: 'Message du commit', 'aria-label': 'Message du commit', rows: '3' });
    ta.value = draft;
    ta.addEventListener('input', () => { draft = ta.value; updateCommitButtons(); });
    const amend = h('input', { type: 'checkbox', id: 'commit-amend' });
    amend.checked = amendDraft;
    amend.addEventListener('change', () => { amendDraft = amend.checked; updateCommitButtons(); });
    const bIndex = h('button', { type: 'button', class: 'btn primary', id: 'btn-commit-index' }, 'Committer l’index');
    const bAll = h('button', { type: 'button', class: 'btn', id: 'btn-commit-all' }, 'Tout committer');
    bIndex.addEventListener('click', () => commit(false, bIndex));
    bAll.addEventListener('click', () => commit(true, bAll));
    const view = h('div', null,
      h('div', { class: 'section' },
        h('div', { class: 'section-head' }, h('h2', null, 'Travail en cours'),
          h('button', { type: 'button', class: 'btn small', id: 'btn-stash', onclick: ev => act('stash', {}, { btn: ev.currentTarget }) }, 'Mettre de côté')),
        h('div', { class: 'group-title' }, h('span', { id: 'staged-title' }),
          h('button', { type: 'button', class: 'btn small', id: 'btn-unstage-all', onclick: ev => act('unstageAll', {}, { btn: ev.currentTarget }) }, 'Tout désindexer')),
        staged,
        h('div', { class: 'group-title' }, h('span', { id: 'unstaged-title' }),
          h('button', { type: 'button', class: 'btn small', id: 'btn-stage-all', onclick: ev => act('stageAll', {}, { btn: ev.currentTarget }) }, 'Tout indexer')),
        unstaged),
      h('div', { class: 'section commit-form' },
        h('div', { class: 'section-head' }, h('h2', null, 'Committer')),
        ta,
        h('div', { class: 'row-actions' },
          h('label', null, amend, 'Modifier le dernier commit'),
          bIndex, bAll)));
    return { view, staged, unstaged, ta, amend, bIndex, bAll };
  }

  function updateCommitButtons() {
    if (!wipView || !S.state) return;
    const ch = S.state.changes;
    const hasStaged = ch.some(c => c.staged);
    const hasMsg = wipView.ta.value.trim().length > 0;
    const amend = wipView.amend.checked && !S.state.empty;
    wipView.amend.disabled = S.state.empty;
    wipView.bIndex.disabled = !(amend || (hasStaged && hasMsg));
    wipView.bAll.disabled = !(amend || (ch.length > 0 && hasMsg));
    wipView.bIndex.title = amend ? 'Remplacer le dernier commit par l’index (et le nouveau message s’il est saisi)'
      : (!hasStaged ? 'Aucun fichier indexé' : (!hasMsg ? 'Saisissez un message' : 'Committer les fichiers indexés'));
    wipView.bAll.title = 'Indexer tout le travail en cours, y compris les nouveaux fichiers, puis committer';
  }

  async function commit(all, btn) {
    const message = wipView.ta.value;
    const amend = wipView.amend.checked;
    const opt = { btn };
    if (amend && all) opt.confirm = ['Modifier le dernier commit ?', 'Tout le travail en cours sera ajouté au dernier commit, qui sera remplacé.', 'Modifier le commit'];
    else if (amend) opt.confirm = ['Modifier le dernier commit ?', 'Le dernier commit sera remplacé' + (message.trim() ? ' avec le nouveau message.' : ' (message conservé).'), 'Modifier le commit'];
    const r = await act('commit', { message, all, amend }, opt);
    if (r && r.ok) { draft = ''; amendDraft = false; wipView.ta.value = ''; wipView.amend.checked = false; updateCommitButtons(); }
  }

  function renderWip() {
    if (!wipView) wipView = buildWipView();
    const ch = S.state.changes;
    const st = ch.filter(c => c.staged), un = ch.filter(c => c.unstaged || c.untracked);
    wipView.staged.textContent = ''; wipView.unstaged.textContent = '';
    st.forEach(c => wipView.staged.append(...fileItem(c, true)));
    un.forEach(c => wipView.unstaged.append(...fileItem(c, false)));
    if (!st.length) wipView.staged.append(h('li', { class: 'muted file', text: 'Aucun fichier indexé.' }));
    if (!un.length) wipView.unstaged.append(h('li', { class: 'muted file', text: ch.length ? 'Tout est indexé.' : 'Aucune modification.' }));
    wipView.view.querySelector('#staged-title').textContent = `Indexés (${st.length})`;
    wipView.view.querySelector('#unstaged-title').textContent = `Non indexés (${un.length})`;
    wipView.view.querySelector('#btn-unstage-all').disabled = !st.length;
    wipView.view.querySelector('#btn-stage-all').disabled = !un.length;
    wipView.view.querySelector('#btn-stash').disabled = !ch.length;
    updateCommitButtons();
    showPanel(wipView.view);
    if (S.openFile) loadDiff();
  }

  // ---- détail d'un commit (VI-05, VI-13, VI-16, VI-17)
  async function renderCommit(sha) {
    let c = S.commitCache.get(sha);
    if (!c) {
      try { c = await api(`/api/commit?sha=${encodeURIComponent(sha)}`); }
      catch (e) { toast(e.message, true); return; }
      S.commitCache.set(sha, c);
    }
    if (S.sel !== sha) return;
    const st = S.state;
    const lines = c.message.split('\n');
    const isHead = sha === st.head;
    const actions = h('div', { class: 'actions' },
      h('button', {
        type: 'button', class: 'btn', title: 'Remettre les fichiers dans l’état de ce commit, sans changer de branche',
        onclick: ev => act('restoreCommit', { sha }, {
          btn: ev.currentTarget, danger: true,
          confirm: ['Restaurer les fichiers ?', `Les fichiers du projet vont reprendre leur état au commit ${sha.slice(0, 8)}.\nLa branche ne change pas. Votre travail actuel est d’abord enregistré dans un point de reprise.`, 'Restaurer']
        })
      }, c.auto ? 'Restaurer ce point de reprise' : 'Restaurer les fichiers'),
      !isHead && !c.auto ? h('button', {
        type: 'button', class: 'btn ghost', title: 'Se placer sur ce commit (hors branche)',
        onclick: ev => act('checkoutCommit', { sha }, {
          btn: ev.currentTarget,
          confirm: ['Se placer sur ce commit ?', `Vous quitterez la branche « ${st.branch || ''} » pour le commit ${sha.slice(0, 8)} (hors branche).\nAucune branche n’est modifiée. Pour revenir, choisissez une branche.`, 'Se placer ici']
        })
      }, 'Se placer ici') : null,
      isHead && st.branch && !c.auto ? h('button', {
        type: 'button', class: 'btn ghost', title: 'Annuler ce commit en gardant ses modifications',
        onclick: ev => act('undoCommit', {}, {
          btn: ev.currentTarget, danger: true,
          confirm: ['Annuler le dernier commit ?', 'Le commit disparaît de la branche. Ses modifications sont conservées et indexées, prêtes à être recommittées.', 'Annuler le commit']
        })
      }, 'Annuler ce commit') : null);

    const files = h('ul', { class: 'files' });
    c.files.forEach(f => {
      const isOpen = S.openFile && S.openFile.path === f.path && S.openFile.sha === sha;
      files.append(h('li', { class: 'file' + (isOpen ? ' open' : '') },
        h('span', { class: `st ${f.status}`, title: statusTitle[f.status] || f.status, text: f.status }),
        h('button', { type: 'button', class: 'name', title: f.orig ? `${f.orig} → ${f.path}` : f.path, onclick: () => toggleDiff({ path: f.path, mode: 'commit', sha }) }, h('span', { text: f.path })),
        h('span')));
      if (isOpen) files.append(h('li', { class: 'diff-slot' }, diffBox()));
    });
    if (!c.files.length) files.append(h('li', { class: 'muted file', text: 'Aucun fichier modifié.' }));

    const parents = c.parents.length
      ? c.parents.map((p, i) => [i ? ', ' : '', h('a', { href: '#', class: 'mono', onclick: e => { e.preventDefault(); select(p); } }, p.slice(0, 8))])
      : ['aucun (premier commit)'];
    const view = h('div', null,
      h('div', { class: 'section' },
        c.auto ? h('span', { class: 'tag-auto', text: 'Point de reprise automatique' }) : null,
        h('p', { class: 'message' }, h('span', { class: 'title', text: lines[0] }), lines.slice(1).join('\n').trim()),
        h('dl', { class: 'meta' },
          h('dt', null, 'Auteur'), h('dd', null, `${c.author} <${c.email}>`),
          h('dt', null, 'Date'), h('dd', null, fmtAbs(c.date)),
          h('dt', null, 'Identifiant'), h('dd', { class: 'mono' }, c.sha),
          h('dt', null, c.parents.length > 1 ? 'Parents' : 'Parent'), h('dd', null, parents))),
      h('div', { class: 'section' }, actions),
      h('div', { class: 'section' },
        h('div', { class: 'section-head' }, h('h2', null, `Fichiers (${c.files.length})`)),
        files));
    showPanel(view);
    if (S.openFile) loadDiff();
  }

  // ---- différences (VI-06)
  function diffBox() { return h('div', { class: 'diff', id: 'diff-box' }, h('div', { class: 'diff-note', text: 'Chargement…' })); }

  function toggleDiff(f) {
    const same = S.openFile && S.openFile.path === f.path && S.openFile.mode === f.mode && S.openFile.sha === f.sha;
    S.openFile = same ? null : f;
    refreshPanel();
  }

  async function loadDiff() {
    const f = S.openFile;
    if (!f) return;
    const q = `path=${encodeURIComponent(f.path)}&mode=${f.mode}${f.sha ? `&sha=${f.sha}` : ''}`;
    let d;
    try { d = await api(`/api/diff?${q}`); } catch (e) { toast(e.message, true); return; }
    const box = $('diff-box');
    if (!box || S.openFile !== f) return;
    const scroll = box.scrollTop;
    box.textContent = '';
    if (d.kind === 'binary') { box.append(h('div', { class: 'diff-note', text: 'Fichier binaire : aperçu impossible.' })); return; }
    if (!d.text) { box.append(h('div', { class: 'diff-note', text: d.kind === 'new' ? 'Fichier vide.' : 'Aucune différence.' })); return; }
    const pre = h('pre');
    d.text.replace(/\n$/, '').split('\n').forEach(line => {
      let cls = 'l';
      if (d.kind === 'new') { cls += ' add'; line = '+' + line; }
      else if (/^(diff |index |--- |\+\+\+ |new file|deleted file|similarity|rename )/.test(line)) cls += ' meta-l';
      else if (line.startsWith('@@')) cls += ' hunk';
      else if (line.startsWith('+')) cls += ' add';
      else if (line.startsWith('-')) cls += ' del';
      pre.append(h('span', { class: cls, text: line || ' ' }));
    });
    box.append(pre);
    if (d.truncated) box.append(h('div', { class: 'diff-note', text: 'Affichage tronqué : fichier trop long.' }));
    box.scrollTop = scroll;
  }

  // ------------------------------------------------------------ projets (VI-32, RG-28)
  function renderNoProject() {
    document.title = 'git viewer';
    $('project-name').textContent = 'Aucun projet';
    $('project-path').textContent = 'Cliquez pour en ouvrir un';
    $('graph').textContent = '';
    $('wip-row').hidden = true;
    $('graph-empty').hidden = true;
    showPanel(h('div', { class: 'panel-empty' }, h('p', null, 'Aucun projet ouvert.'),
      h('button', { type: 'button', class: 'btn primary', onclick: openProjectDialog }, 'Ouvrir un projet')));
    tick();
  }

  async function openProject(body, btn) {
    if (btn) { btn.classList.add('busy'); btn.disabled = true; }
    try {
      const r = await api(body ? '/api/open' : '/api/browse', { method: 'POST', body: body || {} });
      if (r.ok === false) { toast(r.message, false); return; }
      $('dlg-project').close();
      if (r.tracked) toast('Projet inscrit à la sauvegarde automatique.');
      await poll();
    } catch (e) {
      toast(e.message, true);
    } finally {
      if (btn) { btn.classList.remove('busy'); btn.disabled = false; }
    }
  }

  async function openProjectDialog() {
    const dlg = $('dlg-project'), list = $('project-list');
    list.textContent = '';
    list.append(h('li', { class: 'muted', text: 'Chargement…' }));
    dlg.showModal();
    let data;
    try { data = await api('/api/projects'); } catch (e) { toast(e.message, true); return; }
    list.textContent = '';
    if (!data.items.length) list.append(h('li', { class: 'muted', text: 'Aucun projet récent ni suivi.' }));
    data.items.forEach(p => {
      const current = data.current && p.path.toLowerCase() === data.current.toLowerCase();
      list.append(h('li', { class: current ? 'current' : null },
        h('div', { class: 'grow' }, h('button', {
          type: 'button', disabled: !p.exists || current, title: p.exists ? p.path : 'Dossier introuvable',
          onclick: ev => openProject({ path: p.path }, ev.currentTarget)
        }, h('span', { class: 't', text: p.name }), h('span', { class: 's', text: p.exists ? p.path : `${p.path} (introuvable)` }))),
        p.tracked ? h('span', { class: 'badge ok', text: 'suivi' }) : null,
        p.recent ? null : h('span', { class: 'badge', text: 'non ouvert' })));
    });
  }
  $('btn-project').addEventListener('click', openProjectDialog);
  $('form-path').addEventListener('submit', e => {
    e.preventDefault();
    const v = $('input-path').value.trim();
    if (v) openProject({ path: v }, e.submitter);
  });
  $('btn-browse').addEventListener('click', ev => openProject(null, ev.currentTarget));

  // ------------------------------------------------------------ branches (VI-15, RG-21)
  async function openBranchDialog() {
    if (!S.state || !S.state.project) return;
    const dlg = $('dlg-branches');
    if (!dlg.open) dlg.showModal();
    let b;
    try { b = await api('/api/branches'); } catch (e) { toast(e.message, true); return; }
    const cur = S.state.branch;
    const loc = $('branch-local'), rem = $('branch-remote');
    loc.textContent = ''; rem.textContent = '';
    b.local.forEach(name => {
      const isCur = name === cur;
      loc.append(h('li', { class: isCur ? 'current' : null },
        h('div', { class: 'grow' }, h('span', { class: 't mono', text: name })),
        isCur ? null : h('button', { type: 'button', class: 'btn small', onclick: ev => branchAct('switch', { branch: name }, ev.currentTarget) }, 'Basculer'),
        isCur || !cur ? null : h('button', {
          type: 'button', class: 'btn small ghost',
          onclick: ev => branchAct('merge', { branch: name }, ev.currentTarget, ['Fusionner ?', `Fusionner « ${name} » dans « ${cur} ».\nEn cas de conflit, la fusion est annulée et rien ne change.`, 'Fusionner'])
        }, 'Fusionner ici'),
        isCur ? null : h('button', {
          type: 'button', class: 'btn small danger',
          onclick: ev => deleteBranch(name, ev.currentTarget)
        }, 'Supprimer')));
    });
    if (!b.local.length) loc.append(h('li', { class: 'muted', text: 'Aucune branche locale.' }));
    b.remote.forEach(name => {
      const local = name.slice(name.indexOf('/') + 1);
      const exists = b.local.includes(local);
      rem.append(h('li', null,
        h('div', { class: 'grow' }, h('span', { class: 't mono', text: name })),
        exists ? h('span', { class: 'badge', text: 'locale existe' })
          : h('button', { type: 'button', class: 'btn small', title: `Créer « ${local} » qui suit ${name}`, onclick: ev => branchAct('switch', { branch: local }, ev.currentTarget) }, 'Basculer')));
    });
    if (!b.remote.length) rem.append(h('li', { class: 'muted', text: 'Aucune branche distante.' }));
  }

  async function branchAct(name, args, btn, confirm) {
    const r = await act(name, args, { btn, confirm });
    if (r && r.ok && name === 'switch') $('dlg-branches').close();
    else if ($('dlg-branches').open) openBranchDialog();
  }

  async function deleteBranch(name, btn) {
    const r = await act('deleteBranch', { branch: name }, {
      btn, danger: true, confirm: ['Supprimer la branche ?', `La branche « ${name} » sera supprimée.`, 'Supprimer']
    });
    if (r && r.needsForce) {
      const r2 = await act('deleteBranch', { branch: name, force: true }, {
        btn, danger: true,
        confirm: ['Branche non fusionnée', `« ${name} » contient des commits qui ne sont dans aucune autre branche.\nIls seront perdus. Supprimer quand même ?`, 'Supprimer définitivement']
      });
      if (!r2) toast('Suppression annulée.');
    }
    if ($('dlg-branches').open) openBranchDialog();
  }

  $('btn-branch').addEventListener('click', openBranchDialog);
  $('form-branch').addEventListener('submit', async e => {
    e.preventDefault();
    const v = $('input-branch').value.trim();
    if (!v) return;
    const r = await act('createBranch', { branch: v }, { btn: e.submitter });
    if (r && r.ok) { $('input-branch').value = ''; $('dlg-branches').close(); }
  });
  document.querySelectorAll('dialog [data-close]').forEach(b => b.addEventListener('click', () => b.closest('dialog').close()));

  // ------------------------------------------------------------ distant (VI-20 à VI-22)
  $('btn-fetch').addEventListener('click', ev => act('fetch', {}, { btn: ev.currentTarget }));
  $('btn-pull').addEventListener('click', ev => act('pull', {}, { btn: ev.currentTarget }));
  $('btn-push').addEventListener('click', ev => act('push', {}, { btn: ev.currentTarget }));

  // ------------------------------------------------------------ menu
  const menu = $('menu');
  $('btn-menu').addEventListener('click', e => { e.stopPropagation(); menu.hidden = !menu.hidden; });
  document.addEventListener('click', e => { if (!menu.hidden && !menu.contains(e.target)) menu.hidden = true; });
  document.addEventListener('keydown', e => { if (e.key === 'Escape') menu.hidden = true; });
  menu.addEventListener('click', async e => {
    const b = e.target.closest('button[data-act]');
    if (!b) return;
    menu.hidden = true;
    const a = b.dataset.act;
    if (a === 'shutdown') {
      if (!(await confirmDlg('Arrêter le visualiseur ?', 'La page ne sera plus mise à jour. Relancez « git viewer » pour la rouvrir.', { danger: true, ok: 'Arrêter' }))) return;
      try { await api('/api/shutdown', { method: 'POST', body: {} }); } catch (err) { /* déjà arrêté */ }
      S.stopped = true; clearTimeout(pollTimer);
      banner('Visualiseur arrêté. Relancez « git viewer » dans un terminal pour le rouvrir.', false);
      return;
    }
    if (a === 'untrack') {
      return act('untrack', { exclude: true }, {
        confirm: ['Ne plus suivre ce projet ?', 'La sauvegarde automatique s’arrête pour ce projet et il ne sera plus réinscrit à l’ouverture. Les points de reprise existants sont conservés.', 'Ne plus suivre']
      });
    }
    act(a, {});
  });

  // ------------------------------------------------------------ préférences
  const themes = ['system', 'light', 'dark'];
  const themeNames = { system: 'système', light: 'clair', dark: 'sombre' };
  function applyTheme(t) {
    document.documentElement.dataset.theme = t;
    $('btn-theme').title = `Thème : ${themeNames[t]}`;
  }
  applyTheme(themes.includes(store.get('theme', 'system')) ? store.get('theme', 'system') : 'system');
  $('btn-theme').addEventListener('click', () => {
    const t = themes[(themes.indexOf(document.documentElement.dataset.theme) + 1) % themes.length];
    applyTheme(t); store.set('theme', t);
  });
  $('toggle-autosave').checked = S.showAuto;
  $('toggle-autosave').addEventListener('change', e => {
    S.showAuto = e.target.checked; store.set('autosave', S.showAuto ? '1' : '0'); loadGraph();
  });
  const lim = $('graph-limit');
  if (![...lim.options].some(o => Number(o.value) === S.limit)) lim.append(h('option', { value: String(S.limit) }, String(S.limit)));
  lim.value = String(S.limit);
  lim.addEventListener('change', () => { S.limit = Number(lim.value); store.set('limit', lim.value); loadGraph(); });

  presence();
  poll();
})();
