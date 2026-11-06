import {useEffect,useState} from "react";
import {KeyboardAvoidingView,Platform,ScrollView,StyleSheet,Text,View} from "react-native";
import {router} from "expo-router";
import {LockKeyhole} from "lucide-react-native";
import {BrandMark} from "@/components/BrandMark";
import {Button,Card,TextField} from "@/components/ui";
import {colors,spacing,radius} from "@/constants/theme";
import {supabase} from "@/lib/supabase";
import {useAuth} from "@/lib/auth";
export default function ChangePasswordScreen(){
 const {profile,refreshProfile,signOut}=useAuth();
 useEffect(()=>{if(profile?.role==="platform_admin")void signOut().finally(()=>router.replace("/sign-in"));},[profile?.role,signOut]);
 if(profile?.role==="platform_admin")return null;
 const [password,setPassword]=useState("");const [confirm,setConfirm]=useState("");const [error,setError]=useState<string|null>(null);const [saving,setSaving]=useState(false);
 const submit=async()=>{
  if(password.length<10||!/[A-Z]/.test(password)||!/[a-z]/.test(password)||!/[0-9]/.test(password)){setError("استخدم 10 أحرف على الأقل، مع حرف كبير وحرف صغير ورقم.");return;}
  if(password!==confirm){setError("كلمتا المرور غير متطابقتين.");return;}
  setSaving(true);setError(null);
  const {error:requestError}=await supabase.functions.invoke("manage-accounts",{body:{action:"change_password",new_password:password}});
  setSaving(false);if(requestError){setError("تعذر تغيير كلمة المرور. تحقق من الاتصال ثم أعد المحاولة.");return;}
  await refreshProfile();router.replace("/(tabs)");
 };
 return <KeyboardAvoidingView style={styles.screen} behavior={Platform.OS==="ios"?"padding":undefined}><ScrollView contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled"><BrandMark/><Card>
  <View style={styles.icon}><LockKeyhole color={colors.brand.primary} size={24}/></View><Text style={styles.title}>تغيير كلمة المرور المؤقتة</Text>
  <Text style={styles.description}>مرحباً {profile?.display_name??""}، يجب اختيار كلمة مرور جديدة قبل استخدام التطبيق.</Text>
  <TextField label="كلمة المرور الجديدة" value={password} onChangeText={setPassword} secureTextEntry autoCapitalize="none" placeholder="10 أحرف على الأقل"/>
  <TextField label="تأكيد كلمة المرور" value={confirm} onChangeText={setConfirm} secureTextEntry autoCapitalize="none" placeholder="أعد كتابة كلمة المرور"/>
  {error?<Text style={styles.error}>{error}</Text>:null}
  <Button label="حفظ كلمة المرور والمتابعة" onPress={()=>void submit()} loading={saving} fullWidth/><Button label="تسجيل الخروج" variant="ghost" onPress={()=>void signOut()} fullWidth/>
 </Card></ScrollView></KeyboardAvoidingView>;
}
const styles=StyleSheet.create({screen:{flex:1,backgroundColor:colors.background.main},content:{flexGrow:1,justifyContent:"center",gap:spacing.lg,padding:spacing.lg,maxWidth:560,width:"100%",alignSelf:"center"},icon:{alignSelf:"center",width:54,height:54,borderRadius:16,backgroundColor:colors.background.subtle,alignItems:"center",justifyContent:"center",marginBottom:spacing.sm},title:{color:colors.text.primary,fontSize:22,fontFamily:"IBMPlexSansArabic_700Bold",textAlign:"center"},description:{color:colors.text.secondary,fontSize:13,lineHeight:22,fontFamily:"IBMPlexSansArabic_400Regular",textAlign:"center",marginBottom:spacing.sm},error:{color:colors.status.danger.text,backgroundColor:colors.status.danger.background,padding:spacing.sm,borderRadius:radius.sm,textAlign:"right",fontFamily:"IBMPlexSansArabic_500Medium"}});
