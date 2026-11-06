import { createClient } from "npm:@supabase/supabase-js@2";

const url = Deno.env.get("SUPABASE_URL");
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

const admin =
  url && serviceKey
    ? createClient(url, serviceKey, {
        auth: { persistSession: false, autoRefreshToken: false },
      })
    : null;

function json(status: number, body: Record<string, unknown>, headers: HeadersInit = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store, max-age=0",
      "X-Content-Type-Options": "nosniff",
      ...headers,
    },
  });
}

function normalizeDigits(value: string): string {
  return value.replace(/[٠-٩۰-۹]/g, (digit) => {
    const arabic = "٠١٢٣٤٥٦٧٨٩";
    const persian = "۰۱۲۳۴۵۶۷۸۹";
    const index = arabic.indexOf(digit);
    return String(index >= 0 ? index : persian.indexOf(digit));
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return json(405, { error: "الطريقة غير مسموحة." }, { Allow: "POST" });
  }

  if (!admin) {
    console.error("subscriber lookup service is not configured");
    return json(503, { error: "الخدمة غير متاحة حاليًا." });
  }

  const contentType = req.headers.get("content-type")?.split(";")[0]?.trim();
  if (contentType !== "application/json") {
    return json(415, { error: "صيغة الطلب غير مدعومة." });
  }

  const declaredLength = Number(req.headers.get("content-length") ?? "0");
  if (declaredLength > 2_048) {
    return json(413, { error: "حجم الطلب أكبر من المسموح." });
  }

  let body: unknown;
  try {
    const raw = await req.text();
    if (raw.length > 2_048) {
      return json(413, { error: "حجم الطلب أكبر من المسموح." });
    }
    body = JSON.parse(raw);
  } catch {
    return json(400, { error: "بيانات البحث غير صالحة." });
  }

  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return json(400, { error: "بيانات البحث غير صالحة." });
  }

  const payload = body as Record<string, unknown>;
  const numberInput =
    typeof payload.subscriber_number === "string" ||
    typeof payload.subscriber_number === "number"
      ? normalizeDigits(String(payload.subscriber_number)).trim()
      : "";
  const phone =
    typeof payload.phone === "string" ? payload.phone.trim() : "";
  const clientIp =
    typeof payload.client_ip === "string" && payload.client_ip.length <= 64
      ? payload.client_ip.trim()
      : "0.0.0.0";

  if (!/^\d{6}$/.test(numberInput) || Number(numberInput) < 100_000 || Number(numberInput) > 999_999) {
    return json(400, { error: "أدخل رقم اشتراك صحيحًا من 6 خانات." });
  }

  if (phone.length < 7 || phone.length > 32) {
    return json(400, { error: "أدخل رقم الهاتف المسجل للاشتراك." });
  }

  // The same-origin Next.js route supplies the client IP from the hosting
  // proxy. Database HMAC limits also apply per number and per phone.
  try {
    const { data, error } = await admin.rpc("lookup_subscriber_portal", {
      p_subscriber_number: Number(numberInput),
      p_phone: phone,
      p_client_ip: clientIp,
    });

    if (error) {
      console.error("subscriber lookup database request failed", error.code);
      return json(503, { error: "تعذر تنفيذ الاستعلام حاليًا. حاول لاحقًا." });
    }

    const result = Array.isArray(data) ? data[0] : null;
    if (!result) {
      return json(503, { error: "تعذر تنفيذ الاستعلام حاليًا. حاول لاحقًا." });
    }

    if (result.rate_limited) {
      const retryAfter = Math.max(1, Number(result.retry_after_seconds) || 60);
      return json(
        429,
        { error: "تم تجاوز عدد محاولات البحث المسموح. حاول بعد قليل." },
        { "Retry-After": String(retryAfter) },
      );
    }

    if (!result.found) {
      // Same response for unknown number, wrong phone, and inactive subscriber.
      return json(404, { found: false, error: "لم نعثر على اشتراك يطابق البيانات المدخلة." });
    }

    return json(200, {
      found: true,
      subscriber: {
        subscriber_number: String(result.subscriber_number).padStart(6, "0"),
        full_name: result.full_name,
        pump_name: result.pump_name,
        pump_code: result.pump_code,
        phone_last4: result.phone_last4,
      },
    });
  } catch {
    console.error("subscriber lookup request failed");
    return json(503, { error: "تعذر تنفيذ الاستعلام حاليًا. حاول لاحقًا." });
  }
});
