import type { SupabaseClient } from "@supabase/supabase-js";

export type AppSettings = {
  monthlyAmount: number;
  yearlySaving: number;
  lateFee: number;
  shareValue: number;
  membersCanSeeOthers: boolean;
};

export const SETTING_DEFAULTS: AppSettings = {
  monthlyAmount: 3000,
  yearlySaving: 0,
  lateFee: 0,
  shareValue: 5000,
  membersCanSeeOthers: true,
};

/** Key in the app_settings table for each field. */
export const SETTING_KEYS: Record<keyof AppSettings, string> = {
  monthlyAmount: "monthly_amount",
  yearlySaving: "yearly_saving",
  lateFee: "late_fee",
  shareValue: "share_value",
  membersCanSeeOthers: "members_can_see_others",
};

/** Reads settings with the caller's session (active members may read them). */
export async function loadSettings(supabase: SupabaseClient): Promise<AppSettings> {
  const { data } = await supabase.from("app_settings").select("key, value");
  const map = new Map((data ?? []).map((r) => [r.key as string, r.value as unknown]));
  const num = (field: Exclude<keyof AppSettings, "membersCanSeeOthers">) => {
    const v = Number(map.get(SETTING_KEYS[field]));
    return Number.isFinite(v) ? v : SETTING_DEFAULTS[field];
  };
  const seeOthers = map.get(SETTING_KEYS.membersCanSeeOthers);
  return {
    monthlyAmount: num("monthlyAmount"),
    yearlySaving: num("yearlySaving"),
    lateFee: num("lateFee"),
    shareValue: num("shareValue"),
    membersCanSeeOthers: typeof seeOthers === "boolean" ? seeOthers : SETTING_DEFAULTS.membersCanSeeOthers,
  };
}
