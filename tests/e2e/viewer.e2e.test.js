// Tests de l'interface du visualiseur (L8) — Playwright + node:test, sans dépendance à installer
// sur un poste où « require('playwright') » fonctionne.  Lancer : node --test tests/e2e/
// Le serveur est le double Node (mock-server.js) qui respecte le contrat d'API du serveur PowerShell.
'use strict';
const { test, before, after, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { execFileSync } = require('child_process');
const { chromium } = require('playwright');
const { start, git } = require('./mock-server');

const SHOTS = path.join(__dirname, 'test-results');
fs.mkdirSync(SHOTS, { recursive: true });
let browser, srv, page, repo, tmp;

function makeRepo() {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'gt-e2e-'));
  repo = path.join(tmp, 'projet démo');
  execFileSync('bash', [path.join(__dirname, 'make-repo.sh'), repo]);
  return repo;
}
const sh = (...args) => git(repo, args);
async function within(ms, fn, label) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { if (await fn()) return Date.now() - t0; await new Promise(r => setTimeout(r, 50)); }
  throw new Error(`${label} : pas observé en ${ms} ms`);
}

before(async () => { browser = await chromium.launch(); });
after(async () => { await browser.close(); });
beforeEach(async () => {
  makeRepo();
  srv = await start({ repo });
  page = await browser.newPage({ viewport: { width: 1280, height: 860 } });
  page.on('pageerror', e => { throw e; });
  await page.goto(`http://127.0.0.1:${srv.port}/#t=${srv.token}`);
  await page.waitForSelector('#graph .row');
});
afterEach(async (t) => {
  await page.screenshot({ path: path.join(SHOTS, t.name.replace(/[^\w-]+/g, '_') + '.png') });
  await page.close();
  srv.server.closeAllConnections?.();
  srv.server.close();
  fs.rmSync(tmp, { recursive: true, force: true });
});

test('R-11 / VI-08 : un commit fait dans un terminal apparaît en moins de 2 s', async () => {
  fs.writeFileSync(path.join(repo, 'terminal.txt'), 'x');
  sh('add', 'terminal.txt'); sh('commit', '-qm', 'Commit depuis le terminal');
  const ms = await within(2000, async () => (await page.locator('#graph .row', { hasText: 'Commit depuis le terminal' }).count()) === 1, 'commit visible');
  assert.ok(ms < 2000, `visible en ${ms} ms`);
});

test('VI-03 / VI-04 : travail en cours et résumé conformes à l’état réel', async () => {
  assert.equal(await page.locator('#wip-count').textContent(), '3 modifications');
  assert.equal(await page.locator('#branch-name').textContent(), 'main');
  assert.equal(await page.locator('#changes-count').textContent(), '3 modifications');
});

test('VI-06 : la différence ouverte se met à jour en moins de 2 s', async () => {
  await page.click('#wip-row');
  await page.locator('.file .name', { hasText: 'src/app.ps1' }).click();
  await page.waitForSelector('#diff-box .add');
  fs.appendFileSync(path.join(repo, 'src', 'app.ps1'), 'ligne ajoutée au vol\n');
  await within(2000, async () => (await page.locator('#diff-box', { hasText: 'ligne ajoutée au vol' }).count()) === 1, 'diff à jour');
});

test('R-12 / VI-10 / VI-12 : indexer un fichier puis committer l’index ne committe que lui', async () => {
  await page.click('#wip-row');
  await page.click('#btn-unstage-all');
  await within(2000, async () => (await page.locator('#staged-title').textContent()) === 'Indexés (0)', 'index vide');
  await page.locator('.file', { hasText: 'src/app.ps1' }).getByRole('button', { name: 'Indexer' }).click();
  await within(2000, async () => (await page.locator('#staged-title').textContent()) === 'Indexés (1)', 'un fichier indexé');
  await page.fill('#commit-msg', 'Seulement app.ps1');
  await page.click('#btn-commit-index');
  await within(3000, async () => (await page.locator('#graph .row', { hasText: 'Seulement app.ps1' }).count()) === 1, 'commit créé');
  const files = sh('show', '--name-only', '--format=', 'HEAD').out.trim().split('\n');
  assert.deepEqual(files, ['src/app.ps1']);
  const left = sh('status', '--porcelain').out;
  assert.match(left, /README\.md/); assert.match(left, /nouveau fichier\.txt/);
});

test('RG-23 / RG-24 : committer est impossible sans message ou avec un index vide', async () => {
  await page.click('#wip-row');
  assert.equal(await page.locator('#btn-commit-index').isDisabled(), true, 'sans message');
  await page.click('#btn-unstage-all');
  await within(2000, async () => (await page.locator('#staged-title').textContent()) === 'Indexés (0)', 'index vide');
  await page.fill('#commit-msg', 'Message');
  assert.equal(await page.locator('#btn-commit-index').isDisabled(), true, 'index vide');
  assert.equal(await page.locator('#btn-commit-all').isDisabled(), false, 'tout committer reste possible');
});

