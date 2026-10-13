// Shared by the challenge server functions: the game rules (the same files the page uses), a database client
// with server rights, and the request handling every function needs.
import { createClient } from "npm:@supabase/supabase-js@2.117.3";
import "../../../shared/characters.js";
import "../../../shared/core.js";

export type Char = { id: string; part: string; ability: string[]; [key: string]: unknown };
const rules = globalThis as unknown as {
  CHARS: Char[];
  compare: (guess: Char, answer: Char) => Record<string, unknown>;
  pickSecret: (pool: Char[], prev: Char | null) => Char;
};
export const { CHARS, compare, pickSecret } = rules;
export const PARTS = [...new Set(CHARS.map(c => c.part))];
export const byId = new Map(CHARS.map(c => [c.id, c]));
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// requests need the player's sign-in token, so allowing every origin is safe
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

// Answers the browser's preflight check, makes sure the player is signed in, reads the JSON body,
// then hands over to the function's own code with the player's id.
export function serve(handler: (player: string, body: Record<string, unknown>) => Promise<Response>) {
  Deno.serve(async req => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
    if (req.method !== "POST") return reply({ error: "Use POST" }, 405);
    const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data, error } = await admin.auth.getUser(token);
    if (error || !data?.user) return reply({ error: "not signed in", code: "28000" }, 401);
    let body: unknown;
    try { body = await req.json(); } catch { return reply({ error: "bad request" }, 400); }
    if (!body || typeof body !== "object" || Array.isArray(body)) return reply({ error: "bad request" }, 400);
    try { return await handler(data.user.id, body as Record<string, unknown>); }
    catch (e) { console.error(e); return reply({ error: "server error" }, 500); }
  });
}

// Errors the database raises on purpose carry our JJ codes (the page shows a message for each); anything else is a bug.
export function dbError(error: { code?: string; message?: string }) {
  if (error.code && /^JJ\d{3}$/.test(error.code)) return reply({ error: error.message, code: error.code }, 400);
  console.error(error);
  return reply({ error: "server error" }, 500);
}
