export type ThemePref = "light" | "dark" | "system";
export const THEME_STORAGE_KEY = "fd-theme";

/**
 * Runs inline in <head> before the first paint, so there is no flash of the wrong theme.
 * Reads the saved preference (default "system") and sets data-theme on <html>.
 */
export const themeInitScript = `(function(){try{var p=localStorage.getItem("${THEME_STORAGE_KEY}");if(p!=="light"&&p!=="dark")p="system";var d=p==="dark"||(p==="system"&&window.matchMedia("(prefers-color-scheme: dark)").matches);document.documentElement.setAttribute("data-theme",d?"dark":"light");document.documentElement.setAttribute("data-theme-pref",p);}catch(e){}})();`;
