// feedback — receives issue / feedback / feature submissions from the connect page.
//
// Public by necessity: the form lives on octagongroup.co.uk and the person filling it in may not
// have a working token (an auth problem is exactly the thing they'd report). So there is no JWT.
// Protections are: strict field validation, a length cap, a honeypot, and a per-IP rate limit.
//
// Store first, notify second. The row is the record; Slack and email are best-effort, so a delivery
// failure can never lose a submission.
//   Slack : app_settings.admin_webhook_url  (already configured)
//   Email : RESEND_API_KEY + FEEDBACK_TO    (skipped cleanly when unset)
import { createClient } from "jsr:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const RESEND_KEY = (Deno.env.get("RESEND_API_KEY") ?? "").trim();
const MAIL_TO = (Deno.env.get("FEEDBACK_TO") ?? "olarkins@octagongroup.co.uk").trim();
const MAIL_FROM = (Deno.env.get("FEEDBACK_FROM") ?? "Octagon Analytics <onboarding@resend.dev>").trim();

const CORS: Record<string, string> = {
  "Content-Type": "application/json",
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const KINDS = new Set(["issue", "feedback", "feature"]);
const LABEL: Record<string, string> = { issue: "Issue", feedback: "Feedback", feature: "Feature request" };

function clean(v: unknown, max: number): string | null {
  const s = typeof v === "string" ? v.trim() : "";
  return s ? s.slice(0, max) : null;
}

async function notifySlack(row: any): Promise<boolean> {
  const { data } = await db.from("app_settings").select("value").eq("key", "admin_webhook_url").maybeSingle();
  const hook = (data?.value ?? "").trim();
  if (!hook) return false;
  const who = [row.from_name, row.from_email].filter(Boolean).join(" · ") || "anonymous";
  const text = `*${LABEL[row.kind]}* from ${who}\n>>> ${String(row.message).slice(0, 1500)}`;
  try {
    const r = await fetch(hook, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ text }) });
    return r.ok;
  } catch { return false; }
}

async function notifyEmail(row: any): Promise<boolean> {
  if (!RESEND_KEY) return false;   // not configured yet — the row and Slack still carry it
  const who = [row.from_name, row.from_email].filter(Boolean).join(" · ") || "anonymous";
  const body = `${LABEL[row.kind]} submitted via the Octagon Analytics connect page.\n\nFrom: ${who}\nWhen: ${row.created_at}\n\n${row.message}\n`;
  try {
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: MAIL_FROM, to: [MAIL_TO],
        reply_to: row.from_email || undefined,
        subject: `[Octagon Analytics] ${LABEL[row.kind]} from ${row.from_name || "a user"}`,
        text: body,
      }),
    });
    return r.ok;
  } catch { return false; }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST") return new Response(JSON.stringify({ error: "POST only" }), { status: 405, headers: CORS });

  let body: any = {};
  try { body = await req.json(); } catch { return new Response(JSON.stringify({ error: "invalid json" }), { status: 400, headers: CORS }); }

  // Honeypot: a real person never fills a hidden field. Answer 200 so bots learn nothing.
  if (clean(body.website, 200)) return new Response(JSON.stringify({ ok: true }), { headers: CORS });

  const kind = String(body.kind ?? "").toLowerCase();
  const message = clean(body.message, 4000);
  if (!KINDS.has(kind)) return new Response(JSON.stringify({ error: "kind must be issue, feedback or feature" }), { status: 400, headers: CORS });
  if (!message || message.length < 5) return new Response(JSON.stringify({ error: "Please add a bit more detail." }), { status: 400, headers: CORS });

  // Rate limit: 5 submissions per 10 minutes from one IP.
  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || "unknown";
  const since = new Date(Date.now() - 10 * 60 * 1000).toISOString();
  const { count } = await db.from("feedback").select("*", { count: "exact", head: true })
    .eq("source", ip).gte("created_at", since);
  if ((count ?? 0) >= 5) {
    return new Response(JSON.stringify({ error: "That's a few in a row — give it a few minutes." }), { status: 429, headers: CORS });
  }

  const row = {
    kind, message,
    from_name: clean(body.name, 120),
    from_email: clean(body.email, 200),
    user_agent: clean(req.headers.get("user-agent"), 300),
    source: ip,
  };

  const { data: saved, error } = await db.from("feedback").insert(row).select().single();
  if (error) return new Response(JSON.stringify({ error: "Could not save that — please try again." }), { status: 500, headers: CORS });

  const [slacked, emailed] = await Promise.all([notifySlack(saved), notifyEmail(saved)]);
  db.from("feedback").update({ slacked, emailed }).eq("id", saved.id).then(() => {}, () => {});

  return new Response(JSON.stringify({ ok: true, id: saved.id }), { headers: CORS });
});
