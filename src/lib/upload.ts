import { MAX_FILE_BYTES, PDF_SLOTS, type FileSlot } from "./members";

export const IMAGE_TYPES = ["image/jpeg", "image/png", "image/webp"];
const MAX_DIMENSION = 1600;
const RESIZE_ABOVE_BYTES = 1024 * 1024;

export type PreparedFile = { blob: Blob; contentType: string; ext: string };
export type UploadError = "fileType" | "fileTooLarge" | "fileUnreadable";

/** "receipt" = a deposit receipt (images or PDF). */
export type UploadSlot = FileSlot | "receipt";
const allowsPdf = (slot: UploadSlot) => slot === "receipt" || PDF_SLOTS.includes(slot as FileSlot);

export function acceptFor(slot: UploadSlot) {
  const types = allowsPdf(slot) ? [...IMAGE_TYPES, "application/pdf"] : IMAGE_TYPES;
  return types.join(",");
}

const EXT: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
  "application/pdf": "pdf",
};

/**
 * Checks the file type and size, and shrinks large photos in the browser
 * (max 1600 px on the long side) before upload.
 */
export async function prepareFile(
  slot: UploadSlot,
  file: File,
): Promise<{ ok: true; file: PreparedFile } | { ok: false; error: UploadError }> {
  const type = file.type.toLowerCase();
  const allowPdf = allowsPdf(slot);

  if (type === "application/pdf") {
    if (!allowPdf) return { ok: false, error: "fileType" };
    if (file.size > MAX_FILE_BYTES) return { ok: false, error: "fileTooLarge" };
    return { ok: true, file: { blob: file, contentType: type, ext: "pdf" } };
  }
  if (!IMAGE_TYPES.includes(type)) return { ok: false, error: "fileType" };

  let bitmap: ImageBitmap;
  try {
    bitmap = await createImageBitmap(file, { imageOrientation: "from-image" });
  } catch {
    return { ok: false, error: "fileUnreadable" };
  }

  const longSide = Math.max(bitmap.width, bitmap.height);
  if (longSide <= MAX_DIMENSION && file.size <= RESIZE_ABOVE_BYTES) {
    bitmap.close();
    return { ok: true, file: { blob: file, contentType: type, ext: EXT[type] } };
  }

  const scale = Math.min(1, MAX_DIMENSION / longSide);
  const canvas = document.createElement("canvas");
  canvas.width = Math.round(bitmap.width * scale);
  canvas.height = Math.round(bitmap.height * scale);
  const ctx = canvas.getContext("2d");
  if (!ctx) {
    bitmap.close();
    return { ok: false, error: "fileUnreadable" };
  }
  ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close();

  // WebP keeps transparency (signatures); browsers without WebP encoding fall back to JPEG.
  let blob = await toBlob(canvas, "image/webp", 0.85);
  if (!blob || blob.type !== "image/webp") {
    const flat = document.createElement("canvas");
    flat.width = canvas.width;
    flat.height = canvas.height;
    const fctx = flat.getContext("2d")!;
    fctx.fillStyle = "#ffffff";
    fctx.fillRect(0, 0, flat.width, flat.height);
    fctx.drawImage(canvas, 0, 0);
    blob = await toBlob(flat, "image/jpeg", 0.85);
  }
  if (!blob) return { ok: false, error: "fileUnreadable" };
  if (blob.size > MAX_FILE_BYTES) return { ok: false, error: "fileTooLarge" };
  return { ok: true, file: { blob, contentType: blob.type, ext: EXT[blob.type] ?? "jpg" } };
}

function toBlob(canvas: HTMLCanvasElement, type: string, quality: number) {
  return new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, type, quality));
}
