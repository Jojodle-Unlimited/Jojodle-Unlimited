// Friends panel: add players by username, answer requests, remove or block. Needs js/online.js.
(function () {
  const Online = window.Online;
  if (!Online) return;
  const POLL_MS = 30000; // the list refreshes on open, on returning to the tab, and every 30 seconds
  const USERNAME = /^[A-Za-z0-9_]{3,20}$/;
  const MESSAGES = {
    JJ001: "Pick a username first.",
    JJ002: "No player with that username.",
    JJ003: "That's you!",
    JJ004: "You've blocked this player. Unblock them first.",
    JJ005: "That request is no longer there.",
  };

  const btn = document.createElement("button");
  btn.id = "friendsBtn"; btn.className = "acct"; btn.type = "button"; btn.hidden = true;
  btn.setAttribute("aria-haspopup", "dialog");
  btn.innerHTML = 'Friends<span class="badge" hidden></span>';
  const badge = btn.querySelector(".badge");

  const modal = document.createElement("div");
  modal.className = "modal"; modal.id = "friendsModal"; modal.hidden = true;
  modal.innerHTML = `
    <div class="modal-panel friends-panel" role="dialog" aria-modal="true" aria-labelledby="friendsTitle">
      <button class="modal-x" type="button" aria-label="Close">×</button>
      <h2 id="friendsTitle">Friends</h2>
      <form class="friend-add" novalidate>
        <label>Add a friend by username
          <span class="friend-add-row"><input name="username" autocomplete="off" spellcheck="false" maxlength="20"><button class="primary" type="submit">Add</button></span>
        </label>
        <p class="acct-msg" role="status"></p>
      </form>
      <section data-list="incoming"><h3>Requests</h3><ul></ul></section>
      <section data-list="friend"><h3>Your friends</h3><ul></ul><p class="acct-hint" data-empty>No friends yet. Add someone by their username.</p></section>
      <section data-list="outgoing"><h3>Sent requests</h3><ul></ul></section>
      <details data-list="blocked"><summary>Blocked players</summary><ul></ul></details>
    </div>`;
  const $m = sel => modal.querySelector(sel);
  const say = text => { $m(".friend-add .acct-msg").textContent = text || ""; };
  const esc = s => String(s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  let friends = [], blocked = [], pollTimer = null, mounted = false;
  const signedIn = () => !!(Online.client && Online.user && Online.profile);

  // ---------- data ----------
  async function refresh(){
    if (!signedIn()) return;
    const [f, b] = await Promise.all([Online.client.rpc("list_friends"), Online.client.rpc("list_blocked")]);
    if (!f.error) friends = f.data || [];
    if (!b.error) blocked = b.data || [];
    render();
  }

  async function call(fn, args){
    const { data, error } = await Online.client.rpc(fn, args);
    if (error){ say(MESSAGES[error.code] || "Something went wrong. Please try again."); return null; }
    return data === null ? true : data;
  }

  // ---------- render ----------
  const row = (f, actions) => `<li><span class="fname">${esc(f.username)}</span><span class="factions">${
    actions.map(([act, label]) => `<button type="button" data-act="${act}" data-id="${esc(f.id)}" data-name="${esc(f.username)}">${label}</button>`).join("")}</span></li>`;

  function render(){
    const incoming = friends.filter(f => f.state === "incoming");
    badge.textContent = incoming.length;
    badge.hidden = incoming.length === 0;
    btn.setAttribute("aria-label", incoming.length ? `Friends, ${incoming.length} new request${incoming.length === 1 ? "" : "s"}` : "Friends");
    const lists = {
      incoming: [incoming, [["accept", "Accept"], ["decline", "Decline"], ["block", "Block"]]],
      friend: [friends.filter(f => f.state === "friend"), [["remove", "Remove"], ["block", "Block"]]],
      outgoing: [friends.filter(f => f.state === "outgoing"), [["cancel", "Cancel"]]],
      blocked: [blocked, [["unblock", "Unblock"]]],
    };
    for (const [key, [items, actions]] of Object.entries(lists)){
      const box = $m(`[data-list="${key}"]`);
      box.querySelector("ul").innerHTML = items.map(f => row(f, actions)).join("");
      if (key === "friend") box.querySelector("[data-empty]").hidden = items.length > 0;
      else box.hidden = items.length === 0;
    }
  }

  // ---------- open / close ----------
  function open(){
    modal.hidden = false; say("");
    $m('[name="username"]').focus();
    refresh();
  }
  function close(){ modal.hidden = true; btn.focus(); }
  btn.addEventListener("click", open);
  $m(".modal-x").addEventListener("click", close);
  modal.addEventListener("mousedown", e => { if (e.target === modal) close(); });
  modal.addEventListener("keydown", e => { if (e.key === "Escape") close(); });

  // ---------- actions ----------
  $m(".friend-add").addEventListener("submit", async e => {
    e.preventDefault();
    const name = e.target.username.value.trim();
    if (!USERNAME.test(name)) return say("Usernames are 3–20 letters, numbers or underscores.");
    const submit = e.target.querySelector('button[type="submit"]');
    submit.disabled = true; say("Sending…");
    try {
      const result = await call("send_friend_request", { target_username: name });
      if (!result) return;
      say(result === "accepted" ? `You and ${name} are now friends.` : `Request sent to ${name}.`);
      e.target.username.value = "";
      await refresh();
    } finally { submit.disabled = false; }
  });

  modal.addEventListener("click", async e => {
    const b = e.target.closest("button[data-act]");
    if (!b) return;
    const other = b.dataset.id, name = b.dataset.name, act = b.dataset.act;
    if (act === "remove" && !confirm(`Remove ${name} from your friends?`)) return;
    if (act === "block" && !confirm(`Block ${name}? They won't be able to send you friend requests or challenges.`)) return;
    b.disabled = true; say("");
    const done =
      act === "accept" ? await call("respond_friend_request", { other, accept: true }) :
      act === "decline" ? await call("respond_friend_request", { other, accept: false }) :
      act === "remove" || act === "cancel" ? await call("remove_friend", { other }) :
      act === "block" ? await call("block_player", { other }) :
      act === "unblock" ? await call("unblock_player", { other }) : null;
    if (done && act === "accept") say(`You and ${name} are now friends.`);
    await refresh();
  });

  // ---------- follow sign-in ----------
  function sync(){
    const bar = document.querySelector(".acct-bar");
    if (bar && !mounted){ bar.insertBefore(btn, bar.firstChild); document.body.appendChild(modal); mounted = true; }
    btn.hidden = !signedIn();
    clearInterval(pollTimer);
    if (signedIn()){
      refresh();
      pollTimer = setInterval(() => { if (!document.hidden) refresh(); }, POLL_MS);
    } else {
      friends = []; blocked = []; render();
      if (!modal.hidden) close();
    }
  }
  Online.onChange(sync);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh(); });

  window.Friends = { refresh, list: () => friends.slice() };
})();
