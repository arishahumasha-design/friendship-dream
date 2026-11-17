import type { Metadata } from "next";
import { Hind_Siliguri, Inter } from "next/font/google";
import { I18nProvider } from "@/components/I18nProvider";
import { SiteHeader } from "@/components/SiteHeader";
import { getDictionary, getLang } from "@/lib/i18n/server";
import { themeInitScript } from "@/lib/theme";
import "./globals.css";

const inter = Inter({ variable: "--font-inter", subsets: ["latin"] });

const hind = Hind_Siliguri({
  variable: "--font-hind",
  subsets: ["bengali", "latin"],
  weight: ["400", "500", "600", "700"],
});

export const metadata: Metadata = {
  title: { default: "Friendship Dream (FD)", template: "%s · Friendship Dream" },
  description: "Friendship Dream — an interest-free savings and investment samiti.",
  robots: { index: false, follow: false },
};

export default async function RootLayout({ children }: LayoutProps<"/">) {
  const lang = await getLang();

  return (
    <html
      lang={lang}
      className={`${inter.variable} ${hind.variable} h-full antialiased`}
      suppressHydrationWarning
    >
      <head>
        <script dangerouslySetInnerHTML={{ __html: themeInitScript }} />
      </head>
      <body className="flex min-h-full flex-col">
        <I18nProvider lang={lang} dictionary={getDictionary(lang)}>
          <SiteHeader />
          <main className="flex flex-1 flex-col">{children}</main>
        </I18nProvider>
      </body>
    </html>
  );
}
