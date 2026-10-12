// Bullpen's app icon, drawn in code: an isometric pixel-art office building on its plot of land.
// Generates the art grids; Tools/icon/render.py turns them into PNGs and AppIcon.icns.
// Run with `make icons` (needs node and python3; the generated files are committed).

// ---- Pixel canvas ----------------------------------------------------------
function Canvas(w, h) { this.w = w; this.h = h; this.px = new Array(w * h).fill(null); }
Canvas.prototype.set = function (x, y, c) { if (x >= 0 && y >= 0 && x < this.w && y < this.h && c) this.px[y * this.w + x] = c; };
Canvas.prototype.rect = function (x, y, w, h, c) { for (let j = y; j < y + h; j++) for (let i = x; i < x + w; i++) this.set(i, j, c); };
Canvas.prototype.blit = function (src, ox, oy) {
  for (let j = 0; j < src.h; j++) for (let i = 0; i < src.w; i++) { const c = src.px[j * src.w + i]; if (c) this.set(ox + i, oy + j, c); }
};

// ---- Bullpen palette (same values as the app) -------------------------------
const P = {
  wood: "#9A6B43", woodDark: "#6E4A2C", woodLight: "#B98757", metal: "#B9BEC8", metalDark: "#80858F",
  screen: "#7FD3FF", chair: "#3B4253", chairDark: "#2A2F3C", lampOn: "#FFD86B", cord: "#2E2E35",
  leaf: "#4FA35A", leafDark: "#377A42", pot: "#C0673E", white: "#FFFFFF", ink: "#2A2633", accent: "#FF8A3D",
  wall: "#D6CCB8", floor: "#8C6B52",
};
function look(skin, hair, shirt) {
  const skins = [["#F6D3B3", "#E2B48F"], ["#EDB98A", "#D39A6A"], ["#D08B5B", "#B57148"], ["#AE5D29", "#91481C"], ["#7A4424", "#5E3118"]];
  const hairs = [["#2B1B12", "#1A100A"], ["#5A3825", "#452A1B"], ["#B7793F", "#9A6230"], ["#E5C27A", "#CDA65C"], ["#8C8C8C", "#6E6E6E"], ["#A6402F", "#86301F"]];
  const shade = c => { const n = parseInt(c.slice(1), 16); const f = v => Math.floor(v * 3 / 4).toString(16).padStart(2, "0"); return "#" + f(n >> 16 & 255) + f(n >> 8 & 255) + f(n & 255); };
  return { skin: skins[skin][0], skinShade: skins[skin][1], hair: hairs[hair][0], hairShade: hairs[hair][1], shirt, shirtShade: shade(shirt), eye: "#23202A", mouth: "#9C4A4A" };
}

