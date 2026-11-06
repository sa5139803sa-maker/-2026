"use client";

import { useCallback, useEffect, useMemo, useState, type FormEvent } from "react";
import { Copy, Plus, RefreshCw, ShieldCheck, UsersRound, Building2 } from "lucide-react";

type Mode = "platform" | "organization";
type ManagedRole = "manager" | "operator" | "collector" | "supervisor";
type Organization = {
  id: string;
  name: string;
  account_limit: number;
  account_count: number;
};
type ManagedUser = {
  id: string;
  display_name: string;
  username: string | null;
  role: ManagedRole;
  must_change_password: boolean;
};
type ListResponse = {
  organizations?: Organization[];
  organization: Organization | null;
  users: ManagedUser[];
};
type Props = {
  mode: Mode;
  organizationId?: string;
};

const roleLabels: Record<ManagedRole, string> = {
  manager: "مدير المؤسسة",
  operator: "مشغّل",
  collector: "محصّل",
  supervisor: "مشرف",
};

async function callAccountsApi<T>(payload: Record<string, unknown>): Promise<T> {
  const response = await fetch("/api/admin/accounts", {
    method: "POST",
    credentials: "same-origin",
    cache: "no-store",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });

  const result: unknown = await response.json().catch(() => null);
  if (!response.ok) {
    const message =
      result && typeof result === "object" && "error" in result &&
      typeof result.error === "string"
        ? result.error
        : "تعذر تنفيذ العملية المطلوبة.";
    throw new Error(message);
  }

  return result as T;
}

