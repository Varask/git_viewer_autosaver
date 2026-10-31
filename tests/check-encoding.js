// Vérifie l'encodage des fichiers livrés (ENF-11 « 0 accent mal affiché ») :
//  - .ps1 / .psm1 : UTF-8 avec BOM (Windows PowerShell 5.1 lit sinon en ANSI)
//  - .cmd / .vbs  : ASCII pur
//  - www/*        : UTF-8 valide, sans BOM
// Usage : node tests/check-encoding.js [--fix]
'use strict';
const fs = require('fs');
const path = require('path');
const root = path.join(__dirname, '..');
const fix = process.argv.includes('--fix');
const BOM = Buffer.from([0xef, 0xbb, 0xbf]);
let bad = 0;

function walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (['.git', 'node_modules', '.claude', 'test-results'].includes(e.name)) continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p); else check(p);
  }
}
function check(p) {
  const ext = path.extname(p).toLowerCase();
  const buf = fs.readFileSync(p);
  const rel = path.relative(root, p);
  const hasBom = buf.subarray(0, 3).equals(BOM);
  if (ext === '.ps1' || ext === '.psm1') {
    if (!hasBom) {
      if (fix) { fs.writeFileSync(p, Buffer.concat([BOM, buf])); console.log(`corrigé  ${rel} (BOM ajouté)`); }
      else { console.log(`ERREUR   ${rel} : BOM UTF-8 absent`); bad++; }
    }
  } else if (ext === '.cmd' || ext === '.vbs') {
    if (buf.some(b => b > 0x7f)) { console.log(`ERREUR   ${rel} : caractère non ASCII`); bad++; }
  } else if (/viewer[\\/]www/.test(rel)) {
    if (hasBom) { console.log(`ERREUR   ${rel} : BOM inutile`); bad++; }
    try { new TextDecoder('utf-8', { fatal: true }).decode(buf); } catch (e) { console.log(`ERREUR   ${rel} : UTF-8 invalide`); bad++; }
  }
}
walk(root);
console.log(bad ? `${bad} problème(s) d'encodage.` : 'Encodage conforme.');
process.exit(bad ? 1 : 0);
