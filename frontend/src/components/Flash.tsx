// The result of a launch / create / note: shown at the top of the page until the next navigation
// (a flash set for the page being navigated to survives that one navigation).
import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from "react";

export type Flash = { ok: boolean; text: string; attach?: string; path?: string };
type Ctx = { flash: Flash | null; setFlash: (f: Flash | null) => void };
const FlashCtx = createContext<Ctx>({ flash: null, setFlash: () => {} });

export function FlashProvider({ children }: { children: ReactNode }) {
  const [flash, set] = useState<Flash | null>(null);
  const setFlash = useCallback(
    (f: Flash | null) => set(f ? { ...f, path: f.path ?? window.location.pathname } : null),
    [],
  );
  const value = useMemo(() => ({ flash, setFlash }), [flash, setFlash]);
  return <FlashCtx.Provider value={value}>{children}</FlashCtx.Provider>;
}

export const useFlash = () => useContext(FlashCtx);

export function FlashView({ flash, onClose }: { flash: Flash; onClose: () => void }) {
  return (
    <div className={`flash ${flash.ok ? "ok" : "bad"}`} role="status">
      <i className={`dot ${flash.ok ? "ok" : "bad"}`} />
      <span>{flash.text}</span>
      {flash.attach && <code>{flash.attach}</code>}
      <button type="button" className="btn small flash-close" onClick={onClose} aria-label="Dismiss">
        ×
      </button>
    </div>
  );
}
