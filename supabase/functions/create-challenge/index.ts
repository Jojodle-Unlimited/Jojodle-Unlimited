// Creates a challenge for a friend, for anyone with a link, or as a rematch.
// The answer is picked here and stored where no player can read it.
// Body: { parts: ["3","4"], maxGuesses: 9 | null, opponent: "<friend's id>" } or { ..., link: true } or { rematchOf: "<challenge id>" }
import { admin, CHARS, dbError, PARTS, pickSecret, reply, serve, UUID } from "../_shared/server.ts";

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

// 12 random letters and digits for a challenge link (bytes 248 and up are skipped so every character is equally likely)
function linkCode() {
  let code = "";
  while (code.length < 12) {
    for (const b of crypto.getRandomValues(new Uint8Array(16))) {
      if (b < 248 && code.length < 12) code += ALPHABET[b % 62];
    }
  }
  return code;
}

serve(async (player, body) => {
  let parts: string[], maxGuesses: number | null, opponent: string | null = null, link = false;
  const rematchOf = body.rematchOf ?? null;

  if (rematchOf !== null) {
    if (typeof rematchOf !== "string" || !UUID.test(rematchOf)) return reply({ error: "bad request" }, 400);
    // a rematch keeps the same settings (the database checks this player was in it)
    const { data: prev, error } = await admin.from("challenges").select("parts, max_guesses").eq("id", rematchOf).maybeSingle();
    if (error) return dbError(error);
    if (!prev) return reply({ error: "no such challenge", code: "JJ006" }, 400);
    parts = prev.parts;
    maxGuesses = prev.max_guesses;
  } else {
    const p = body.parts;
    if (!Array.isArray(p) || !p.length || p.some(x => typeof x !== "string" || !PARTS.includes(x)) || new Set(p).size !== p.length) {
      return reply({ error: "pick at least one part" }, 400);
    }
    parts = [...p].sort((a, b) => Number(a) - Number(b));
    const m = body.maxGuesses ?? null;
    if (m !== null && m !== 9) return reply({ error: "bad guess limit" }, 400);
    maxGuesses = m;
    if (body.link === true) link = true;
    else if (typeof body.opponent === "string" && UUID.test(body.opponent)) opponent = body.opponent;
    else return reply({ error: "choose a friend or make a link" }, 400);
  }

  const secret = pickSecret(CHARS.filter(c => parts.includes(c.part)), null);
  const hint = secret.ability[Math.floor(Math.random() * secret.ability.length)];
  // a new code if a link code were ever already taken
  for (let attempt = 0; attempt < 3; attempt++) {
    const code = link ? linkCode() : null;
    const { data, error } = await admin.rpc("sv_create_challenge", {
      p_creator: player, p_opponent: opponent, p_link_code: code, p_parts: parts, p_max_guesses: maxGuesses,
      p_char_id: secret.id, p_hint: hint, p_rematch_of: rematchOf,
    });
    if (error && error.code === "23505" && link) continue;
    if (error) return dbError(error);
    return reply({ id: data, link_code: code });
  }
  return reply({ error: "server error" }, 500);
});