// Port of CharacterSprite: 18×22 person; poses rest | type | raised | cheer.
function person(L, pose, style, eyesClosed) {
  const c = new Canvas(18, 22);
  c.set(8, 12, L.skinShade); c.set(9, 12, L.skinShade);
  c.rect(4, 13, 10, 9, L.shirt); c.rect(4, 13, 1, 9, L.shirtShade); c.rect(5, 13, 8, 1, L.shirtShade);
  if (style === 1) c.rect(4, 5, 10, 8, L.hairShade);
  c.rect(5, 5, 8, 7, L.skin); c.rect(5, 11, 8, 1, L.skinShade); c.set(4, 8, L.skin); c.set(13, 8, L.skin);
  if (eyesClosed) { c.rect(6, 8, 2, 1, L.skinShade); c.rect(10, 8, 2, 1, L.skinShade); }
  else { c.rect(7, 8, 1, 2, L.eye); c.rect(10, 8, 1, 2, L.eye); }
  c.rect(8, 10, 2, 1, L.mouth);
  c.rect(5, 3, 8, 3, L.hair); c.rect(4, 4, 1, 3, L.hair); c.rect(13, 4, 1, 3, L.hair); c.rect(6, 2, 6, 1, L.hair);
  if (style === 1) { c.rect(4, 7, 1, 5, L.hair); c.rect(13, 7, 1, 5, L.hair); }
  else if (style === 2) c.rect(7, 0, 4, 2, L.hairShade);
  else if (style === 3) for (let x = 5; x <= 12; x += 2) c.set(x, 1, L.hair);
  else c.rect(10, 5, 3, 1, L.hair);
  c.rect(5, 3, 8, 1, L.hairShade);
  const leftDown = () => { c.rect(2, 14, 2, 6, L.shirtShade); c.rect(2, 20, 2, 1, L.skin); };
  const rightDown = () => { c.rect(14, 14, 2, 6, L.shirtShade); c.rect(14, 20, 2, 1, L.skin); };
  if (pose === "rest") { leftDown(); rightDown(); }
  if (pose === "type") { c.rect(3, 15, 2, 4, L.shirtShade); c.rect(5, 18, 2, 1, L.skin); c.rect(13, 15, 2, 4, L.shirtShade); c.rect(11, 19, 2, 1, L.skin); }
  if (pose === "raised") { leftDown(); c.rect(14, 8, 2, 6, L.shirtShade); c.rect(14, 5, 2, 3, L.skin); }
  if (pose === "cheer") { c.rect(2, 7, 2, 7, L.shirtShade); c.rect(2, 4, 2, 3, L.skin); c.rect(14, 7, 2, 7, L.shirtShade); c.rect(14, 4, 2, 3, L.skin); }
  return c;
}
function desk(glow) {
  const c = new Canvas(28, 9);
  c.rect(9, 0, 10, 3, P.metal); c.rect(13, 1, 2, 1, P.white); if (glow) c.rect(9, 0, 10, 1, P.screen);
  c.rect(0, 3, 28, 2, P.woodLight); c.rect(1, 5, 26, 4, P.wood); c.rect(1, 5, 26, 1, P.woodDark); c.rect(12, 6, 4, 1, P.woodDark);
  return c;
}
function chair() { const c = new Canvas(16, 12); c.rect(1, 0, 14, 12, P.chair); c.rect(1, 0, 14, 1, P.chairDark); c.rect(1, 0, 1, 12, P.chairDark); return c; }
function lamp() { const c = new Canvas(10, 12); c.rect(4, 0, 1, 6, P.cord); c.rect(2, 6, 6, 2, P.lampOn); c.rect(1, 8, 8, 2, P.lampOn); c.rect(1, 8, 8, 1, P.metalDark); c.rect(3, 10, 4, 1, P.white); return c; }
function alertBubble() {
  const c = new Canvas(11, 11);
  c.rect(1, 0, 9, 9, P.accent); c.rect(0, 1, 11, 7, P.accent); c.rect(3, 9, 2, 1, P.accent); c.set(2, 10, P.accent);
  c.rect(5, 2, 1, 3, P.white); c.set(5, 6, P.white); return c;
}