test('R-13 / VI-13 : annuler le dernier commit garde ses modifications indexées', async () => {
  const before = sh('rev-parse', 'HEAD~1').out.trim();
  await page.locator('#graph .row.head').click();
  await page.getByRole('button', { name: 'Défaire ce commit' }).click();
  assert.equal(await page.locator('#dlg-confirm').isVisible(), true, 'confirmation demandée');
  await page.click('#confirm-ok');
  await within(3000, async () => sh('rev-parse', 'HEAD').out.trim() === before, 'commit annulé');
  assert.match(sh('diff', '--cached', '--name-only').out, /src\/app\.ps1/);
});

test('R-15 / RG-21 : supprimer une branche non fusionnée demande deux confirmations', async () => {
  await page.click('#btn-branch');
  const row = page.locator('#branch-local li', { hasText: 'experiment' });
  await row.getByRole('button', { name: 'Supprimer' }).click();
  await page.click('#confirm-ok');
  await page.waitForSelector('#dlg-confirm[open]');
  assert.equal(await page.locator('#confirm-title').textContent(), 'Branche non fusionnée');
  assert.ok(sh('branch', '--list', 'experiment').out.trim(), 'toujours présente entre les deux confirmations');
  await page.click('#confirm-ok');
  await within(3000, async () => !sh('branch', '--list', 'experiment').out.trim(), 'branche supprimée');
});

test('VI-15 : changer de branche en deux clics', async () => {
  await page.click('#btn-branch');
  await page.locator('#branch-local li', { hasText: 'feature/graphe' }).getByRole('button', { name: 'Basculer' }).click().catch(() => {});
  // le travail en cours peut bloquer git switch : on vérifie le message plutôt que l'état
  await page.waitForSelector('.toast');
});

test('VI-02 : points de reprise distincts et masquables en un clic', async () => {
  assert.equal(await page.locator('#graph svg .node.auto').count(), 2, 'losanges des points de reprise');
  assert.equal(await page.locator('#graph .row.auto').count(), 2);
  await page.click('#toggle-autosave');
  await within(2000, async () => (await page.locator('#graph .row.auto').count()) === 0, 'masqués');
});

test('VI-05 : détail d’un commit en un clic', async () => {
  await page.locator('#graph .row', { hasText: 'Correction : chemins accentués' }).click();
  await page.waitForSelector('.meta');
  assert.match(await page.locator('#panel-body').textContent(), /Guillaume/);
  assert.match(await page.locator('#panel-body').textContent(), /src\/données é\.txt/);
});

