// Serveur de test : même contrat d'API que viewer/GitViewer.psm1, implémenté en Node sur un vrai dépôt git.
// Sert uniquement aux tests de l'interface (Playwright) hors Windows. N'est pas livré à l'utilisateur.
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const WWW = path.join(__dirname, '..', '..', 'viewer', 'www');
const AUTO_EMAIL = 'autosave@git-tools.local';

function git(repo, args, opts = {}) {
  try {
    const out = execFileSync('git', ['-c', 'core.quotepath=false', ...args], {
      cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, GIT_TERMINAL_PROMPT: '0', LC_ALL: 'C', ...(opts.env || {}) }
    });
    return { code: 0, out, err: '' };
  } catch (e) {
    if (opts.allowFail) return { code: e.status || 1, out: String(e.stdout || ''), err: String(e.stderr || '').trim() };
    throw new Error(String(e.stderr || e.message).trim());
  }
}
const val = (repo, args) => { const r = git(repo, args, { allowFail: true }); return r.code === 0 && r.out.trim() ? r.out.trim() : null; };

function start({ repo, port = 0, token = 'a1b2c3d4e5f60718293a4b5c6d7e8f90', autosave = {} }) {
  const shared = { project: repo, seq: 1, presence: 0, stopped: false, autosave, nextRun: Date.now() + (autosave.nextInMs != null ? autosave.nextInMs : 12 * 60000) };
  const json = (res, status, obj) => { const b = Buffer.from(JSON.stringify(obj)); res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': b.length, 'Cache-Control': 'no-store' }); res.end(b); };
  const fail = (status, message) => Object.assign(new Error(message), { status });

  // Réglages : même schéma et mêmes messages que Get-GTSettingsSchema / ConvertTo-GTSettingValue.
  const SCHEMA = [
    { key: 'intervalMin', tool: 'autosave', type: 'int', min: 5, max: 240, unit: 'min', default: 30, label: 'Intervalle de sauvegarde', help: 'Durée entre deux passages.' },
    { key: 'keepSeries', tool: 'autosave', type: 'bool', default: false, label: 'Garder les points de reprise après un commit', help: '…' },
    { key: 'shareRemote', tool: 'autosave', type: 'bool', default: false, label: 'Envoyer les points de reprise sur le distant', help: '…' },
    { key: 'autoTrack', tool: 'autosave', type: 'bool', default: true, label: 'Suivre automatiquement les projets ouverts ici', help: '…' },
    { key: 'autoTrackExclude', tool: 'autosave', type: 'list', default: [], label: 'Projets jamais inscrits automatiquement', help: '…' },
    { key: 'launcher', tool: 'autosave', type: 'choice', choices: ['conhost', 'wscript'], default: 'conhost', label: 'Lanceur sans fenêtre', help: '…' },
    { key: 'graphLimit', tool: 'viewer', type: 'int', min: 50, max: 5000, unit: 'commits', default: 400, label: 'Commits chargés à l’ouverture', help: '…' }
  ];
  const cfg = Object.fromEntries(SCHEMA.map(s => [s.key, s.default]));
  cfg.autoTrackExclude = ['C:\\Projets\\ancien projet'];
  function settings(extra) {
    return Object.assign({ autosaveInstalled: true, items: SCHEMA.map(s => Object.assign({}, s, { value: cfg[s.key], available: true })) }, extra || {});
  }
  function setSetting(data) {
    if (data.reset) { SCHEMA.forEach(s => { cfg[s.key] = s.default; }); shared.autosave.intervalMin = cfg.intervalMin; return settings({ ok: true, message: 'Réglages remis à leurs valeurs par défaut.' }); }
    const s = SCHEMA.find(x => x.key === data.key);
    if (!s) throw fail(400, `Réglage inconnu : « ${data.key} ».`);
    let v = data.value;
    if (s.type === 'int' && !(Number.isInteger(v) || /^\d+$/.test(String(v))) || s.type === 'int' && (+v < s.min || +v > s.max)) throw fail(400, `« ${v} » refusé pour « ${s.label} » : nombre entier de ${s.min} à ${s.max}.`);
    if (s.type === 'int') v = +v;
    if (s.type === 'bool' && typeof v !== 'boolean') throw fail(400, `Valeur refusée pour « ${s.label} » : activé ou désactivé.`);
    if (s.type === 'choice' && !s.choices.includes(v)) throw fail(400, `« ${v} » refusé pour « ${s.label} » : valeurs acceptées ${s.choices.join(', ')}.`);
    cfg[s.key] = v;
    if (s.key === 'intervalMin') { shared.autosave.intervalMin = v; shared.nextRun = Date.now() + v * 60000; }
    return settings({ ok: true, message: `${s.label} : ${s.type === 'bool' ? (v ? 'activé' : 'désactivé') : s.type === 'list' ? 'liste mise à jour' : v + (s.unit ? ' ' + s.unit : '')}.` });
  }

  function state() {
    const r = shared.project;
    const branch = val(r, ['symbolic-ref', '-q', '--short', 'HEAD']);
    const head = val(r, ['rev-parse', '-q', '--verify', 'HEAD^{commit}']);
    let upstream = null, ahead = 0, behind = 0;
    if (branch && head) {
      upstream = val(r, ['rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}']);
      if (upstream) { const n = val(r, ['rev-list', '--left-right', '--count', 'HEAD...@{u}']).split(/\s+/); ahead = +n[0]; behind = +n[1]; }
    }
    const raw = git(r, ['status', '--porcelain=v1', '-z', '--untracked-files=all']).out;
    const parts = raw.split('\0'); const changes = [];
    for (let i = 0; i < parts.length; i++) {
      const e = parts[i]; if (e.length < 4) continue;
      const x = e[0], y = e[1], p = e.slice(3); let orig = null;
      if (x === 'R' || x === 'C') orig = parts[++i];
      changes.push({ path: p, orig, x, y, staged: x !== ' ' && x !== '?', unstaged: y !== ' ', untracked: x === '?', conflict: x === 'U' || y === 'U' });
    }
    const refs = git(r, ['for-each-ref', '--format=%(refname) %(objectname)']).out;
    let fp = `${head}|${refs}|${raw}`;
    for (const c of changes) { try { const s = fs.statSync(path.join(r, c.path)); fp += `|${c.path}:${s.size}:${s.mtimeMs}`; } catch (e) { /* supprimé */ } }
    const stash = git(r, ['stash', 'list', '--format=%H'], { allowFail: true }).out.split('\n').filter(Boolean).length;
    let points = 0;
    if (branch && head) { const tip = val(r, ['rev-parse', '-q', '--verify', `refs/autosave/${branch}/${head}`]); if (tip) points = +val(r, ['rev-list', '--count', `${head}..${tip}`]); }
    const a = Object.assign({ installed: true, tracked: true, active: true, intervalMin: 30 }, shared.autosave);
    const next = a.active ? new Date(shared.nextRun).toISOString() : null;
    return {
      project: r, name: path.basename(r), branch, head, detached: !branch && !!head, empty: !head, upstream, ahead, behind,
      hasRemote: git(r, ['remote'], { allowFail: true }).out.trim().length > 0, changes, stashCount: stash, busy: null,
      autosave: { installed: a.installed, tracked: a.tracked, active: a.active, nextRun: next, intervalMin: a.intervalMin, points },
      fingerprint: require('crypto').createHash('sha1').update(fp).digest('hex'), serverTime: new Date().toISOString(), projectSeq: shared.seq
    };
  }

  function graph(limit, auto) {
    const r = shared.project;
    if (!val(r, ['rev-parse', '-q', '--verify', 'HEAD^{commit}'])) return { commits: [], main: null, limit, truncated: false };
    const args = ['log', '--date-order', '-n', String(limit + 1), '--decorate=full', '--decorate-refs=refs/heads/', '--decorate-refs=refs/remotes/', '--decorate-refs=refs/tags/',
      '--format=%H%x1f%P%x1f%D%x1f%an%x1f%at%x1f%ce%x1f%s%x1e', '--exclude=refs/stash', '--exclude=refs/remotes/*/HEAD'];
    if (auto) args.push('--decorate-refs=refs/autosave/'); else args.push('--exclude=refs/autosave/*');
    args.push('--all', 'HEAD');
    const commits = git(r, args).out.split('\x1e').map(s => s.replace(/^\n+|\n+$/g, '')).filter(Boolean).map(rec => {
      const f = rec.split('\x1f');
      const refs = f[2] ? f[2].split(', ').map(d => {
        d = d.replace(/^tag: /, '');
        const type = d.startsWith('refs/heads/') ? 'head' : d.startsWith('refs/remotes/') ? 'remote' : d.startsWith('refs/tags/') ? 'tag' : d.startsWith('refs/autosave/') ? 'autosave' : 'other';
        let name = d.replace(/^refs\/(heads|remotes|tags)\//, '');
        if (type === 'autosave') name = d.replace(/^refs\/autosave\//, '').replace(/\/[0-9a-f]{40,64}$/, '');
        return { name, type, full: d };
      }) : [];
      return { h: f[0], p: f[1].split(' ').filter(Boolean), refs, an: f[3], at: +f[4], auto: f[5] === AUTO_EMAIL, s: f[6] };
    });
    const truncated = commits.length > limit; if (truncated) commits.pop();
    let main = null;
    for (const c of ['refs/heads/main', 'refs/heads/master']) { const s = val(r, ['rev-parse', '-q', '--verify', c + '^{commit}']); if (s) { main = { ref: c, sha: s }; break; } }
    return { commits, main, limit, truncated };
  }

  function commit(sha) {
    if (!/^[0-9a-f]{7,64}$/.test(sha)) throw fail(400, 'Identifiant de commit invalide.');
    const r = shared.project;
    const f = git(r, ['show', '-s', '--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ce%x1f%B', sha]).out.split('\x1f');
    const parents = f[1].split(' ').filter(Boolean);
    const d = git(r, parents.length ? ['diff-tree', '-r', '-M', '--name-status', '-z', parents[0], f[0]] : ['diff-tree', '-r', '--root', '--name-status', '-z', f[0]]).out.split('\0');
    const files = []; let i = (!parents.length && /^[0-9a-f]{40}/.test(d[0])) ? 1 : 0;
    while (i < d.length) { const st = d[i++]; if (!st) continue; const code = st[0]; if (code === 'R' || code === 'C') { files.push({ status: code, orig: d[i], path: d[i + 1] }); i += 2; } else { files.push({ status: code, orig: null, path: d[i++] }); } }
    return { sha: f[0], parents, author: f[2], email: f[3], date: +f[4], auto: f[6] === AUTO_EMAIL, message: f.slice(7).join('\x1f').trimEnd(), files };
  }

  function diff(p, mode, sha) {
    const r = shared.project;
    if (!p || p.includes('..') || path.isAbsolute(p)) throw fail(400, 'Chemin de fichier invalide.');
    let kind = 'diff', text;
    if (mode === 'commit') { const par = val(r, ['show', '-s', '--format=%P', sha]); text = par ? git(r, ['diff', '-M', par.split(' ')[0], sha, '--', p]).out : git(r, ['show', '--format=', sha, '--', p]).out; }
    else if (mode === 'staged') text = git(r, ['diff', '--cached', '-M', '--', p]).out;
    else if (!val(r, ['ls-files', '--', p])) { kind = 'new'; text = fs.existsSync(path.join(r, p)) ? fs.readFileSync(path.join(r, p), 'utf8') : ''; }
    else text = git(r, ['diff', '--', p]).out;
    return { text, truncated: false, kind, path: p, mode };
  }

  function ga(args, ok) { const x = git(shared.project, args, { allowFail: true }); return x.code === 0 ? { ok: true, message: ok } : { ok: false, message: 'Échec : ' + (x.err || x.out).trim() }; }
  function action(name, a) {
    const r = shared.project; a = a || {};
    const paths = a.paths || (a.path ? [a.path] : []);
    switch (name) {
      case 'stage': return ga(['add', '-A', '--', ...paths], 'Fichier(s) indexé(s).');
      case 'stageAll': return ga(['add', '-A'], 'Toutes les modifications sont indexées.');
      case 'unstage': return ga(['restore', '--staged', '--', ...paths], 'Fichier(s) désindexé(s).');
      case 'unstageAll': return ga(['restore', '--staged', '--', ':/'], 'Index vidé.');
      case 'discard': {
        if (val(r, ['ls-tree', '--name-only', 'HEAD', '--', a.path])) return ga(['restore', '--source=HEAD', '--staged', '--worktree', '--', a.path], `Modifications annulées : ${a.path}`);
        git(r, ['rm', '--cached', '-q', '--', a.path], { allowFail: true }); fs.rmSync(path.join(r, a.path), { force: true });
        return { ok: true, message: `Nouveau fichier supprimé : ${a.path}` };
      }
      case 'commit': {
        if (!String(a.message || '').trim() && !a.amend) throw fail(400, 'Le message du commit est obligatoire.');
        if (a.all) git(r, ['add', '-A']);
        else if (!a.amend && git(r, ['diff', '--cached', '--quiet'], { allowFail: true }).code === 0) throw fail(400, 'Aucun fichier indexé : indexez des fichiers ou choisissez « tout committer ».');
        const args = ['commit']; if (a.amend) args.push('--amend');
        if (String(a.message || '').trim()) args.push('-m', a.message); else args.push('--no-edit');
        if (a.amend && !a.all) args.push('--allow-empty');
        return ga(args, a.amend ? 'Dernier commit modifié.' : 'Commit créé.');
      }
      case 'undoCommit': return ga(['reset', '--soft', 'HEAD~1'], 'Dernier commit annulé : ses modifications sont indexées.');
      case 'stash': return ga(['stash', 'push', '-u', '-m', 'git-tools'], 'Modifications mises de côté.');
      case 'stashPop': return ga(['stash', 'pop'], 'Modifications réappliquées.');
      case 'switch': return ga(['switch', a.branch], `Branche courante : ${a.branch}`);
      case 'createBranch':
        if (git(r, ['check-ref-format', '--branch', a.branch], { allowFail: true }).code) throw fail(400, `Nom de branche invalide : « ${a.branch} ».`);
        return ga(['switch', '-c', a.branch], `Branche ${a.branch} créée.`);
      case 'merge': return ga(['merge', '--no-edit', a.branch], `Branche ${a.branch} fusionnée.`);
      case 'deleteBranch': {
        const x = git(r, ['branch', a.force ? '-D' : '-d', a.branch], { allowFail: true });
        if (x.code === 0) return { ok: true, message: `Branche ${a.branch} supprimée.` };
        if (/not fully merged/.test(x.err)) return { ok: false, needsForce: true, message: `La branche ${a.branch} n'est pas fusionnée : ses commits seront perdus.` };
        return { ok: false, message: 'Échec : ' + x.err };
      }
      case 'restoreCommit': return ga(['restore', `--source=${a.sha}`, '--worktree', '--', ':/'], 'Fichiers restaurés.');
      case 'checkoutCommit': return ga(['switch', '--detach', a.sha], `Positionné sur ${a.sha.slice(0, 8)} (hors branche).`);
      case 'fetch': case 'pull': case 'push': return { ok: false, message: 'Aucun dépôt distant configuré.' };
      case 'autosaveNow': return { ok: true, message: 'Rien de nouveau à sauvegarder.' };
      case 'track': shared.autosave.tracked = true; return { ok: true, message: 'Projet suivi par la sauvegarde automatique.' };
      case 'untrack': shared.autosave.tracked = false; return { ok: true, message: 'Projet retiré de la sauvegarde.' };
      default: throw fail(404, `Action inconnue : ${name}`);
    }
  }

  const server = http.createServer((req, res) => {
    const port = server.address().port;
    if (req.headers.host !== `127.0.0.1:${port}` && req.headers.host !== `localhost:${port}`) { res.writeHead(403); return res.end('Hôte refusé.'); }
    const u = new URL(req.url, `http://127.0.0.1:${port}`);
    if (!u.pathname.startsWith('/api/')) {
      const map = { '/': 'index.html', '/index.html': 'index.html', '/app.js': 'app.js', '/graph.js': 'graph.js', '/styles.css': 'styles.css', '/favicon.svg': 'favicon.svg' };
      const f = map[u.pathname]; if (!f) { res.writeHead(404); return res.end(); }
      const body = fs.readFileSync(path.join(WWW, f), 'utf8');
      const type = { html: 'text/html', js: 'text/javascript', css: 'text/css', svg: 'image/svg+xml' }[f.split('.').pop()];
      const headers = { 'Content-Type': `${type}; charset=utf-8`, 'Cache-Control': 'no-store' };
      if (f === 'index.html') headers['Content-Security-Policy'] = "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'";
      res.writeHead(200, headers); return res.end(body);
    }
    if (u.pathname === '/api/presence') {
      if (u.searchParams.get('t') !== token) { res.writeHead(403); return res.end(); }
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store' });
      let seq = -1;
      const t = setInterval(() => { if (shared.seq !== seq) { seq = shared.seq; res.write(`event: project\ndata: ${seq}\n\n`); } }, 300);
      shared.presence++; req.on('close', () => { clearInterval(t); shared.presence--; });
      return;
    }
    if (req.headers['x-gittools-token'] !== token) return json(res, 403, { ok: false, message: 'Accès refusé.' });
    let body = '';
    req.on('data', c => { body += c; });
    req.on('end', () => {
      try {
        const data = body ? JSON.parse(body) : {};
        const q = u.searchParams;
        switch (`${req.method} ${u.pathname}`) {
          case 'GET /api/ping': return json(res, 200, { ok: true });
          case 'GET /api/state': return json(res, 200, state());
          case 'GET /api/graph': return json(res, 200, graph(+q.get('limit') || 400, q.get('autosave') !== '0'));
          case 'GET /api/commit': return json(res, 200, commit(q.get('sha') || ''));
          case 'GET /api/diff': return json(res, 200, diff(q.get('path'), q.get('mode'), q.get('sha')));
          case 'GET /api/branches': return json(res, 200, {
            local: git(shared.project, ['for-each-ref', '--format=%(refname:short)', 'refs/heads/']).out.split('\n').filter(Boolean),
            remote: git(shared.project, ['for-each-ref', '--format=%(refname:short)', 'refs/remotes/']).out.split('\n').filter(s => s && !s.endsWith('/HEAD'))
          });
          case 'GET /api/projects': return json(res, 200, { current: shared.project, items: [{ path: shared.project, name: path.basename(shared.project), exists: true, tracked: true, recent: true }], autosaveInstalled: true });
          case 'POST /api/open': {
            if (!data.path) return json(res, 200, { ok: true, project: shared.project });
            if (!fs.existsSync(data.path) || !val(data.path, ['rev-parse', '--show-toplevel'])) throw fail(400, `« ${data.path} » n'est pas un projet git. Le projet affiché reste inchangé.`);
            shared.project = val(data.path, ['rev-parse', '--show-toplevel']); shared.seq++;
            return json(res, 200, { ok: true, project: shared.project, tracked: false, projectSeq: shared.seq });
          }
          case 'POST /api/browse': return json(res, 200, { ok: false, message: 'Aucun dossier choisi.' });
          case 'POST /api/action': return json(res, 200, action(data.name, data.args));
          case 'GET /api/settings': return json(res, 200, settings());
          case 'POST /api/settings': return json(res, 200, setSetting(data));
          case 'POST /api/shutdown': shared.stopped = true; return json(res, 200, { ok: true });
          default: return json(res, 404, { ok: false, message: 'Route inconnue' });
        }
      } catch (e) { return json(res, e.status || 500, { ok: false, message: e.message }); }
    });
  });
  return new Promise(resolve => server.listen(port, '127.0.0.1', () => resolve({ server, shared, port: server.address().port, token })));
}

module.exports = { start, git };

if (require.main === module) {
  start({ repo: process.argv[2] || process.cwd(), port: +process.argv[3] || 8765 }).then(s => console.log(`http://127.0.0.1:${s.port}/`));
}