// ---- Colour helpers ----------------------------------------------------------
const hx = c => { const n = parseInt(c.slice(1), 16); return [n >> 16 & 255, n >> 8 & 255, n & 255]; };
const toHex = ([r, g, b]) => "#" + [r, g, b].map(v => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, "0")).join("");
const mix = (a, b, t) => { const A = hx(a), B = hx(b); return toHex(A.map((v, i) => v + (B[i] - v) * t)); };
Canvas.prototype.get = function (x, y) { return (x >= 0 && y >= 0 && x < this.w && y < this.h) ? this.px[y * this.w + x] : null; };
Canvas.prototype.blend = function (x, y, c, a) { const cur = this.get(x, y); if (cur) this.set(x, y, mix(cur, c, a)); };
// Light pooling: brightens pixels around a point, falling off with distance.
Canvas.prototype.glow = function (cx, cy, r, c, strength) {
  for (let y = Math.floor(cy - r); y <= cy + r; y++) for (let x = Math.floor(cx - r); x <= cx + r; x++) {
    const d = Math.hypot(x - cx, y - cy); if (d <= r) this.blend(x, y, c, strength * (1 - d / r) ** 1.6);
  }
};
const BAYER = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]];
// Vertical gradient through colour stops, dithered so it reads as pixel art.
function sky(c, stops, y0 = 0, y1 = c.h) {
  for (let y = y0; y < y1; y++) for (let x = 0; x < c.w; x++) {
    const t = (y - y0) / Math.max(1, y1 - y0 - 1) * (stops.length - 1);
    const i = Math.min(stops.length - 2, Math.floor(t)); let f = t - i;
    const q = Math.round(f * 4) / 4; const th = (BAYER[y % 4][x % 4] + .5) / 16;
    f = (f - q) * 4 > th - .5 ? Math.min(1, q + .25) : q;
    c.set(x, y, mix(stops[i], stops[i + 1], f));
  }
}
function bricks(c, x0, y0, w, h, base, dark, light) {
  c.rect(x0, y0, w, h, base);
  for (let y = y0; y < y0 + h; y++) for (let x = x0; x < x0 + w; x++) {
    const row = Math.floor((y - y0) / 2), off = row % 2 ? 2 : 0;
    if ((y - y0) % 2 === 1 && (x - x0 + off) % 4 !== 0) continue;
    if ((y - y0) % 2 === 1) c.set(x, y, dark); else if ((x - x0 + off) % 4 === 0) c.set(x, y, dark);
    if ((x * 7 + y * 13) % 23 === 0) c.set(x, y, light);
  }
}
function starsField(c, n, maxY, seed) { let s = seed; for (let i = 0; i < n; i++) { s = (s * 9301 + 49297) % 233280; const x = s % c.w; s = (s * 9301 + 49297) % 233280; const y = s % maxY; c.set(x, y, i % 3 ? "#CFD6FF" : "#FFF4C7"); } }

const claude = look(1, 1, "#D97A4A"), codex = look(2, 0, "#3E9E7E"), slate = look(0, 3, "#6B7A99"), violet = look(3, 5, "#8E6BC2"), mustard = look(4, 2, "#D9A441");
const crew = [claude, codex, slate, violet, mustard];

// Small person (5×7) for 64-pixel scenes: hair, face with eyes, shirt, arms.
function mini(c, x, y, L, pose) {
  c.rect(x + 1, y, 3, 1, L.hair); c.rect(x, y + 1, 5, 1, L.hair);
  c.rect(x + 1, y + 2, 3, 2, L.skin); c.set(x + 1, y + 2, L.eye); c.set(x + 3, y + 2, L.eye);
  c.rect(x, y + 4, 5, 3, L.shirt); c.rect(x, y + 4, 1, 3, L.shirtShade);
  if (pose === "raised") { c.rect(x + 5, y + 1, 1, 4, L.shirtShade); c.set(x + 5, y, L.skin); }
}
// A lit office window at 64-scale: back wall, lamp pool, person at a laptop.
function officeWindow(c, x, y, w, h, L, opts = {}) {
  const wallTop = opts.alert ? "#FFC28A" : "#FFE6A6", wallBottom = opts.alert ? "#F2925A" : "#F2C46A";
  for (let j = 0; j < h; j++) c.rect(x, y + j, w, 1, mix(wallTop, wallBottom, j / (h - 1)));
  c.set(x + Math.floor(w / 2), y, "#3A2E28"); c.rect(x + Math.floor(w / 2) - 1, y + 1, 3, 1, "#FFF6D5");
  if (L) { mini(c, x + Math.floor(w / 2) - 2, y + 2, L, opts.alert ? "raised" : null); c.rect(x + 1, y + h - 2, w - 2, 1, "#8A5A3A"); c.rect(x + Math.floor(w / 2) - 1, y + h - 3, 3, 1, opts.typing ? P.screen : P.metal); }
  c.rect(x, y + h - 1, w, 1, "#5E3B26");
}


