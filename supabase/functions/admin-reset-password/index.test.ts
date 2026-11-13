// Test with a fake Supabase (auth + database). Run: deno test --allow-net --allow-env index.test.ts
function assertEquals(actual: unknown, expected: unknown) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a !== e) throw new Error(`expected ${e} but got ${a}`);
}

const OFFICER = "00000000-0000-0000-0000-00000000000a";
const REP = "00000000-0000-0000-0000-000000000001";
const tokens: Record<string, string> = { "officer-token": OFFICER, "rep-token": REP };
const profiles: Record<string, { role: string; active: boolean; full_name: string }> = {
  [OFFICER]: { role: "officer", active: true, full_name: "Head of Education" },
  [REP]: { role: "rep", active: true, full_name: "Lina Berg" },
};
const passwordSet: Record<string, string> = {};
const notified: string[] = [];

const fake = Deno.serve({ port: 54398, onListen() {} }, async (req) => {
  const u = new URL(req.url);
  const auth = req.headers.get("Authorization")?.replace("Bearer ", "") ?? "";
  if (u.pathname === "/auth/v1/user") {
    const id = tokens[auth];
    return id ? Response.json({ id, aud: "authenticated", role: "authenticated" }) : Response.json({ msg: "bad jwt" }, { status: 401 });
  }
  if (u.pathname.startsWith("/auth/v1/admin/users/") && req.method === "PUT") {
    if (auth !== "service-key") return Response.json({ msg: "not admin" }, { status: 403 });
    const id = u.pathname.split("/").pop()!;
    passwordSet[id] = (await req.json()).password;
    return Response.json({ id });
  }
  if (u.pathname === "/rest/v1/profiles") {
    const id = (u.searchParams.get("id") ?? "").replace("eq.", "");
    const p = profiles[id];
    return Response.json(p ? [{ id, ...p }] : []);
  }
  if (u.pathname === "/rest/v1/notifications" && req.method === "POST") {
    const row = await req.json();
    notified.push(Array.isArray(row) ? row[0].user_id : row.user_id);
    return new Response(null, { status: 201 });
  }
  return new Response("not found", { status: 404 });
});

Deno.env.set("SUPABASE_URL", "http://localhost:54398");
Deno.env.set("SUPABASE_ANON_KEY", "anon-key");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "service-key");
await import("./index.ts");

const call = (token: string | null, body: unknown) =>
  fetch("http://localhost:8000", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });

const opts = { sanitizeResources: false, sanitizeOps: false };

Deno.test({ name: "not signed in → 401", ...opts, async fn() {
  const r = await call(null, { user_id: REP, password: "Temp-12345" });
  assertEquals(r.status, 401); await r.body?.cancel();
} });

Deno.test({ name: "a representative cannot reset passwords → 403", ...opts, async fn() {
  const r = await call("rep-token", { user_id: OFFICER, password: "Temp-12345" });
  assertEquals(r.status, 403); await r.body?.cancel();
  assertEquals(passwordSet[OFFICER], undefined);
} });

Deno.test({ name: "too short password → 400", ...opts, async fn() {
  const r = await call("officer-token", { user_id: REP, password: "short" });
  assertEquals(r.status, 400); await r.body?.cancel();
} });

Deno.test({ name: "officer resets a rep's password and the rep is notified", ...opts, async fn() {
  const r = await call("officer-token", { user_id: REP, password: "Temp-12345" });
  assertEquals(r.status, 200);
  assertEquals(await r.json(), { ok: true, user: "Lina Berg" });
  assertEquals(passwordSet[REP], "Temp-12345");
  assertEquals(notified, [REP]);
} });

Deno.test({ name: "officer cannot reset own password here → 400", ...opts, async fn() {
  const r = await call("officer-token", { user_id: OFFICER, password: "Temp-12345" });
  assertEquals(r.status, 400); await r.body?.cancel();
  await fake.shutdown();
  setTimeout(() => Deno.exit(0), 50);
} });
