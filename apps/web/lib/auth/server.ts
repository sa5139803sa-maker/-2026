import "server-only";

import { redirect } from "next/navigation";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export type WebRole = "platform_admin" | "manager";

export type WebProfile = {
  id: string;
  organization_id: string | null;
  display_name: string;
  role: WebRole;
  username: string | null;
  must_change_password: boolean;
};

export async function getCurrentWebProfile(): Promise<WebProfile | null> {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
    error: userError,
  } = await supabase.auth.getUser();

  if (userError || !user) return null;

  const { data, error } = await supabase
    .from("profiles")
    .select("id,organization_id,display_name,role,username,must_change_password")
    .eq("id", user.id)
    .maybeSingle();

  if (error || !data) return null;
  if (data.role !== "platform_admin" && data.role !== "manager") return null;

  if (data.role === "platform_admin" && data.organization_id !== null) {
    return null;
  }

  if (data.role === "manager" && !data.organization_id) {
    return null;
  }

  return data as WebProfile;
}

export async function requireWebRole(expectedRole: WebRole): Promise<WebProfile> {
  const profile = await getCurrentWebProfile();

  if (!profile) {
    redirect("/login?reason=web_access");
  }

  if (profile.must_change_password) {
    redirect("/change-password");
  }

  if (profile.role !== expectedRole) {
    redirect(profile.role === "platform_admin" ? "/platform" : "/organization");
  }

  return profile;
}