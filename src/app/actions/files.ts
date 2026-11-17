"use server";

import { SIGNED_URL_SECONDS } from "@/lib/members";
import { createClient } from "@/lib/supabase/server";

export type SignResult = { url: string } | { error: true };

/**
 * Fresh 60-second link to view one stored file.
 * Uses the caller's own session, so RLS + storage policies decide (owner or admin).
 * `fileId` is a member_documents id, or "avatar" for the member's photo.
 */
export async function signFile(memberId: string, fileId: string): Promise<SignResult> {
  const supabase = await createClient();

  if (fileId === "avatar") {
    const { data } = await supabase
      .from("profiles")
      .select("photo_path")
      .eq("id", memberId)
      .maybeSingle();
    if (!data?.photo_path) return { error: true };
    const { data: signed } = await supabase.storage
      .from("avatars")
      .createSignedUrl(data.photo_path, SIGNED_URL_SECONDS);
    return signed?.signedUrl ? { url: signed.signedUrl } : { error: true };
  }

  const { data } = await supabase
    .from("member_documents")
    .select("storage_path")
    .eq("id", fileId)
    .eq("member_id", memberId)
    .maybeSingle();
  if (!data?.storage_path) return { error: true };
  const { data: signed } = await supabase.storage
    .from("documents")
    .createSignedUrl(data.storage_path, SIGNED_URL_SECONDS);
  return signed?.signedUrl ? { url: signed.signedUrl } : { error: true };
}

/**
 * Fresh 60-second link to view one deposit receipt.
 * Runs with the caller's own session: only the member who owns the deposit, or an admin, gets a link.
 */
export async function signReceipt(depositId: string): Promise<SignResult> {
  const supabase = await createClient();
  const { data } = await supabase
    .from("deposits")
    .select("receipt_path")
    .eq("id", depositId)
    .maybeSingle();
  if (!data?.receipt_path) return { error: true };
  const { data: signed } = await supabase.storage
    .from("receipts")
    .createSignedUrl(data.receipt_path, SIGNED_URL_SECONDS);
  return signed?.signedUrl ? { url: signed.signedUrl } : { error: true };
}

/**
 * Fresh 60-second link to an expense receipt. Receipts live in the private 'receipts' bucket in the folder
 * of the admin who uploaded them; the storage policy lets only that admin or another admin read them.
 * `source` says where the path is stored: a waiting request, or the approved expense.
 */
export async function signExpenseReceipt(source: "request" | "expense", id: string): Promise<SignResult> {
  if (typeof id !== "string" || (source !== "request" && source !== "expense")) return { error: true };
  const supabase = await createClient();
  const { data } = await supabase
    .from(source === "request" ? "money_requests" : "expenses")
    .select("receipt_path")
    .eq("id", id)
    .maybeSingle();
  if (!data?.receipt_path) return { error: true };
  const { data: signed } = await supabase.storage
    .from("receipts")
    .createSignedUrl(data.receipt_path, SIGNED_URL_SECONDS);
  return signed?.signedUrl ? { url: signed.signedUrl } : { error: true };
}
