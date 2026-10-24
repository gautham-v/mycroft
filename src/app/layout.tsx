import type { Metadata, Viewport } from "next";
import { IBM_Plex_Mono, Inter } from "next/font/google";
import { ServiceWorkerRegister } from "@/components/sw-register";
import "./globals.css";

const inter = Inter({ variable: "--font-inter", subsets: ["latin"], weight: ["400", "500", "600"], display: "swap" });
const plexMono = IBM_Plex_Mono({ variable: "--font-plex-mono", subsets: ["latin"], weight: ["400", "500"], display: "swap" });

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
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#FAFAF8" },
    { media: "(prefers-color-scheme: dark)", color: "#141412" },
  ],
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="en" className={`${inter.variable} ${plexMono.variable} antialiased`}>
      <body>
        {children}
        <ServiceWorkerRegister />
      </body>
    </html>
  );
}
