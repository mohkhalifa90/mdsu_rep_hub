// Supabase Edge Function: admin-reset-password
// The Head of Education sets a temporary password for a representative who forgot theirs.
// Only signed-in, active officers/admins may call it. Deploy with JWT verification ON (default).
//
// Request body: { "user_id": "<uuid>", "password": "<at least 8 characters>" }
// SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided automatically.

import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

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
    return json({ error: "Only the Head of Education can reset passwords" }, 403);
  }

  // 3) Validate the request
  let body: { user_id?: string; password?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Bad request" }, 400);
  }
  const userId = body.user_id ?? "";
  const password = body.password ?? "";
  if (!/^[0-9a-f-]{36}$/i.test(userId)) return json({ error: "Unknown user" }, 400);
  if (password.length < 8) return json({ error: "The password must be at least 8 characters" }, 400);
  if (userId === who.user.id) return json({ error: "Use “Change my password” for your own account" }, 400);

  const { data: target } = await admin.from("profiles").select("id, full_name").eq("id", userId).maybeSingle();
  if (!target) return json({ error: "Unknown user" }, 404);

  // 4) Set the new password
  const { error } = await admin.auth.admin.updateUserById(userId, { password });
  if (error) return json({ error: error.message }, 500);

  await admin.from("notifications").insert({
    user_id: userId,
    title: "Your password was reset",
    body: "The Head of Education gave you a temporary password. Please change it under More → My profile.",
    link: "more",
  });
  return json({ ok: true, user: target.full_name });
});
