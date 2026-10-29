// "Help us read it" without an account: the app sends the file here with the pilot's email and consent.
// The pilot's device keeps a random token per report; only its hash is stored, and it is the only way to read or change that report.
//   ?action=upload   body: the file; header x-meta: URL-encoded JSON {file_name, kind, note, error, email, consent}  -> {id, token}
//   ?action=status   body: [{id, token}]                                                                             -> [{id, status, admin_note}]
//   ?action=works    body: {items: [{id, token}], file_name}  marks the pilot's own waiting report as working now     -> {done}
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-meta, x-client-info" };
const out = (body: unknown, status = 200) => Response.json(body, { status, headers: CORS });
const sha = async (s: string) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s))))
  .map((b) => b.toString(16).padStart(2, "0")).join("");
const KINDS = ["logbook", "ecrew", "roster", "other"], MAX = 20 * 1048576;

// the reports whose token matches
async function mine(sb: any, items: unknown) {
  if (!Array.isArray(items)) return [];
  const list = items.slice(0, 20).filter((x: any) => Number.isInteger(x?.id) && typeof x?.token === "string" && x.token.length >= 32);
  if (!list.length) return [];
  const { data } = await sb.from("file_reports").select("id,file_name,status,admin_note,guest_token_hash").is("user_id", null).in("id", list.map((x: any) => x.id));
  const want = new Map(await Promise.all(list.map(async (x: any) => [x.id, await sha(x.token)] as [number, string])));
  return (data || []).filter((r: any) => r.guest_token_hash && want.get(r.id) === r.guest_token_hash);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return out({ error: "use POST" }, 405);
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const action = new URL(req.url).searchParams.get("action");
  try {
    if (action === "upload") {
      let meta: any = {};
      try { meta = JSON.parse(decodeURIComponent(req.headers.get("x-meta") || "")); } catch { return out({ error: "bad request" }, 400); }
      const email = String(meta.email || "").trim().toLowerCase(), name = String(meta.file_name || "").trim().slice(0, 200);
      if (meta.consent !== true) return out({ error: "consent needed" }, 400);
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email) || email.length > 200) return out({ error: "Please enter a valid email address." }, 400);
      if (!name) return out({ error: "bad request" }, 400);
      const hourAgo = new Date(Date.now() - 3600e3).toISOString(), dayAgo = new Date(Date.now() - 86400e3).toISOString();
      const all = await sb.from("file_reports").select("id", { count: "exact", head: true }).is("user_id", null).gte("created_at", hourAgo);
      const own = await sb.from("file_reports").select("id", { count: "exact", head: true }).is("user_id", null).eq("email", email).gte("created_at", dayAgo);
      if ((all.count || 0) >= 30 || (own.count || 0) >= 5) return out({ error: "Too many files sent just now. Please try again tomorrow, or email it to us." }, 429);
      const bytes = new Uint8Array(await req.arrayBuffer());
      if (!bytes.length) return out({ error: "The file is empty." }, 400);
      if (bytes.length > MAX) return out({ error: "That file is over 20 MB. Please email it to us instead." }, 413);
      const token = Array.from(crypto.getRandomValues(new Uint8Array(24))).map((b) => b.toString(16).padStart(2, "0")).join("");
      const safe = name.replace(/[^\w.\-]+/g, "_").slice(-80), path = `guest/${crypto.randomUUID()}/${safe}`;
      const up = await sb.storage.from("file-reports").upload(path, bytes, { contentType: req.headers.get("content-type") || "application/octet-stream", upsert: false });
      if (up.error) throw up.error;
      const ins = await sb.from("file_reports").insert({ user_id: null, email, file_name: name, path, size: bytes.length,
        kind: KINDS.includes(meta.kind) ? meta.kind : "other", error: meta.error ? String(meta.error).slice(0, 500) : null,
        note: meta.note ? String(meta.note).slice(0, 2000) : null, guest_token_hash: await sha(token) }).select("id").single();
      if (ins.error) { await sb.storage.from("file-reports").remove([path]); throw ins.error; }
      return out({ id: ins.data.id, token });
    }
    if (action === "status") {
      const rows = await mine(sb, await req.json().catch(() => null));
      return out(rows.map((r: any) => ({ id: r.id, file_name: r.file_name, status: r.status, admin_note: r.admin_note })));
    }
    if (action === "works") {
      const body = await req.json().catch(() => ({})), fname = String(body?.file_name || "");
      const ids = (await mine(sb, body?.items)).filter((r: any) => r.file_name === fname && (r.status === "new" || r.status === "working")).map((r: any) => r.id);
      if (ids.length) await sb.from("file_reports").update({ status: "done", updated_at: new Date().toISOString(), admin_note: "Imported successfully by the pilot." }).in("id", ids).is("admin_note", null);
      if (ids.length) await sb.from("file_reports").update({ status: "done", updated_at: new Date().toISOString() }).in("id", ids);
      return out({ done: ids.length, ids });
    }
    return out({ error: "unknown action" }, 400);
  } catch (e) {
    console.error(e);
    return out({ error: "Couldn't send the file right now." }, 500);
  }
});
