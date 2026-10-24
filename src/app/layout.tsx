import type { Metadata, Viewport } from "next";
import { ServiceWorkerRegister } from "@/components/sw-register";
import "./globals.css";

export const metadata: Metadata = {
  title: "Openfeed",
  description: "A quiet RSS and YouTube reader.",
  manifest: "/manifest.webmanifest",
  applicationName: "Openfeed",
  appleWebApp: { capable: true, title: "Openfeed", statusBarStyle: "default" },
  // Next 16 emits only mobile-web-app-capable; older iOS still keys off the apple- prefixed tag.
  other: { "apple-mobile-web-app-capable": "yes" },
  icons: {
    icon: [
      { url: "/icons/icon-192.png", sizes: "192x192", type: "image/png" },
      { url: "/icons/icon-512.png", sizes: "512x512", type: "image/png" },
    ],
    apple: [{ url: "/icons/apple-touch-icon-180.png", sizes: "180x180" }],
  },
};

export const viewport: Viewport = {
  // Desktop (lg+) shows the ground behind inset panels; smaller screens show the full-bleed panel.
  themeColor: [
    { media: "(prefers-color-scheme: light) and (min-width: 1024px)", color: "#F2F2F4" },
    { media: "(prefers-color-scheme: dark) and (min-width: 1024px)", color: "#000000" },
    { media: "(prefers-color-scheme: light)", color: "#FFFFFF" },
    { media: "(prefers-color-scheme: dark)", color: "#161618" },
  ],
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
};

// Applies the stored theme (see src/hooks/use-settings.ts) during HTML parsing, before first paint.
const THEME_SCRIPT = `(function(){try{var t=JSON.parse(localStorage.getItem("openfeed.settings")||"{}").theme;if(t==="light"||t==="dark")document.documentElement.setAttribute("data-theme",t)}catch(e){}})()`;

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="en" className="antialiased" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: THEME_SCRIPT }} />
      </head>
      <body>
        {children}
        <ServiceWorkerRegister />
      </body>
    </html>
  );
}