// ---- Isometric engine -----------------------------------------------------------
// World: x grows right-down, y grows left-down, z up. Screen: sx = ox + x - y, sy = oy + (x + y) / 2 - z.
function inPoly(px, py, poly) {
  let inside = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const [xi, yi] = poly[i], [xj, yj] = poly[j];
    if ((yi > py) !== (yj > py) && px < (xj - xi) * (py - yi) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}
function Iso(c, ox, oy) { this.c = c; this.ox = ox; this.oy = oy; }
Iso.prototype.p = function (x, y, z) { return [this.ox + x - y, this.oy + (x + y) / 2 - z]; };
Iso.prototype.fill = function (poly, shade) {
  const xs = poly.map(p => p[0]), ys = poly.map(p => p[1]);
  for (let py = Math.floor(Math.min(...ys)); py <= Math.ceil(Math.max(...ys)); py++)
    for (let px = Math.floor(Math.min(...xs)); px <= Math.ceil(Math.max(...xs)); px++)
      if (inPoly(px + .5, py + .5, poly)) { const col = shade(px + .5, py + .5); if (col) this.c.set(px, py, col); }
};
// Face on the plane y = Y (seen on the left): shade(x, z).
Iso.prototype.left = function (x0, x1, Y, z0, z1, shade) {
  const P = (x, z) => this.p(x, Y, z);
  this.fill([P(x0, z0), P(x1, z0), P(x1, z1), P(x0, z1)], (sx, sy) => {
    const x = sx - this.ox + Y, z = this.oy + (x + Y) / 2 - sy; return shade(x, z);
  });
};
// Face on the plane x = X (seen on the right): shade(y, z).
Iso.prototype.right = function (X, y0, y1, z0, z1, shade) {
  const P = (y, z) => this.p(X, y, z);
  this.fill([P(y0, z0), P(y1, z0), P(y1, z1), P(y0, z1)], (sx, sy) => {
    const y = this.ox + X - sx, z = this.oy + (X + y) / 2 - sy; return shade(y, z);
  });
};
// Top face at height Z: shade(x, y).
Iso.prototype.top = function (x0, x1, y0, y1, Z, shade) {
  const P = (x, y) => this.p(x, y, Z);
  this.fill([P(x0, y0), P(x1, y0), P(x1, y1), P(x0, y1)], (sx, sy) => {
    const a = sx - this.ox, b = 2 * (sy - this.oy + Z); return shade((a + b) / 2, (b - a) / 2);
  });
};
Iso.prototype.box = function (x0, y0, z0, w, d, h, top, left, right) {
  this.left(x0, x0 + w, y0 + d, z0, z0 + h, typeof left === "function" ? left : () => left);
  this.right(x0 + w, y0, y0 + d, z0, z0 + h, typeof right === "function" ? right : () => right);
  this.top(x0, x0 + w, y0, y0 + d, z0 + h, typeof top === "function" ? top : () => top);
};

const H = (a, b, c = 0) => { let h = (a * 374761393 + b * 668265263 + c * 2147483647) >>> 0; h = (h ^ (h >>> 13)) * 1274126177 >>> 0; return (h ^ (h >>> 16)) >>> 0; };

// ---- The building, parametrised by a style -------------------------------------------
const SZ = 112, W = 24, D = 18, FLOOR = 9, FLOORS = 4, HT = FLOOR * (FLOORS + 1) + 2;

function windowPixel(st, face, x, z, idx, floor) {
  // x: position along the facade, z: height. Returns a colour or null (= wall).
  if (z < FLOOR) return null;
  const f = Math.floor((z - FLOOR) / FLOOR), zz = (z - FLOOR) - f * FLOOR;
  if (f >= FLOORS || zz < 2 || zz >= 8) return null;
  const col = Math.floor((x - 1) / 6), wx = Math.floor(x - 1 - col * 6);
  if (x < 2 || wx < 0 || wx > 3 || col * 6 + 6 > (face === "L" ? W : D) + 1) return null;
  const wz = 7 - Math.floor(zz);                      // 0 = top row of the window
  const h = H(col, f, face === "L" ? 1 : 2);
  const alert = face === "L" && f === 3 && col === 2;
  const lit = alert || (h % 100) < st.litRatio * 100;
  if (wx === 3 || wz === 5) return st.frame;          // frame/sill
  if (!lit) return wz % 2 ? st.winDark : st.winDarkLine;
  const person = (h >> 8) % 3 !== 0 ? crew[(h >> 4) % 5] : null;
  const base = alert ? st.alertWin : mix(st.winTop, st.winBottom, wz / 4);
  if (st.reflect && !alert && (wx + wz) % 4 === 0) return st.reflect;
  if (!person || st.noPeople) return base;
  if (wz === 1 && wx >= 1) return person.hair;
  if (wz === 2 && wx >= 1) return person.skin;
  if (wz >= 3 && wx >= 1) return person.shirt;
  return base;
}

function wall(st, face, x, z) {
  const b = face === "L" ? st.brick : st.brickSide;
  if (z >= HT - 2) return b.cornice;
  if (Math.abs(z - FLOOR) < .5 || (z > FLOOR && Math.floor(z - FLOOR) % FLOOR === 0)) return b.ledge;
  if (z < FLOOR) {                                      // stone ground floor
    if (st.flat) return b.base;
    return (Math.floor(x) % 5 === 0) ? b.dark : b.stone;
  }
  if (st.flat) return b.base;
  const row = Math.floor(z / 2), xi = Math.floor(x) + (row % 2) * 2;
  if (Math.floor(z) % 2 === 1 || xi % 4 === 0) return b.dark;
  return (H(Math.floor(x), Math.floor(z)) % 17 === 0) ? b.light : b.base;
}

function storefront(st, face, x, z) {
  if (face !== "L" || z >= FLOOR - 1 || z < 1) return null;
  if (x >= 11 && x < 15) return z > 6 ? st.awning : (x >= 12 && x < 14 ? st.doorLight : st.frame);   // door
  if ((x >= 3 && x < 9) || (x >= 17 && x < 23)) {
    if (z > 6.5) return st.awning;
    if (z < 2) return st.frame;
    return st.shop;
  }
  return null;
}

function drawScene(st) {
  const c = new Canvas(SZ, SZ);
  sky(c, st.sky, 0, SZ);
  if (st.stars) starsField(c, 30, 50, 5);
  if (st.moon) { c.glow(st.moon[0], st.moon[1], 12, "#FFF1C9", .3); c.rect(st.moon[0] - 3, st.moon[1] - 4, 7, 9, "#FFF4D8"); c.rect(st.moon[0] - 4, st.moon[1] - 3, 9, 7, "#FFF4D8"); c.set(st.moon[0] - 1, st.moon[1] - 1, "#E8DDBF"); c.set(st.moon[0] + 2, st.moon[1] + 1, "#E8DDBF"); }
  if (st.sun) { c.glow(st.sun[0], st.sun[1], 16, "#FFF3B0", .45); c.rect(st.sun[0] - 4, st.sun[1] - 4, 9, 9, "#FFF0A8"); }
  (st.clouds || []).forEach(([x, y, w]) => { c.rect(x, y, w, 3, st.cloud); c.rect(x + 2, y - 2, w - 5, 2, st.cloud); c.rect(x + 1, y + 3, w - 2, 1, st.cloudShade); });
  const iso = new Iso(c, 56, 70);
  const G0 = -8, G1x = W + 8, G1y = D + 8;

  // Ground block: soil sides, then grass/pavement top.
  iso.left(G0, G1x, G1y, -7, 0, (x, z) => z > -1.2 ? st.grassEdge : mix(st.soil[0], st.soil[1], (-z) / 7) && ((H(Math.floor(x), Math.floor(z)) % 13 === 0) ? st.stone : mix(st.soil[0], st.soil[1], (-z) / 7)));
  iso.right(G1x, G0, G1y, -7, 0, (y, z) => z > -1.2 ? st.grassEdgeSide : ((H(Math.floor(y), Math.floor(z), 3) % 13 === 0) ? st.stone : mix(st.soilSide[0], st.soilSide[1], (-z) / 7)));
  iso.top(G0, G1x, G0, G1y, 0, (x, y) => {
    const nearBuilding = x > -4 && x < W + 4 && y > -4 && y < D + 4;
    const path = x > 10 && x < 16 && y >= D;
    if (nearBuilding || path) return ((Math.floor(x) + Math.floor(y)) % 4 === 0 && !st.flat) ? st.paveLine : st.pave;
    if (st.flat) return st.grass[0];
    const n = H(Math.floor(x), Math.floor(y), 7) % 9;
    return n === 0 ? st.grass[2] : n < 3 ? st.grass[1] : st.grass[0];
  });
  if (st.wet) iso.top(G0, G1x, D + 4, G1y, 0.01, (x, y) => (H(Math.floor(x), Math.floor(y), 9) % 7 === 0) ? st.puddle : null);

  // Trees and bench behind/left of the building (drawn before it).
  const tree = (x, y) => {
    const [sx, sy] = iso.p(x, y, 0);
    c.rect(Math.round(sx), Math.round(sy) - 5, 1, 5, st.trunk);
    for (let j = -6; j <= 6; j++) for (let i = -5; i <= 5; i++) {
      if (i * i / 30 + j * j / 40 > 1) continue;
      const shade = (i - j) > 2 ? st.leafLight : (i + j) > 3 ? st.leafDark : st.leaf;
      c.set(Math.round(sx) + i, Math.round(sy) - 11 + j, (H(i + 9, j + 9, x) % 11 === 0 && !st.flat) ? st.leafLight : shade);
    }
  };
  tree(-6, 4); tree(W + 5, -5);

  // Building.
  const B = st;
  iso.left(0, W, D, 0, HT, (x, z) => storefront(st, "L", x, z) || windowPixel(st, "L", x, z) || wall(st, "L", x, z));
  iso.right(W, 0, D, 0, HT, (y, z) => windowPixel(st, "R", D - y, z) || wall(st, "R", D - y, z));
  iso.top(0, W, 0, D, HT, (x, y) => (x < 1.2 || y < 1.2 || x > W - 1.2 || y > D - 1.2) ? st.rim : ((Math.floor(x) + Math.floor(y)) % 6 === 0 && !st.flat ? st.roofLine : st.roof));

  // Rooftop: water tower, AC units, antenna, skylight.
  iso.box(4, 3, HT, 7, 7, 3, st.metalTop, st.metalL, st.metalR);                                    // tower base
  for (const [lx, ly] of [[5, 4], [10, 4], [5, 9], [10, 9]]) iso.box(lx, ly, HT + 3, 1, 1, 3, st.wood, st.woodDark, st.woodDark);
  iso.box(4, 3, HT + 6, 7, 7, 8, st.tankTop, (x, z) => (Math.floor(z) % 3 === 0 ? st.woodDark : st.wood), (y, z) => (Math.floor(z) % 3 === 0 ? st.woodDarker : st.woodDark));
  iso.box(4.5, 3.5, HT + 14, 6, 6, 2, st.tankTop, st.woodDark, st.woodDarker);
  iso.box(15, 11, HT, 5, 4, 3, st.metalTop, st.metalL, st.metalR);
  iso.box(19, 4, HT, 4, 4, 2, st.metalTop, st.metalL, st.metalR);
  { const [ax, ay] = iso.p(21, 15, HT); c.rect(Math.round(ax), Math.round(ay) - 14, 1, 14, "#2A2A33"); c.rect(Math.round(ax) - 2, Math.round(ay) - 10, 5, 1, "#2A2A33");
    c.set(Math.round(ax), Math.round(ay) - 15, "#FF4D4D"); if (st.glow) c.glow(Math.round(ax), Math.round(ay) - 15, 4, "#FF6A6A", .6); }
  if (st.sign) { // neon sign hanging on the right face
    iso.right(W + 0.5, 6, 12, 16, 34, (y, z) => (y > 6.6 && y < 11.4 && z > 16.6 && z < 33.4) ? ((Math.floor(z) % 4 === 1) ? st.signLetter : st.sign) : st.signFrame);
    const [nx, ny] = iso.p(W, 9, 25); c.glow(nx, ny, 12, st.sign, .25);
  }

  // Street furniture in front.
  iso.box(G1x - 7, D + 5, 0, 5, 1.2, 1.4, st.wood, st.woodDark, st.woodDark);                     // bench
  { const [lx, ly] = iso.p(2, D + 6, 0); c.rect(Math.round(lx), Math.round(ly) - 15, 1, 15, "#24242C"); c.rect(Math.round(lx) - 1, Math.round(ly) - 16, 3, 2, "#24242C");
    c.set(Math.round(lx), Math.round(ly) - 14, st.lampLight); if (st.glow) { c.glow(Math.round(lx), Math.round(ly) - 13, 10, "#FFE09A", st.glow); c.glow(Math.round(lx), Math.round(ly) + 1, 8, "#FFE09A", st.glow * .8); } }
  { const [px, py] = iso.p(19, D + 4, 0); mini(c, Math.round(px) - 2, Math.round(py) - 8, crew[1]); }
  tree(W + 7, D + 3);
  if (st.glow) {                                                       // light spilling from the shop
    for (const x of [6, 13, 20]) { const [gx, gy] = iso.p(x, D + 2, 0); c.glow(gx, gy, 7, "#FFD98A", st.glow * .7); }
    const [ex, ey] = iso.p(15, D, 39); c.glow(ex, ey, 9, "#FF9A5A", .35);
  }
  if (st.rain) for (let i = 0; i < 140; i++) { const x = H(i, 1) % SZ, y = H(i, 2) % SZ; c.blend(x, y, "#BFD3FF", .5); c.blend(x - 1, y + 1, "#BFD3FF", .35); }
  if (st.snow) for (let i = 0; i < 90; i++) { const x = H(i, 3) % SZ, y = H(i, 4) % SZ; c.set(x, y, "#FFFFFF"); }
  return c;
}

const brickWarm = { base: "#B4603F", dark: "#934A2F", light: "#CB7552", ledge: "#E2C9A6", cornice: "#7A3F28", stone: "#C9B79C" };
const brickWarmSide = { base: "#7E4129", dark: "#66331F", light: "#8E4C31", ledge: "#A8927A", cornice: "#552B1B", stone: "#8E7F6C" };
const common = {
  brick: brickWarm, brickSide: brickWarmSide, frame: "#4A2D1E", winDark: "#2D2B48", winDarkLine: "#3A3858",
  winTop: "#FFE8A6", winBottom: "#F2B65E", alertWin: "#FF9A5A", roof: "#5B4A44", roofLine: "#4E3F3A", rim: "#8A766A",
  metalTop: "#C5CAD3", metalL: "#9AA0AB", metalR: "#767C87", wood: "#8E6240", woodDark: "#6E4A2E", woodDarker: "#553820", tankTop: "#5E4030",
  pave: "#B9B2A8", paveLine: "#A39C92", grass: ["#5E9C4C", "#4E8A40", "#78B35E"], grassEdge: "#5E9C4C", grassEdgeSide: "#477838",
  soil: ["#8A6244", "#5A3E2A"], soilSide: ["#6A4A33", "#43301F"], stone: "#9A8C7C",
  trunk: "#5A3A26", leaf: "#4F9A4A", leafDark: "#3A7A38", leafLight: "#77BC62",
  shop: "#FFD98A", doorLight: "#FFE9B0", awning: "#C2483C", lampLight: "#FFE8A0", litRatio: .62, glow: .3,
};
const styles = [
  { key: "S1", name: "Atardecer", idea: "La R1 hecha diorama: edificio en volumen sobre su parcela, cielo de atardecer, ventanas encendiéndose y la farola ya prendida.",
    ...common, sky: ["#241F52", "#53397A", "#B4567A", "#F2A06A", "#F9C98A"], stars: true, moon: [92, 16] },
  { key: "S2", name: "Noche", idea: "Casi todas las oficinas encendidas, luna, estrellas y charcos de luz en la acera. El «!» naranja se ve de lejos.",
    ...common, sky: ["#0E1230", "#1C2456", "#2E3270"], stars: true, moon: [18, 16], litRatio: .82, glow: .45,
    grass: ["#2F5A3A", "#28503A", "#3E6E48"], grassEdge: "#2F5A3A", grassEdgeSide: "#234430", pave: "#6C6A7A", paveLine: "#5C5A6A",
    leaf: "#2E5E3E", leafDark: "#224A30", leafLight: "#3E7650", soil: ["#4A3A34", "#2A2028"], soilSide: ["#3A2E2A", "#211A20"],
    brick: { ...brickWarm, base: "#8E4B34", dark: "#733A27", light: "#A15A40", ledge: "#B9A288", stone: "#9C8E7C" },
    brickSide: { ...brickWarmSide, base: "#5E3020", dark: "#4A2518", light: "#6A3826", ledge: "#7E6E5E", stone: "#6E6458" } },
  { key: "S3", name: "Día", idea: "A plena luz: cielo azul, nubes y sol. Las ventanas reflejan el cielo y dejan ver a la gente; hierba viva y árboles.",
    ...common, sky: ["#5FAEE6", "#8CC8F0", "#C8E6F8"], sun: [92, 16], clouds: [[8, 22, 14], [72, 40, 12]], cloud: "#FFFFFF", cloudShade: "#DCEBF6",
    winTop: "#BFE2F7", winBottom: "#7FB3D9", reflect: "#E8F6FF", litRatio: .9, glow: 0, shop: "#BFE2F7", doorLight: "#9CCAE8" },
  { key: "S4", name: "Lluvia de noche", idea: "Noche de lluvia: cortina de agua, acera mojada con charcos que reflejan la luz y el edificio como refugio cálido.",
    ...common, sky: ["#141A2E", "#25304A", "#3A4560"], litRatio: .75, glow: .5, rain: true, wet: true, puddle: "#FFD98A",
    grass: ["#2E4A3C", "#263F33", "#3A5A48"], grassEdge: "#2E4A3C", grassEdgeSide: "#203629", pave: "#4E5468", paveLine: "#3E4458",
    leaf: "#2A4A3A", leafDark: "#1E3A2C", leafLight: "#386050", soil: ["#3A3236", "#221C22"], soilSide: ["#2E282C", "#1A161A"] },
  { key: "S5", name: "Nieve", idea: "Invierno al anochecer: tejado y parcela nevados, árboles blancos y nieve cayendo. Muy acogedor con las luces cálidas.",
    ...common, sky: ["#2A2F5C", "#5A5F94", "#A9A6C9"], stars: true, snow: true, litRatio: .7, glow: .4,
    grass: ["#EEF2FA", "#DDE4F2", "#FFFFFF"], grassEdge: "#F4F7FC", grassEdgeSide: "#C9D2E6", pave: "#C7CEDD", paveLine: "#B3BBCC",
    roof: "#F2F5FB", roofLine: "#DDE3EF", rim: "#FFFFFF", tankTop: "#F4F7FC",
    leaf: "#E6ECF6", leafDark: "#BFC9DC", leafLight: "#FFFFFF" },
  { key: "S6", name: "Neón", idea: "Noche urbana con un cartel de neón en el lateral. Contraste fuerte y colores saturados; la más llamativa en el Dock.",
    ...common, sky: ["#0A0820", "#1E0F3A", "#3A1450"], stars: true, litRatio: .7, glow: .45,
    sign: "#FF4FB4", signLetter: "#FFD1F0", signFrame: "#2A1A3A",
    winTop: "#7FF3FF", winBottom: "#4AB8E8", shop: "#FF8FD8", awning: "#7A2AB0", doorLight: "#B8F6FF",
    grass: ["#1E3040", "#18283A", "#26405A"], grassEdge: "#1E3040", grassEdgeSide: "#142233", pave: "#3A3456", paveLine: "#2E2846",
    leaf: "#1F4A5A", leafDark: "#173A48", leafLight: "#2A6878", soil: ["#2A2034", "#160F20"], soilSide: ["#201A2C", "#100A18"],
    brick: { ...brickWarm, base: "#5A3A6A", dark: "#46294F", light: "#6E4A80", ledge: "#9A82B0", cornice: "#2E1E3A", stone: "#7A6A90" },
    brickSide: { ...brickWarmSide, base: "#3A2546", dark: "#2E1C38", light: "#46304F", ledge: "#5E4E72", cornice: "#1E1428", stone: "#4E4262" } },
];
// The app icon (S1) and the seasonal Dock icons (S2 Halloween, S5 Christmas).
const chosen = { S1: "AppIcon", S2: "AppIcon-halloween", S5: "AppIcon-christmas" };
const out = styles.filter(st => chosen[st.key]).map(st => {
  const art = drawScene(st);
  return { key: chosen[st.key], bg: [st.sky[0], st.sky[st.sky.length - 1]], w: art.w, h: art.h, px: art.px };
});
require("fs").writeFileSync(process.argv[2] || "icon-art.json", JSON.stringify(out));
