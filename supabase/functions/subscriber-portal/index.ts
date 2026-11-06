import { createClient } from "npm:@supabase/supabase-js@2";
import { trustedGatewayIp } from "./trusted-gateway-ip.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type",
  "Access-Control-Max-Age": "600",
  "Vary": "Origin",
};

function jsonResponse(body: Record<string, unknown>, status = 200, extraHeaders: HeadersInit = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      ...extraHeaders,
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "private, no-store, max-age=0",
      "Pragma": "no-cache",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

function normalizeArabicDigits(value: string): string {
  return value.replace(/[٠-٩۰-۹]/g, (digit) => {
    const code = digit.charCodeAt(0);
    return String(code >= 0x06f0 ? code - 0x06f0 : code - 0x0660);
  });
}



Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { status: 200, headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "الطريقة غير مدعومة." }, 405, { Allow: "POST, OPTIONS" });
  }

  if (req.headers.get("content-type")?.split(";")[0].trim() !== "application/json") {
    return jsonResponse({ error: "صيغة الطلب غير مدعومة." }, 415);
  }

  const declaredLength = Number(req.headers.get("content-length") ?? "0");
  if (declaredLength > 2_048) {
    return jsonResponse({ error: "حجم الطلب أكبر من المسموح." }, 413);
  }

  const rawBody = await req.text();
  if (rawBody.length > 2_048) {
    return jsonResponse({ error: "حجم الطلب أكبر من المسموح." }, 413);
  }

  let payload: unknown;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    return jsonResponse({ error: "بيانات الاستعلام غير صالحة." }, 400);
  }

  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return jsonResponse({ error: "بيانات الاستعلام غير صالحة." }, 400);
  }

  const input = payload as Record<string, unknown>;
  const subscriberNumber =
    typeof input.subscriber_number === "string"
      ? normalizeArabicDigits(input.subscriber_number.trim())
      : "";

  const phone = typeof input.phone === "string" ? input.phone.trim() : "";
  if (!/^\d{6}$/.test(subscriberNumber) || phone.length < 7 || phone.length > 32) {
    // Identical response for malformed and unknown identities.
    return jsonResponse({ found: false });
  }

  const clientIp = trustedGatewayIp(req.headers);
  if (!clientIp) {
    return jsonResponse({ error: "خدمة الاستعلام غير متاحة مؤقتًا." }, 503);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    console.error("subscriber portal service configuration missing");
    return jsonResponse({ error: "خدمة الاستعلام غير متاحة مؤقتًا." }, 503);
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
      detectSessionInUrl: false,
    },
    global: { fetch },
  });

  const { data, error } = await admin.rpc("lookup_subscriber_portal", {
    p_subscriber_number: Number(subscriberNumber),
    p_phone: phone,
    p_client_ip: clientIp,
  });

  if (error) {
    console.error("subscriber lookup failed", error.message);
    return jsonResponse({ error: "تعذر تنفيذ الاستعلام. حاول لاحقًا." }, 503);
  }

  const result = Array.isArray(data) ? data[0] : null;
  if (!result) {
    return jsonResponse({ found: false });
  }

  if (result.rate_limited) {
    const retryAfter = Math.max(1, Number(result.retry_after_seconds) || 60);
    return jsonResponse(
      { error: "تجاوزت عدد محاولات الاستعلام. حاول بعد قليل." },
      429,
      { "Retry-After": String(retryAfter) },
    );
  }

  if (!result.found) {
    // Do not reveal whether the number exists, is inactive, or the phone mismatched.
    return jsonResponse({ found: false });
  }

  return jsonResponse({
    found: true,
    subscriber: {
      subscriber_number: String(result.subscriber_number).padStart(6, "0"),
      full_name: result.full_name,
      pump_name: result.pump_name,
      pump_code: result.pump_code,
      phone_last4: result.phone_last4,
    },
  });
});