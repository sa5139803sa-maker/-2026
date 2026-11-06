"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { LogOut } from "lucide-react";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";

export function LogoutButton({ compact = false }: { compact?: boolean }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);

  async function logout() {
    setBusy(true);
    const { error } = await createSupabaseBrowserClient().auth.signOut();
    setBusy(false);
    if (error) return;
    router.replace("/login");
    router.refresh();
  }

  return (
    <button
      className="ghost-button full-width"
      type="button"
      onClick={() => void logout()}
      disabled={busy}
      aria-label="تسجيل الخروج"
    >
      <LogOut size={16} />
      {!compact ? <span className="logout-label">{busy ? "جارٍ الخروج..." : "تسجيل الخروج"}</span> : null}
    </button>
  );
}