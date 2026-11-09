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

export type PumpPowerSource = {
  id: string;
  pump_id: string;
  name: string;
  source_type: "solar" | "generator" | "grid" | "other";
  is_active: boolean;
};

export type PowerUsageRow = {
  pump_id: string;
  period_start: string;
  power_source_id: string;
  power_source_name: string;
  total_seconds: number;
  total_minutes: number;
  data_source: "automatic" | "daily_survey";
};

export type DailyScheduleEntry = {
  id: string;
  subscriber_id: string;
  weekday: number;
  sort_order: number;
  planned_minutes: number;
  entry_type?: "weekly" | "weekly_reassigned";
  schedule_entry_id?: string | null;
  weekly_entitlement_allocation_id?: string | null;
  reassigned_from_date?: string | null;
  subscribers: {
    id: string;
    full_name: string;
    subscriber_number: number;
    branch_id: string | null;
    operator_id: string | null;
  };
};

export type WeeklyEntitlementAllocationForDay = {
  id: string;
  subscriber_id: string;
  allocation_date: string;
  source_schedule_entry_id: string | null;
  original_minutes: number;
  allocated_minutes: number;
  consumed_minutes: number;
  available_minutes: number;
  weekday: number;
  sort_order: number;
  subscribers: {
    id: string;
    full_name: string;
    subscriber_number: number;
    branch_id: string | null;
    operator_id: string | null;
  };
};

export type WeeklyEntitlementTransferOption = {
  allocation_id: string;
  subscriber_id: string;
  subscriber_name: string;
  source_date: string;
  original_minutes: number;
  allocated_minutes: number;
  consumed_minutes: number;
  available_minutes: number;
  target_allocated_minutes: number;
  weekly_quota_minutes: number;
  weekly_consumed_minutes: number;
  weekly_remaining_minutes: number;
  cycle_start: string;
  cycle_end: string;
};

export type WeeklyQueueOperationLink = {
  id: string;
  subscriber_id: string;
  operation_id: string | null;
  weekly_entitlement_allocation_id: string | null;
  source_type: "weekly" | "weekly_reassigned";
  planned_minutes: number;
  status: "queued" | "running" | "completed" | "delayed" | "cancelled";
};

export type DailyQueueItem = {
  id: string;
  daily_queue_id: string;
  source_type: "weekly" | "weekly_reassigned" | "additional_registered" | "additional_guest" | "emergency" | "other";
  schedule_entry_id: string | null;
  subscriber_id: string | null;
  subscriber_name_snapshot: string;
  branch_id: string | null;
  branch_name_snapshot: string | null;
  planned_minutes: number;
  sort_order: number;
  status: "queued" | "running" | "completed" | "delayed" | "cancelled";
  operation_id: string | null;
  started_at: string | null;
  completed_at: string | null;
  weekly_entitlement_allocation_id?: string | null;
  /** False when this is a redacted placeholder for another operator's turn. */
  is_owned: boolean;
};

export type DailyQueueEvent = {
  id: string;
  event_type: "queue_generated" | "item_created" | "item_deferred" | "item_cancelled"
    | "item_operator_reassigned" | "reordered" | "branch_order_override" | "started" | "completed"
    | "auto_advance_scheduled" | "auto_advance_retargeted"
    | "auto_advance_cancelled" | "queue_closed" | "weekly_minutes_transferred";
  /** Null when the redacted queue view hides another actor's identity. */
  actor_id: string | null;
  occurred_at: string;
  reason: string | null;
  metadata: Record<string, unknown>;
};

export type DailyQueue = {
  id: string;
  organization_id: string;
  pump_id: string;
  weekly_schedule_id: string;
  queue_date: string;
  week_starts_on: number;
  weekly_cycle_start: string;
  status: "ready" | "running" | "closed";
  queue_version: number;
  auto_advance_queue_item_id: string | null;
  auto_advance_at: string | null;
  auto_advance_token: string | null;
  auto_advance_cancelled_at: string | null;
  items: DailyQueueItem[];
  events: DailyQueueEvent[];
};

