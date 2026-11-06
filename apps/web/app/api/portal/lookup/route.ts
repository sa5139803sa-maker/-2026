import { isIP } from "node:net";
import { NextRequest, NextResponse } from "next/server";
import { getPublicSupabaseConfig } from "@/lib/supabase/env";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const revalidate = 0;

function error(message: string, status: number, retryAfter?: string) {
  return NextResponse.json(
    { found: false, error: message },
    {
      status,
      headers: {
        "Cache-Control": "no-store, max-age=0",
        ...(retryAfter ? { "Retry-After": retryAfter } : {}),
      },
    },
  );
}

export async function POST(request: NextRequest) {
  if (request.headers.get("origin") !== request.nextUrl.origin) {
    return error("طلب غير مسموح.", 403);
  }

  if (request.headers.get("content-type")?.split(";")[0]?.trim() !== "application/json") {
    return error("صيغة الطلب غير مدعومة.", 415);
  }

  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (contentLength > 2_048) {
    return error("حجم الطلب أكبر من المسموح.", 413);
  }

  let body: unknown;
  try {
    const raw = await request.text();
    if (raw.length > 2_048) return error("حجم الطلب أكبر من المسموح.", 413);
    body = JSON.parse(raw);
  } catch {
    return error("بيانات البحث غير صالحة.", 400);
  }

  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return error("بيانات البحث غير صالحة.", 400);
  }

  const input = body as Record<string, unknown>;
  if (
    (typeof input.subscriber_number !== "string" &&
      typeof input.subscriber_number !== "number") ||
    typeof input.phone !== "string"
  ) {
    return error("أدخل رقم الاشتراك ورقم الهاتف.", 400);
  }

  const subscriberNumber = String(input.subscriber_number).trim();
  const phone = input.phone.trim();
  if (!/^\d{6}$/.test(subscriberNumber) || phone.length < 7 || phone.length > 32) {
    return error("تحقق من رقم الاشتراك ورقم الهاتف.", 400);
  }

  // Production hosting must sanitize/overwrite forwarded client-IP headers.
  // Never deploy this endpoint behind a proxy that accepts arbitrary XFF values.
  const forwarded = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  const realIp = request.headers.get("x-real-ip")?.trim();
  const candidateIp = forwarded || realIp || "";
  const clientIp =
    isIP(candidateIp) !== 0
      ? candidateIp
      : process.env.NODE_ENV !== "production"
        ? "127.0.0.1"
        : "";

  if (!clientIp) {
    return error("تعذر التحقق من مصدر الاتصال. حاول لاحقًا.", 503);
  }

  try {
    const { url, publishableKey } = getPublicSupabaseConfig();
    const upstream = await fetch(`${url}/functions/v1/subscriber-lookup`, {
      method: "POST",
      cache: "no-store",
      signal: AbortSignal.timeout(10_000),
      headers: {
        "Content-Type": "application/json",
        apikey: publishableKey,
        Authorization: `Bearer ${publishableKey}`,
      },
      body: JSON.stringify({
        subscriber_number: subscriberNumber,
        phone,
        // Supabase Edge Function applies independent per-IP, per-number and
        // per-phone HMAC rate limits. The raw value is not stored in the DB.
        client_ip: clientIp,
      }),
    });

    const result: unknown = await upstream.json().catch(() => null);
    const response = NextResponse.json(
      result ?? { found: false, error: "تعذر تنفيذ الاستعلام." },
      {
        status: upstream.status,
        headers: {
          "Cache-Control": "no-store, max-age=0",
          ...(upstream.headers.get("retry-after")
            ? { "Retry-After": upstream.headers.get("retry-after")! }
            : {}),
        },
      },
    );
    return response;
  } catch {
    return error("تعذر تنفيذ الاستعلام حاليًا. حاول لاحقًا.", 503);
  }
}