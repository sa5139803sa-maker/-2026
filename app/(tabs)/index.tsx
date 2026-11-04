import { useEffect, useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';
import { Bell, CalendarDays, ChevronLeft, CircleDollarSign, Droplets, Users } from 'lucide-react-native';
import { BrandMark } from '@/components/BrandMark';
import { SectionTitle, StatCard, StatusBadge } from '@/components/UI';
import { Card } from '@/components/ui';
import { colors, radius, spacing } from '@/constants/theme';
import { useAuth } from '@/lib/auth';
import { supabase } from '@/lib/supabase';

const previewActivities = [
  { time: '10:24 ص', pump: 'الغطاس #1', subscriber: 'أحمد محمد', type: 'تعبئة عادية', status: 'مكتملة', tone: 'success' as const },
  { time: '09:50 ص', pump: 'الغطاس #2', subscriber: 'خالد علي', type: 'تعبئة إضافية', status: 'معلق', tone: 'warning' as const },
  { time: '09:30 ص', pump: 'الغطاس #1', subscriber: 'سارة محمود', type: 'تعبئة عادية', status: 'مكتملة', tone: 'success' as const },
];

export default function DashboardScreen() {
  const { profile } = useAuth();
  const [stats, setStats] = useState({ pumps: 0, subscribers: 0 });
  const [dataError, setDataError] = useState<string | null>(null);

  useEffect(() => {
    if (!profile?.organization_id) return;
    let active = true;
    const loadStats = async () => {
      const [pumpsResult, subscribersResult] = await Promise.all([
        supabase.from('pumps').select('id', { count: 'exact', head: true }).eq('organization_id', profile.organization_id as string),
        supabase.from('subscribers').select('id', { count: 'exact', head: true }).eq('organization_id', profile.organization_id as string).eq('is_active', true),
      ]);
      if (!active) return;
      if (pumpsResult.error || subscribersResult.error) {
        console.error('dashboard stats load failed', pumpsResult.error ?? subscribersResult.error);
        setDataError('تعذر تحديث أرقام لوحة المتابعة.');
        return;
      }
      setStats({ pumps: pumpsResult.count ?? 0, subscribers: subscribersResult.count ?? 0 });
    };
    void loadStats();
    return () => { active = false; };
  }, [profile?.organization_id]);

  return <ScrollView style={styles.screen} contentContainerStyle={styles.content} showsVerticalScrollIndicator={false}>
    <View style={styles.header}><BrandMark compact /><View style={styles.headerActions}><StatusBadge label="عرض أولي" status="info" /><Bell size={21} color={colors.text.primary} /><View style={styles.avatar}><Text style={styles.avatarText}>أ</Text></View></View></View>
    <View style={styles.welcome}><View><Text style={styles.eyebrow}>لوحة المؤسسة</Text><Text style={styles.title}>مرحباً، {profile?.display_name ?? 'مدير المؤسسة'}</Text><Text style={styles.subtitle}>إليك ملخص العمل لهذا اليوم</Text></View><CalendarDays color={colors.brand.teal} size={27} /></View>
    {dataError && <Text style={styles.dataError}>{dataError}</Text>}
    <View style={styles.stats}><StatCard label="الغواطس العاملة" value={`${stats.pumps}`} caption="من بيانات المؤسسة" icon={<Droplets size={20} color={colors.brand.primary} />} tone="info" /><StatCard label="المشتركون النشطون" value={`${stats.subscribers}`} caption="من بيانات المؤسسة" icon={<Users size={20} color={colors.status.info.main} />} tone="info" /><StatCard label="مدفوعات اليوم" value="—" caption="ستتوفر في المرحلة المالية" icon={<CircleDollarSign size={20} color={colors.status.success.main} />} tone="success" /><StatCard label="المستحقات المتأخرة" value="—" caption="ستتوفر في المرحلة المالية" icon={<CircleDollarSign size={20} color={colors.status.danger.main} />} tone="danger" /></View>
    <Card style={styles.chartCard} padded={false}><View style={styles.sectionHeading}><SectionTitle title="ملخص التشغيل اليومي" /><StatusBadge label="بيانات توضيحية" status="warning" /></View><View style={styles.chart}><View style={[styles.chartBar, { height: 72, backgroundColor: '#B7E8EA' }]} /><View style={[styles.chartBar, { height: 108, backgroundColor: '#75D1D4' }]} /><View style={[styles.chartBar, { height: 86, backgroundColor: '#42B9C0' }]} /><View style={[styles.chartBar, { height: 126, backgroundColor: colors.brand.teal }]} /><View style={[styles.chartBar, { height: 98, backgroundColor: '#75D1D4' }]} /><View style={[styles.chartBar, { height: 145, backgroundColor: colors.brand.primary }]} /><View style={[styles.chartBar, { height: 116, backgroundColor: '#42B9C0' }]} /></View><View style={styles.chartLabels}>{['السبت', 'الأحد', 'الإثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة'].map((day) => <Text key={day} style={styles.chartLabel}>{day}</Text>)}</View></Card>
    <Card style={styles.listCard} padded={false}><View style={styles.sectionHeading}><SectionTitle title="أحدث العمليات" /><StatusBadge label="بيانات توضيحية" status="warning" /></View>{previewActivities.map((item) => <View style={styles.activity} key={`${item.time}-${item.subscriber}`}><View style={styles.activityIcon}><Droplets size={17} color={colors.brand.teal} /></View><View style={styles.activityBody}><Text style={styles.activityTitle}>{item.subscriber}</Text><Text style={styles.activityMeta}>{item.pump} · {item.type}</Text></View><View style={styles.activityEnd}><Text style={styles.time}>{item.time}</Text><StatusBadge label={item.status} status={item.tone} /></View><ChevronLeft size={17} color={colors.text.secondary} /></View>)}</Card>
  </ScrollView>;
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background.main, direction: 'rtl' }, content: { padding: spacing.md, paddingTop: spacing.lg, gap: spacing.md, maxWidth: 1100, width: '100%', alignSelf: 'center' },
  header: { flexDirection: 'row-reverse', alignItems: 'center', justifyContent: 'space-between' }, headerActions: { flexDirection: 'row', alignItems: 'center', gap: spacing.md }, avatar: { width: 34, height: 34, borderRadius: 17, backgroundColor: colors.brand.primary, alignItems: 'center', justifyContent: 'center' }, avatarText: { color: colors.text.inverse, fontFamily: 'IBMPlexSansArabic_700Bold' }, welcome: { backgroundColor: colors.brand.navy, borderRadius: radius.lg, padding: spacing.lg, flexDirection: 'row-reverse', justifyContent: 'space-between', alignItems: 'center' }, eyebrow: { color: '#B7DDE4', fontSize: 12, fontFamily: 'IBMPlexSansArabic_500Medium', marginBottom: 4 }, title: { color: colors.text.inverse, fontSize: 25, fontFamily: 'IBMPlexSansArabic_700Bold' }, subtitle: { color: '#C3D4DC', fontSize: 12, fontFamily: 'IBMPlexSansArabic_400Regular', marginTop: 4 }, stats: { flexDirection: 'row', gap: spacing.sm, flexWrap: 'wrap' }, dataError: { color: colors.status.danger.text, backgroundColor: colors.status.danger.background, borderRadius: radius.sm, padding: spacing.sm, fontSize: 12, fontFamily: 'IBMPlexSansArabic_500Medium', textAlign: 'right' }, chartCard: { padding: spacing.md }, sectionHeading: { flexDirection: 'row-reverse', alignItems: 'center', justifyContent: 'space-between', gap: spacing.sm }, chart: { height: 160, flexDirection: 'row', alignItems: 'flex-end', justifyContent: 'space-around', paddingHorizontal: spacing.sm, borderBottomWidth: 1, borderBottomColor: colors.border }, chartBar: { width: 25, maxWidth: '11%', borderTopLeftRadius: 6, borderTopRightRadius: 6 }, chartLabels: { flexDirection: 'row', justifyContent: 'space-around', marginTop: spacing.sm }, chartLabel: { color: colors.text.secondary, fontSize: 10, fontFamily: 'IBMPlexSansArabic_400Regular' }, listCard: { padding: spacing.md }, activity: { minHeight: 62, flexDirection: 'row-reverse', alignItems: 'center', gap: spacing.sm, borderTopWidth: 1, borderTopColor: colors.background.subtle }, activityIcon: { width: 36, height: 36, borderRadius: 10, alignItems: 'center', justifyContent: 'center', backgroundColor: colors.background.subtle }, activityBody: { flex: 1, alignItems: 'flex-end' }, activityTitle: { color: colors.text.primary, fontSize: 13, fontFamily: 'IBMPlexSansArabic_700Bold' }, activityMeta: { color: colors.text.secondary, fontSize: 11, fontFamily: 'IBMPlexSansArabic_400Regular', marginTop: 2 }, activityEnd: { alignItems: 'flex-end', gap: 4 }, time: { color: colors.text.secondary, fontSize: 10, fontFamily: 'IBMPlexSansArabic_400Regular' },
});
