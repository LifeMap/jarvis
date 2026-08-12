export type ScheduleType = "one_time" | "recurring";
export type ScheduleStatus = "scheduled" | "running" | "completed" | "failed" | "disabled";
export type RecurrenceRule =
  | { frequency: "daily"; hour: number; minute: number }
  | { frequency: "weekly"; weekday: number; hour: number; minute: number };
export type ScheduleRule = { runAt: string } | RecurrenceRule;
export interface JarvisSchedule {
  id: string; title: string; instruction: string; scheduleType: ScheduleType; scheduleRule: ScheduleRule;
  timezone: string; enabled: boolean; status: ScheduleStatus; nativeScheduleId: string | null;
  createdAt: string; updatedAt: string; lastRunAt: string | null; nextRunAt: string | null; lastResult: string | null;
}
export interface CreateScheduleInput {
  title: string; instruction: string; scheduleType: ScheduleType; scheduleRule: ScheduleRule; timezone?: string;
}
export interface UpdateScheduleInput { title?: string; instruction?: string; scheduleRule?: ScheduleRule; timezone?: string; enabled?: boolean }
