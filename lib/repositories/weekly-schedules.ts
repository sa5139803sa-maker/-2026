import { supabase } from "@/lib/supabase";

export type WeeklyScheduleStatus = "draft" | "active" | "archived";

export type WeeklySchedulePump = {
  id: string;
  name: string;
  code: string;
  status: "active" | "paused" | "maintenance" | "inactive";
};

export type WeeklyScheduleSubscriber = {
  id: string;
  full_name: string;
  subscriber_number: number;
  weekly_quota_minutes: number | null;
  default_weekday: number | null;
};

export type WeeklyScheduleVersion = {
  id: string;
  pump_id: string;
  name: string;
  effective_from: string;
  effective_to: string | null;
  week_starts_on: number;
  status: WeeklyScheduleStatus;
  created_at: string;
};

export type WeeklyScheduleAllocation = {
  weekday: number;
  planned_minutes: number;
};

export type WeeklyScheduleMember = {
  subscriber_id: string;
  weekly_quota_minutes: number;
  default_weekday: number;
  allocations: WeeklyScheduleAllocation[];
};

export type WeeklyScheduleDraftPayload = {
  subscriber_id: string;
  weekly_quota_minutes: number;
  default_weekday: number;
  allocations: WeeklyScheduleAllocation[];
};

export const weeklySchedulesRepository = {
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
      .select("id,full_name,subscriber_number,weekly_quota_minutes,default_weekday")
      .eq("organization_id", organizationId)
      .eq("pump_id", pumpId)
      .eq("is_active", true)
      .order("subscriber_number", { ascending: true });
  },

  listScheduleVersions(organizationId: string, pumpId: string) {
    return supabase
      .from("weekly_schedules")
      .select("id,pump_id,name,effective_from,effective_to,week_starts_on,status,created_at")
      .eq("organization_id", organizationId)
      .eq("pump_id", pumpId)
      .order("effective_from", { ascending: false })
      .order("created_at", { ascending: false });
  },

  async loadScheduleMembers(organizationId: string, scheduleId: string) {
    const [membersResult, entriesResult] = await Promise.all([
      supabase
        .from("weekly_schedule_subscribers")
        .select("subscriber_id,weekly_quota_minutes,default_weekday")
        .eq("organization_id", organizationId)
        .eq("weekly_schedule_id", scheduleId),
      supabase
        .from("schedule_entries")
        .select("subscriber_id,weekday,planned_minutes")
        .eq("organization_id", organizationId)
        .eq("weekly_schedule_id", scheduleId)
        .order("weekday", { ascending: true })
        .order("sort_order", { ascending: true }),
    ]);

    const error = membersResult.error ?? entriesResult.error;
    if (error) return { data: null, error };

    const allocationsBySubscriber = new Map<string, WeeklyScheduleAllocation[]>();
    for (const entry of entriesResult.data ?? []) {
      const list = allocationsBySubscriber.get(entry.subscriber_id) ?? [];
      list.push({ weekday: entry.weekday, planned_minutes: entry.planned_minutes });
      allocationsBySubscriber.set(entry.subscriber_id, list);
    }

    const members: WeeklyScheduleMember[] = (membersResult.data ?? []).map((member) => ({
      subscriber_id: member.subscriber_id,
      weekly_quota_minutes: member.weekly_quota_minutes,
      default_weekday: member.default_weekday,
      allocations: allocationsBySubscriber.get(member.subscriber_id) ?? [],
    }));
    return { data: members, error: null };
  },

  saveDraft(args: {
    scheduleId?: string | null;
    pumpId: string;
    name: string;
    effectiveFrom: string;
    effectiveTo?: string | null;
    weekStartsOn: number;
    subscribers: WeeklyScheduleDraftPayload[];
  }) {
    return supabase.rpc("save_weekly_schedule_draft", {
      p_schedule_id: args.scheduleId ?? null,
      p_pump_id: args.pumpId,
      p_name: args.name,
      p_effective_from: args.effectiveFrom,
      p_effective_to: args.effectiveTo ?? null,
      p_week_starts_on: args.weekStartsOn,
      p_subscribers: args.subscribers,
    });
  },

  activate(scheduleId: string) {
    return supabase.rpc("activate_weekly_schedule", {
      p_schedule_id: scheduleId,
    });
  },

  deleteDraft(organizationId: string, scheduleId: string) {
    return supabase
      .from("weekly_schedules")
      .delete()
      .eq("organization_id", organizationId)
      .eq("id", scheduleId)
      .eq("status", "draft");
  },
};
