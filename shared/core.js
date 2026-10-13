// Game rules shared by the page and the Supabase server functions, so both always agree.
// Works as a plain <script> in the browser and as a side-effect import on the server.

function norm(s){ return String(s).toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[^a-z0-9]+/g, " ").trim(); }
function side(c){ return c.ally === true ? "Ally" : c.ally === false ? "Enemy" : "Neutral"; }
const STOP = new Set(["and","of","the","from","in","to","a","an","on","with","for","by"]);
function words(s){ return norm(s).split(" ").filter(w => w && !STOP.has(w)); }

function listCompare(a, b){
  const A = new Set(a.map(norm)), B = new Set(b.map(norm));
  if (A.size === B.size && [...A].every(x => B.has(x))) return "g";
  return [...A].some(x => B.has(x)) ? "o" : "r";
}

// how a guess g compares with the answer s, cell by cell
function compare(g, s){
  const affs = new Set(s.affiliation.map(norm));
  const named = [g.user, g.stand, ...g.ua].some(n => affs.has(norm(n)));
  const pg = parseInt(g.part, 10), ps = parseInt(s.part, 10);
  const sWords = new Set(s.ability.flatMap(words));
  return {
    user: g.id === s.id || norm(g.user) === norm(s.user) ? "g" : named ? "o" : "r",
    stand: g.id === s.id || norm(g.stand) === norm(s.stand) ? "g" : named ? "o" : "r",
    gender: g.gender === s.gender ? "g" : "r",
    ability: listCompare(g.ability, s.ability),
    abilityMarks: g.ability.map(a => words(a).some(w => sWords.has(w))),
    type: listCompare(g.type, s.type),
    side: side(g) === side(s) ? "g" : "r",
    affiliation: (g.affiliation.length === 0 && s.affiliation.length === 0) ? "g" : listCompare(g.affiliation, s.affiliation),
    part: pg === ps ? "g" : "r",
    arrow: pg === ps ? "" : (ps > pg ? "↑" : "↓")
  };
}

// every part in play has the same chance, then every character within that part; never the previous answer
function pickSecret(p, prev){
  const byPart = {};
  for (const c of p) (byPart[c.part] = byPart[c.part] || []).push(c);
  const inPlay = Object.keys(byPart);
  let next;
  do {
    const list = byPart[inPlay[Math.floor(Math.random() * inPlay.length)]];
    next = list[Math.floor(Math.random() * list.length)];
  } while (p.length > 1 && prev && next.id === prev.id);
  return next;
}

Object.assign(globalThis, { norm, side, words, listCompare, compare, pickSecret });
