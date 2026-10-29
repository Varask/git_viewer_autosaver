/* git viewer — disposition et dessin du graphe (VI-01, VI-02, ADR-11).
   La chaîne des premiers parents de la branche principale occupe toujours la colonne 0. */
(function () {
  'use strict';
  const ROW = 30, LANE = 14, PAD = 11, MAX_W = 280;
  const NS = 'http://www.w3.org/2000/svg';

  function layout(commits, mainSha) {
    const idx = new Map();
    commits.forEach((c, i) => idx.set(c.h, i));
    const main = new Set();
    let m = mainSha;
    while (m && idx.has(m) && !main.has(m)) { main.add(m); m = commits[idx.get(m)].p[0]; }
    const reserved = main.size > 0;
    const lanes = [reserved ? mainSha : null];
    const firstFree = () => {
      for (let j = reserved ? 1 : 0; j < lanes.length; j++) if (lanes[j] == null) return j;
      lanes.push(null); return lanes.length - 1;
    };
    const rows = [];
    let width = 1;
    for (let i = 0; i < commits.length; i++) {
      const c = commits[i];
      const top = lanes.slice();
      const incoming = [];
      top.forEach((s, j) => { if (s === c.h) incoming.push(j); });
      let col;
      if (main.has(c.h)) col = 0;
      else if (incoming.length) {
        const side = incoming.filter(j => !(reserved && j === 0));
        col = side.length ? Math.min(...side) : firstFree();
      } else col = firstFree();
      for (const j of incoming) lanes[j] = null;
      lanes[col] = null;

      const parents = [];
      c.p.forEach((p, k) => {
        if (reserved && main.has(p)) {
          if (main.has(c.h) && k === 0) lanes[0] = p;
          parents.push({ lane: 0, out: false });
          return;
        }
        const existing = lanes.indexOf(p);
        if (existing >= 0) { parents.push({ lane: existing, out: !idx.has(p) }); return; }
        const target = (k === 0 && lanes[col] == null && !(reserved && col === 0)) ? col : firstFree();
        lanes[target] = p;
        parents.push({ lane: target, out: !idx.has(p) });
      });
      while (lanes.length > 1 && lanes[lanes.length - 1] == null) lanes.pop();
      rows.push({ col, top, incoming, parents, bottom: lanes.slice() });
      width = Math.max(width, top.length, lanes.length, col + 1);
    }
    return { rows, width, main };
  }

  const x = j => PAD + j * LANE;
  const color = j => `var(--lane-${j % 8})`;

  function path(d, cls, stroke) {
    const p = document.createElementNS(NS, 'path');
    p.setAttribute('d', d);
    if (cls) p.setAttribute('class', cls);
    p.setAttribute('stroke', stroke);
    return p;
  }
  function seg(x1, y1, x2, y2) {
    if (x1 === x2) return `M${x1} ${y1}V${y2}`;
    const my = (y1 + y2) / 2;
    return `M${x1} ${y1}C${x1} ${my} ${x2} ${my} ${x2} ${y2}`;
  }

  function draw(svg, commits, lay, headSha) {
    while (svg.firstChild) svg.removeChild(svg.firstChild);
    const w = Math.min(MAX_W, PAD * 2 + (lay.width - 1) * LANE);
    svg.setAttribute('width', String(w));
    svg.setAttribute('height', String(commits.length * ROW));
    const edges = document.createElementNS(NS, 'g');
    const nodes = document.createElementNS(NS, 'g');
    lay.rows.forEach((r, i) => {
      const c = commits[i];
      const y0 = i * ROW, yc = y0 + ROW / 2, y1 = y0 + ROW;
      r.top.forEach((s, j) => {
        if (s == null || s === c.h) return;
        if (r.bottom[j] === s) edges.appendChild(path(`M${x(j)} ${y0}V${y1}`, '', color(j)));
      });
      r.incoming.forEach(j => edges.appendChild(path(seg(x(j), y0, x(r.col), yc), '', color(Math.max(j, r.col)))));
      r.parents.forEach(p => {
        const cls = c.auto ? 'auto' : '';
        edges.appendChild(path(seg(x(r.col), yc, x(p.lane), y1), cls, color(Math.max(p.lane, r.col))));
      });
      const cx = x(r.col);
      if (c.auto) {
        const d = document.createElementNS(NS, 'path');
        d.setAttribute('d', `M${cx} ${yc - 5.5}L${cx + 5.5} ${yc}L${cx} ${yc + 5.5}L${cx - 5.5} ${yc}Z`);
        d.setAttribute('class', 'node auto');
        nodes.appendChild(d);
      } else {
        const n = document.createElementNS(NS, 'circle');
        n.setAttribute('cx', cx); n.setAttribute('cy', yc); n.setAttribute('r', c.p.length > 1 ? 3.6 : 4.6);
        n.setAttribute('class', 'node');
        n.setAttribute('fill', c.p.length > 1 ? 'var(--surface)' : color(r.col));
        n.setAttribute('stroke', color(r.col));
        nodes.appendChild(n);
      }
      if (c.h === headSha) {
        const ring = document.createElementNS(NS, 'circle');
        ring.setAttribute('cx', cx); ring.setAttribute('cy', yc); ring.setAttribute('r', 8);
        ring.setAttribute('class', 'head-ring');
        nodes.appendChild(ring);
      }
    });
    svg.appendChild(edges);
    svg.appendChild(nodes);
    return w;
  }

  window.GTGraph = { layout, draw, ROW, LANE, PAD, MAX_W };
})();
