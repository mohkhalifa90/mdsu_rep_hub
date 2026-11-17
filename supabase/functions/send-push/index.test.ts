// End-to-end test of send-push with a fake Google (OAuth + FCM) and a fake database API.
// Run: deno test --allow-net --allow-env index.test.ts
function assert(cond: unknown, msg = "assertion failed"): asserts cond {
  if (!cond) throw new Error(msg);
}
function assertEquals(actual: unknown, expected: unknown) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a !== e) throw new Error(`expected ${e} but got ${a}`);
}

// ---------- a real RSA key pair, like a Firebase service account ----------
const keys = await crypto.subtle.generateKey(
  { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
  true,
  ["sign", "verify"],
);
const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", keys.privateKey));
const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8)).match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----\n`;

// ---------- fake database (PostgREST) ----------
let tokens = [
  { token: "good-token", user_id: "u1" },
  { token: "dead-token", user_id: "u1" },
  { token: "other-user", user_id: "u2" },
];
const db = Deno.serve({ port: 54399, onListen() {} }, (req) => {
  const url = new URL(req.url);
  if (url.pathname.endsWith("/notifications")) {
    // unread count (HEAD with Prefer: count=exact)
    return new Response(null, { status: 200, headers: { "Content-Range": "*/3" } });
  }
  if (!url.pathname.endsWith("/device_tokens")) return new Response("not found", { status: 404 });
  if (req.method === "GET") {
    const user = url.searchParams.get("user_id")!.replace("eq.", "");
    return Response.json(tokens.filter((t) => t.user_id === user).map(({ token }) => ({ token })));
  }
  if (req.method === "DELETE") {
    const list = url.searchParams.get("token")!.replace(/^in\.\(|\)$/g, "").split(",").map((s) => s.replace(/"/g, ""));
    tokens = tokens.filter((t) => !list.includes(t.token));
    return new Response(null, { status: 204 });
  }
  return new Response("bad", { status: 400 });
});

// ---------- fake Google: verifies the JWT signature, records FCM sends ----------
const sentTo: string[] = [];
const realFetch = globalThis.fetch;
globalThis.fetch = async (input: string | URL | Request, init?: RequestInit) => {
  const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
  if (url === "https://oauth2.googleapis.com/token") {
    const assertion = new URLSearchParams(String(init!.body)).get("assertion")!;
    const [h, c, s] = assertion.split(".");
    const sig = Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (ch) => ch.charCodeAt(0));
    const ok = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", keys.publicKey, sig, new TextEncoder().encode(`${h}.${c}`));
    const claims = JSON.parse(atob(c.replace(/-/g, "+").replace(/_/g, "/")));
    if (!ok || claims.iss !== "push@test.iam.gserviceaccount.com") return new Response("bad jwt", { status: 400 });
    return Response.json({ access_token: "ya29.test", expires_in: 3600 });
  }
  if (url.startsWith("https://fcm.googleapis.com/v1/projects/mdsu-test/messages:send")) {
    assertEquals(new Headers(init!.headers).get("Authorization"), "Bearer ya29.test");
    const body = JSON.parse(String(init!.body));
    if (body.message.token === "dead-token") {
      return new Response(JSON.stringify({ error: { status: "NOT_FOUND", details: [{ errorCode: "UNREGISTERED" }] } }), { status: 404 });
    }
    sentTo.push(body.message.token);
    assertEquals(body.message.notification.title, "Time report approved");
    assertEquals(body.message.data.link, "hours");
    assertEquals(body.message.data.badge, "3");                         // red number on the app icon
    assertEquals(body.message.android.notification.notification_count, 1); // Samsung adds them up
    assertEquals(body.message.webpush.fcm_options.link, "https://mdsu-rep-hub.pages.dev");
    assertEquals(body.message.android.collapse_key, "n1");             // never replaces an earlier one
    assertEquals(body.message.webpush.notification.tag, "n1");
    return Response.json({ name: "projects/mdsu-test/messages/1" });
  }
  return realFetch(input, init);
};

Deno.env.set("SUPABASE_URL", "http://localhost:54399");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "service-role-test");
Deno.env.set("WEBHOOK_SECRET", "s3cret");
Deno.env.set("FIREBASE_SERVICE_ACCOUNT", JSON.stringify({
  project_id: "mdsu-test",
  client_email: "push@test.iam.gserviceaccount.com",
  private_key: pem,
}));

await import("./index.ts"); // starts the function on port 8000

const hook = (secret: string, record: unknown) =>
  realFetch("http://localhost:8000", {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-webhook-secret": secret },
    body: JSON.stringify({ type: "INSERT", table: "notifications", schema: "public", record, old_record: null }),
  });

const record = { id: "n1", user_id: "u1", title: "Time report approved", body: "325 SEK will be paid out", link: "hours" };

Deno.test({
  name: "wrong webhook secret is rejected",
  sanitizeResources: false, sanitizeOps: false,
  async fn() {
    const res = await hook("wrong", record);
    assertEquals(res.status, 401);
    await res.body?.cancel();
  },
});

Deno.test({
  name: "sends to the user's phones and removes dead tokens",
  sanitizeResources: false, sanitizeOps: false,
  async fn() {
    const res = await hook("s3cret", record);
    assertEquals(res.status, 200);
    assertEquals(await res.json(), { sent: 1, removed: 1 });
    assertEquals(sentTo, ["good-token"]);                       // not other-user, not dead-token
    assert(!tokens.some((t) => t.token === "dead-token"));      // cleaned up
    assert(tokens.some((t) => t.token === "other-user"));       // untouched
  },
});

Deno.test({
  name: "user without phones: nothing sent",
  sanitizeResources: false, sanitizeOps: false,
  async fn() {
    const res = await hook("s3cret", { ...record, user_id: "nobody" });
    assertEquals(await res.json(), { sent: 0 });
    await db.shutdown();
    setTimeout(() => Deno.exit(0), 50); // stop the function's server
  },
});
