import { Redirect } from 'expo-router';
import { ActivityIndicator, StyleSheet, View } from 'react-native';
import { useAuth } from '@/lib/auth';
import { colors } from '@/constants/theme';

export default function EntryScreen() {
  const { session, loading } = useAuth();
  if (loading) return <View style={styles.loading}><ActivityIndicator color={colors.brand.teal} /></View>;
  return <Redirect href={session ? '/(tabs)' : '/sign-in'} />;
}

const styles = StyleSheet.create({ loading: { flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: colors.background.main } });
