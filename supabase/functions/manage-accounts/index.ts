import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(url, serviceKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

type AppRole = "platform_admin" | "manager" | "operator" | "collector" | "supervisor";
type Profile = {
  id: string;
  organization_id: string | null;
  role: AppRole;
  username: string | null;
  display_name: string;
  must_change_password: boolean;
};

function response(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function normalizeUsername(value: unknown): string {
  if (typeof value !== "string") throw new Error("أدخل اسم مستخدم صالحاً.");
  const normalized = value.normalize("NFKC").trim().toLocaleLowerCase();
  if (
    normalized.length < 3 ||
    normalized.length > 40 ||
    !/^[\p{L}\p{N}._-]+$/u.test(normalized)
  ) throw new Error("اسم المستخدم من 3 إلى 40 حرفاً، ويسمح بالحروف والأرقام والنقطة والشرطة.");
  return normalized;
}

function usernameEmail(username: string): string {
  const bytes = new TextEncoder().encode(username);
  const encoded = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return `u-${encoded}@login.water-management.invalid`;
}

function temporaryPassword(): string {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%";
  const bytes = new Uint8Array(20);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (byte) => alphabet[byte % alphabet.length]).join("");
}

async function audit(
  actorId: string,
  action: string,
  targetUserId: string | null,
  organizationId: string | null,
  metadata: Record<string, unknown> = {},
) {
  const { error } = await admin.from("account_audit_log").insert({
    actor_id: actorId,
    target_user_id: targetUserId,
    organization_id: organizationId,
    action,
    metadata,
  });
  if (error) console.error("account audit insert failed", error.message);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return response(405, { error: "Method not allowed" });

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return response(401, { error: "يلزم تسجيل الدخول." });

  const caller = createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: authData, error: authError } = await caller.auth.getUser();
  if (authError || !authData.user) return response(401, { error: "جلسة الدخول غير صالحة." });

  const actorId = authData.user.id;
  const { data: actorData, error: actorError } = await admin
    .from("profiles")
    .select("id,organization_id,role,username,display_name,must_change_password")
    .eq("id", actorId)
    .single();
  if (actorError || !actorData) return response(403, { error: "لا يوجد ملف صلاحيات صالح لهذا الحساب." });

  const actor = actorData as Profile;
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return response(400, { error: "صيغة الطلب غير صالحة." });
  }

  const action = body.action;
  if (actor.must_change_password && action !== "change_password") {
    return response(403, { error: "يجب تغيير كلمة المرور المؤقتة أولاً." });
  }

  try {
    if (action === "change_password") {
      const password = body.new_password;
      if (typeof password !== "string" || password.length < 10 ||
          !/[A-Z]/.test(password) || !/[a-z]/.test(password) || !/[0-9]/.test(password)) {
        return response(400, { error: "كلمة المرور الجديدة يجب أن تكون 10 أحرف على الأقل، وتحتوي حرفاً كبيراً وصغيراً ورقماً." });
      }
      if (!actor.must_change_password) {
        return response(409, { error: "هذا الحساب لا يحتاج إلى تغيير كلمة المرور المؤقتة." });
      }
      const { error: passwordError } = await admin.auth.admin.updateUserById(actorId, { password });
      if (passwordError) return response(400, { error: "تعذر تحديث كلمة المرور." });
      const { error: profileError } = await admin
        .from("profiles")
        .update({ must_change_password: false })
        .eq("id", actorId);
      if (profileError) return response(500, { error: "تم تحديث كلمة المرور لكن تعذر إكمال حالة الحساب. أعد المحاولة." });
      await audit(actorId, "password_changed", actorId, actor.organization_id);
      return response(200, { success: true });
    }

    if (action === "list_users") {
      if (actor.role !== "platform_admin" && actor.role !== "manager") {
        return response(403, { error: "لا تملك صلاحية إدارة الحسابات." });
      }
      let organizations: Array<{ id: string; name: string; account_limit: number; account_count: number }> = [];
      let organizationId = actor.organization_id;
      if (actor.role === "platform_admin") {
        const { data, error } = await admin.from("organizations").select("id,name,account_limit").order("name");
        if (error) throw error;
        const all = data ?? [];
        organizations = await Promise.all(all.map(async (org) => {
          const { count } = await admin.from("profiles").select("id", { count: "exact", head: true }).eq("organization_id", org.id);
          return { ...org, account_count: count ?? 0 };
        }));
        if (typeof body.organization_id === "string") organizationId = body.organization_id;
        else organizationId = null;
      } else if (!organizationId) {
        return response(403, { error: "حساب المدير غير مرتبط بمؤسسة." });
      }

      if (!organizationId) return response(200, { organizations, users: [], organization: null });
      if (actor.role === "platform_admin" && !organizations.some((org) => org.id === organizationId)) {
        return response(404, { error: "المؤسسة غير موجودة." });
      }
      const [{ data: org, error: orgError }, { data: users, error: usersError }, { count }] = await Promise.all([
        admin.from("organizations").select("id,name,account_limit").eq("id", organizationId).single(),
        admin.from("profiles").select("id,display_name,username,role,must_change_password,created_at").eq("organization_id", organizationId).order("created_at"),
        admin.from("profiles").select("id", { count: "exact", head: true }).eq("organization_id", organizationId),
      ]);
      if (orgError || usersError) throw orgError ?? usersError;
      return response(200, {
        organizations,
        organization: org ? { ...org, account_count: count ?? 0 } : null,
        users: users ?? [],
      });
    }

    if (action === "create_user") {
      if (actor.role !== "platform_admin" && actor.role !== "manager") {
        return response(403, { error: "لا تملك صلاحية إنشاء الحسابات." });
      }
      const username = normalizeUsername(body.username);
      const displayName = typeof body.display_name === "string" ? body.display_name.trim() : "";
      if (displayName.length < 2 || displayName.length > 120) throw new Error("أدخل الاسم الكامل بشكل صحيح.");
      const role = body.role as AppRole;
      const allowedRoles: AppRole[] = actor.role === "platform_admin"
        ? ["manager", "operator", "collector", "supervisor"]
        : ["operator", "collector", "supervisor"];
      if (!allowedRoles.includes(role)) return response(403, { error: "لا يمكنك إنشاء حساب بهذا الدور." });

      const organizationId = actor.role === "manager"
        ? actor.organization_id
        : (typeof body.organization_id === "string" ? body.organization_id : null);
      if (!organizationId) throw new Error("اختر المؤسسة أولاً.");

      const password = temporaryPassword();
      const { data: created, error: createError } = await admin.auth.admin.createUser({
        email: usernameEmail(username),
        password,
        email_confirm: true,
        user_metadata: { display_name: displayName, managed_account: true },
      });
      if (createError || !created.user) throw createError ?? new Error("تعذر إنشاء حساب الدخول.");

      const { error: assignError } = await admin.rpc("assign_managed_user", {
        p_user_id: created.user.id,
        p_organization_id: organizationId,
        p_role: role,
        p_username: username,
        p_display_name: displayName,
      });
      if (assignError) {
        await admin.auth.admin.deleteUser(created.user.id);
        const message = assignError.message.includes("account limit")
          ? "وصلت المؤسسة إلى الحد الأقصى للحسابات."
          : assignError.message.includes("Username already exists")
            ? "اسم المستخدم مستخدم بالفعل."
            : "تعذر إكمال إنشاء الحساب.";
        return response(409, { error: message });
      }
      await audit(actorId, "account_created", created.user.id, organizationId, { username, role });
      return response(200, { success: true, username, temporary_password: password });
    }

    if (action === "reset_password") {
      if (actor.role !== "platform_admin" && actor.role !== "manager") {
        return response(403, { error: "لا تملك صلاحية إعادة تعيين كلمات المرور." });
      }
      const targetId = typeof body.target_user_id === "string" ? body.target_user_id : "";
      if (!targetId || targetId === actorId) return response(400, { error: "اختر حساباً آخر لإعادة تعيين كلمة مروره." });
      const { data: target, error: targetError } = await admin
        .from("profiles")
        .select("id,organization_id,role,username")
        .eq("id", targetId)
        .single();
      if (targetError || !target) return response(404, { error: "الحساب المطلوب غير موجود." });
      if (actor.role === "manager" &&
          (target.organization_id !== actor.organization_id || target.role === "manager" || target.role === "platform_admin")) {
        return response(403, { error: "يمكنك إعادة تعيين كلمات مرور موظفي مؤسستك فقط." });
      }
      if (target.role === "platform_admin") return response(403, { error: "لا يمكن إعادة تعيين حساب مدير منصة من هذه الواجهة." });

      const { data: targetAuthData } = await admin.auth.admin.getUserById(targetId);
      const loginIdentifier = target.username ?? targetAuthData?.user?.email ?? null;
      const password = temporaryPassword();
      const { error: flagError } = await admin.from("profiles")
        .update({
          must_change_password: true,
          session_invalid_before: new Date(Date.now() + 1000).toISOString(),
        })
        .eq("id", targetId);
      if (flagError) throw flagError;
      const { error: passwordError } = await admin.auth.admin.updateUserById(targetId, { password });
      if (passwordError) {
        await admin.from("profiles").update({ must_change_password: false }).eq("id", targetId);
        throw passwordError;
      }
      await audit(actorId, "password_reset", targetId, target.organization_id, { username: loginIdentifier });
      return response(200, {
        success: true,
        username: loginIdentifier,
        temporary_password: password,
        previous_sessions_fenced: true,
      });
    }

    if (action === "set_limit") {
      if (actor.role !== "platform_admin") return response(403, { error: "تعديل حدود الحسابات متاح لمدير المنصة فقط." });
      const organizationId = typeof body.organization_id === "string" ? body.organization_id : "";
      const limit = Number(body.account_limit);
      if (!organizationId || !Number.isInteger(limit) || limit < 1 || limit > 1000) {
        return response(400, { error: "الحد يجب أن يكون عدداً صحيحاً بين 1 و1000." });
      }
      const { error } = await admin.rpc("set_organization_account_limit", {
        p_organization_id: organizationId,
        p_account_limit: limit,
      });
      if (error) {
        if (error.message.includes("current account count")) {
          return response(409, { error: "لا يمكن خفض الحد عن عدد الحسابات الموجودة حالياً." });
        }
        throw error;
      }
      await audit(actorId, "account_limit_changed", null, organizationId, { account_limit: limit });
      return response(200, { success: true, account_limit: limit });
    }

    return response(400, { error: "العملية المطلوبة غير معروفة." });
  } catch (error) {
    console.error("manage-accounts failed", error);
    return response(400, { error: error instanceof Error ? error.message : "تعذر إكمال العملية." });
  }
});
