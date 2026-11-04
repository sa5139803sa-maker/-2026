import { ReactNode } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from 'react-native';
import { CheckCircle2, CircleAlert, Clock3 } from 'lucide-react-native';
import { colors, radius, spacing } from '@/constants/theme';

export function SectionTitle({ title, action }: { title: string; action?: string }) {
  return <View style={styles.sectionTitle}><Text style={styles.sectionText}>{title}</Text>{action && <Text style={styles.action}>{action}</Text>}</View>;
}

export function StatCard({ label, value, caption, icon, tone = 'info' }: { label: string; value: string; caption: string; icon: ReactNode; tone?: 'info' | 'success' | 'warning' | 'danger' }) {
  const palette = colors.status[tone];
  return <View style={styles.statCard}><View style={[styles.statIcon, { backgroundColor: palette.background }]}>{icon}</View><Text style={styles.statLabel}>{label}</Text><Text style={styles.statValue}>{value}</Text><Text style={[styles.statCaption, { color: palette.text }]}>{caption}</Text></View>;
}

export function StatusBadge({ label, status }: { label: string; status: 'success' | 'warning' | 'danger' | 'info' }) {
  const palette = colors.status[status];
  const Icon = status === 'success' ? CheckCircle2 : status === 'warning' ? Clock3 : CircleAlert;
  return <View style={[styles.badge, { backgroundColor: palette.background }]}><Icon size={14} color={palette.main} strokeWidth={2.4} /><Text style={[styles.badgeText, { color: palette.text }]}>{label}</Text></View>;
}

export function PrimaryButton({ label, icon, onPress }: { label: string; icon?: ReactNode; onPress?: () => void }) {
  return <Pressable onPress={onPress} style={({ pressed }) => [styles.primaryButton, pressed && styles.pressed]}><Text style={styles.primaryButtonText}>{label}</Text>{icon}</Pressable>;
}

export function LoadingState() {
  return <View style={styles.loading}><ActivityIndicator color={colors.brand.teal} /><Text style={styles.loadingText}>جاري التحميل...</Text></View>;
}

const styles = StyleSheet.create({
  sectionTitle: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: spacing.md },
  sectionText: { color: colors.text.primary, fontSize: 17, fontFamily: 'IBMPlexSansArabic_700Bold' },
  action: { color: colors.brand.teal, fontSize: 13, fontFamily: 'IBMPlexSansArabic_600SemiBold' },
  statCard: { flex: 1, minWidth: 145, backgroundColor: colors.background.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, shadowColor: colors.brand.navy, shadowOpacity: 0.04, shadowRadius: 8, shadowOffset: { width: 0, height: 3 }, elevation: 2 },
  statIcon: { width: 36, height: 36, borderRadius: 10, alignItems: 'center', justifyContent: 'center', marginBottom: spacing.sm },
  statLabel: { color: colors.text.secondary, fontSize: 12, fontFamily: 'IBMPlexSansArabic_500Medium' },
  statValue: { color: colors.text.primary, fontSize: 24, lineHeight: 31, fontFamily: 'IBMPlexSansArabic_700Bold', marginTop: 2 },
  statCaption: { fontSize: 11, fontFamily: 'IBMPlexSansArabic_600SemiBold', marginTop: 2 },
  badge: { flexDirection: 'row', alignItems: 'center', gap: 4, alignSelf: 'flex-start', borderRadius: radius.pill, paddingHorizontal: 9, paddingVertical: 5 },
  badgeText: { fontSize: 11, fontFamily: 'IBMPlexSansArabic_600SemiBold' },
  primaryButton: { minHeight: 48, borderRadius: radius.md, backgroundColor: colors.brand.primary, alignItems: 'center', justifyContent: 'center', flexDirection: 'row', gap: spacing.sm, paddingHorizontal: spacing.lg },
  primaryButtonText: { color: colors.text.inverse, fontSize: 14, fontFamily: 'IBMPlexSansArabic_700Bold' },
  pressed: { opacity: 0.8, transform: [{ scale: 0.98 }] },
  loading: { alignItems: 'center', justifyContent: 'center', padding: spacing.xl, gap: spacing.sm },
  loadingText: { color: colors.text.secondary, fontSize: 13, fontFamily: 'IBMPlexSansArabic_500Medium' },
});