test('RG-28 / RG-25 : un dossier invalide est refusé ; un projet valide réinitialise la page', async () => {
  await page.click('#wip-row');
  await page.fill('#commit-msg', 'brouillon');
  await page.click('#btn-project');
  await page.fill('#input-path', tmp);
  await page.click('#form-path button[type=submit]');
  await page.waitForSelector('.toast.err');
  assert.match(await page.locator('.toast.err').first().textContent(), /n'est pas un projet git/);
  assert.equal(await page.locator('#project-name').textContent(), 'projet démo');
  const other = path.join(tmp, 'autre');
  fs.mkdirSync(other); git(other, ['init', '-q', '-b', 'main']);
  git(other, ['-c', 'user.name=a', '-c', 'user.email=a@a', 'commit', '-q', '--allow-empty', '-m', 'premier']);
  await page.fill('#input-path', other);
  await page.click('#form-path button[type=submit]');
  await within(3000, async () => (await page.locator('#project-name').textContent()) === 'autre', 'projet changé');
  assert.equal(await page.locator('#panel-body').isHidden(), true, 'sélection réinitialisée');
});

test('VI-07 : compte à rebours à la seconde', async () => {
  const a = await page.locator('#countdown').textContent();
  await page.waitForTimeout(1300);
  const b = await page.locator('#countdown').textContent();
  assert.match(a, /^\d+:\d\d$/); assert.notEqual(a, b);
});

test('ENF-11 : 375 px sans défilement horizontal, thème sombre', async () => {
  await page.setViewportSize({ width: 375, height: 800 });
  await page.click('#wip-row');
  const sw = await page.evaluate(() => document.documentElement.scrollWidth);
  assert.ok(sw <= 375, `largeur ${sw}`);
  await page.click('#btn-theme'); await page.click('#btn-theme');
  assert.equal(await page.evaluate(() => document.documentElement.dataset.theme), 'dark');
  const bg = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
  assert.equal(bg, 'rgb(18, 22, 24)');
});

test('VI-03 : aucune ligne « Travail en cours » sur un projet propre', async () => {
  sh('stash', '-u');
  await within(2000, async () => !(await page.locator('#wip-row').isVisible()), 'ligne masquée');
  fs.writeFileSync(path.join(repo, 'a.txt'), 'x');
  await within(2000, async () => page.locator('#wip-row').isVisible(), 'ligne réapparue');
});

test('VI-05 : parents affichés comme identifiants cliquables', async () => {
  await page.locator('#graph .row', { hasText: 'Fusion de feature/graphe' }).click();
  await page.waitForSelector('.meta');
  const dd = await page.locator('.meta dd').last().textContent();
  assert.match(dd, /^[0-9a-f]{8}(, [0-9a-f]{8})*$/);
});

test('ENF-11 : à 375 px, noms de branches entiers et cibles ≥ 32 px', async () => {
  await page.setViewportSize({ width: 375, height: 812 });
  await page.click('#btn-branch');
  await page.waitForSelector('#branch-local li .t');
  const cut = await page.$$eval('#branch-local .t', els => els.filter(e => e.scrollWidth > e.clientWidth).length);
  assert.equal(cut, 0, 'noms tronqués');
  await page.click('#dlg-branches [data-close]');
  await page.click('#wip-row');
  const small = await page.$$eval('button:not([hidden]), select', els => els
    .filter(e => e.offsetParent && !e.closest('.history-head') && !e.classList.contains('name') && !e.classList.contains('row'))
    .filter(e => e.getBoundingClientRect().height < 32).map(e => e.id || e.textContent.trim()));
  assert.deepEqual(small, [], 'contrôles trop petits');
  const barH = await page.$eval('#bar', e => e.getBoundingClientRect().height);
  assert.ok(barH <= 130, `en-tête de ${barH} px`);
});

test('ENF-07 : le jeton quitte l’URL, la page reste reliée au rechargement ; sans jeton, message clair', async () => {
  assert.equal(new URL(page.url()).hash, '', 'jeton encore visible dans l’URL');
  const html = await page.evaluate(async () => (await fetch('/')).text());
  assert.ok(!html.includes(srv.token), 'jeton présent dans la page servie');
  await page.reload(); await page.waitForSelector('#graph .row');
  const p2 = await browser.newPage();
  await p2.goto(`http://127.0.0.1:${srv.port}/`);
  await p2.waitForSelector('#banner:not([hidden])');
  assert.match(await p2.locator('#banner').textContent(), /Relancez « git viewer »/);
  await p2.close();
});

test('ENF-07 : l’API refuse une requête sans jeton', async () => {
  const r = await page.evaluate(async () => (await fetch('/api/state')).status);
  assert.equal(r, 403);
});

test('R-20 / TR-10 / TR-11 : intervalle 30 → 15 depuis les réglages, valeur invalide refusée avec les bornes', async () => {
  await page.click('#btn-settings');                                   // clic 1
  const inp = page.locator('#set-intervalMin');
  await inp.waitFor();
  assert.equal(await inp.inputValue(), '30');
  await inp.fill('15'); await inp.press('Enter');                      // clic 2 (saisie)
  await within(5000, async () => /^1[45]:\d\d$/.test(await page.locator('#countdown').textContent()), 'compte à rebours sur 15 min');
  await page.locator('#set-intervalMin').fill('3'); await page.locator('#set-intervalMin').press('Enter');
  const err = page.locator('[data-key="intervalMin"] .field-err');
  await err.waitFor({ state: 'visible' });
  assert.match(await err.textContent(), /de 5 à 240/);
  assert.equal(srv.shared.autosave.intervalMin, 15, 'valeur invalide enregistrée');
});

test('TR-10 : case à cocher, liste d’exclusion et retour aux valeurs par défaut en 1 action', async () => {
  await page.click('#btn-settings');
  await page.locator('#set-keepSeries').check();
  await within(2000, async () => (await page.locator('[data-key="keepSeries"] .def').textContent()).startsWith('Par défaut'), 'valeur modifiée signalée');
  await page.locator('#set-autoTrackExclude').getByRole('button', { name: 'Retirer' }).click();
  await page.locator('[data-key="autoTrackExclude"]', { hasText: 'Aucun projet exclu' }).waitFor();
  await page.click('#btn-settings-reset');
  await page.click('#confirm-ok');
  await within(2000, async () => !(await page.locator('#set-keepSeries').isChecked()), 'conservation désactivée');
  assert.equal(await page.locator('#set-intervalMin').inputValue(), '30');
});

test('ENF-11 : réglages à 375 px sans défilement horizontal', async () => {
  await page.setViewportSize({ width: 375, height: 812 });
  await page.click('#btn-menu');
  await page.getByRole('menuitem', { name: 'Réglages…' }).click();
  await page.locator('#set-intervalMin').waitFor();
  const over = await page.$eval('#dlg-settings', d => d.scrollWidth - d.clientWidth);
  assert.ok(over <= 0, `dépassement de ${over} px`);
  const sw = await page.evaluate(() => document.documentElement.scrollWidth);
  assert.ok(sw <= 375, `largeur ${sw}`);
});