export type DailyWorkReportDetails = {
  id: string;
  work_date: string;
  operator_id: string;
  created_by: string;
  work_started_at: string;
  work_ended_at: string;
  stoppage_minutes: number;
  status: "draft" | "submitted";
  submitted_at: string | null;
  submitted_by: string | null;
  updated_at: string;
  sourceTotals: {
    id: string;
    power_source_id: string;
    source_name_snapshot: string;
    minutes: number;
  }[];
  items: {
    id: string;
    entry_type: "weekly" | "weekly_reassigned" | "additional_registered" | "additional_guest";
    sort_order: number;
    subscriber_name_snapshot: string | null;
    external_beneficiary_name: string | null;
    scheduled_minutes: number;
    app_recorded_minutes: number;
    manual_minutes: number;
    extra_minutes: number;
    weekly_minutes_consumed: number;
    app_over_quota_minutes: number;
    fulfillment_status: "complete" | "partial" | "not_done" | "additional";
  }[];
  events: {
    id: string;
    actor_id: string;
    event_type: "draft_created" | "draft_updated" | "submitted";
    occurred_at: string;
    metadata: Record<string, unknown>;
  }[];
};

export type DailyPumpEnergyReport = {
  id: string;
  work_date: string;
  work_started_at: string;
  work_ended_at: string;
  stoppage_minutes: number;
  status: "draft" | "submitted";
  submitted_at: string | null;
  revision: number;
  sourceTotals: {
    id: string;
    power_source_id: string;
    source_name_snapshot: string;
    minutes: number;
  }[];
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
  operator_id: string;
  subscriber_operator_id: string | null;
  current_power_source_id: string | null;
  last_power_source_id: string | null;
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

  async listPumpOperators(organizationId: string, pumpId: string) {
    const assignments = await supabase
      .from("pump_assignments")
      .select("user_id")
      .eq("organization_id", organizationId)
      .eq("pump_id", pumpId)
      .eq("assignment_role", "operator");

    if (assignments.error) return { data: null, error: assignments.error };
    const ids = [...new Set((assignments.data ?? []).map((row) => row.user_id))];
    if (ids.length === 0) return { data: [], error: null };

    return supabase
      .from("profiles")
      .select("id,display_name")
      .eq("organization_id", organizationId)
      .eq("role", "operator")
      .in("id", ids)
      .order("display_name", { ascending: true });
  },

  async listDailyReportOperators(organizationId: string, pumpId: string, workDate: string) {
    const reports = await supabase
      .from("daily_work_reports")
      .select("operator_id")
      .eq("organization_id", organizationId)
      .eq("pump_id", pumpId)
      .eq("work_date", workDate);

    if (reports.error) return { data: null, error: reports.error };
    const ids = [...new Set((reports.data ?? []).map((row) => row.operator_id))];
    if (ids.length === 0) return { data: [], error: null };

    return supabase
      .from("profiles")
      .select("id,display_name")
      .eq("organization_id", organizationId)
      .eq("role", "operator")
      .in("id", ids)
      .order("display_name", { ascending: true });
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

  listPowerSources(organizationId: string, pumpId: string) {
    return supabase
      .from("pump_power_sources")
      .select("id,pump_id,name,source_type,is_active")
      .eq("organization_id", organizationId)
      .eq("pump_id", pumpId)
      .eq("is_active", true)
      .order("name", { ascending: true });
  },

  listPowerSourcesForReport(organizationId: string, pumpId: string) {
    // Historical sources remain selectable in a retrospective report after archival.
    return supabase
      .from("pump_power_sources")
      .select("id,pump_id,name,source_type,is_active")
      .eq("organization_id", organizationId)
      .eq("pump_id", pumpId)
      .order("name", { ascending: true });
  },

  createPowerSource(pumpId: string, name: string, sourceType: PumpPowerSource["source_type"]) {
    return supabase
      .from("pump_power_sources")
      .insert({ pump_id: pumpId, name: name.trim(), source_type: sourceType })
      .select("id,pump_id,name,source_type,is_active")
      .single();
  },

  archivePowerSource(sourceId: string) {
    return supabase
      .from("pump_power_sources")
      .update({ is_active: false })
      .eq("id", sourceId);
  },

  async loadOrCreateDailyQueue(organizationId: string, pumpId: string, queueDate: string) {
    const generated = await supabase.rpc("generate_daily_queue", {
      p_pump_id: pumpId,
      p_queue_date: queueDate,
    });
    if (generated.error) return { data: null, error: generated.error };

    const queueResult = await supabase
      .from("daily_queues")
      .select("id,organization_id,pump_id,weekly_schedule_id,queue_date,week_starts_on,weekly_cycle_start,status,queue_version,auto_advance_queue_item_id,auto_advance_at,auto_advance_token,auto_advance_cancelled_at")
      .eq("organization_id", organizationId)
      .eq("pump_id", pumpId)
      .eq("queue_date", queueDate)
      .maybeSingle();

    if (queueResult.error || !queueResult.data) {
      return { data: null, error: queueResult.error };
    }

    const queueViewResult = await supabase.rpc("get_daily_queue_operator_view", {
      p_queue_id: queueResult.data.id,
    });

    if (queueViewResult.error) {
      return { data: null, error: queueViewResult.error };
    }

    const queueView = (queueViewResult.data ?? {}) as {
      items?: DailyQueueItem[];
      events?: DailyQueueEvent[];
    };

    return {
      data: {
        ...queueResult.data,
        items: queueView.items ?? [],
        events: queueView.events ?? [],
      } satisfies DailyQueue,
      error: null,
    };
  },

  addDailyQueueItem(
    queueId: string,
    sourceType: "additional_registered" | "additional_guest" | "emergency",
    plannedMinutes: number,
    subscriberId?: string | null,
    subscriberName?: string | null,
  ) {
    return supabase.rpc("add_daily_queue_item", {
      p_queue_id: queueId,
      p_source_type: sourceType,
      p_subscriber_id: subscriberId ?? null,
      p_subscriber_name: subscriberName ?? null,
      p_planned_minutes: plannedMinutes,
    });
  },

  reorderDailyQueue(queueId: string, expectedVersion: number, orderedItemIds: string[], overrideReason?: string | null) {
    return supabase.rpc("reorder_daily_queue", {
      p_queue_id: queueId,
      p_expected_version: expectedVersion,
      p_order: orderedItemIds,
      p_override_reason: overrideReason ?? null,
    });
  },

  deferDailyQueueItem(queueId: string, itemId: string, expectedVersion: number, reason: string) {
    return supabase.rpc("defer_daily_queue_item", {
      p_queue_id: queueId,
      p_queue_item_id: itemId,
      p_expected_version: expectedVersion,
      p_reason: reason,
    });
  },

  cancelDailyQueueItem(queueId: string, itemId: string, expectedVersion: number, reason: string) {
    return supabase.rpc("cancel_daily_queue_item", {
      p_queue_id: queueId,
      p_queue_item_id: itemId,
      p_expected_version: expectedVersion,
      p_reason: reason,
    });
  },

  startDailyQueueItem(queueId: string, itemId: string, powerSourceId: string) {
    return supabase.rpc("start_daily_queue_item", {
      p_queue_id: queueId,
      p_queue_item_id: itemId,
      p_power_source_id: powerSourceId,
    });
  },

  startNextDailyQueueItem(queueId: string, itemId: string, token: string, powerSourceId: string) {
    return supabase.rpc("start_next_daily_queue_item", {
      p_queue_id: queueId,
      p_queue_item_id: itemId,
      p_auto_advance_token: token,
      p_power_source_id: powerSourceId,
    });
  },

  cancelDailyQueueAutoAdvance(queueId: string, token: string, reason?: string | null) {
    return supabase.rpc("cancel_daily_queue_auto_advance", {
      p_queue_id: queueId,
      p_auto_advance_token: token,
      p_reason: reason ?? null,
    });
  },

  listDailyScheduleEntries(organizationId: string, pumpId: string, workDate: string) {
    const weekday = new Date(`${workDate}T12:00:00Z`).getUTCDay() || 7;
    return supabase
      .from("schedule_entries")
      .select("id,subscriber_id,weekday,sort_order,planned_minutes,subscribers!inner(id,full_name,subscriber_number,branch_id,operator_id),weekly_schedules!inner(id,status,effective_from,effective_to)")
      .eq("organization_id", organizationId)
      .eq("pump_id", pumpId)
      .eq("weekday", weekday)
      .in("weekly_schedules.status", ["active", "archived"])
      .lte("weekly_schedules.effective_from", workDate)
      .or(`effective_to.is.null,effective_to.gte.${workDate}`, { referencedTable: "weekly_schedules" })
      .order("sort_order", { ascending: true });
  },

  async listWeeklyEntitlementAllocationsForDay(
    _organizationId: string,
    pumpId: string,
    workDate: string,
  ) {
    const result = await supabase.rpc("get_daily_work_report_allocations", {
      p_pump_id: pumpId,
      p_work_date: workDate,
    });

    if (result.error) return { data: null, error: result.error };

    const rows = (result.data ?? []) as {
      id: string;
      subscriber_id: string;
      allocation_date: string;
      source_schedule_entry_id: string | null;
      original_minutes: number;
      allocated_minutes: number;
      consumed_minutes: number;
      available_minutes: number;
      weekday: number;
      sort_order: number;
      full_name: string;
      subscriber_number: number;
      branch_id: string | null;
      operator_id: string | null;
    }[];

    return {
      data: rows.map((row) => ({
        id: row.id,
        subscriber_id: row.subscriber_id,
        allocation_date: row.allocation_date,
        source_schedule_entry_id: row.source_schedule_entry_id,
        original_minutes: row.original_minutes,
        allocated_minutes: row.allocated_minutes,
        consumed_minutes: row.consumed_minutes,
        available_minutes: row.available_minutes,
        weekday: row.weekday,
        sort_order: row.sort_order,
        subscribers: {
          id: row.subscriber_id,
          full_name: row.full_name,
          subscriber_number: row.subscriber_number,
          branch_id: row.branch_id,
          operator_id: row.operator_id,
        },
      })) satisfies WeeklyEntitlementAllocationForDay[],
      error: null,
    };
  },

  listWeeklyQueueItemsForReport(organizationId: string, pumpId: string, workDate: string) {
    return supabase
      .from("queue_items")
      .select("id,subscriber_id,operation_id,weekly_entitlement_allocation_id,source_type,planned_minutes,status,daily_queues!inner(queue_date)")
      .eq("organization_id", organizationId)
      .eq("pump_id", pumpId)
      .eq("daily_queues.queue_date", workDate)
      .in("source_type", ["weekly", "weekly_reassigned"])
      .order("sort_order", { ascending: true });
  },

  getWeeklyEntitlementTransferOptions(pumpId: string, targetDate: string) {
    return supabase.rpc("get_weekly_entitlement_transfer_options", {
      p_pump_id: pumpId,
      p_target_date: targetDate,
    });
  },

  transferWeeklyEntitlementMinutes(args: {
    sourceAllocationId: string;
    targetDate: string;
    minutes: number;
    reason: string;
  }) {
    return supabase.rpc("transfer_weekly_entitlement_minutes", {
      p_source_allocation_id: args.sourceAllocationId,
      p_target_date: args.targetDate,
      p_minutes: args.minutes,
      p_reason: args.reason,
    });
  },

  getScheduleWeekStartsOn(organizationId: string, pumpId: string, workDate: string) {
    return supabase
      .from("weekly_schedules")
      .select("week_starts_on,effective_from")
      .eq("organization_id", organizationId)
      .eq("pump_id", pumpId)
      .in("status", ["active", "archived"])
      .lte("effective_from", workDate)
      .or(`effective_to.is.null,effective_to.gte.${workDate}`)
      .order("effective_from", { ascending: false })
      .limit(1)
      .maybeSingle();
  },

  getPowerUsage(from: string, to: string, period: "day" | "week" | "month", pumpId: string) {
    return supabase.rpc("get_pump_power_usage", {
      p_from: from,
      p_to: to,
      p_period: period,
      p_pump_id: pumpId,
    });
  },

  getReportActors(organizationId: string, actorIds: string[]) {
    if (actorIds.length === 0) {
      return Promise.resolve({ data: [], error: null });
    }
    return supabase
      .from("profiles")
      .select("id,display_name")
      .eq("organization_id", organizationId)
      .in("id", actorIds);
  },

  async getDailyPumpEnergyReport(organizationId: string, pumpId: string, workDate: string) {
    const reportResult = await supabase
      .from("daily_pump_energy_reports")
      .select("id,work_date,work_started_at,work_ended_at,stoppage_minutes,status,submitted_at,revision")
      .eq("organization_id", organizationId)
      .eq("pump_id", pumpId)
      .eq("work_date", workDate)
      .maybeSingle();

    if (reportResult.error || !reportResult.data) {
      return { data: null, error: reportResult.error };
    }

    const sourcesResult = await supabase
      .from("daily_pump_energy_source_totals")
      .select("id,power_source_id,source_name_snapshot,minutes")
      .eq("organization_id", organizationId)
      .eq("daily_pump_energy_report_id", reportResult.data.id)
      .order("source_name_snapshot", { ascending: true });

    if (sourcesResult.error) return { data: null, error: sourcesResult.error };
    return {
      data: {
        ...reportResult.data,
        sourceTotals: (sourcesResult.data ?? []) as DailyPumpEnergyReport["sourceTotals"],
      } satisfies DailyPumpEnergyReport,
      error: null,
    };
  },

  async getDailyWorkReport(
    organizationId: string,
    pumpId: string,
    workDate: string,
    operatorId?: string | null,
  ) {
    let reportQuery = supabase
      .from("daily_work_reports")
      .select("id,work_date,operator_id,created_by,work_started_at,work_ended_at,stoppage_minutes,status,submitted_at,submitted_by,updated_at")
      .eq("organization_id", organizationId)
      .eq("pump_id", pumpId)
      .eq("work_date", workDate);

    if (operatorId) reportQuery = reportQuery.eq("operator_id", operatorId);
    const reportResult = await reportQuery.order("operator_id", { ascending: true }).limit(1).maybeSingle();

    if (reportResult.error || !reportResult.data) {
      return { data: null, error: reportResult.error };
    }

    const reportId = reportResult.data.id;
    const [energyResult, itemsResult, eventsResult] = await Promise.all([
      this.getDailyPumpEnergyReport(organizationId, pumpId, workDate),
      supabase
        .from("daily_work_report_items")
        .select("id,entry_type,sort_order,subscriber_name_snapshot,external_beneficiary_name,scheduled_minutes,app_recorded_minutes,manual_minutes,extra_minutes,weekly_minutes_consumed,app_over_quota_minutes,fulfillment_status")
        .eq("organization_id", organizationId)
        .eq("daily_work_report_id", reportId)
        .order("sort_order", { ascending: true }),
      supabase
        .from("daily_work_report_events")
        .select("id,actor_id,event_type,occurred_at,metadata")
        .eq("organization_id", organizationId)
        .eq("daily_work_report_id", reportId)
        .order("occurred_at", { ascending: true }),
    ]);

    const detailError = energyResult.error ?? itemsResult.error ?? eventsResult.error;
    if (detailError) return { data: null, error: detailError };

    return {
      data: {
        ...reportResult.data,
        sourceTotals: energyResult.data?.sourceTotals ?? [],
        items: (itemsResult.data ?? []) as DailyWorkReportDetails["items"],
        events: (eventsResult.data ?? []) as DailyWorkReportDetails["events"],
      } satisfies DailyWorkReportDetails,
      error: null,
    };
  },

  saveDailyWorkReport(args: {
    pumpId: string;
    operatorId: string;
    workStartedAt: string;
    workEndedAt: string;
    stoppageMinutes: number;
    sourceTotals: { power_source_id: string; minutes: number }[];
    items: {
      entry_type: "weekly" | "weekly_reassigned" | "additional_registered" | "additional_guest";
      schedule_entry_id?: string | null;
      weekly_entitlement_allocation_id?: string | null;
      subscriber_id?: string | null;
      external_beneficiary_name?: string | null;
      sort_order: number;
      manual_minutes: number;
      extra_minutes: number;
      note?: string | null;
    }[];
    submit: boolean;
    reportId?: string | null;
  }) {
    return supabase.rpc("save_daily_work_report", {
      p_pump_id: args.pumpId,
      p_target_operator_id: args.operatorId,
      p_work_started_at: args.workStartedAt,
      p_work_ended_at: args.workEndedAt,
      p_stoppage_minutes: args.stoppageMinutes,
      p_source_totals: args.sourceTotals,
      p_items: args.items,
      p_submit: args.submit,
      p_report_id: args.reportId ?? null,
    });
  },

  listPumpOperations(organizationId: string, pumpId: string, day: string) {
    return supabase
      .from("pump_operations")
      .select("id,pump_id,subscriber_id,subscriber_name,operator_id,subscriber_operator_id,planned_minutes,status,started_at,paused_at,pause_reason,paused_seconds,ended_at,actual_seconds,operation_date,current_power_source_id,last_power_source_id")
      .eq("organization_id", organizationId)
      .eq("pump_id", pumpId)
      .or(`operation_date.eq.${day},status.in.(running,paused)`)
      .order("started_at", { ascending: false });
  },

  start(pumpId: string, subscriberId: string | null, subscriberName: string | null, plannedMinutes: number, powerSourceId: string) {
    return supabase.rpc("start_pump_operation", {
      p_pump_id: pumpId,
      p_subscriber_id: subscriberId,
      p_subscriber_name: subscriberName,
      p_planned_minutes: plannedMinutes,
      p_power_source_id: powerSourceId,
    });
  },

  pause(operationId: string, reason: string) {
    return supabase.rpc("pause_pump_operation", {
      p_operation_id: operationId,
      p_reason: reason,
    });
  },

  resume(operationId: string, powerSourceId: string) {
    return supabase.rpc("resume_pump_operation", {
      p_operation_id: operationId,
      p_power_source_id: powerSourceId,
    });
  },

  extendTime(operationId: string, addedMinutes: number) {
    return supabase.rpc("extend_pump_operation_time", {
      p_operation_id: operationId,
      p_added_minutes: addedMinutes,
    });
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
