import { Suspense } from "react";
import { MycroftApp } from "@/components/mycroft-app";

export default function Page() {
  return (
    <Suspense fallback={<div className="h-dvh bg-[var(--ground)]" />}>
      <MycroftApp />
    </Suspense>
  );
}
