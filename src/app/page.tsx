import { Suspense } from "react";
import { OpenfeedApp } from "@/components/openfeed-app";

export default function Page() {
  return (
    <Suspense fallback={<div className="h-dvh bg-[var(--ground)]" />}>
      <OpenfeedApp />
    </Suspense>
  );
}
