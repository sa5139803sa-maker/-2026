"use client";

import { useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { Search, ShieldCheck, UserRound, Droplets, RefreshCw } from "lucide-react";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";

type SubscriberResult = {
  subscriber_number: string;
  full_name: string;
  pump_name: string | null;
  pump_code: string | null;
  phone_last4: string;
};

type LookupResponse = {
  found?: boolean;
  subscriber?: SubscriberResult;
  error?: string;
};

function toLatinDigits(value: string): string {
  return value.replace(/[٠-٩۰-۹]/g, (digit) => {
    const code = digit.charCodeAt(0);
    return String(code >= 0x06f0 ? code - 0x06f0 : code - 0x0660);
  });
}

export function SubscriberLookupForm() {
  const router = useRouter();
  const [subscriberNumber, setSubscriberNumber] = useState("");
  const [phone, setPhone] = useState("");
  const [result, setResult] = useState<SubscriberResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setResult(null);
    setError(null);

    const normalizedNumber = toLatinDigits(subscriberNumber.trim());
    const normalizedPhone = phone.trim();

    if (!/^\d{6}$/.test(normalizedNumber)) {
      setError("أدخل رقم المشترك المكوّن من 6 خانات.");
      return;
    }

    if (normalizedPhone.length < 7 || normalizedPhone.length > 32) {
      setError("أدخل رقم الهاتف المسجل لدى المؤسسة.");
      return;
    }

    setBusy(true);
    try {
      const { data, error: requestError } = await createSupabaseBrowserClient()
        .functions.invoke<LookupResponse>("subscriber-portal", {
          body: {
            subscriber_number: normalizedNumber,
            phone: normalizedPhone,
          },
        });

      if (requestError) {
        const status = (requestError as { context?: Response }).context?.status;
        if (status === 429) throw new Error("تجاوزت عدد محاولات الاستعلام. حاول بعد قليل.");
        throw new Error("تعذر الاتصال بخدمة الاستعلام. حاول مجددًا.");
      }

      if (data?.error) throw new Error(data.error);
      if (!data?.found || !data.subscriber) {
        setError("تعذر العثور على اشتراك مطابق. تحقق من رقم المشترك ورقم الهاتف.");
        return;
      }

      setResult(data.subscriber);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "تعذر إكمال الاستعلام.");
    } finally {
      setBusy(false);
    }
  }

  function reset() {
    setResult(null);
    setError(null);
    setSubscriberNumber("");
    setPhone("");
  }

  return (
    <div className="portal-lookup">
      <form className="portal-search" onSubmit={(event) => void submit(event)}>
        <label className="field">
          <span>رقم المشترك</span>
          <input
            value={subscriberNumber}
            onChange={(event) => setSubscriberNumber(toLatinDigits(event.target.value).replace(/\D/g, "").slice(0, 6))}
            inputMode="numeric"
            autoComplete="off"
            maxLength={6}
            pattern="[0-9٠-٩۰-۹]{6}"
            placeholder="مثال: 123456"
            required
            dir="ltr"
          />
          <small>رقم فريد من 6 خانات صادر من النظام.</small>
        </label>

        <label className="field">
          <span>رقم الهاتف المسجل</span>
          <input
            value={phone}
            onChange={(event) => setPhone(event.target.value.slice(0, 32))}
            type="tel"
            inputMode="tel"
            autoComplete="tel"
            placeholder="أدخل رقم الهاتف المرتبط بالاشتراك"
            required
            dir="ltr"
          />
          <small>يجب أن يطابق الرقم المسجل لدى المؤسسة.</small>
        </label>

        {error ? <div className="error" role="alert">{error}</div> : null}

        <button className="primary-button full-width" type="submit" disabled={busy}>
          {busy ? <RefreshCw size={16} className="spin" /> : <Search size={16} />}
          {busy ? "جارٍ التحقق..." : "الاستعلام عن الاشتراك"}
        </button>
      </form>

      {result ? (
        <section className="surface-card portal-result" aria-live="polite">
          <div className="portal-result-head">
            <div className="stat-icon"><UserRound size={21} /></div>
            <div>
              <strong>تم العثور على الاشتراك</strong>
              <small>تطابق رقم المشترك ورقم الهاتف</small>
            </div>
            <span className="badge" style={{ background: "var(--success-bg)", color: "#146C43" }}>مطابق</span>
          </div>

          <div className="portal-number">
            <span>رقم المشترك</span>
            <strong dir="ltr">{result.subscriber_number}</strong>
          </div>

          <div className="portal-detail">
            <span>اسم المشترك</span>
            <strong>{result.full_name}</strong>
          </div>

          <div className="portal-detail">
            <span>الغطاس المرتبط</span>
            <strong>{result.pump_name ? `${result.pump_name}${result.pump_code ? ` · ${result.pump_code}` : ""}` : "غير مرتبط حاليًا"}</strong>
          </div>

          <div className="portal-detail">
            <span>رقم الهاتف</span>
            <strong dir="ltr">•••• {result.phone_last4}</strong>
          </div>

          <button className="ghost-button full-width" type="button" onClick={reset}>
            استعلام جديد
          </button>
        </section>
      ) : null}

      <div className="portal-privacy">
        <ShieldCheck size={16} />
        <span>لا نعرض تفاصيل الاشتراك عند عدم تطابق الرقمين، وتخضع المحاولات لحدود حماية تلقائية.</span>
      </div>
    </div>
  );
}