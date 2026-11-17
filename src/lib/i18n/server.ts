import { cookies } from "next/headers";
import { bn } from "./bn";
import { en } from "./en";
import { DEFAULT_LANG, LANG_COOKIE, isLang, type Dictionary, type Lang } from "./types";

const dictionaries: Record<Lang, Dictionary> = { en, bn };

export function getDictionary(lang: Lang): Dictionary {
  return dictionaries[lang];
}

/** Current UI language from the cookie (English by default). */
export async function getLang(): Promise<Lang> {
  const value = (await cookies()).get(LANG_COOKIE)?.value;
  return isLang(value) ? value : DEFAULT_LANG;
}

export async function getI18n() {
  const lang = await getLang();
  return { lang, t: getDictionary(lang) };
}
