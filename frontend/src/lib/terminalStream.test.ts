// The live terminal's wire format: what the server sends, parsed; what the browser sends, encoded.
import { describe, expect, it } from "vitest";
import { controlFrame, fromBase64, inputFrame, parseServer, terminalUrl, toBase64 } from "./terminalStream";

const dec = (b: Uint8Array) => new TextDecoder().decode(b);

describe("parseServer", () => {
  it("reads the first message: the size and the screen now", () => {
    const f = parseServer(JSON.stringify({ ok: true, session: "w", cols: 80, rows: 24, screen: btoa("SCREEN\r\n") }));
    expect(f.kind).toBe("hello");
    if (f.kind !== "hello") return;
    expect([f.session, f.cols, f.rows, dec(f.screen)]).toEqual(["w", 80, 24, "SCREEN\r\n"]);
  });

  it("reads every stream frame", () => {
    const o = parseServer(JSON.stringify({ o: btoa("hi") }));
    expect(o.kind === "output" && dec(o.data)).toBe("hi");
    expect(parseServer(JSON.stringify({ size: { cols: 100, rows: 30 } }))).toEqual({
      kind: "size",
      cols: 100,
      rows: 30,
    });
    expect(parseServer(JSON.stringify({ control: true }))).toEqual({ kind: "control", on: true });
    expect(parseServer(JSON.stringify({ refused: "no" }))).toEqual({ kind: "refused", why: "no" });
    expect(parseServer(JSON.stringify({ exit: "gone" }))).toEqual({ kind: "exit", why: "gone" });
    expect(parseServer(JSON.stringify({ ok: false, error: "x" }))).toEqual({ kind: "denied", error: "x" });
  });

  it("never acts on anything else", () => {
    for (const raw of ["nope", "[]", "{}", '{"size":{"cols":0,"rows":3}}', '{"ok":true,"session":"w"}'])
      expect(parseServer(raw).kind).toBe("unknown");
  });
});

describe("client frames", () => {
  it("encodes keys as UTF-8 base64 and control as a boolean", () => {
    expect(JSON.parse(inputFrame("é\r")) as unknown).toEqual({ i: toBase64(new TextEncoder().encode("é\r")) });
    expect(dec(fromBase64((JSON.parse(inputFrame("é\x1b")) as { i: string }).i))).toBe("é\x1b");
    expect(controlFrame(true)).toBe('{"control":true}');
  });

  it("round-trips a paste larger than one fromCharCode chunk", () => {
    const big = new Uint8Array(70_000).map((_, i) => i % 256);
    expect(fromBase64(toBase64(big))).toEqual(big);
  });
});

describe("terminalUrl", () => {
  it("is the page's own origin, wss under https", () => {
    expect(terminalUrl({ protocol: "https:", host: "b.example" }, "a b", "default")).toBe(
      "wss://b.example/api/terminal?session=a+b&socket=default",
    );
    expect(terminalUrl({ protocol: "http:", host: "127.0.0.1:4100" }, "w", "s")).toBe(
      "ws://127.0.0.1:4100/api/terminal?session=w&socket=s",
    );
  });
});
