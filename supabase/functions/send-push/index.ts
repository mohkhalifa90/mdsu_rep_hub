// Supabase Edge Function: send-push
// Called by a Database Webhook on INSERT into public.notifications.
// Sends the notification to every phone the user is signed in on, through
// Firebase Cloud Messaging (FCM HTTP v1) – Android, iPhone and the web version
// (iPhone "Add to Home Screen" app). Each message carries the number of unread
// notifications, shown as the red number on the app icon.
//
// Secrets (Supabase → Edge Functions → Secrets):
//   FIREBASE_SERVICE_ACCOUNT  the whole JSON file from Firebase → Project settings → Service accounts
//   WEBHOOK_SECRET            any long random text; the webhook sends it in the header x-webhook-secret
//   WEB_APP_URL (optional)    the web version's address, opened when a web notification is tapped
//                             (default https://mdsu-rep-hub.pages.dev)
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.

import { createClient } from "npm:@supabase/supabase-js@2";

interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

interface NotificationRow {
  id: string;
  user_id: string;
  title: string;
  body: string;
  link: string | null;
}

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

// ---------- Google OAuth token from the service account (cached ~55 min) ----------
let cachedToken: { value: string; expires: number } | null = null;

function base64url(data: ArrayBuffer | Uint8Array | string): string {
  const bytes = typeof data === "string"
    ? new TextEncoder().encode(data)
    : new Uint8Array(data instanceof Uint8Array ? data : new Uint8Array(data));
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\\n/g, "")
    .replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

export async function googleAccessToken(sa: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && cachedToken.expires > now + 60) return cachedToken.value;

  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64url(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const unsigned = `${header}.${claims}`;
  const key = await importPrivateKey(sa.private_key);
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned),
  );
  const jwt = `${unsigned}.${base64url(signature)}`;

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  if (!res.ok) throw new Error(`Google token error ${res.status}: ${await res.text()}`);
  const json = await res.json() as { access_token: string; expires_in: number };
  cachedToken = { value: json.access_token, expires: now + json.expires_in };
  return json.access_token;
}

// ---------- FCM message ----------
const webAppUrl = () => (Deno.env.get("WEB_APP_URL") || "https://mdsu-rep-hub.pages.dev").replace(/\/+$/, "");

export function fcmMessage(token: string, n: NotificationRow, unread = 1) {
  const badge = Math.max(1, unread);
  // Each notification gets its own key/tag. Without this, FCM treats notifications as
  // "collapsible": while a phone sleeps it keeps only the newest one, and the phone
  // replaces the previous notification instead of showing both.
  const key = n.id.replace(/-/g, "").slice(0, 32);
  return {
    message: {
      token,
      notification: { title: n.title, body: n.body || undefined },
      data: { link: n.link ?? "", notification_id: n.id, badge: String(badge) },
      android: {
        priority: "HIGH",
        collapse_key: key,
        notification: { sound: "default", notification_count: badge, tag: key },
      },
      apns: { headers: { "apns-collapse-id": key }, payload: { aps: { sound: "default", badge } } },
      webpush: {
        headers: { Urgency: "high", Topic: key },
        notification: {
          icon: `${webAppUrl()}/icons/Icon-192.png`,
          badge: `${webAppUrl()}/icons/Icon-192.png`,
          tag: key,
        },
        fcm_options: { link: webAppUrl() },
      },
    },
  };
}

/** Unread notifications of the user (this one included) – the number on the app icon. */
async function unreadCount(userId: string): Promise<number> {
  try {
    const { count } = await supabase
      .from("notifications")
      .select("id", { count: "exact", head: true })
      .eq("user_id", userId)
      .is("read_at", null);
    return count ?? 1;
  } catch {
    return 1;
  }
}

Deno.serve(async (req) => {
  const secret = Deno.env.get("WEBHOOK_SECRET");
  if (secret && req.headers.get("x-webhook-secret") !== secret) {
    return new Response("Unauthorized", { status: 401 });
  }

  let payload: { type?: string; table?: string; record?: NotificationRow };
  try {
    payload = await req.json();
  } catch {
    return new Response("Bad JSON", { status: 400 });
  }
  const n = payload.record;
  if (payload.type !== "INSERT" || payload.table !== "notifications" || !n) {
    return Response.json({ skipped: true });
  }

  const saJson = Deno.env.get("FIREBASE_SERVICE_ACCOUNT");
  if (!saJson) return Response.json({ skipped: "FIREBASE_SERVICE_ACCOUNT not set" });
  const sa = JSON.parse(saJson) as ServiceAccount;

  const { data: devices, error } = await supabase
    .from("device_tokens")
    .select("token")
    .eq("user_id", n.user_id);
  if (error) return new Response(error.message, { status: 500 });
  if (!devices?.length) return Response.json({ sent: 0 });

  const accessToken = await googleAccessToken(sa);
  const unread = await unreadCount(n.user_id);
  let sent = 0;
  const stale: string[] = [];
  const errors: string[] = [];

  for (const { token } of devices as { token: string }[]) {
    const res = await fetch(
      `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(fcmMessage(token, n, unread)),
      },
    );
    if (res.ok) {
      sent++;
    } else {
      const text = await res.text();
      // Forget a token only when FCM says the token itself is dead – never because the
      // message was rejected for another reason (that would silently unregister every phone).
      const deadToken = res.status === 404 || text.includes("UNREGISTERED") ||
        (res.status === 400 && /registration token/i.test(text));
      if (deadToken) {
        stale.push(token);
      } else {
        console.error("FCM error", res.status, text);
        errors.push(`${res.status}: ${text.slice(0, 300)}`);
      }
    }
  }

  if (stale.length) await supabase.from("device_tokens").delete().in("token", stale);
  return Response.json(errors.length ? { sent, removed: stale.length, errors } : { sent, removed: stale.length });
});
