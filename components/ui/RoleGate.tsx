import type { ReactNode } from "react";
import { LockKeyhole } from "lucide-react-native";
import { EmptyState } from "./EmptyState";
import { ErrorState } from "./ErrorState";
import { LoadingState } from "./LoadingState";
import { useAuth } from "@/lib/auth";
import { canAccessFeature, type ProtectedFeature } from "@/lib/permissions";

type RoleGateProps = {
  feature: ProtectedFeature;
  children: ReactNode;
  featureName?: string;
};

export function RoleGate({
  feature,
  children,
  featureName = "هذه الشاشة",
}: RoleGateProps) {
  const { profile, loading, profileError, refreshProfile } = useAuth();

  if (loading) {
    return <LoadingState message="جاري التحقق من صلاحيات الحساب..." />;
  }

  if (!profile) {
    return (
      <ErrorState
        title="تعذر التحقق من حسابك"
        message={profileError ?? "لم يتم العثور على ملف مستخدم مرتبط بجلسة الدخول."}
        retryLabel="إعادة تحميل الحساب"
        onRetry={() => void refreshProfile()}
      />
    );
  }

  if (!canAccessFeature(profile.role, feature)) {
    return (
      <EmptyState
        title="لا تملك صلاحية فتح هذه الشاشة"
        message={`الوصول إلى ${featureName} غير متاح للدور الحالي. اطلب من مدير المؤسسة مراجعة صلاحيات حسابك.`}
        icon={<LockKeyhole size={30} color="#617586" />}
      />
    );
  }

  return <>{children}</>;
}
