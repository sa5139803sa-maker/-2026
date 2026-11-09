import { useEffect } from 'react';
import { Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { SplashScreen } from 'expo-router';
import { useFonts } from 'expo-font';
import { IBMPlexSansArabic_400Regular, IBMPlexSansArabic_500Medium, IBMPlexSansArabic_600SemiBold, IBMPlexSansArabic_700Bold } from '@expo-google-fonts/ibm-plex-sans-arabic';
import { useFrameworkReady } from '@/hooks/useFrameworkReady';
import { AuthProvider } from '@/lib/auth';
import { initializeAndroidTimerChannels, installTimerNotificationHandler } from '@/lib/alerts/native-notifications';

SplashScreen.preventAutoHideAsync();
installTimerNotificationHandler();

export default function RootLayout() {
  useFrameworkReady();
  const [fontsLoaded, fontError] = useFonts({
    IBMPlexSansArabic_400Regular,
    IBMPlexSansArabic_500Medium,
    IBMPlexSansArabic_600SemiBold,
    IBMPlexSansArabic_700Bold,
  });
  useEffect(() => {
    if (fontsLoaded || fontError) SplashScreen.hideAsync();
  }, [fontsLoaded, fontError]);
  useEffect(() => {
    void initializeAndroidTimerChannels().catch((error) => {
      console.warn('Could not initialize Android timer notification channels.', error);
    });
  }, []);
  if (!fontsLoaded && !fontError) return null;
  return <AuthProvider><><Stack screenOptions={{ headerShown: false }}><Stack.Screen name="(tabs)" /><Stack.Screen name="sign-in" /><Stack.Screen name="change-password" /><Stack.Screen name="account-management" /><Stack.Screen name="reports" /><Stack.Screen name="weekly-schedule" /><Stack.Screen name="alert-settings" /></Stack><StatusBar style="dark" /></></AuthProvider>;
}
