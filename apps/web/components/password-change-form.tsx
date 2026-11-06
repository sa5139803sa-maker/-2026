"use client";

import { useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { LockKeyhole } from "lucide-react";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";

export function PasswordChangeForm() {
  const router = useRouter();
  const [password, setPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);

    if (
      password.length < 10 ||
      !/[A-Z]/.test(password) ||
      !/[a-z]/.test(password) ||
      !/[0-9]/.test(password)
    ) {
      setError("استخدم 10 أحرف على الأقل، مع حرف كبير وحرف صغير ورقم.");
      return;
    }

    if (password !== confirmPassword) {
      setError("كلمتا المرور غير متطابقتين.");
      return;
    }

    setBusy(true);
    try {
      const response = await fetch("/api/admin/accounts", {
        method: "POST",
        credentials: "same-origin",
        cache: "no-store",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "change_password", new_password: password }),
      });
      const result = await response.json().catch(() => null);

      if (!response.ok) {
        throw new Error(
          result && typeof result.error === "string"
            ? result.error
            : "تعذر تغيير كلمة المرور.",
        );
      }

      // Password changes can invalidate the current access token. Clear the
      // browser session and require a fresh login with the new password.
      await createSupabaseBrowserClient().auth.signOut();
      setPassword("");
      setConfirmPassword("");
      router.replace("/login?password_changed=1");
      router.refresh();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "تعذر تغيير كلمة المرور.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="auth-card">
      <div className="auth-head">
        <div className="brand">
          <span className="brand-mark"><LockKeyhole size={21} /></span>
          <div><div className="brand-name">حماية الحساب</div><div className="brand-en">ACCOUNT SECURITY</div></div>
        </div>
        <h1>تغيير كلمة المرور المؤقتة</h1>
        <p>يجب تعيين كلمة مرور جديدة قبل فتح لوحة الإدارة.</p>
      </div>
      <form className="stack" onSubmit={(event) => void submit(event)}>
        <div className="field">
          <label htmlFor="new-password">كلمة المرور الجديدة</label>
          <input
            id="new-password"
            type="password"
            autoComplete="new-password"
            value={password}
            onChange={(event) => setPassword(event.target.value)}
            required
            minLength={10}
          />
          <small>10 أحرف على الأقل، وحرف كبير وصغير ورقم.</small>
        </div>
        <div className="field">
          <label htmlFor="confirm-password">تأكيد كلمة المرور</label>
          <input
            id="confirm-password"
            type="password"
            autoComplete="new-password"
            value={confirmPassword}
            onChange={(event) => setConfirmPassword(event.target.value)}
            required
            minLength={10}
          />
        </div>
        {error ? <div className="error" role="alert">{error}</div> : null}
        <button className="primary-button full-width" type="submit" disabled={busy}>
          {busy ? "جارٍ التحديث..." : "حفظ كلمة المرور"}
        </button>
      </form>
    </div>
  );
}