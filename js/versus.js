// Versus: challenge friends or anyone with a link, with the friends list in the same panel.
// Needs js/online.js and js/friends.js; the board's challenge mode lives in index.html (window.Game).
(function () {
  const Online = window.Online, Game = window.Game, Friends = window.Friends;
  if (!Online || !Game || !Friends) return;
  const POLL_MS = 30000; // the list refreshes when shown, on live pings, on returning to the tab, and every 30 seconds
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const MESSAGES = {
    JJ001: "Pick a username first.",
    JJ006: "That challenge isn't available.",
    JJ007: "This challenge is over.",
    JJ008: "You've already finished this challenge.",
    JJ009: "You can only challenge friends directly. Make a link instead.",
    JJ010: "You have 20 open challenges. Finish or cancel some first.",
    JJ011: "That challenge isn't available any more.",
    JJ012: "That's your own challenge.",
    JJ013: "You already guessed that character.",
    JJ014: "The race hasn't started yet.",
    "28000": "Please sign in again.",
  };
  const message = code => MESSAGES[code] || "Something went wrong. Check your connection and try again.";
  const RULES = {
    async: "You both get the same answer. Fewest guesses wins; same number of guesses, the faster time wins. The other player has 24 hours to accept.",
    race: "You both get the same answer at the same moment, and the first to solve wins. The other player has 10 minutes to join you in the lobby.",
  };
  const esc = s => String(s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const guessWord = n => `${n} ${n === 1 ? "guess" : "guesses"}`;
  const signedIn = () => !!(Online.client && Online.user && Online.profile);
  const linkFor = code => location.href.split(/[?#]/)[0] + "?challenge=" + encodeURIComponent(code);
  const buttons = acts => acts.map(([act, label, main]) => `<button type="button"${main ? ' class="primary"' : ""} data-act="${act}">${label}</button>`).join("");

  // ---------- markup ----------
  const btn = document.createElement("button");
  btn.id = "vsBtn"; btn.className = "acct"; btn.type = "button"; btn.hidden = true;
  btn.setAttribute("aria-haspopup", "dialog");
  btn.innerHTML = 'Versus<span class="badge" hidden></span>';

  const modal = document.createElement("div");
  modal.className = "modal"; modal.id = "vsModal"; modal.hidden = true;
  modal.innerHTML = `
    <div class="modal-panel vs-panel" role="dialog" aria-modal="true" aria-labelledby="vsTitle">
      <button class="modal-x" type="button" aria-label="Close">×</button>
      <h2 id="vsTitle">Versus</h2>
      <div class="tabs" role="tablist" aria-label="Versus">
        <button type="button" role="tab" id="vsTabC" aria-controls="vsPaneC" data-tab="challenges">Challenges<span class="badge" hidden></span></button>
        <button type="button" role="tab" id="vsTabF" aria-controls="vsPaneF" data-tab="friends">Friends<span class="badge" hidden></span></button>
      </div>
      <div role="tabpanel" id="vsPaneC" aria-labelledby="vsTabC">
        <div data-view="list">
          <button class="primary" type="button" data-act="new">New challenge</button>
          <p class="acct-msg" role="status"></p>
          <section data-group="incoming"><h3>Challenges for you</h3><ul></ul></section>
          <section data-group="turn"><h3>Your turn</h3><ul></ul></section>
          <section data-group="waiting"><h3>Waiting for them</h3><ul></ul></section>
          <section data-group="done"><h3>Results</h3><ul></ul></section>
          <p class="acct-hint" data-empty>No challenges yet. Start one, or open a challenge link someone sent you.</p>
        </div>
        <form class="vs-form" data-view="new" novalidate hidden>
          <label>Opponent<select name="opponent"></select></label>
          <fieldset><legend>Game</legend>
            <label class="choice"><input type="radio" name="mode" value="async" checked><span>Take turns<small>Play any time in the next 24 hours</small></span></label>
            <label class="choice"><input type="radio" name="mode" value="race"><span>Live race<small>Right now, at the same moment; first to solve wins</small></span></label>
          </fieldset>
          <fieldset><legend>Parts</legend><div class="vs-parts"></div></fieldset>
          <fieldset><legend>Guesses</legend>
            <label class="choice"><input type="radio" name="limit" value="9" checked> 9 guesses</label>
            <label class="choice"><input type="radio" name="limit" value="none"> No limit</label>
          </fieldset>
          <p class="acct-hint" data-rules></p>
          <div class="acct-row"><button class="primary" type="submit">Make link</button><button type="button" data-act="back">Back</button></div>
          <p class="acct-msg" role="alert"></p>
        </form>
        <div class="vs-made" data-view="made" hidden>
          <p data-made></p>
          <div class="link-row" data-link><input readonly aria-label="Challenge link"><button type="button" data-act="copy">Copy</button></div>
          <div class="acct-row"><button class="primary" type="button" data-act="play">Play now</button><button type="button" data-act="share" hidden>Share</button><button type="button" data-act="done">Done</button></div>
          <p class="acct-msg" role="status"></p>
        </div>
      </div>
      <div role="tabpanel" id="vsPaneF" aria-labelledby="vsTabF" hidden></div>
    </div>`;
  const $m = sel => modal.querySelector(sel);
  const tabs = { challenges: $m("#vsTabC"), friends: $m("#vsTabF") };
  const panes = { challenges: $m("#vsPaneC"), friends: $m("#vsPaneF") };
  const form = $m('[data-view="new"]'), partsBox = $m(".vs-parts");
  const say = (view, text) => { $m(`[data-view="${view}"] .acct-msg`).textContent = text || ""; };

  // what a challenge link shows to the person who opens it
  const invite = document.createElement("div");
  invite.className = "modal"; invite.id = "vsInvite"; invite.hidden = true;
  invite.innerHTML = `
    <div class="modal-panel vs-invite" role="dialog" aria-modal="true" aria-labelledby="vsInviteTitle">
      <button class="modal-x" type="button" aria-label="Close">×</button>
      <h2 id="vsInviteTitle">Challenge!</h2>
      <div data-body></div>
      <div class="acct-row" data-actions></div>
      <p class="acct-msg" role="alert"></p>
    </div>`;
  const $i = sel => invite.querySelector(sel);

  // a live race invite pops up: it can't wait in a list for long
  const toast = document.createElement("div");
  toast.className = "vs-toast"; toast.id = "vsToast"; toast.hidden = true;
  toast.setAttribute("role", "alert");

  let items = [], seen = new Set(), tab = "challenges", view = "list", made = null;
  let pollTimer = null, mounted = false, urlHandled = false, inviteCode = null, toastFor = null;
  const toasted = new Set(); // race invites already shown in the notice (each pops up once)
  const known = new Map(); // each list entry as last seen, to notice when the challenge on the board changes

  // ---------- server ----------
  // every call resolves to { data } or { error: { code, text } }, never throws. A call lost to a dropped connection
  // (status 0) is tried once more: the database calls are all safe to repeat, and so is a guess (a repeat is refused
  // as already guessed and the board catches up). Creating a challenge is never repeated, so it can't make two.
  // A call that timed out (no answer in 20 seconds, see js/online.js) isn't repeated: the player hears about it at once.
  const pause = ms => new Promise(r => setTimeout(r, ms));
  const timedOut = e => !!e && (e.name === "AbortError" || /^AbortError/.test(e.message || "") || /aborted/i.test(e.hint || ""));
  async function rpc(fn, args, again = true){
    let res;
    try { res = await Online.client.rpc(fn, args); } catch (e) { res = { error: { name: e && e.name }, status: 0 }; }
    const { data, error, status } = res;
    if (error && status === 0 && again && !timedOut(error)){ await pause(400); return rpc(fn, args, false); }
    return error ? { error: { code: error.code || "network", text: message(error.code) } } : { data };
  }
  async function invoke(name, body, again = false){
    try {
      const { data, error } = await Online.client.functions.invoke(name, { body });
      if (!error) return { data };
      if (error.name === "FunctionsFetchError" && again && !timedOut(error.context)){ await pause(400); return invoke(name, body, false); }
      let code = null;
      try { code = (await error.context.json()).code; } catch (e) { /* not one of our replies */ }
      return { error: { code: code || (error.name === "FunctionsFetchError" ? "network" : null), text: message(code) } };
    } catch (e) { return { error: { code: "network", text: message() } }; }
  }
  const load = async id => { const r = await rpc("get_challenge", { p_id: id }); return r.error ? r : { ch: r.data }; };

  // ---------- results already seen (per browser), so only new ones light up the badge ----------
  const seenKey = () => "jju:seen:" + Online.user.id;
  function loadSeen(){
    try { seen = new Set(JSON.parse(localStorage.getItem(seenKey())) || []); } catch (e) { seen = new Set(); }
  }
  function markSeen(ids, prune){
    const fresh = ids.filter(id => !seen.has(id));
    if (!fresh.length) return;
    fresh.forEach(id => seen.add(id));
    if (prune) seen = new Set([...seen].filter(id => items.some(x => x.id === id))); // forget challenges no longer listed
    try { localStorage.setItem(seenKey(), JSON.stringify([...seen])); } catch (e) { /* not saved: the badge comes back next visit */ }
  }

  // ---------- list ----------
  const isOpen = x => x.status === "pending" || x.status === "active";
  function groups(){
    const g = { incoming: [], turn: [], waiting: [], done: [] };
    for (const x of items){
      if (!isOpen(x)) g.done.push(x);
      else if (x.status === "pending" && x.role === "opponent") g.incoming.push(x);
      else if (!x.my_finished && !(x.mode === "race" && x.status === "pending")) g.turn.push(x);
      else g.waiting.push(x);
    }
    return g;
  }

  async function refresh(){
    if (!signedIn()) return;
    const r = await rpc("list_challenges");
    if (r.error || !signedIn()) return;
    items = Array.isArray(r.data) ? r.data : [];
    render();
    // the challenge on the board changed (e.g. the opponent finished): show it there too
    const cur = Game.matchId();
    for (const x of items){
      const key = JSON.stringify(x), before = known.get(x.id);
      known.set(x.id, key);
      if (x.id === cur && before && before !== key) load(cur).then(c => { if (c.ch) Game.updateMatch(c.ch); });
    }
  }

  function setBadge(el, n){ el.textContent = n; el.hidden = !n; }
  function render(){
    const g = groups();
    if (!modal.hidden && tab === "challenges" && view === "list") markSeen(g.done.filter(x => x.status === "finished").map(x => x.id), true);
    // the badge counts what needs this player: new challenges, games to finish, results not seen yet, friend requests
    const mine = g.incoming.length + g.turn.filter(x => x.status === "active").length + g.done.filter(x => x.status === "finished" && !seen.has(x.id)).length;
    const requests = Friends.incoming();
    setBadge(btn.querySelector(".badge"), mine + requests);
    setBadge(tabs.challenges.querySelector(".badge"), mine);
    setBadge(tabs.friends.querySelector(".badge"), requests);
    btn.setAttribute("aria-label", mine + requests ? `Versus, ${mine + requests} new` : "Versus");
    for (const key of Object.keys(g)){
      const box = $m(`[data-group="${key}"]`), ul = box.querySelector("ul"), html = g[key].map(x => itemHTML(x, key)).join("");
      box.hidden = !g[key].length;
      if (ul._html !== html){ ul.innerHTML = html; ul._html = html; } // unchanged lists keep their buttons (no lost clicks)
    }
    $m("[data-empty]").hidden = items.length > 0;
    syncToast();
  }

  // pops up a live race invite, or a race of yours that can start now (the other player joined) while you're elsewhere
  function syncToast(){
    const live = items.filter(x => x.mode === "race" && x.id !== Game.matchId()
      && ((x.status === "pending" && x.role === "opponent") || (x.status === "active" && !x.starts_at)));
    if (toastFor && !live.some(x => x.id === toastFor)) hideToast(); // answered, started, called off or expired
    const fresh = live.find(x => !toasted.has(x.id));
    if (!fresh) return;
    const invite = fresh.status === "pending";
    toasted.add(fresh.id);
    toastFor = fresh.id;
    toast.dataset.invite = invite ? "1" : "";
    toast.innerHTML = `<p><b>${esc(fresh.opponent)}</b> ${invite ? "wants to race you now!" : "is ready to race!"}</p>
      <p class="acct-hint">${esc(Game.partsText(fresh.parts))} · ${fresh.max_guesses ? guessWord(fresh.max_guesses) : "No guess limit"} · first to solve wins</p>
      <div class="acct-row">${buttons([["join", invite ? "Join" : "Go to the lobby", true], ["later", "Not now"]])}</div>`;
    toast.hidden = false;
  }
  function hideToast(){ toast.hidden = true; toastFor = null; }
  toast.addEventListener("click", async e => {
    const b = e.target.closest("button[data-act]");
    if (!b || !toastFor) return;
    if (b.dataset.act === "later") return hideToast();
    const id = toastFor, invite = toast.dataset.invite === "1";
    b.disabled = true;
    const r = invite ? await rpc("accept_challenge", { p_id: id }) : {};
    const err = r.error || await play(id);
    b.disabled = false;
    if (err){ toast.querySelector(".acct-hint").textContent = err.text; return; }
    hideToast();
    refresh();
  });

  function itemHTML(x, key){
    const who = x.opponent ? `<b>${esc(x.opponent)}</b>` : null, race = x.mode === "race";
    let title, cls = "", acts = [];
    if (key === "incoming"){
      title = race ? `${who} wants to race you now` : `${who} challenged you`;
      acts = [["accept", race ? "Join" : "Accept &amp; play", true], ["decline", "Decline"]];
    } else if (key === "turn" && race){
      title = `${who ? `vs ${who}` : "Link race"} · ${x.starts_at ? "racing now" : "in the lobby"}`;
      acts = [["play", x.starts_at ? "Back to the race" : "Go to the lobby", true]];
      if (!x.starts_at) acts.push(["cancel", "Call off"]);
    } else if (key === "turn"){ title = `${who ? `vs ${who}` : "Link challenge"} · your turn`; acts = [["play", x.my_started ? "Continue" : "Play", true]]; }
    else if (key === "waiting" && race){
      title = x.status === "pending" ? (who ? `vs ${who} · waiting for them to join` : "Link race · nobody has joined yet") : `vs ${who} · still racing`;
      acts = x.status === "pending" ? [["play", "Go to the lobby", true]] : [["view", "View"]];
    } else if (key === "waiting"){
      title = !who ? "Link challenge · nobody has taken it yet" : `vs ${who} · ${x.status === "pending" ? "hasn't accepted yet" : "still playing"}`;
      acts = [["view", "View"]];
    } else if (x.status === "finished"){
      cls = x.result;
      title = `<span class="res">${{ win: "Won", loss: "Lost", draw: "Draw" }[x.result]}</span> vs ${who}`;
      acts = [["view", "View"], ["rematch", "Rematch", true]];
    } else {
      title = x.status === "declined" ? (x.role === "creator" ? `${who} declined` : `You declined ${who}`)
        : `${who ? `vs ${who}` : race ? "Link race" : "Link challenge"} · ${x.status === "expired" ? "expired" : race ? "called off" : "cancelled"}`;
      if (x.my_started) acts = [["view", "View"]];
    }
    if (x.role === "creator" && x.status === "pending"){ if (x.link_code) acts.push(["copy", "Copy link"]); acts.push(["cancel", "Cancel"]); }
    const facts = [esc(Game.partsText(x.parts)), x.max_guesses ? guessWord(x.max_guesses) : "No guess limit"];
    if (key === "turn" && x.status === "pending" && x.opponent) facts.push("not accepted yet");
    if (isOpen(x)) facts.push(Game.timeLeft(x.expires_at) + (race && !x.starts_at ? " to join" : ""));
    const score = x.status !== "finished" ? "" : `<div class="ch-meta">You: ${x.my_solved ? guessWord(x.my_guesses) : "not solved"} · ${esc(x.opponent)}: ${x.their_solved ? guessWord(x.their_guesses) : "not solved"}</div>`;
    return `<li class="ch-item ${cls}" data-id="${esc(x.id)}"><div class="ch-title">${title}${race ? '<span class="tag">Live race</span>' : ""}</div>${score}<div class="ch-meta">${facts.join(" · ")}</div>${
      acts.length ? `<div class="ch-actions">${buttons(acts)}</div>` : ""}</li>`;
  }

  $m('[data-view="list"]').addEventListener("click", async e => {
    const b = e.target.closest("button[data-act]");
    if (!b) return;
    if (b.dataset.act === "new") return showNew();
    const li = b.closest("[data-id]"), x = li && items.find(i => i.id === li.dataset.id);
    if (!x) return;
    const act = b.dataset.act, id = x.id;
    if (act === "decline" && !confirm(`Decline ${x.opponent}'s challenge?`)) return;
    if (act === "cancel" && !confirm(x.mode === "race" ? "Call off this race?" : "Cancel this challenge? Nobody will be able to play it.")) return;
    b.disabled = true; say("list", "");
    let err = null;
    if (act === "accept"){ const r = await rpc("accept_challenge", { p_id: id }); err = r.error || await play(id); }
    else if (act === "decline") err = (await rpc("decline_challenge", { p_id: id })).error;
    else if (act === "cancel") err = (await rpc("cancel_challenge", { p_id: id })).error;
    else if (act === "play" || act === "view") err = await play(id);
    else if (act === "rematch") err = await rematch(id);
    else if (act === "copy" && await copy(linkFor(x.link_code))) say("list", "Link copied.");
    b.disabled = false;
    if (err) say("list", err.text);
    refresh();
  });

  // ---------- playing ----------
  // put a challenge on the board; resolves to null, or the error if it couldn't be opened
  async function play(id){
    const r = await load(id);
    if (r.error) return r.error;
    // a challenge sent to this player that they haven't accepted yet: answer it in the panel first
    if (r.ch.role === "opponent" && r.ch.status === "pending"){ hideInvite(); setUrl(null); open("challenges"); return null; }
    close(false); hideInvite();
    if (toastFor === id) hideToast();
    const code = r.ch.link_code;
    Game.playMatch({
      ch: r.ch,
      start: async () => { const s = await rpc("start_challenge", { p_id: id }); return s.error ? s : load(id); },
      guess: charId => invoke("challenge-guess", { id, charId }, true),
      reload: () => load(id),
      giveUp: async () => { const s = await rpc("give_up_challenge", { p_id: id }); return s.error ? s : load(id); },
      ready: async () => { const s = await rpc("race_ready", { p_id: id }); return s.error ? s : load(id); },
      unready: () => rpc("race_unready", { p_id: id }),
      cancel: async () => { const s = await rpc("cancel_challenge", { p_id: id }); return s.error ? s : load(id); },
      rematch: () => rematch(id),
      copyLink: async () => (await copy(linkFor(code))) ? { text: "Link copied." } : null,
      done: () => refresh(),
      left: () => { setUrl(null); refresh(); },
    });
    setUrl("play", id);
    if (r.ch.status === "finished"){ markSeen([id], false); render(); }
    return null;
  }

  // a rematch has the same settings; if the other player asked first, pressing Rematch accepts theirs
  async function rematch(prevId){
    const r = await invoke("create-challenge", { rematchOf: prevId });
    if (r.error) return r.error;
    const c = await load(r.data.id);
    if (c.error) return c.error;
    if (c.ch.role === "opponent" && c.ch.status === "pending"){
      const a = await rpc("accept_challenge", { p_id: c.ch.id });
      if (a.error) return a.error;
    }
    refresh();
    return play(c.ch.id);
  }

  // ---------- new challenge ----------
  partsBox.innerHTML = Game.PARTS.map(p => `<button type="button" class="ptog" data-part="${esc(p)}" aria-pressed="false" aria-label="Part ${esc(p)}: ${
    esc(Game.partName(p))}" title="Part ${esc(p)}: ${esc(Game.partName(p))}">${esc(p)}</button>`).join("");
  partsBox.addEventListener("click", e => {
    const b = e.target.closest(".ptog");
    if (!b) return;
    const on = b.getAttribute("aria-pressed") === "true";
    if (on && partsBox.querySelectorAll('[aria-pressed="true"]').length === 1) return say("new", "Keep at least one part on.");
    b.setAttribute("aria-pressed", String(!on));
    say("new", "");
  });

  const submitBtn = form.querySelector('[type="submit"]');
  const updateSubmit = () => {
    const race = form.mode.value === "race";
    submitBtn.textContent = form.opponent.value === "link" ? "Make link" : race ? "Send race invite" : "Send challenge";
    $m("[data-rules]").textContent = RULES[race ? "race" : "async"];
  };
  form.opponent.addEventListener("change", updateSubmit);
  form.addEventListener("change", e => { if (e.target.name === "mode") updateSubmit(); });
  function fillOpponents(want = form.opponent.value){
    const friends = Friends.list().filter(f => f.state === "friend");
    form.opponent.innerHTML = '<option value="link">Anyone with a link</option>' + friends.map(f => `<option value="${esc(f.id)}">${esc(f.username)}</option>`).join("");
    form.opponent.value = friends.some(f => f.id === want) ? want : "link";
    updateSubmit();
  }
  function showNew(friendId){
    showView("new");
    form.mode.value = "async";
    fillOpponents(friendId || "link");
    const on = new Set(Game.parts()); // starts from the parts this player has on
    partsBox.querySelectorAll(".ptog").forEach(b => b.setAttribute("aria-pressed", String(on.has(b.dataset.part))));
    form.limit.value = "9";
    say("new", "");
    form.opponent.focus();
    Friends.refresh();
  }
  form.addEventListener("submit", async e => {
    e.preventDefault();
    const parts = [...partsBox.querySelectorAll('[aria-pressed="true"]')].map(b => b.dataset.part);
    if (!parts.length) return say("new", "Pick at least one part.");
    const opp = form.opponent.value, body = { parts, maxGuesses: form.limit.value === "9" ? 9 : null, mode: form.mode.value };
    if (opp === "link") body.link = true; else body.opponent = opp;
    submitBtn.disabled = true; say("new", opp === "link" ? "Making your link…" : "Sending…");
    const r = await invoke("create-challenge", body);
    submitBtn.disabled = false;
    if (r.error) return say("new", r.error.text);
    say("new", "");
    refresh();
    // a race with a friend goes straight to the lobby, where they'll join you
    if (body.mode === "race" && opp !== "link"){ const err = await play(r.data.id); if (err) say("new", err.text); return; }
    const friend = Friends.list().find(f => f.id === opp);
    showMade(r.data, friend ? friend.username : null, body.mode === "race");
  });
  form.querySelector('[data-act="back"]').addEventListener("click", () => { showView("list"); $m('[data-act="new"]').focus(); });

  function showMade(data, friendName, race){
    made = data;
    showView("made");
    $m("[data-made]").innerHTML = race
      ? "Your race link is ready. Send it to someone, then wait in the lobby: the race starts as soon as they join."
      : friendName ? `Challenge sent to <b>${esc(friendName)}</b>! They have 24 hours to accept. Play your turn now or later.`
      : "Your challenge link is ready. Send it to anyone: the first person to accept it plays you.";
    $m('[data-view="made"] [data-act="play"]').textContent = race ? "Go to the lobby" : "Play now";
    $m("[data-link]").hidden = !data.link_code;
    if (data.link_code) $m("[data-link] input").value = linkFor(data.link_code);
    $m('[data-view="made"] [data-act="share"]').hidden = !(data.link_code && navigator.share);
    say("made", "");
    $m('[data-view="made"] [data-act="play"]').focus();
  }
  $m('[data-view="made"]').addEventListener("click", async e => {
    const b = e.target.closest("button[data-act]");
    if (!b || !made) return;
    const act = b.dataset.act, link = made.link_code ? linkFor(made.link_code) : null;
    if (act === "copy"){ if (await copy(link)) say("made", "Link copied."); }
    else if (act === "share"){
      try { await navigator.share({ title: "JoJodle Unlimited", text: "I challenge you to a JoJodle duel!", url: link }); }
      catch (err) { /* share sheet closed */ }
    }
    else if (act === "play"){ b.disabled = true; const err = await play(made.id); b.disabled = false; if (err) say("made", err.text); }
    else if (act === "done"){ showView("list"); $m('[data-act="new"]').focus(); }
  });
  $m("[data-link] input").addEventListener("focus", e => e.target.select());

  function showView(v){
    view = v;
    for (const k of ["list", "new", "made"]) $m(`[data-view="${k}"]`).hidden = k !== v;
    if (v === "list"){ say("list", ""); render(); }
  }

  // ---------- panel ----------
  function setTab(t){
    tab = t;
    for (const [k, el] of Object.entries(tabs)){ el.setAttribute("aria-selected", String(k === t)); el.tabIndex = k === t ? 0 : -1; panes[k].hidden = k !== t; }
    if (t === "friends"){ Friends.clearMessage(); Friends.refresh(); } else refresh();
    render();
  }
  $m(".tabs").addEventListener("click", e => { const b = e.target.closest('[role="tab"]'); if (b) setTab(b.dataset.tab); });
  $m(".tabs").addEventListener("keydown", e => {
    if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
    e.preventDefault();
    setTab(tab === "challenges" ? "friends" : "challenges");
    tabs[tab].focus();
  });

  function open(which, friendId){
    if (!signedIn()) return Online.open();
    modal.hidden = false;
    setTab(which || tab);
    if (friendId) showNew(friendId);
    else { showView("list"); tabs[tab].focus(); }
  }
  function close(refocus = true){
    if (modal.hidden) return;
    modal.hidden = true;
    if (refocus) btn.focus();
  }
  btn.addEventListener("click", () => open());
  $m(".modal-x").addEventListener("click", () => close());
  modal.addEventListener("mousedown", e => { if (e.target === modal) close(); });
  modal.addEventListener("keydown", e => { if (e.key === "Escape") close(); });

  // ---------- challenge links (?challenge=CODE) ----------
  function hideInvite(){
    if (invite.hidden) return;
    invite.hidden = true; inviteCode = null;
    setUrl(null);
  }
  async function showInvite(){
    const code = inviteCode;
    if (!code) return;
    invite.hidden = false;
    $i(".acct-msg").textContent = "";
    const set = (body, acts) => {
      $i("[data-body]").innerHTML = body;
      $i("[data-actions]").innerHTML = buttons(acts);
      const first = $i("[data-actions] button");
      if (first) first.focus();
    };
    if (!Online.user) return set("<p>Someone challenged you to a JoJodle duel! Sign in to see the challenge and play. All you need is an email address.</p>", [["signin", "Sign in", true], ["close", "Not now"]]);
    if (!Online.profile) return set("<p>Someone challenged you to a JoJodle duel! Pick a username to see the challenge.</p>", [["signin", "Pick a username", true], ["close", "Not now"]]);
    set("<p>Loading the challenge…</p>", []);
    const r = await rpc("peek_challenge", { p_code: code });
    if (inviteCode !== code || invite.hidden) return; // closed meanwhile
    if (r.error) return set(`<p>${r.error.code === "JJ011" ? "This challenge link isn't available. It may have been cancelled." : esc(r.error.text)}</p>`, [["close", "Close"]]);
    const p = r.data, who = `<b>${esc(p.creator)}</b>`, waiting = p.status === "pending" && !p.claimed;
    const race = p.mode === "race", kind = race ? "race" : "challenge";
    invite.dataset.id = p.id;
    if (p.mine) return set(`<p>This is your own ${kind} link.${waiting ? ` Send it to someone so they can ${race ? "race" : "play"} you.` : ""}</p>`,
      waiting ? [["copy", "Copy link", true], ["play", race ? "Go to the lobby" : "Open it"], ["close", "Close"]] : [["play", "Open it", true], ["close", "Close"]]);
    if (p.claimed_by_me) return set(`<p>You've accepted ${who}'s ${kind}.</p>`, [["play", race ? "Go to the race" : "Continue", true], ["close", "Close"]]);
    if (p.claimed) return set(`<p>Someone else already accepted ${who}'s ${kind}.</p>`, [["close", "Close"]]);
    if (p.status === "expired") return set(`<p>${who}'s ${kind} expired before anyone accepted it.</p>`, [["close", "Close"]]);
    if (p.status !== "pending") return set(`<p>${who} ${race ? "called off this race" : "cancelled this challenge"}.</p>`, [["close", "Close"]]);
    set(`<p>${race ? `${who} wants to race you live!` : `${who} challenged you!`}</p>
      <p class="vs-rules"><b>${esc(Game.partsText(p.parts))}</b> · <b>${p.max_guesses ? guessWord(p.max_guesses) : "No guess limit"}</b> · ${Game.timeLeft(p.expires_at)} to ${race ? "join" : "accept"}</p>
      <p class="vs-rules">${race ? "You both get the same answer at the same moment, and the first to solve wins." : "You both get the same answer. Fewest guesses wins; same number of guesses, the faster time wins."}</p>`,
      [["accept", race ? "Join the race" : "Accept and play", true], ["close", "Not now"]]);
  }
  invite.addEventListener("click", async e => {
    const b = e.target.closest("button[data-act]");
    if (!b) return;
    const act = b.dataset.act, code = inviteCode;
    if (act === "close") return hideInvite();
    if (act === "signin") return Online.open();
    b.disabled = true;
    let err = null;
    if (act === "accept"){ const r = await rpc("accept_challenge", { p_code: code }); err = r.error || await play(r.data); }
    else if (act === "play") err = await play(invite.dataset.id);
    else if (act === "copy" && await copy(linkFor(code))) $i(".acct-msg").textContent = "Link copied.";
    b.disabled = false;
    if (err) $i(".acct-msg").textContent = err.text;
    refresh();
  });
  $i(".modal-x").addEventListener("click", hideInvite);
  invite.addEventListener("mousedown", e => { if (e.target === invite) hideInvite(); });
  invite.addEventListener("keydown", e => { if (e.key === "Escape") hideInvite(); });

  // ---------- helpers ----------
  // the address bar shows ?play=<id> while a challenge is on the board, so a reload comes back to it
  function setUrl(key, value){
    const u = new URL(location.href);
    u.searchParams.delete("play"); u.searchParams.delete("challenge");
    if (key) u.searchParams.set(key, value);
    try { history.replaceState(null, "", u.href); } catch (e) { /* not allowed for this page address */ }
  }
  // true once copied; if the browser won't allow it, shows the link to copy by hand and returns false
  async function copy(text){
    try { await navigator.clipboard.writeText(text); return true; } catch (e) { /* fall back below */ }
    const prev = document.activeElement, t = document.createElement("textarea");
    t.value = text; t.setAttribute("readonly", ""); t.style.cssText = "position:fixed;top:0;left:0;opacity:0";
    document.body.appendChild(t); t.select();
    let ok = false;
    try { ok = document.execCommand("copy"); } catch (e) { ok = false; }
    t.remove();
    if (prev && prev.focus) prev.focus();
    if (!ok) window.prompt("Copy this link:", text);
    return ok;
  }
  function handleUrl(){
    if (urlHandled || !Online.ready) return;
    urlHandled = true;
    const q = new URLSearchParams(location.search), code = q.get("challenge"), id = q.get("play");
    if (code){ inviteCode = code.slice(0, 64); showInvite(); }
    else if (id){
      if (!signedIn() || !UUID.test(id)) return setUrl(null);
      play(id).then(err => { if (err){ setUrl(null); Game.note(err.text); } });
    }
  }

  // ---------- follow sign-in ----------
  function sync(){
    if (!mounted){
      const bar = document.querySelector(".acct-bar");
      if (!bar) return;
      bar.insertBefore(btn, bar.firstChild);
      panes.friends.appendChild(Friends.panel);
      document.body.appendChild(modal);
      document.body.appendChild(invite);
      document.body.appendChild(toast);
      mounted = true;
    }
    btn.hidden = false; // signed-out players see it too; it asks them to sign in
    clearInterval(pollTimer);
    if (signedIn()){
      loadSeen();
      refresh();
      pollTimer = setInterval(() => { if (!document.hidden) refresh(); }, POLL_MS);
    } else {
      items = []; known.clear(); render(); hideToast();
      close(false);
      if (Game.matchId()) Game.leaveMatch();
    }
    if (inviteCode && !invite.hidden) showInvite();
    handleUrl();
  }
  Online.onChange(sync);
  Online.onPing(kind => {
    // a guess in a race: the board reloads it to show the opponent's new colours
    if (kind === "race"){ const cur = Game.matchId(); if (cur) load(cur).then(c => { if (c.ch) Game.updateMatch(c.ch); }); }
    else if (kind === "challenges" || kind === null) refresh();
  });
  Friends.onUpdate(() => { render(); if (view === "new" && !modal.hidden) fillOpponents(); });
  document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh(); });

  window.Versus = { open, refresh, challenge: friendId => open("challenges", friendId) };
})();
