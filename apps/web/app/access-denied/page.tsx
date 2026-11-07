import Link from "next/link";

export default function AccessDeniedPage() {
  return (
    <main className="page-center">
      <section className="auth-card">
        <div className="error">ليس لهذا الحساب صلاحية دخول لوحة الويب.</div>
        <h1 style={{ fontSize: 21, margin: "18px 0 8px" }}>استخدم تطبيق العاملين</h1>
        <p className="muted small" style={{ lineHeight: 1.9 }}>
          حسابات المشغّل والمحصّل والمشرف مخصصة لتطبيق Android. أما مدير المنصة ومدير المؤسسة
          فيستخدمان لوحة الويب وفق الدور المحدد.
        </p>
        <Link className="primary-button full-width" href="/login">العودة إلى تسجيل الدخول</Link>
      </section>
    </main>
  );
}