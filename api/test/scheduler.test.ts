import { describe,expect,it } from "vitest";
import { nextRun } from "../src/scheduler/schedule-time";
describe("Scheduler time calculation",()=>{
  it("converts Asia/Seoul local recurrence to the correct UTC instant",()=>{
    expect(nextRun("recurring",{frequency:"daily",hour:8,minute:0},"Asia/Seoul",new Date("2026-08-12T00:00:00Z")).toISOString()).toBe("2026-08-12T23:00:00.000Z");
  });
  it("calculates the next weekly occurrence",()=>{
    expect(nextRun("recurring",{frequency:"weekly",weekday:1,hour:8,minute:0},"Asia/Seoul",new Date("2026-08-12T00:00:00Z")).toISOString()).toBe("2026-08-16T23:00:00.000Z");
  });
  it("rejects invalid timezone and past one-time schedules",()=>{
    expect(()=>nextRun("one_time",{runAt:"2020-01-01T00:00:00Z"},"Asia/Seoul",new Date("2026-01-01"))).toThrow();
    expect(()=>nextRun("recurring",{frequency:"daily",hour:8,minute:0},"Invalid/Zone")).toThrow();
  });
});
