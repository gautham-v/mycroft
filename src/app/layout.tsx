import type { Metadata, Viewport } from "next";
import { ServiceWorkerRegister } from "@/components/sw-register";
import "./globals.css";

export const metadata: Metadata = {
  title: "Mycroft",
  description: "A quiet RSS and YouTube reader.",
  manifest: "/manifest.webmanifest",
  applicationName: "Mycroft",
  appleWebApp: { capable: true, title: "Mycroft", statusBarStyle: "default" },
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

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="en" className="antialiased">
      <body>
        {children}
        <ServiceWorkerRegister />
      </body>
    </html>
  );
}
