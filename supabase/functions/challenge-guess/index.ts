// Scores one guess in a challenge with the same rules as solo play. The answer is only sent once this player has finished.
// Body: { id: "<challenge id>", charId: "<character id>" }
import { admin, byId, compare, dbError, reply, serve, UUID } from "../_shared/server.ts";

const HINT_AFTER = 8; // same as solo play

serve(async (player, body) => {
  const { id, charId } = body;
  if (typeof id !== "string" || !UUID.test(id) || typeof charId !== "string") return reply({ error: "bad request" }, 400);

  const { data: rows, error } = await admin.rpc("sv_guess_context", { p_id: id, p_player: player });
  if (error) return dbError(error);
  const ctx = rows && rows[0];
  if (!ctx) return reply({ error: "no such challenge", code: "JJ006" }, 400);
  if (ctx.status !== "pending" && ctx.status !== "active") return reply({ error: "the challenge is over", code: "JJ007" }, 400);
  if (ctx.finished) return reply({ error: "you already finished", code: "JJ008" }, 400);
  const guess = byId.get(charId), secret = byId.get(ctx.char_id);
  if (!guess || !ctx.parts.includes(guess.part)) return reply({ error: "that character isn't in this challenge" }, 400);
  if (ctx.guessed.includes(charId)) return reply({ error: "already guessed", code: "JJ013" }, 400);
  if (!secret) { console.error("unknown answer", ctx.char_id); return reply({ error: "server error" }, 500); }

  const result = compare(guess, secret);
  const correct = guess.id === secret.id;
  const { data: saved, error: saveError } = await admin.rpc("sv_record_guess", {
    p_id: id, p_player: player, p_char_id: charId, p_result: result, p_correct: correct,
  });
  if (saveError) return dbError(saveError);
  const r = saved[0];
  return reply({
    n: r.n, result, correct, finished: r.finished, solved: r.solved, status: r.status,
    outcome: r.status === "finished" ? (r.winner === null ? "draw" : r.winner === player ? "win" : "loss") : null,
    secret: r.finished ? secret.id : null,
    hint: r.n >= HINT_AFTER || r.finished ? ctx.hint : null,
  });
});
