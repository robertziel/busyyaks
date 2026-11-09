import { useEffect, useState } from "react";

// Re-render every `every` ms so relative times ("12s ago") count up between data reads.
export function useNow(every: number): number {
  const [t, setT] = useState(() => Date.now());
  useEffect(() => {
    const id = window.setInterval(() => setT(Date.now()), every);
    return () => window.clearInterval(id);
  }, [every]);
  return t;
}
