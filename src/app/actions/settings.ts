"use server";

import { revalidatePath } from "next/cache";
import { getCurrentProfile } from "@/lib/auth";
import { depositErrorKey, type DepositErrorKey } from "@/lib/deposits";
import { parseAmount } from "@/lib/format";
import { loadSettings, SETTING_KEYS, type AppSettings } from "@/lib/settings";
import { createClient } from "@/lib/supabase/server";

export type SettingsInput = {
  monthlyAmount: string;
  yearlySaving: string;
  lateFee: string;
  shareValue: string;
  membersCanSeeOthers: boolean;
};

export type SettingsErrorKey = "errMonthly" | "errShare" | "errZeroOrMore" | "errNotAllowed" | "errSaveFailed";

export type SettingsResult =
  | { ok: true; changed: number }
  | { ok: false; field?: keyof AppSettings; error: SettingsErrorKey | DepositErrorKey };

const MAX_VALUE = 10_000_000;

/** Super admin only. RLS also lets only the super admin update app_settings. */
export async function saveSettings(input: SettingsInput): Promise<SettingsResult> {
  const me = await getCurrentProfile();
  if (!me || me.status !== "active" || me.role !== "super_admin") return { ok: false, error: "errNotAllowed" };

  const num = (text: string) => {
    const v = parseAmount(String(text));
    return v !== null && v <= MAX_VALUE ? v : null;
  };
  const monthlyAmount = num(input.monthlyAmount);
  const yearlySaving = num(input.yearlySaving);
  const lateFee = num(input.lateFee);
  const shareValue = num(input.shareValue);
  if (monthlyAmount === null || monthlyAmount <= 0) return { ok: false, field: "monthlyAmount", error: "errMonthly" };
  if (yearlySaving === null) return { ok: false, field: "yearlySaving", error: "errZeroOrMore" };
  if (lateFee === null) return { ok: false, field: "lateFee", error: "errZeroOrMore" };
  if (shareValue === null || shareValue <= 0) return { ok: false, field: "shareValue", error: "errShare" };
  if (typeof input.membersCanSeeOthers !== "boolean") return { ok: false, error: "errSaveFailed" };

  const next: AppSettings = {
    monthlyAmount,
    yearlySaving,
    lateFee,
    shareValue,
    membersCanSeeOthers: input.membersCanSeeOthers,
  };

  const supabase = await createClient();
  const current = await loadSettings(supabase);
  const fields = Object.keys(next) as (keyof AppSettings)[];
  let changed = 0;

  for (const field of fields) {
    if (next[field] === current[field]) continue;
    const { data, error } = await supabase
      .from("app_settings")
      .update({ value: next[field], updated_by: me.id, updated_at: new Date().toISOString() })
      .eq("key", SETTING_KEYS[field])
      .select("key")
      .maybeSingle();
    if (error) {
      const key = depositErrorKey(error);
      return { ok: false, field, error: key === "errGeneric" ? "errSaveFailed" : key };
    }
    if (!data) return { ok: false, field, error: "errNotAllowed" };
    changed++;
  }

  revalidatePath("/admin/settings");
  revalidatePath("/deposits");
  return { ok: true, changed };
}
