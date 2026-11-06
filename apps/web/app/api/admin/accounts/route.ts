import { NextRequest, NextResponse } from "next/server";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { getPublicSupabaseConfig } from "@/lib/supabase/env";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function jsonError(message: string, status: number) {
  return NextResponse.json(
    { error: message },
    {
      status,
      headers: { "Cache-Control": "private, no-store, max-age=0" },
    },
  );
}

export async function POST(request: NextRequest) {
  const origin = request.headers.get("origin");
  if (!origin || origin !== request.nextUrl.origin) {
    return jsonError("طلب غير مسموح.", 403);
  }

  const contentType = request.headers.get("content-type")?.split(";")[0];
  if (contentType !== "application/json") {
    return jsonError("صيغة الطلب غير مدعومة.", 415);
  }

  const declaredLength = Number(request.headers.get("content-length") ?? "0");
  if (declaredLength > 8_192) {
    return jsonError("حجم الطلب أكبر من المسموح.", 413);
  }

  const rawBody = await request.text();
  if (rawBody.length > 8_192) {
    return jsonError("حجم الطلب أكبر من المسموح.", 413);
  }

  let body: Record<string, unknown>;
  try {
    const parsed: unknown = JSON.parse(rawBody);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return jsonError("صيغة الطلب غير صالحة.", 400);
    }
    body = parsed as Record<string, unknown>;
  } catch {
    return jsonError("صيغة الطلب غير صالحة.", 400);
  }

  const action = body.action;
  const supabase = await createServerSupabaseClient();
  const {
    data: { user },
    error: userError,
  } = await supabase.auth.getUser();

  if (userError || !user) {
    return jsonError("انتهت جلسة الدخول. سجّل الدخول مجددًا.", 401);
  }

  const { data: profile, error: profileError } = await supabase
    .from("profiles")
    .select("id,organization_id,role,must_change_password")
    .eq("id", user.id)
    .maybeSingle();

  if (
    profileError ||
    !profile ||
    (profile.role !== "platform_admin" && profile.role !== "manager")
  ) {
    return jsonError("لا تملك صلاحية استخدام لوحة الويب.", 403);
  }

  if (profile.role === "platform_admin" && profile.organization_id !== null) {
    return jsonError("نطاق حساب مدير المنصة غير صالح.", 403);
  }

  if (profile.role === "manager" && !profile.organization_id) {
    return jsonError("حساب مدير المؤسسة غير مرتبط بمؤسسة.", 403);
  }

  if (profile.must_change_password && action !== "change_password") {
    return jsonError("يجب تغيير كلمة المرور المؤقتة أولًا.", 403);
  }

  if (action === "change_password") {
    if (!profile.must_change_password) {
      return jsonError("لا توجد مطالبة بتغيير كلمة المرور لهذا الحساب.", 409);
    }
    if (typeof body.new_password !== "string") {
      return jsonError("كلمة المرور الجديدة غير صالحة.", 400);
    }
  } else if (action === "create_organization") {
    if (
      profile.role !== "platform_admin" ||
      typeof body.name !== "string" ||
      body.name.trim().length < 2 ||
      body.name.trim().length > 120
    ) {
      return jsonError("إنشاء المؤسسة متاح لمدير المنصة وباسم صالح فقط.", 403);
    }
    body = { action, name: body.name.trim() };
  } else if (action === "list_users") {
    if (profile.role === "manager") {
      body = { action, organization_id: profile.organization_id };
    } else if (
      body.organization_id !== undefined &&
      (typeof body.organization_id !== "string" ||
        !UUID_PATTERN.test(body.organization_id))
    ) {
      return jsonError("معرّف المؤسسة غير صالح.", 400);
    } else {
      body = body.organization_id
        ? { action, organization_id: body.organization_id }
        : { action };
    }
  } else if (action === "create_user") {
    const allowedRoles =
      profile.role === "platform_admin"
        ? ["manager", "operator", "collector", "supervisor"]
        : ["operator", "collector", "supervisor"];

    if (
      typeof body.username !== "string" ||
      typeof body.display_name !== "string" ||
      typeof body.role !== "string" ||
      !allowedRoles.includes(body.role)
    ) {
      return jsonError("بيانات إنشاء الحساب غير مكتملة أو غير مسموحة.", 400);
    }

    if (profile.role === "manager") {
      body = {
        action,
        username: body.username,
        display_name: body.display_name,
        role: body.role,
        organization_id: profile.organization_id,
      };
    } else if (
      typeof body.organization_id !== "string" ||
      !UUID_PATTERN.test(body.organization_id)
    ) {
      return jsonError("اختر مؤسسة صحيحة.", 400);
    } else {
      body = {
        action,
        username: body.username,
        display_name: body.display_name,
        role: body.role,
        organization_id: body.organization_id,
      };
    }
  } else if (action === "reset_password") {
    if (
      typeof body.target_user_id !== "string" ||
      !UUID_PATTERN.test(body.target_user_id)
    ) {
      return jsonError("الحساب المطلوب غير صالح.", 400);
    }
    body = { action, target_user_id: body.target_user_id };
  } else if (action === "set_limit") {
    if (
      profile.role !== "platform_admin" ||
      typeof body.organization_id !== "string" ||
      !UUID_PATTERN.test(body.organization_id) ||
      !Number.isInteger(body.account_limit) ||
      Number(body.account_limit) < 1 ||
      Number(body.account_limit) > 1_000
    ) {
      return jsonError("لا يمكن تنفيذ تعديل حد الحسابات بهذه البيانات.", 403);
    }
    body = {
      action,
      organization_id: body.organization_id,
      account_limit: Number(body.account_limit),
    };
  } else {
    return jsonError("العملية المطلوبة غير معروفة.", 400);
  }

  // getUser() above verifies the identity with Supabase Auth. The session is
  // used only as a bearer credential for the existing JWT-protected function.
  const {
    data: { session },
    error: sessionError,
  } = await supabase.auth.getSession();

  if (sessionError || !session || session.user.id !== user.id) {
    return jsonError("تعذر التحقق من جلسة الدخول.", 401);
  }

  const { url, publishableKey } = getPublicSupabaseConfig();

  try {
    const upstream = await fetch(`${url}/functions/v1/manage-accounts`, {
      method: "POST",
      cache: "no-store",
      headers: {
        "Content-Type": "application/json",
        apikey: publishableKey,
        Authorization: `Bearer ${session.access_token}`,
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(12_000),
    });

    const payload: unknown = await upstream.json().catch(() => null);
    return NextResponse.json(
      payload ?? { error: "تعذر استلام استجابة صالحة من خدمة الحسابات." },
      {
        status: upstream.status,
        headers: { "Cache-Control": "private, no-store, max-age=0" },
      },
    );
  } catch {
    return jsonError("تعذر الاتصال بخدمة إدارة الحسابات.", 502);
  }
}