export function AccountConsole({ mode, organizationId }: Props) {
  const isPlatform = mode === "platform";
  const [organizations, setOrganizations] = useState<Organization[]>([]);
  const [organization, setOrganization] = useState<Organization | null>(null);
  const [selectedOrganizationId, setSelectedOrganizationId] = useState(organizationId ?? "");
  const [users, setUsers] = useState<ManagedUser[]>([]);
  const [username, setUsername] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [newRole, setNewRole] = useState<ManagedRole>(isPlatform ? "manager" : "operator");
  const [accountLimit, setAccountLimit] = useState("");
  const [temporaryCredentials, setTemporaryCredentials] = useState<{
    username: string;
    password: string;
  } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [copied, setCopied] = useState(false);

  const load = useCallback(async (targetOrganizationId?: string | null) => {
    setBusy(true);
    setError(null);
    try {
      const payload: Record<string, unknown> = { action: "list_users" };
      if (targetOrganizationId) payload.organization_id = targetOrganizationId;

      const data = await callAccountsApi<ListResponse>(payload);
      setOrganizations(data.organizations ?? []);
      setOrganization(data.organization);
      setUsers(data.users ?? []);
      if (data.organization) {
        setAccountLimit(String(data.organization.account_limit));
      } else if (isPlatform && !targetOrganizationId) {
        setAccountLimit("");
      }
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "تعذر تحميل الحسابات.");
    } finally {
      setBusy(false);
    }
  }, [isPlatform]);

  useEffect(() => {
    void load(isPlatform ? null : organizationId);
  }, [isPlatform, organizationId, load]);

  const totalAccounts = useMemo(
    () => organizations.reduce((total, item) => total + item.account_count, 0),
    [organizations],
  );
  const totalCapacity = useMemo(
    () => organizations.reduce((total, item) => total + item.account_limit, 0),
    [organizations],
  );

  async function selectOrganization(id: string) {
    setSelectedOrganizationId(id);
    setTemporaryCredentials(null);
    setNotice(null);
    await load(id);
  }

  async function createAccount(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setNotice(null);
    setTemporaryCredentials(null);

    if (!username.trim() || !displayName.trim()) {
      setError("أدخل اسم المستخدم والاسم الكامل.");
      return;
    }

    const organizationToUse = isPlatform ? selectedOrganizationId : organizationId;
    if (!organizationToUse) {
      setError("اختر المؤسسة أولًا.");
      return;
    }

    setBusy(true);
    try {
      const result = await callAccountsApi<{
        username: string;
        temporary_password: string;
      }>({
        action: "create_user",
        organization_id: organizationToUse,
        username,
        display_name: displayName,
        role: newRole,
      });

      setTemporaryCredentials({
        username: result.username,
        password: result.temporary_password,
      });
      setUsername("");
      setDisplayName("");
      setNotice("تم إنشاء الحساب. احفظ كلمة المرور المؤقتة وسلمها لصاحب الحساب عبر قناة آمنة.");
      await load(organizationToUse);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "تعذر إنشاء الحساب.");
    } finally {
      setBusy(false);
    }
  }

  async function resetPassword(user: ManagedUser) {
    setError(null);
    setNotice(null);
    setTemporaryCredentials(null);
    setBusy(true);
    try {
      const result = await callAccountsApi<{
        username: string | null;
        temporary_password: string;
      }>({
        action: "reset_password",
        target_user_id: user.id,
      });
      setTemporaryCredentials({
        username: result.username ?? user.username ?? "الحساب",
        password: result.temporary_password,
      });
      setNotice("تم إصدار كلمة مؤقتة جديدة. سيُطلب من المستخدم تغييرها عند الدخول التالي.");
      await load(isPlatform ? selectedOrganizationId : organizationId);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "تعذرت إعادة تعيين كلمة المرور.");
    } finally {
      setBusy(false);
    }
  }

  async function saveLimit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!organization || !/^\d+$/.test(accountLimit)) return;
    const limit = Number(accountLimit);
    if (!Number.isInteger(limit) || limit < 1 || limit > 1_000) {
      setError("يجب أن يكون الحد بين 1 و1000 حساب.");
      return;
    }

    setBusy(true);
    setError(null);
    setNotice(null);
    try {
      await callAccountsApi({
        action: "set_limit",
        organization_id: organization.id,
        account_limit: limit,
      });
      setNotice("تم تحديث حد الحسابات بنجاح.");
      await load(organization.id);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "تعذر تحديث حد الحسابات.");
    } finally {
      setBusy(false);
    }
  }

  async function copyTemporaryCredentials() {
    if (!temporaryCredentials) return;
    try {
      await navigator.clipboard.writeText(
        `اسم المستخدم: ${temporaryCredentials.username}\nكلمة المرور المؤقتة: ${temporaryCredentials.password}`,
      );
      setCopied(true);
    } catch {
      setError("تعذر النسخ تلقائيًا. انسخ بيانات الدخول يدويًا.");
    }
  }

  const availableRoles: ManagedRole[] = isPlatform
    ? ["manager", "operator", "collector", "supervisor"]
    : ["operator", "collector", "supervisor"];

  return (
    <div className="content-width">
      {error ? <div className="error" role="alert" style={{ marginBottom: 14 }}>{error}</div> : null}
      {notice ? <div className="success" role="status" style={{ marginBottom: 14 }}>{notice}</div> : null}

      {isPlatform ? (
        <>
          <div className="grid-3">
            <div className="surface-card stat-card">
              <div><div className="stat-caption">المؤسسات المسجلة</div><div className="stat-value">{organizations.length}</div></div>
              <div className="stat-icon"><Building2 size={20} /></div>
            </div>
            <div className="surface-card stat-card">
              <div><div className="stat-caption">الحسابات الحالية</div><div className="stat-value">{totalAccounts}</div></div>
              <div className="stat-icon"><UsersRound size={20} /></div>
            </div>
            <div className="surface-card stat-card">
              <div><div className="stat-caption">السعة الإجمالية للحسابات</div><div className="stat-value">{totalCapacity}</div></div>
              <div className="stat-icon"><ShieldCheck size={20} /></div>
            </div>
          </div>

          <div className="section-heading">
            <div><h2>المؤسسات</h2><p>اختر مؤسسة لإدارة حساباتها وحدها المسموح.</p></div>
            <button className="ghost-button" type="button" onClick={() => void load(selectedOrganizationId || null)} disabled={busy}>
              <RefreshCw size={15} /> تحديث
            </button>
          </div>

          <div className="org-list">
            {organizations.map((item) => (
              <button
                key={item.id}
                type="button"
                className={`org-row ${selectedOrganizationId === item.id ? "selected" : ""}`}
                onClick={() => void selectOrganization(item.id)}
                aria-pressed={selectedOrganizationId === item.id}
              >
                <span>
                  <strong>{item.name}</strong>
                  <small>{item.account_count} حساب مستخدم من أصل {item.account_limit}</small>
                </span>
                <span className="badge">{selectedOrganizationId === item.id ? "محددة" : "إدارة المؤسسة"}</span>
              </button>
            ))}
            {organizations.length === 0 && !busy ? (
              <div className="surface-card muted small">لا توجد مؤسسات مسجلة في قاعدة التطوير حتى الآن.</div>
            ) : null}
          </div>
        </>
      ) : null}

      {organization ? (
        <div className="section-heading">
          <div>
            <h2>{organization.name}</h2>
            <p>{isPlatform ? "إدارة حسابات المؤسسة وحدودها من نطاق المنصة." : "يمكنك إدارة حسابات موظفي مؤسستك فقط."}</p>
          </div>
        </div>
      ) : null}

      {!isPlatform || organization ? (
        <>
          {organization ? (
            <div className="surface-card" style={{ marginBottom: 16 }}>
              <div className="quota-line">
                <div>
                  <h3>استهلاك الحسابات</h3>
                  <div className="stat-caption">يشمل مدير المؤسسة وجميع الموظفين.</div>
                </div>
                <div className="quota-number">{organization.account_count} / {organization.account_limit}</div>
              </div>
              {isPlatform ? (
                <form className="form-grid" onSubmit={(event) => void saveLimit(event)}>
                  <div className="field">
                    <label htmlFor="account-limit">الحد الأعلى للحسابات</label>
                    <input
                      id="account-limit"
                      type="number"
                      min="1"
                      max="1000"
                      step="1"
                      value={accountLimit}
                      onChange={(event) => setAccountLimit(event.target.value)}
                      required
                    />
                  </div>
                  <div style={{ alignSelf: "end" }}>
                    <button className="secondary-button" type="submit" disabled={busy}>
                      حفظ الحد
                    </button>
                  </div>
                </form>
              ) : (
                <div className="notice">تعديل حد الحسابات متاح لمدير المنصة من لوحة الويب.</div>
              )}
            </div>
          ) : null}

          <div className="grid-2">
            <section className="surface-card">
              <h3>إنشاء حساب جديد</h3>
              <p className="muted small" style={{ lineHeight: 1.8, margin: "7px 0 16px" }}>
                يصدر النظام كلمة مرور عشوائية مؤقتة وتُعرض لك مرة واحدة بعد نجاح الإنشاء.
              </p>
              <form className="stack" onSubmit={(event) => void createAccount(event)}>
                <div className="field">
                  <label htmlFor="new-username">اسم المستخدم</label>
                  <input
                    id="new-username"
                    autoComplete="off"
                    autoCapitalize="none"
                    dir="auto"
                    value={username}
                    onChange={(event) => setUsername(event.target.value)}
                    minLength={3}
                    maxLength={40}
                    required
                    placeholder="مثال: operator01"
                  />
                  <small>من 3 إلى 40 حرفًا؛ حروف أو أرقام أو نقطة أو شرطة.</small>
                </div>
                <div className="field">
                  <label htmlFor="new-display-name">الاسم الكامل</label>
                  <input
                    id="new-display-name"
                    value={displayName}
                    onChange={(event) => setDisplayName(event.target.value)}
                    minLength={2}
                    maxLength={120}
                    required
                    placeholder="اسم صاحب الحساب"
                  />
                </div>
                <div className="field">
                  <label htmlFor="new-role">نوع الحساب</label>
                  <select
                    id="new-role"
                    value={newRole}
                    onChange={(event) => setNewRole(event.target.value as ManagedRole)}
                  >
                    {availableRoles.map((role) => <option key={role} value={role}>{roleLabels[role]}</option>)}
                  </select>
                </div>
                <button className="primary-button full-width" type="submit" disabled={busy || (isPlatform && !selectedOrganizationId)}>
                  <Plus size={16} /> إنشاء الحساب
                </button>
                {isPlatform && !selectedOrganizationId ? (
                  <small className="muted">اختر مؤسسة من القائمة أولًا.</small>
                ) : null}
              </form>
            </section>

            <section className="surface-card">
              <h3>حسابات المؤسسة</h3>
              <p className="muted small" style={{ lineHeight: 1.8, margin: "7px 0 16px" }}>
                لا يمكن لمدير المؤسسة إدارة مديري المؤسسات أو حسابات المنصة.
              </p>
              <div className="table-wrap">
                <table>
                  <thead>
                    <tr><th>المستخدم</th><th>الدور</th><th>الحالة</th><th>الإجراء</th></tr>
                  </thead>
                  <tbody>
                    {users.map((user) => (
                      <tr key={user.id}>
                        <td>
                          <strong>{user.display_name}</strong>
                          <span className="subline">{user.username ?? "دخول بالبريد الإلكتروني"}</span>
                        </td>
                        <td>{roleLabels[user.role]}</td>
                        <td>{user.must_change_password ? <span className="badge" style={{ background: "var(--warning-bg)", color: "#946200" }}>تغيير كلمة المرور</span> : <span className="badge" style={{ background: "var(--success-bg)", color: "#146C43" }}>نشط</span>}</td>
                        <td>
                          {user.role !== "manager" || isPlatform ? (
                            <div className="row-actions">
                              <button
                                className="secondary-button"
                                type="button"
                                onClick={() => void resetPassword(user)}
                                disabled={busy}
                              >
                                <RefreshCw size={13} /> إعادة تعيين
                              </button>
                            </div>
                          ) : <span className="muted small">—</span>}
                        </td>
                      </tr>
                    ))}
                    {users.length === 0 ? (
                      <tr><td colSpan={4} className="muted">لا توجد حسابات لعرضها.</td></tr>
                    ) : null}
                  </tbody>
                </table>
              </div>
            </section>
          </div>
        </>
      ) : isPlatform ? (
        <div className="surface-card" style={{ marginTop: 16 }}>
          <h3>إدارة حسابات المؤسسة</h3>
          <p className="muted small">اختر مؤسسة لعرض الحسابات وإدارة كلمات المرور وحد الحسابات. لا يمكن إنشاء مؤسسة من هذه الشاشة.</p>
        </div>
      ) : null}

      {temporaryCredentials ? (
        <section className="surface-card" style={{ marginTop: 16 }}>
          <div className="section-heading" style={{ marginTop: 0 }}>
            <div><h2>بيانات الدخول المؤقتة</h2><p>انسخها وسلمها لصاحب الحساب عبر قناة آمنة. لن تُعرض مرة أخرى.</p></div>
          </div>
          <div className="temp-password">
            <span>{temporaryCredentials.password}</span>
            <button className="secondary-button" type="button" onClick={() => void copyTemporaryCredentials()}>
              <Copy size={14} /> {copied ? "تم النسخ" : "نسخ"}
            </button>
          </div>
          <div className="small muted" style={{ marginTop: 9 }}>
            اسم المستخدم: <b dir="auto">{temporaryCredentials.username}</b>
          </div>
          <button
            className="ghost-button"
            type="button"
            style={{ marginTop: 12 }}
            onClick={() => { setTemporaryCredentials(null); setCopied(false); }}
          >
            إخفاء بيانات الدخول
          </button>
        </section>
      ) : null}
    </div>
  );
}