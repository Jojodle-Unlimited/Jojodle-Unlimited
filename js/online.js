// Online features: sign in with an emailed 6-digit code and pick a username.
// Solo play never depends on this file; if the Supabase library can't load, the sign-in button simply doesn't appear.
(function () {
  const SUPABASE_URL = "https://xqdoijxwjwcahnindanw.supabase.co";
  // publishable key: meant to be public, the database rules decide what each player can read or change
  const SUPABASE_KEY = "sb_publishable_t7bM8R-Pqd3liLTeHV1siA_79-ovd3O";
  const LIB = "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.3/dist/umd/supabase.js";
  const USERNAME = /^[A-Za-z0-9_]{3,20}$/;
  const RESEND_WAIT = 60; // seconds between code emails (the project allows one a minute per address)

  const Online = window.Online = {
    client: null, user: null, profile: null, ready: false,
    listeners: [],
    onChange(fn){ this.listeners.push(fn); },
  };
  const notify = () => Online.listeners.forEach(fn => { try { fn(Online); } catch (e) { console.error(e); } });

  // ---------- markup ----------
  const chip = document.createElement("button");
  chip.id = "acctBtn"; chip.className = "acct"; chip.type = "button";
  chip.setAttribute("aria-haspopup", "dialog");
  chip.textContent = "Sign in";

  const modal = document.createElement("div");
  modal.className = "modal"; modal.id = "acctModal"; modal.hidden = true;
  modal.innerHTML = `
    <div class="modal-panel" role="dialog" aria-modal="true" aria-labelledby="acctTitle">
      <button class="modal-x" type="button" aria-label="Close">×</button>
      <h2 id="acctTitle">Sign in</h2>
      <form data-step="email" novalidate>
        <p>Enter your email and we'll send you a 6-digit code. No password needed.</p>
        <label>Email<input type="email" name="email" autocomplete="email" required></label>
        <button class="primary" type="submit">Email me a code</button>
        <p class="acct-msg" role="alert"></p>
      </form>
      <form data-step="code" novalidate hidden>
        <p>We sent a code to <b data-email></b>. If the email has a sign-in link instead, you can just click it.</p>
        <label>Code<input name="code" inputmode="numeric" autocomplete="one-time-code" maxlength="6" required></label>
        <button class="primary" type="submit">Sign in</button>
        <div class="acct-row"><button type="button" data-act="resend">Send a new code</button><button type="button" data-act="back">Use a different email</button></div>
        <p class="acct-msg" role="alert"></p>
      </form>
      <form data-step="username" novalidate hidden>
        <p>Pick a username. Friends will find you by it.</p>
        <label>Username<input name="username" autocomplete="username" maxlength="20" required></label>
        <p class="acct-hint">3–20 letters, numbers or underscores.</p>
        <button class="primary" type="submit">Save</button>
        <p class="acct-msg" role="alert"></p>
      </form>
      <div data-step="account" hidden>
        <p>Signed in as <b data-username></b></p>
        <p class="acct-hint" data-useremail></p>
        <button type="button" data-act="signout">Sign out</button>
      </div>
    </div>`;

  const $m = sel => modal.querySelector(sel);
  const steps = ["email", "code", "username", "account"];
  const titles = { email: "Sign in", code: "Enter your code", username: "Pick a username", account: "Your account" };
  const say = (step, text) => { $m(`[data-step="${step}"] .acct-msg`).textContent = text || ""; };
  let pendingEmail = "", cooldownTimer = null, cooldownLeft = 0, lastFocus = null;

  function show(step){
    steps.forEach(s => { $m(`[data-step="${s}"]`).hidden = s !== step; });
    $m("#acctTitle").textContent = titles[step];
    const first = $m(`[data-step="${step}"] input, [data-step="${step}"] button`);
    if (first && !modal.hidden) first.focus();
  }
  function open(){
    lastFocus = chip; // return focus to the button that opened the dialog (some browsers don't focus buttons on click)
    modal.hidden = false;
    show(!Online.user ? "email" : !Online.profile ? "username" : "account");
  }
  function close(){
    modal.hidden = true;
    steps.forEach(s => say(s === "account" ? "email" : s, ""));
    if (lastFocus && document.contains(lastFocus)) lastFocus.focus();
  }

  function renderChip(){
    chip.textContent = !Online.user ? "Sign in" : Online.profile ? Online.profile.username : "Pick a username";
    chip.classList.toggle("signed-in", !!Online.user);
    if (Online.profile){ $m("[data-username]").textContent = Online.profile.username; }
    $m("[data-useremail]").textContent = Online.user ? Online.user.email : "";
  }

  function startCooldown(){
    clearInterval(cooldownTimer);
    cooldownLeft = RESEND_WAIT;
    const btn = $m('[data-act="resend"]');
    const tick = () => {
      btn.disabled = cooldownLeft > 0;
      btn.textContent = cooldownLeft > 0 ? `Send a new code (${cooldownLeft}s)` : "Send a new code";
      if (cooldownLeft-- <= 0) clearInterval(cooldownTimer);
    };
    tick(); cooldownTimer = setInterval(tick, 1000);
  }

  function friendlyError(error){
    const msg = String(error && (error.message || error)) || "";
    if ((error && error.status === 429) || /rate limit/i.test(msg)) return "Too many sign-in emails right now. Please try again in a little while.";
    if (/only request this after/i.test(msg)) return msg;
    if (/invalid.*email|email.*invalid/i.test(msg)) return "That doesn't look like an email address.";
    return "Something went wrong. Please try again.";
  }

  async function sendCode(email){
    const btn = $m('[data-step="email"] button[type="submit"]');
    btn.disabled = true;
    try {
      const { error } = await Online.client.auth.signInWithOtp({ email, options: { shouldCreateUser: true, emailRedirectTo: location.origin + location.pathname } });
      if (error) return friendlyError(error);
      pendingEmail = email;
      $m("[data-email]").textContent = email;
      startCooldown();
      return null;
    } catch (e) { return friendlyError(e); }
    finally { btn.disabled = false; }
  }

  async function loadProfile(){
    if (!Online.user){ Online.profile = null; return; }
    const { data } = await Online.client.from("profiles").select("username").eq("id", Online.user.id).maybeSingle();
    Online.profile = data || null;
  }

  // ---------- events ----------
  chip.addEventListener("click", open);
  $m(".modal-x").addEventListener("click", close);
  modal.addEventListener("mousedown", e => { if (e.target === modal) close(); });
  modal.addEventListener("keydown", e => { if (e.key === "Escape") close(); });

  $m('[data-step="email"]').addEventListener("submit", async e => {
    e.preventDefault();
    const email = e.target.email.value.trim();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return say("email", "That doesn't look like an email address.");
    say("email", "Sending…");
    const err = await sendCode(email);
    if (err) return say("email", err);
    say("email", ""); show("code");
  });

  $m('[data-step="code"]').addEventListener("submit", async e => {
    e.preventDefault();
    const code = e.target.code.value.replace(/\D/g, "");
    if (code.length !== 6) return say("code", "The code is 6 digits.");
    const btn = e.target.querySelector('button[type="submit"]');
    btn.disabled = true; say("code", "Checking…");
    try {
      const { error } = await Online.client.auth.verifyOtp({ email: pendingEmail, token: code, type: "email" });
      if (error) return say("code", "That code didn't work. Check it, or send a new one.");
      say("code", "");
      // onAuthStateChange loads the profile; wait for it, then move on
      await signedIn;
      show(Online.profile ? "account" : "username");
      if (Online.profile) close();
    } catch (err) { say("code", friendlyError(err)); }
    finally { btn.disabled = false; }
  });
  $m('[data-act="resend"]').addEventListener("click", async () => {
    const err = await sendCode(pendingEmail);
    say("code", err || "New code sent.");
  });
  $m('[data-act="back"]').addEventListener("click", () => { say("code", ""); show("email"); });

  $m('[data-step="username"]').addEventListener("submit", async e => {
    e.preventDefault();
    const username = e.target.username.value.trim();
    if (!USERNAME.test(username)) return say("username", "Use 3–20 letters, numbers or underscores.");
    const btn = e.target.querySelector('button[type="submit"]');
    btn.disabled = true; say("username", "Saving…");
    try {
      const { data, error } = await Online.client.from("profiles").insert({ id: Online.user.id, username }).select("username").single();
      if (error) return say("username", error.code === "23505" ? "That username is taken." : error.code === "23514" ? "Use 3–20 letters, numbers or underscores." : "Couldn't save that. Please try again.");
      Online.profile = data;
      say("username", ""); renderChip(); notify(); close();
    } finally { btn.disabled = false; }
  });

  $m('[data-act="signout"]').addEventListener("click", async () => {
    await Online.client.auth.signOut();
    close();
  });

  // ---------- start ----------
  let resolveSignedIn; let signedIn = new Promise(r => { resolveSignedIn = r; });
  function init(){
    if (!window.supabase || !window.supabase.createClient) return;
    Online.client = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } });
    Online.client.auth.onAuthStateChange((event, session) => {
      const user = session ? session.user : null;
      const changed = (user && user.id) !== (Online.user && Online.user.id);
      Online.user = user;
      // run outside the auth callback (the client asks not to await other calls inside it)
      setTimeout(async () => {
        if (changed || (user && !Online.profile)) await loadProfile();
        if (!user) Online.profile = null;
        Online.ready = true;
        renderChip(); notify();
        if (user) resolveSignedIn(); else signedIn = new Promise(r => { resolveSignedIn = r; });
      }, 0);
    });
    document.querySelector(".hero").appendChild(chip);
    document.body.appendChild(modal);
  }
  const s = document.createElement("script");
  s.src = LIB; s.async = true;
  s.onload = init;
  s.onerror = () => console.warn("Online features unavailable: couldn't load the Supabase library.");
  document.head.appendChild(s);
})();
