import { useEffect, useState } from 'react';
import { Modal, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { ChevronDown, Droplets, Plus, UsersRound, X } from 'lucide-react-native';
import { router } from 'expo-router';
import { SectionTitle, StatusBadge } from '@/components/UI';
import { TextField } from '@/components/ui';
import { colors, radius, spacing } from '@/constants/theme';
import { useAuth } from '@/lib/auth';
import { supabase } from '@/lib/supabase';

type Pump = { id: string; name: string; code: string; status: 'active' | 'paused' | 'maintenance' | 'inactive' };
type Subscriber = { id: string; full_name: string; phone: string | null; is_active: boolean; pump_id: string | null };
type ModalMode = 'pump' | 'subscriber' | null;

export default function ManagementScreen() {
  const { profile } = useAuth();
  const [pumps, setPumps] = useState<Pump[]>([]);
  const [subscribers, setSubscribers] = useState<Subscriber[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [modalMode, setModalMode] = useState<ModalMode>(null);
  const [pumpName, setPumpName] = useState('');
  const [pumpCode, setPumpCode] = useState('');
  const [subscriberName, setSubscriberName] = useState('');
  const [subscriberPhone, setSubscriberPhone] = useState('');
  const [selectedPumpId, setSelectedPumpId] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const isManager = profile?.role === 'manager';

  const loadData = async () => {
    if (!profile?.organization_id) return;
    setLoading(true);
    setError(null);
    const [pumpsResult, subscribersResult] = await Promise.all([
      supabase.from('pumps').select('id, name, code, status').eq('organization_id', profile.organization_id).order('created_at', { ascending: true }),
      supabase.from('subscribers').select('id, full_name, phone, is_active, pump_id').eq('organization_id', profile.organization_id).order('created_at', { ascending: false }),
    ]);
    if (pumpsResult.error || subscribersResult.error) {
      console.error('management data load failed', pumpsResult.error ?? subscribersResult.error);
      setError('تعذر تحميل بيانات الإدارة. حاول مرة أخرى.');
    } else {
      setPumps((pumpsResult.data ?? []) as Pump[]);
      setSubscribers((subscribersResult.data ?? []) as Subscriber[]);
    }
    setLoading(false);
  };

  useEffect(() => { void loadData(); }, [profile?.organization_id]);

  const closeModal = () => {
    setModalMode(null);
    setPumpName('');
    setPumpCode('');
    setSubscriberName('');
    setSubscriberPhone('');
    setSelectedPumpId(null);
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
    setSaving(true);
    setError(null);
    const result = modalMode === 'pump'
      ? await supabase.from('pumps').insert({ organization_id: profile.organization_id, name: pumpName.trim(), code: pumpCode.trim() })
      : await supabase.from('subscribers').insert({ organization_id: profile.organization_id, pump_id: selectedPumpId, full_name: subscriberName.trim(), phone: subscriberPhone.trim() || null });
    setSaving(false);
    if (result.error) {
      console.error('management record create failed', result.error);
      setError('تعذر حفظ البيانات. تحقق من القيم وحاول مرة أخرى.');
      return;
    }
    closeModal();
    await loadData();
  };

  return <ScrollView style={styles.screen} contentContainerStyle={styles.content}><View style={styles.header}><View><Text style={styles.eyebrow}>إدارة المؤسسة</Text><Text style={styles.title}>الغواطس والمشتركون</Text></View><Pressable onPress={() => router.back()} style={styles.closePage}><X size={20} color={colors.text.primary} /></Pressable></View>{error && <Text style={styles.error}>{error}</Text>}{!profile?.organization_id && <View style={styles.empty}><Text style={styles.emptyTitle}>لم يتم ربطك بمؤسسة</Text><Text style={styles.emptyText}>أنشئ مؤسسة من شاشة التسجيل حتى تبدأ بإضافة البيانات.</Text></View>}{profile?.organization_id && <><View style={styles.summary}><View style={styles.summaryItem}><Droplets size={19} color={colors.brand.teal} /><Text style={styles.summaryValue}>{pumps.length}</Text><Text style={styles.summaryLabel}>الغواطس</Text></View><View style={styles.summaryItem}><UsersRound size={19} color={colors.brand.primary} /><Text style={styles.summaryValue}>{subscribers.length}</Text><Text style={styles.summaryLabel}>المشتركون</Text></View><View style={styles.summaryItem}><StatusBadge label={isManager ? 'مدير' : 'قراءة فقط'} status={isManager ? 'success' : 'info'} /><Text style={styles.summaryLabel}>الصلاحية</Text></View></View><View style={styles.card}><SectionTitle title="الغواطس" action={isManager ? 'يمكنك الإضافة' : 'للقراءة فقط'} />{pumps.map((pump) => <View style={styles.row} key={pump.id}><View style={styles.rowIcon}><Droplets size={17} color={colors.brand.teal} /></View><View style={styles.rowBody}><Text style={styles.rowTitle}>{pump.name}</Text><Text style={styles.rowMeta}>{pump.code}</Text></View><StatusBadge label={pump.status === 'active' ? 'نشط' : 'متوقف'} status={pump.status === 'active' ? 'success' : 'warning'} /></View>)}{!loading && pumps.length === 0 && <Text style={styles.emptyInline}>لا توجد غواطس بعد.</Text>}{isManager && <Pressable onPress={() => setModalMode('pump')} style={styles.addButton}><Plus size={17} color={colors.brand.primary} /><Text style={styles.addText}>إضافة غطاس</Text></Pressable>}</View><View style={styles.card}><SectionTitle title="المشتركون" action={`${subscribers.length} سجل`} />{subscribers.slice(0, 8).map((subscriber) => <View style={styles.row} key={subscriber.id}><View style={styles.personIcon}><Text style={styles.personText}>{subscriber.full_name.slice(0, 1)}</Text></View><View style={styles.rowBody}><Text style={styles.rowTitle}>{subscriber.full_name}</Text><Text style={styles.rowMeta}>{subscriber.phone ?? 'بدون رقم هاتف'}</Text></View><StatusBadge label={subscriber.is_active ? 'نشط' : 'مؤرشف'} status={subscriber.is_active ? 'success' : 'warning'} /></View>)}{!loading && subscribers.length === 0 && <Text style={styles.emptyInline}>لا يوجد مشتركون بعد.</Text>}{isManager && <Pressable onPress={() => setModalMode('subscriber')} style={styles.addButton}><Plus size={17} color={colors.brand.primary} /><Text style={styles.addText}>إضافة مشترك</Text></Pressable>}</View></>}<Modal visible={modalMode !== null} transparent animationType="slide" onRequestClose={closeModal}><View style={styles.modalOverlay}><View style={styles.modalCard}><View style={styles.modalHeader}><Text style={styles.modalTitle}>{modalMode === 'pump' ? 'إضافة غطاس' : 'إضافة مشترك'}</Text><Pressable onPress={closeModal} style={styles.modalClose}><X size={18} color={colors.text.primary} /></Pressable></View>{modalMode === 'pump' ? <><Field label="اسم الغطاس" value={pumpName} placeholder="مثال: الغطاس الرئيسي" onChangeText={setPumpName} /><Field label="الرمز" value={pumpCode} placeholder="مثال: P-01" onChangeText={setPumpCode} /></> : <><Field label="اسم المشترك" value={subscriberName} placeholder="الاسم الكامل" onChangeText={setSubscriberName} /><Field label="رقم الهاتف" value={subscriberPhone} placeholder="رقم الاتصال" onChangeText={setSubscriberPhone} keyboardType="phone-pad" /><Text style={styles.fieldLabel}>الغطاس المرتبط</Text><Pressable onPress={() => setSelectedPumpId(selectedPumpId ? null : pumps[0]?.id ?? null)} style={styles.pumpPicker}><Text style={styles.pumpPickerText}>{pumps.find((pump) => pump.id === selectedPumpId)?.name ?? 'اختر غطاساً (اختياري)'}</Text><ChevronDown size={17} color={colors.text.secondary} /></Pressable>{selectedPumpId && <View style={styles.pumpOptions}>{pumps.map((pump) => <Pressable key={pump.id} onPress={() => setSelectedPumpId(pump.id)} style={styles.pumpOption}><Text style={styles.pumpOptionText}>{pump.name} · {pump.code}</Text></Pressable>)}</View>}</>}<Pressable onPress={() => void save()} disabled={saving} style={({ pressed }) => [styles.saveButton, pressed && { opacity: 0.8 }]}><Text style={styles.saveButtonText}>{saving ? 'جاري الحفظ...' : 'حفظ البيانات'}</Text></Pressable></View></View></Modal></ScrollView>;
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

const styles = StyleSheet.create({ screen: { flex: 1, backgroundColor: colors.background.main, direction: 'rtl' }, content: { padding: spacing.md, paddingTop: spacing.lg, gap: spacing.md, maxWidth: 760, width: '100%', alignSelf: 'center', paddingBottom: spacing.xxl }, header: { flexDirection: 'row-reverse', justifyContent: 'space-between', alignItems: 'center' }, eyebrow: { color: colors.brand.teal, fontSize: 12, fontFamily: 'IBMPlexSansArabic_600SemiBold' }, title: { color: colors.text.primary, fontSize: 24, fontFamily: 'IBMPlexSansArabic_700Bold', marginTop: 3 }, closePage: { width: 40, height: 40, borderRadius: 12, borderWidth: 1, borderColor: colors.border, alignItems: 'center', justifyContent: 'center', backgroundColor: colors.background.surface }, error: { color: colors.status.danger.text, backgroundColor: colors.status.danger.background, borderRadius: radius.sm, padding: spacing.sm, fontSize: 12, lineHeight: 20, fontFamily: 'IBMPlexSansArabic_500Medium', textAlign: 'right' }, summary: { flexDirection: 'row-reverse', gap: spacing.sm }, summaryItem: { flex: 1, minHeight: 95, alignItems: 'center', justifyContent: 'center', gap: 4, backgroundColor: colors.background.surface, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md }, summaryValue: { color: colors.text.primary, fontSize: 22, fontFamily: 'IBMPlexSansArabic_700Bold' }, summaryLabel: { color: colors.text.secondary, fontSize: 11, fontFamily: 'IBMPlexSansArabic_500Medium' }, card: { backgroundColor: colors.background.surface, borderRadius: radius.lg, borderWidth: 1, borderColor: colors.border, padding: spacing.md }, row: { minHeight: 62, flexDirection: 'row-reverse', alignItems: 'center', gap: spacing.sm, borderTopWidth: 1, borderTopColor: colors.background.subtle }, rowIcon: { width: 36, height: 36, borderRadius: 10, backgroundColor: colors.background.subtle, alignItems: 'center', justifyContent: 'center' }, personIcon: { width: 36, height: 36, borderRadius: 18, backgroundColor: colors.brand.aqua, alignItems: 'center', justifyContent: 'center' }, personText: { color: colors.brand.navy, fontFamily: 'IBMPlexSansArabic_700Bold' }, rowBody: { flex: 1, alignItems: 'flex-end' }, rowTitle: { color: colors.text.primary, fontSize: 13, fontFamily: 'IBMPlexSansArabic_700Bold' }, rowMeta: { color: colors.text.secondary, fontSize: 11, fontFamily: 'IBMPlexSansArabic_400Regular', marginTop: 2 }, addButton: { minHeight: 46, marginTop: spacing.sm, borderRadius: radius.md, borderWidth: 1, borderColor: colors.brand.aqua, backgroundColor: colors.background.subtle, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: spacing.sm }, addText: { color: colors.brand.primary, fontSize: 13, fontFamily: 'IBMPlexSansArabic_700Bold' }, emptyInline: { color: colors.text.secondary, fontSize: 12, fontFamily: 'IBMPlexSansArabic_400Regular', textAlign: 'right', paddingVertical: spacing.md }, empty: { backgroundColor: colors.background.surface, borderRadius: radius.lg, padding: spacing.xl, alignItems: 'center' }, emptyTitle: { color: colors.text.primary, fontSize: 16, fontFamily: 'IBMPlexSansArabic_700Bold' }, emptyText: { color: colors.text.secondary, fontSize: 12, textAlign: 'center', lineHeight: 21, fontFamily: 'IBMPlexSansArabic_400Regular', marginTop: spacing.sm },
  fieldLabel: { color: colors.text.primary, fontSize: 12, fontFamily: 'IBMPlexSansArabic_700Bold', textAlign: 'right' }, modalOverlay: { flex: 1, justifyContent: 'flex-end', backgroundColor: 'rgba(11,52,73,0.28)' }, modalCard: { backgroundColor: colors.background.surface, borderTopLeftRadius: 24, borderTopRightRadius: 24, padding: spacing.lg, gap: spacing.md }, modalHeader: { flexDirection: 'row-reverse', justifyContent: 'space-between', alignItems: 'center' }, modalTitle: { color: colors.text.primary, fontSize: 18, fontFamily: 'IBMPlexSansArabic_700Bold' }, modalClose: { width: 36, height: 36, borderRadius: 10, alignItems: 'center', justifyContent: 'center', backgroundColor: colors.background.subtle }, pumpPicker: { minHeight: 48, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, paddingHorizontal: spacing.md, flexDirection: 'row-reverse', alignItems: 'center', justifyContent: 'space-between' }, pumpPickerText: { color: colors.text.primary, fontSize: 13, fontFamily: 'IBMPlexSansArabic_400Regular' }, pumpOptions: { borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, backgroundColor: colors.background.subtle, marginTop: -spacing.sm }, pumpOption: { padding: spacing.sm, borderBottomWidth: 1, borderBottomColor: colors.border }, pumpOptionText: { color: colors.text.primary, fontSize: 12, fontFamily: 'IBMPlexSansArabic_500Medium', textAlign: 'right' }, saveButton: { minHeight: 50, borderRadius: radius.md, backgroundColor: colors.brand.primary, alignItems: 'center', justifyContent: 'center', marginTop: spacing.sm }, saveButtonText: { color: colors.text.inverse, fontSize: 14, fontFamily: 'IBMPlexSansArabic_700Bold' },
});
