import { useEffect } from 'react';
import { ActivityIndicator, StyleSheet, View } from 'react-native';
import { router, Tabs } from 'expo-router';
import { Activity, Banknote, LayoutDashboard, MoreHorizontal, UserRound } from 'lucide-react-native';
import { colors } from '@/constants/theme';
import { useAuth } from '@/lib/auth';

export default function TabLayout() {
  const { session, loading } = useAuth();
  useEffect(() => {
    if (!loading && !session) router.replace('/sign-in');
  }, [loading, session]);
  if (loading) return <View style={styles.loading}><ActivityIndicator color={colors.brand.teal} /></View>;
  if (!session) return null;
  return <Tabs screenOptions={{ headerShown: false, tabBarActiveTintColor: colors.brand.primary, tabBarInactiveTintColor: colors.text.secondary, tabBarLabelStyle: { fontFamily: 'IBMPlexSansArabic_600SemiBold', fontSize: 11 }, tabBarStyle: { height: 72, paddingTop: 8, paddingBottom: 10, borderTopColor: colors.border, backgroundColor: colors.background.surface }, tabBarHideOnKeyboard: true }}>
    <Tabs.Screen name="index" options={{ title: 'الرئيسية', tabBarIcon: ({ color, size }) => <LayoutDashboard color={color} size={size} /> }} />
    <Tabs.Screen name="operations" options={{ title: 'التشغيل', tabBarIcon: ({ color, size }) => <Activity color={color} size={size} /> }} />
    <Tabs.Screen name="collections" options={{ title: 'التحصيل', tabBarIcon: ({ color, size }) => <Banknote color={color} size={size} /> }} />
    <Tabs.Screen name="portal" options={{ title: 'بوابة المشترك', tabBarIcon: ({ color, size }) => <UserRound color={color} size={size} /> }} />
    <Tabs.Screen name="management" options={{ href: null }} />
    <Tabs.Screen name="more" options={{ title: 'المزيد', tabBarIcon: ({ color, size }) => <MoreHorizontal color={color} size={size} /> }} />
  </Tabs>;
}

const styles = StyleSheet.create({ loading: { flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: colors.background.main } });
