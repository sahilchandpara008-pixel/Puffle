import type { Metadata } from "next";
import "./globals.css";

const site = process.env.NEXT_PUBLIC_SITE_URL ?? "https://puffle-web.vercel.app";

export const metadata: Metadata = {
  metadataBase: new URL(site),
  title: { default: "Puffle — Cloud storage & creator channels", template: "%s · Puffle" },
  description: "Puffle: private cloud storage and creator channels, made for India.",
  openGraph: { siteName: "Puffle", type: "website" },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
