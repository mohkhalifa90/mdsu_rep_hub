// Supabase Edge Function: admin-create-user
// The Head of Education creates an account for a representative (useful when sign-up is closed).
// The account is active at once and gets a temporary password that must be changed at first sign-in.
// Only signed-in, active officers/admins may call it. Deploy with JWT verification ON (default).
//
// Request body: { "full_name": "Name Surname", "email": "abc12345@student.mdu.se" }
// Answer:       { "ok": true, "password": "<temporary password>" }
// SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided automatically.

import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

// Easy to read and type: no 0/O, 1/l/I
function tempPassword(length = 10): string {
  const chars = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => chars[b % chars.length]).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) return json({ error: "Not signed in" }, 401);

  // 1) Who is calling?
  const asCaller = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data: who, error: whoErr } = await asCaller.auth.getUser();
  if (whoErr || !who?.user) return json({ error: "Not signed in" }, 401);

  // 2) Is the caller the Head of Education (or admin)?
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data: me } = await admin.from("profiles").select("role, active").eq("id", who.user.id).maybeSingle();
  if (!me || !me.active || (me.role !== "officer" && me.role !== "admin")) {
    return json({ error: "Only the Head of Education can create accounts" }, 403);
  }

  // 3) Validate the request
  let body: { full_name?: string; email?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Bad request" }, 400);
  }
  const name = (body.full_name ?? "").trim();
  const email = (body.email ?? "").trim().toLowerCase();
  if (name.length < 2) return json({ error: "Write the name" }, 400);
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ error: "Write a valid email address" }, 400);

  // 4) Create the account (the invite lets it through even when sign-up is closed)
  await admin.from("account_invites").upsert({ email });
  const password = tempPassword();
  const { data, error } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { full_name: name },
  });
  if (error || !data?.user) {
    await admin.from("account_invites").delete().eq("email", email);
    const msg = error?.message ?? "Could not create the account";
    return json({ error: /already|registered|exists/i.test(msg) ? "This email already has an account" : msg }, 400);
  }
  return json({ ok: true, user_id: data.user.id, password });
});
