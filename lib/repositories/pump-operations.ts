import { supabase } from "@/lib/supabase";

export type OperationPump = {
  id: string;
  name: string;
  code: string;
  status: "active" | "paused" | "maintenance" | "inactive";
};

export type OperationSubscriber = {
  id: string;
  full_name: string;
  subscriber_number: number;
  pump_id: string;
  created_at: string;
};

export type PumpOperation = {
  id: string;
  pump_id: string;
  subscriber_id: string | null;
  subscriber_name: string;
  planned_minutes: number;
  status: "running" | "paused" | "completed";
  started_at: string;
  paused_at: string | null;
  pause_reason: string | null;
  paused_seconds: number;
  ended_at: string | null;
  actual_seconds: number | null;
  operation_date: string;
};

export type DashboardOperation = PumpOperation & { pump_name: string };

export type PumpOperationsDashboard = {
  today_operations: number;
  active_operations: number;
  daily: { date: string; count: number }[];
  recent: DashboardOperation[];
};

export const pumpOperationsRepository = {
  listPumps(organizationId: string) {
    return supabase
      .from("pumps")
      .select("id,name,code,status")
      .eq("organization_id", organizationId)
      .order("created_at", { ascending: true });
  },

  listActiveSubscribers(organizationId: string, pumpId: string) {
    return supabase
      .from("subscribers")
      .select("id,full_name,subscriber_number,pump_id,created_at")
      .eq("organization_id", organizationId)
      .eq("pump_id", pumpId)
      .eq("is_active", true)
      .order("subscriber_number", { ascending: true });
  },

  listPumpOperations(organizationId: string, pumpId: string, day: string) {
    return supabase
      .from("pump_operations")
      .select("id,pump_id,subscriber_id,subscriber_name,planned_minutes,status,started_at,paused_at,pause_reason,paused_seconds,ended_at,actual_seconds,operation_date")
      .eq("organization_id", organizationId)
      .eq("pump_id", pumpId)
      .or(`operation_date.eq.${day},status.in.(running,paused)`)
      .order("started_at", { ascending: false });
  },

  start(pumpId: string, subscriberId: string | null, subscriberName: string | null, plannedMinutes: number) {
    return supabase.rpc("start_pump_operation", {
      p_pump_id: pumpId,
      p_subscriber_id: subscriberId,
      p_subscriber_name: subscriberName,
      p_planned_minutes: plannedMinutes,
    });
  },

  pause(operationId: string, reason: string) {
    return supabase.rpc("pause_pump_operation", {
      p_operation_id: operationId,
      p_reason: reason,
    });
  },

  resume(operationId: string) {
    return supabase.rpc("resume_pump_operation", { p_operation_id: operationId });
  },

  complete(operationId: string) {
    return supabase.rpc("complete_pump_operation", { p_operation_id: operationId });
  },

  loadDashboard(pFrom: string, pToday: string) {
    return supabase.rpc("get_pump_operations_dashboard", {
      p_from: pFrom,
      p_today: pToday,
    });
  },

  countActiveSubscribers(organizationId: string) {
    return supabase
      .from("subscribers")
      .select("id", { count: "exact", head: true })
      .eq("organization_id", organizationId)
      .eq("is_active", true);
  },
};
