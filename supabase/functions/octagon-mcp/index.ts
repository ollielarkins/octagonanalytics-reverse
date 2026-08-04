// octagon-mcp — remote MCP server (Streamable HTTP / JSON-RPC 2.0) for claude.ai
// connectors. Exposes a get_dashboard tool returning live recruitment aggregates
// (no PII) from public.dashboard_json(). Add this function's URL as an
// organization connector in claude.ai Team/Enterprise settings; recruiters then
// share the same live data. verify_jwt=false (public; aggregates only).
//
// Connector URL: https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/octagon-mcp
import { createClient } from "jsr:@supabase/supabase-js@2";
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const SERVER = { name: "octagon-analytics", version: "1.0.0" };
const TOOLS = [{
  name: "get_dashboard",
  description: "Live Octagon recruitment dashboard from RecruitCRM: firm KPIs, the 2026 hiring funnel (CV sent -> interview -> offer -> placed), per-consultant performance (attributed by job owner) and the deal pipeline. Aggregates only, no candidate PII. Takes no arguments. Call this at the start of a conversation to show the recruitment dashboard, and whenever the user asks about firm-wide or per-consultant recruitment performance.",
  inputSchema: { type: "object", properties: {}, additionalProperties: false },
}];

const rpc = (id: any, result: any) => ({ jsonrpc: "2.0", id, result });
const rpcErr = (id: any, code: number, message: string) => ({ jsonrpc: "2.0", id, error: { code, message } });

async function handle(m: any): Promise<any> {
  const { id, method, params } = m ?? {};
  if (method === "initialize") return rpc(id, { protocolVersion: params?.protocolVersion || "2025-06-18", capabilities: { tools: {} }, serverInfo: SERVER });
  if (typeof method === "string" && method.startsWith("notifications/")) return null;
  if (method === "ping") return rpc(id, {});
  if (method === "tools/list") return rpc(id, { tools: TOOLS });
  if (method === "tools/call") {
    const name = params?.name;
    if (name === "get_dashboard") {
      const { data, error } = await db.rpc("dashboard_json");
      if (error) return rpc(id, { content: [{ type: "text", text: "Error: " + error.message }], isError: true });
      return rpc(id, { content: [{ type: "text", text: JSON.stringify(data) }] });
    }
    return rpcErr(id, -32602, "Unknown tool: " + name);
  }
  if (id === undefined || id === null) return null;
  return rpcErr(id, -32601, "Method not found: " + method);
}

Deno.serve(async (req) => {
  const headers: Record<string, string> = { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "*", "Access-Control-Allow-Methods": "POST, GET, OPTIONS" };
  if (req.method === "OPTIONS") return new Response(null, { headers });
  if (req.method === "GET") return new Response(JSON.stringify({ name: SERVER.name, version: SERVER.version, transport: "streamable-http", note: "POST JSON-RPC 2.0 MCP messages here" }), { headers });
  let msg: any; try { msg = await req.json(); } catch { return new Response(JSON.stringify(rpcErr(null, -32700, "Parse error")), { headers }); }
  if (Array.isArray(msg)) {
    const out = (await Promise.all(msg.map(handle))).filter((x) => x !== null);
    return new Response(out.length ? JSON.stringify(out) : "", { status: out.length ? 200 : 202, headers });
  }
  const res = await handle(msg);
  if (res === null) return new Response("", { status: 202, headers });
  return new Response(JSON.stringify(res), { headers });
});
