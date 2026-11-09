import { useCallback, useEffect, useRef, useState } from 'react';
import { Modal, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { CalendarDays, ChevronDown, Droplets, Plus, UsersRound, X } from 'lucide-react-native';
import { router } from 'expo-router';
import { SectionTitle, StatusBadge } from '@/components/UI';
import {
  TextField,
  RoleGate,
} from '@/components/ui';
import { colors, radius, spacing } from '@/constants/theme';
import { useAuth } from '@/lib/auth';
import { supabase } from '@/lib/supabase';
import { PumpAssignmentsManager } from '@/components/management/PumpAssignmentsManager';

type Pump = { id: string; name: string; code: string; status: 'active' | 'paused' | 'maintenance' | 'inactive' };
type Subscriber = { id: string; subscriber_number: number; full_name: string; phone: string; is_active: boolean; pump_id: string | null; operator_id: string | null };
type AssignedOperator = { id: string; display_name: string; pump_id: string };
type ModalMode = 'pump' | 'subscriber' | 'reassign' | null;

export default function ManagementScreen() {
  return (
    <RoleGate feature="management" featureName="إدارة الغواطس والمشتركين">
      <ManagementScreenContent />
    </RoleGate>
  );
}

function ManagementScreenContent() {
  const { profile } = useAuth();
  const [pumps, setPumps] = useState<Pump[]>([]);
  const [subscribers, setSubscribers] = useState<Subscriber[]>([]);
  const [assignedOperators, setAssignedOperators] = useState<AssignedOperator[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [modalMode, setModalMode] = useState<ModalMode>(null);
  const [pumpName, setPumpName] = useState('');
  const [pumpCode, setPumpCode] = useState('');
  const [subscriberName, setSubscriberName] = useState('');
  const [subscriberPhone, setSubscriberPhone] = useState('');
  const [selectedPumpId, setSelectedPumpId] = useState<string | null>(null);
  const [selectedOperatorId, setSelectedOperatorId] = useState("");
  const [operatorPickerOpen, setOperatorPickerOpen] = useState(false);
  const [selectedSubscriberId, setSelectedSubscriberId] = useState("");
  const [assignmentReason, setAssignmentReason] = useState("");
  const [saving, setSaving] = useState(false);
  const isManager = profile?.role === 'manager';
  const organizationId = profile?.organization_id ?? null;
  const dataRequestSequence = useRef(0);

  const loadData = useCallback(async () => {
    if (!organizationId) {
      dataRequestSequence.current += 1;
      setPumps([]);
      setSubscribers([]);
      setAssignedOperators([]);
      setError(null);
      setLoading(false);
      return;
    }

    const requestId = ++dataRequestSequence.current;
    setLoading(true);
    setError(null);

    try {
      const [pumpsResult, subscribersResult, operatorAssignmentsResult] = await Promise.all([
        supabase
          .from('pumps')
          .select('id, name, code, status')
          .eq('organization_id', organizationId)
          .order('created_at', { ascending: true }),
        supabase
          .from('subscribers')
          .select('id, subscriber_number, full_name, phone, is_active, pump_id, operator_id')
          .eq('organization_id', organizationId)
          .order('created_at', { ascending: false }),
        supabase
          .from('pump_assignments')
          .select('pump_id,user_id,profiles!inner(id,display_name)')
          .eq('organization_id', organizationId)
          .eq('assignment_role', 'operator')
          .order('created_at', { ascending: true }),
      ]);

      if (requestId !== dataRequestSequence.current) return;

      if (pumpsResult.error || subscribersResult.error || operatorAssignmentsResult.error) {
        console.error('management data load failed', pumpsResult.error ?? subscribersResult.error ?? operatorAssignmentsResult.error);
        setError('تعذر تحميل بيانات الإدارة. حاول مرة أخرى.');
        setPumps([]);
        setSubscribers([]);
      } else {
        setPumps((pumpsResult.data ?? []) as Pump[]);
        setSubscribers((subscribersResult.data ?? []) as Subscriber[]);
        setAssignedOperators((operatorAssignmentsResult.data ?? []).flatMap((assignment) => {
          const profile = assignment.profiles as unknown as { id: string; display_name: string } | null;
          return profile ? [{ id: profile.id, display_name: profile.display_name, pump_id: assignment.pump_id }] : [];
        }));
      }
    } catch (loadError) {
      console.error('management data request failed', loadError);
      if (requestId === dataRequestSequence.current) {
        setError('تعذر تحميل بيانات الإدارة. حاول مرة أخرى.');
        setPumps([]);
        setSubscribers([]);
        setAssignedOperators([]);
      }
    } finally {
      if (requestId === dataRequestSequence.current) {
        setLoading(false);
      }
    }
  }, [organizationId]);

  useEffect(() => {
    void loadData();
    return () => {
      // Ignore any response still in flight when the screen or organization changes.
      dataRequestSequence.current += 1;
    };
  }, [loadData]);

  const closeModal = () => {
    setModalMode(null);
    setPumpName('');
    setPumpCode('');
    setSubscriberName('');
    setSubscriberPhone('');
    setSelectedPumpId(null);
    setSelectedOperatorId("");
    setOperatorPickerOpen(false);
    setSelectedSubscriberId("");
    setAssignmentReason("");
  };

  const openSubscriberReassignment = (subscriber: Subscriber) => {
    if (!subscriber.pump_id) return;
    setError(null);
    setSelectedSubscriberId(subscriber.id);
    setSelectedPumpId(subscriber.pump_id);
    setSelectedOperatorId(subscriber.operator_id ?? "");
    setAssignmentReason("");
    setOperatorPickerOpen(false);
    setModalMode("reassign");
  };

  const save = async () => {
    if (!profile?.organization_id) return;
    if (modalMode === 'pump' && (!pumpName.trim() || !pumpCode.trim())) {
      setError('أدخل اسم الغطاس ورمزه.');
      return;
    }
    if (modalMode === 'subscriber' && !subscriberName.trim()) {
      setError('أدخل اسم المشترك.');
      return;
    }
    if (modalMode === 'subscriber' && !subscriberPhone.trim()) {
      setError('رقم الهاتف مطلوب لتمكين المشترك من الاستعلام في البوابة.');
      return;
    }
    if ((modalMode === 'subscriber' || modalMode === 'reassign') && selectedPumpId) {
      const operatorIsAssigned = assignedOperators.some(
        (operator) => operator.pump_id === selectedPumpId && operator.id === selectedOperatorId,
      );
      if (!operatorIsAssigned) {
        setError('اختر مشغّلًا مسندًا إلى الغطاس المحدد.');
        return;
      }
    }
    if (modalMode === 'reassign' && assignmentReason.trim().length < 2) {
      setError('اكتب سبب تغيير مسؤولية المشترك (حرفان على الأقل).');
      return;
    }
    setSaving(true);
    setError(null);
    const result = modalMode === 'pump'
      ? await supabase.from('pumps').insert({ organization_id: profile.organization_id, name: pumpName.trim(), code: pumpCode.trim() })
      : modalMode === 'subscriber'
        ? await supabase.from('subscribers').insert({ organization_id: profile.organization_id, pump_id: selectedPumpId, operator_id: selectedPumpId ? selectedOperatorId : null, full_name: subscriberName.trim(), phone: subscriberPhone.trim() })
        : await supabase.rpc('assign_subscriber_operator', {
            p_subscriber_id: selectedSubscriberId,
            p_operator_id: selectedOperatorId,
            p_reason: assignmentReason.trim(),
          });
    setSaving(false);
    if (result.error) {
      console.error('management record create failed', result.error);
      setError('تعذر حفظ البيانات. تحقق من القيم وحاول مرة أخرى.');
      return;
    }
    closeModal();
    await loadData();
  };

  return <ScrollView style={styles.screen} contentContainerStyle={styles.content}><View style={styles.header}><View><Text style={styles.eyebrow}>إدارة المؤسسة</Text><Text style={styles.title}>الغواطس والمشتركون</Text></View><Pressable onPress={() => router.back()} style={styles.closePage}><X size={20} color={colors.text.primary} /></Pressable></View>{error && <Text style={styles.error}>{error}</Text>}{!profile?.organization_id && <View style={styles.empty}><Text style={styles.emptyTitle}>لم يتم ربطك بمؤسسة</Text><Text style={styles.emptyText}>أنشئ مؤسسة من شاشة التسجيل حتى تبدأ بإضافة البيانات.</Text></View>}{profile?.organization_id && <><View style={styles.summary}><View style={styles.summaryItem}><Droplets size={19} color={colors.brand.teal} /><Text style={styles.summaryValue}>{pumps.length}</Text><Text style={styles.summaryLabel}>الغواطس</Text></View><View style={styles.summaryItem}><UsersRound size={19} color={colors.brand.primary} /><Text style={styles.summaryValue}>{subscribers.length}</Text><Text style={styles.summaryLabel}>المشتركون</Text></View><View style={styles.summaryItem}><StatusBadge label={isManager ? 'مدير' : 'قراءة فقط'} status={isManager ? 'success' : 'info'} /><Text style={styles.summaryLabel}>الصلاحية</Text></View></View><View style={styles.card}><SectionTitle title="الغواطس" action={isManager ? 'يمكنك الإضافة' : 'للقراءة فقط'} />{pumps.map((pump) => <View style={styles.row} key={pump.id}><View style={styles.rowIcon}><Droplets size={17} color={colors.brand.teal} /></View><View style={styles.rowBody}><Text style={styles.rowTitle}>{pump.name}</Text><Text style={styles.rowMeta}>{pump.code}</Text></View><StatusBadge label={pump.status === 'active' ? 'نشط' : 'متوقف'} status={pump.status === 'active' ? 'success' : 'warning'} /></View>)}{!loading && pumps.length === 0 && <Text style={styles.emptyInline}>لا توجد غواطس بعد.</Text>}{isManager && <Pressable onPress={() => setModalMode('pump')} style={styles.addButton}><Plus size={17} color={colors.brand.primary} /><Text style={styles.addText}>إضافة غطاس</Text></Pressable>}</View><PumpAssignmentsManager organizationId={organizationId} pumps={pumps} />{isManager && <Pressable onPress={() => router.push("/weekly-schedule")} style={styles.scheduleButton}><CalendarDays size={18} color={colors.brand.primary} /><View style={styles.scheduleButtonBody}><Text style={styles.scheduleButtonTitle}>إعداد الجداول والحصص الأسبوعية</Text><Text style={styles.rowMeta}>توزيع حصة المشترك واعتماد نسخ الجداول</Text></View><ChevronDown size={17} color={colors.brand.primary} /></Pressable>}<View style={styles.card}><SectionTitle title="المشتركون" action={`${subscribers.length} سجل`} />{subscribers.slice(0, 8).map((subscriber) => <View style={styles.row} key={subscriber.id}><View style={styles.personIcon}><Text style={styles.personText}>{subscriber.full_name.slice(0, 1)}</Text></View><View style={styles.rowBody}><Text style={styles.rowTitle}>{subscriber.full_name}</Text><Text style={styles.rowMeta}>رقم المشترك: {String(subscriber.subscriber_number).padStart(6, '0')}</Text><Text style={styles.rowMeta}>{subscriber.phone}</Text><Text style={styles.rowMeta}>المشغّل: {assignedOperators.find((operator) => operator.id === subscriber.operator_id)?.display_name ?? 'غير معيّن'}</Text></View><StatusBadge label={subscriber.is_active ? 'نشط' : 'مؤرشف'} status={subscriber.is_active ? 'success' : 'warning'} />{isManager && subscriber.pump_id && <Pressable onPress={() => openSubscriberReassignment(subscriber)} style={styles.addButton}><Text style={styles.addText}>تغيير المشغّل</Text></Pressable>}</View>)}{!loading && subscribers.length === 0 && <Text style={styles.emptyInline}>لا يوجد مشتركون بعد.</Text>}{isManager && <Pressable onPress={() => setModalMode('subscriber')} style={styles.addButton}><Plus size={17} color={colors.brand.primary} /><Text style={styles.addText}>إضافة مشترك</Text></Pressable>}</View></>}<Modal visible={modalMode !== null} transparent animationType="slide" onRequestClose={closeModal}><View style={styles.modalOverlay}><View style={styles.modalCard}><View style={styles.modalHeader}><Text style={styles.modalTitle}>{modalMode === 'pump' ? 'إضافة غطاس' : modalMode === 'subscriber' ? 'إضافة مشترك' : 'تغيير مشغّل المشترك'}</Text><Pressable onPress={closeModal} style={styles.modalClose}><X size={18} color={colors.text.primary} /></Pressable></View>
{modalMode === 'pump' ? <><Field label="اسم الغطاس" value={pumpName} placeholder="مثال: الغطاس الرئيسي" onChangeText={setPumpName} /><Field label="الرمز" value={pumpCode} placeholder="مثال: P-01" onChangeText={setPumpCode} /></> : modalMode === 'subscriber' ? <><Field label="اسم المشترك" value={subscriberName} placeholder="الاسم الكامل" onChangeText={setSubscriberName} /><Field label="رقم الهاتف (مطلوب للبوابة)" value={subscriberPhone} placeholder="مثال: 0591234567" onChangeText={setSubscriberPhone} keyboardType="phone-pad" /><Text style={styles.fieldLabel}>الغطاس المرتبط</Text><Pressable onPress={() => { const nextPumpId = selectedPumpId ? null : pumps[0]?.id ?? null; setSelectedPumpId(nextPumpId); setSelectedOperatorId(""); setOperatorPickerOpen(false); }} style={styles.pumpPicker}><Text style={styles.pumpPickerText}>{pumps.find((pump) => pump.id === selectedPumpId)?.name ?? 'اختر غطاساً (اختياري)'}</Text><ChevronDown size={17} color={colors.text.secondary} /></Pressable>{selectedPumpId && <View style={styles.pumpOptions}>{pumps.map((pump) => <Pressable key={pump.id} onPress={() => { setSelectedPumpId(pump.id); setSelectedOperatorId(""); setOperatorPickerOpen(false); }} style={styles.pumpOption}><Text style={styles.pumpOptionText}>{pump.name} · {pump.code}</Text></Pressable>)}</View>}</> : <><Text style={styles.rowTitle}>{subscribers.find((subscriber) => subscriber.id === selectedSubscriberId)?.full_name ?? 'المشترك'}</Text><Text style={styles.rowMeta}>الغطاس: {pumps.find((pump) => pump.id === selectedPumpId)?.name ?? '—'}</Text></>}
{modalMode !== 'pump' && <><Text style={styles.fieldLabel}>المشغّل المسؤول</Text><Pressable onPress={() => setOperatorPickerOpen((open) => !open)} style={styles.pumpPicker}><Text style={styles.pumpPickerText}>{assignedOperators.find((operator) => operator.id === selectedOperatorId && operator.pump_id === selectedPumpId)?.display_name ?? 'اختر المشغّل المسؤول'}</Text><ChevronDown size={17} color={colors.text.secondary} /></Pressable>{operatorPickerOpen && <View style={styles.pumpOptions}>{assignedOperators.filter((operator) => operator.pump_id === selectedPumpId).map((operator) => <Pressable key={operator.id} onPress={() => { setSelectedOperatorId(operator.id); setOperatorPickerOpen(false); }} style={styles.pumpOption}><Text style={styles.pumpOptionText}>{operator.display_name}</Text></Pressable>)}{!assignedOperators.some((operator) => operator.pump_id === selectedPumpId) && <Text style={styles.emptyInline}>لا يوجد مشغّلون مسندون لهذا الغطاس. أضف مشغّلًا أولًا.</Text>}</View>}{modalMode === 'reassign' && <Field label="سبب تغيير المسؤولية" value={assignmentReason} placeholder="مثال: إعادة توزيع نطاق العمل" onChangeText={setAssignmentReason} />}</>}
<Pressable onPress={() => void save()} disabled={saving} style={({ pressed }) => [styles.saveButton, pressed && { opacity: 0.8 }]}><Text style={styles.saveButtonText}>{saving ? 'جاري الحفظ...' : modalMode === 'reassign' ? 'حفظ تغيير المسؤولية' : 'حفظ البيانات'}</Text></Pressable></View></View></Modal></ScrollView>;
}

function Field({ label, value, placeholder, onChangeText, keyboardType = 'default' }: { label: string; value: string; placeholder: string; onChangeText: (value: string) => void; keyboardType?: 'default' | 'phone-pad' }) {
  return (
    <TextField
      label={label}
      value={value}
      placeholder={placeholder}
      onChangeText={onChangeText}
      keyboardType={keyboardType}
    />
  );
}

const styles = StyleSheet.create({ scheduleButton: { minHeight: 66, paddingHorizontal: spacing.md, paddingVertical: spacing.sm, borderRadius: radius.lg, borderWidth: 1, borderColor: colors.brand.aqua, backgroundColor: colors.background.surface, flexDirection: 'row-reverse', alignItems: 'center', gap: spacing.sm }, scheduleButtonBody: { flex: 1, alignItems: 'flex-end', gap: 2 }, scheduleButtonTitle: { color: colors.brand.primary, fontSize: 13, fontFamily: 'IBMPlexSansArabic_700Bold' }, screen: { flex: 1, backgroundColor: colors.background.main, direction: 'rtl' }, content: { padding: spacing.md, paddingTop: spacing.lg, gap: spacing.md, maxWidth: 760, width: '100%', alignSelf: 'center', paddingBottom: spacing.xxl }, header: { flexDirection: 'row-reverse', justifyContent: 'space-between', alignItems: 'center' }, eyebrow: { color: colors.brand.teal, fontSize: 12, fontFamily: 'IBMPlexSansArabic_600SemiBold' }, title: { color: colors.text.primary, fontSize: 24, fontFamily: 'IBMPlexSansArabic_700Bold', marginTop: 3 }, closePage: { width: 40, height: 40, borderRadius: 12, borderWidth: 1, borderColor: colors.border, alignItems: 'center', justifyContent: 'center', backgroundColor: colors.background.surface }, error: { color: colors.status.danger.text, backgroundColor: colors.status.danger.background, borderRadius: radius.sm, padding: spacing.sm, fontSize: 12, lineHeight: 20, fontFamily: 'IBMPlexSansArabic_500Medium', textAlign: 'right' }, summary: { flexDirection: 'row-reverse', gap: spacing.sm }, summaryItem: { flex: 1, minHeight: 95, alignItems: 'center', justifyContent: 'center', gap: 4, backgroundColor: colors.background.surface, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md }, summaryValue: { color: colors.text.primary, fontSize: 22, fontFamily: 'IBMPlexSansArabic_700Bold' }, summaryLabel: { color: colors.text.secondary, fontSize: 11, fontFamily: 'IBMPlexSansArabic_500Medium' }, card: { backgroundColor: colors.background.surface, borderRadius: radius.lg, borderWidth: 1, borderColor: colors.border, padding: spacing.md }, row: { minHeight: 62, flexDirection: 'row-reverse', alignItems: 'center', gap: spacing.sm, borderTopWidth: 1, borderTopColor: colors.background.subtle }, rowIcon: { width: 36, height: 36, borderRadius: 10, backgroundColor: colors.background.subtle, alignItems: 'center', justifyContent: 'center' }, personIcon: { width: 36, height: 36, borderRadius: 18, backgroundColor: colors.brand.aqua, alignItems: 'center', justifyContent: 'center' }, personText: { color: colors.brand.navy, fontFamily: 'IBMPlexSansArabic_700Bold' }, rowBody: { flex: 1, alignItems: 'flex-end' }, rowTitle: { color: colors.text.primary, fontSize: 13, fontFamily: 'IBMPlexSansArabic_700Bold' }, rowMeta: { color: colors.text.secondary, fontSize: 11, fontFamily: 'IBMPlexSansArabic_400Regular', marginTop: 2 }, addButton: { minHeight: 46, marginTop: spacing.sm, borderRadius: radius.md, borderWidth: 1, borderColor: colors.brand.aqua, backgroundColor: colors.background.subtle, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: spacing.sm }, addText: { color: colors.brand.primary, fontSize: 13, fontFamily: 'IBMPlexSansArabic_700Bold' }, emptyInline: { color: colors.text.secondary, fontSize: 12, fontFamily: 'IBMPlexSansArabic_400Regular', textAlign: 'right', paddingVertical: spacing.md }, empty: { backgroundColor: colors.background.surface, borderRadius: radius.lg, padding: spacing.xl, alignItems: 'center' }, emptyTitle: { color: colors.text.primary, fontSize: 16, fontFamily: 'IBMPlexSansArabic_700Bold' }, emptyText: { color: colors.text.secondary, fontSize: 12, textAlign: 'center', lineHeight: 21, fontFamily: 'IBMPlexSansArabic_400Regular', marginTop: spacing.sm },
  fieldLabel: { color: colors.text.primary, fontSize: 12, fontFamily: 'IBMPlexSansArabic_700Bold', textAlign: 'right' }, modalOverlay: { flex: 1, justifyContent: 'flex-end', backgroundColor: 'rgba(11,52,73,0.28)' }, modalCard: { backgroundColor: colors.background.surface, borderTopLeftRadius: 24, borderTopRightRadius: 24, padding: spacing.lg, gap: spacing.md }, modalHeader: { flexDirection: 'row-reverse', justifyContent: 'space-between', alignItems: 'center' }, modalTitle: { color: colors.text.primary, fontSize: 18, fontFamily: 'IBMPlexSansArabic_700Bold' }, modalClose: { width: 36, height: 36, borderRadius: 10, alignItems: 'center', justifyContent: 'center', backgroundColor: colors.background.subtle }, pumpPicker: { minHeight: 48, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, paddingHorizontal: spacing.md, flexDirection: 'row-reverse', alignItems: 'center', justifyContent: 'space-between' }, pumpPickerText: { color: colors.text.primary, fontSize: 13, fontFamily: 'IBMPlexSansArabic_400Regular' }, pumpOptions: { borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, backgroundColor: colors.background.subtle, marginTop: -spacing.sm }, pumpOption: { padding: spacing.sm, borderBottomWidth: 1, borderBottomColor: colors.border }, pumpOptionText: { color: colors.text.primary, fontSize: 12, fontFamily: 'IBMPlexSansArabic_500Medium', textAlign: 'right' }, saveButton: { minHeight: 50, borderRadius: radius.md, backgroundColor: colors.brand.primary, alignItems: 'center', justifyContent: 'center', marginTop: spacing.sm }, saveButtonText: { color: colors.text.inverse, fontSize: 14, fontFamily: 'IBMPlexSansArabic_700Bold' },
});
