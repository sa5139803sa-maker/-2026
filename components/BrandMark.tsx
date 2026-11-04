import { Droplets } from 'lucide-react-native';
import { StyleSheet, Text, View } from 'react-native';
import { colors, spacing } from '@/constants/theme';

type BrandMarkProps = { compact?: boolean };

export function BrandMark({ compact = false }: BrandMarkProps) {
  return (
    <View style={[styles.wrap, compact && styles.compactWrap]}>
      <View style={[styles.mark, compact && styles.compactMark]}>
        <Droplets color={colors.text.inverse} size={compact ? 23 : 34} strokeWidth={2.2} />
      </View>
      {!compact && (
        <View>
          <Text style={styles.arabic}>إدارة المياه</Text>
          <Text style={styles.english}>Water Management</Text>
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  compactWrap: { gap: 0 },
  mark: { width: 56, height: 56, borderRadius: 28, backgroundColor: colors.brand.teal, alignItems: 'center', justifyContent: 'center' },
  compactMark: { width: 40, height: 40, borderRadius: 20 },
  arabic: { color: colors.brand.navy, fontSize: 21, fontFamily: 'IBMPlexSansArabic_700Bold', textAlign: 'right' },
  english: { color: colors.brand.primary, fontSize: 11, fontFamily: 'IBMPlexSansArabic_500Medium', letterSpacing: 0.4 },
});
