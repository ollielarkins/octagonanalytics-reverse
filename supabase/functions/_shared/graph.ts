// Microsoft Graph access for the inbox feature, shared by inbox-sync (polling) and octagon-mcp
// (reading one message, creating a reply draft).
//
// App-only auth (client credentials). The Entra app holds Mail.ReadWrite as an APPLICATION
// permission and nothing else: Mail.ReadWrite can create drafts but cannot send, so no code path
// here can send an email even by mistake. Which mailboxes the app may touch is restricted on
// Microsoft's side (Exchange RBAC for Applications / application access policy, scoped to a group);
// inbox_mailboxes decides which of those we actually poll.
//
// Secrets: MS_TENANT_ID, MS_CLIENT_ID, MS_CLIENT_SECRET. Missing secrets are reported as
// not_configured rather than thrown, so the cron does not fail before the admin has set them up.

const TENANT = (Deno.env.get("MS_TENANT_ID") ?? "").trim();
const CLIENT = (Deno.env.get("MS_CLIENT_ID") ?? "").trim();
const SECRET = (Deno.env.get("MS_CLIENT_SECRET") ?? "").trim();
export const GRAPH = "https://graph.microsoft.com/v1.0";

export function graphConfigured(): boolean { return !!(TENANT && CLIENT && SECRET); }

let cached: { token: string; exp: number } | null = null;
export async function graphToken(): Promise<string> {
  if (cached && cached.exp > Date.now() + 60_000) return cached.token;
  const res = await fetch(`https://login.microsoftonline.com/${encodeURIComponent(TENANT)}/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: CLIENT, client_secret: SECRET, scope: "https://graph.microsoft.com/.default", grant_type: "client_credentials" }),
  });
  const j: any = await res.json().catch(() => ({}));
  if (!res.ok || !j.access_token) throw new Error(`graph_auth_failed ${res.status} ${j.error ?? ""}`.trim());
  cached = { token: j.access_token, exp: Date.now() + Number(j.expires_in ?? 3600) * 1000 };
  return cached.token;
}

// path is either a full URL (a nextLink/deltaLink, which Graph hands back absolute) or a path under v1.0.
export async function graph(method: string, path: string, body?: any, headers: Record<string, string> = {}) {
  const url = path.startsWith("http") ? path : `${GRAPH}${path}`;
  const res = await fetch(url, {
    method,
    headers: { Authorization: `Bearer ${await graphToken()}`, Accept: "application/json", "Content-Type": "application/json", ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text(); let json: any = null; try { json = JSON.parse(text); } catch {}
  return { ok: res.ok, status: res.status, json, text };
}

export const mbx = (m: string) => `/users/${encodeURIComponent(m)}`;
