"use client";

import { useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { ArrowLeft, Droplets, LockKeyhole, UserRound } from "lucide-react";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { validateLoginIdentifier, usernameToAuthEmail } from "@/lib/auth/username";

export function LoginForm() {
  const router = useRouter();
  const [identifier, setIdentifier] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);

    if (!validateLoginIdentifier(identifier) || password.length < 1) {
      setError("أدخل اسم المستخدم أو البريد الإلكتروني وكلمة المرور.");
      return;
    }

    setBusy(true);
    const supabase = createSupabaseBrowserClient();
    const { data, error: signInError } = await supabase.auth.signInWithPassword({
      email: usernameToAuthEmail(identifier),
      password,
    });

    if (signInError || !data.user) {
      setBusy(false);
      setError("تعذر تسجيل الدخول. تحقق من بيانات الدخول وحاول مجددًا.");
      return;
    }

    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select("id,organization_id,role,must_change_password")
      .eq("id", data.user.id)
      .maybeSingle();

    if (
      profileError ||
      !profile ||
      (profile.role !== "platform_admin" && profile.role !== "manager") ||
      (profile.role === "platform_admin" && profile.organization_id !== null) ||
      (profile.role === "manager" && !profile.organization_id)
    ) {
      await supabase.auth.signOut();
      setBusy(false);
      setError("هذا الحساب غير مخصص للوحة الويب أو لا يملك نطاق صلاحيات صالحًا.");
      return;
    }

    setBusy(false);
    if (profile.must_change_password) {
      router.replace("/change-password");
    } else {
      router.replace(profile.role === "platform_admin" ? "/platform" : "/organization");
    }
    router.refresh();
  }

  return (
    <form className="stack" onSubmit={(event) => void submit(event)}>
      <div className="field">
        <label htmlFor="identifier">اسم المستخدم أو البريد الإلكتروني</label>
        <div style={{ position: "relative" }}>
          <UserRound size={17} style={{ position: "absolute", right: 13, top: 14, color: "#617586" }} />
          <input
            id="identifier"
            name="username"
            autoComplete="username"
            value={identifier}
            onChange={(event) => setIdentifier(event.target.value)}
            placeholder="أدخل اسم المستخدم أو البريد"
            required
            dir="auto"
            style={{ paddingRight: 40 }}
          />
        </div>
      </div>

      <div className="field">
        <label htmlFor="password">كلمة المرور</label>
        <div style={{ position: "relative" }}>
          <LockKeyhole size={17} style={{ position: "absolute", right: 13, top: 14, color: "#617586" }} />
          <input
            id="password"
            name="password"
            type="password"
            autoComplete="current-password"
            value={password}
            onChange={(event) => setPassword(event.target.value)}
            placeholder="أدخل كلمة المرور"
            required
            style={{ paddingRight: 40 }}
          />
        </div>
      </div>

      {error ? <div className="error" role="alert">{error}</div> : null}

      <button className="primary-button full-width" type="submit" disabled={busy}>
        {busy ? "جارٍ التحقق..." : "تسجيل الدخول"}
        <ArrowLeft size={17} />
      </button>
      <p className="small muted" style={{ textAlign: "center", lineHeight: 1.9, margin: 0 }}>
        هذه البوابة مخصصة لمدير المنصة ومدير المؤسسة. حسابات العاملين الميدانيين تستخدم تطبيق Android.
      </p>
    </form>
  );
}