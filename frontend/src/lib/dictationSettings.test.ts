// Settings → Dictation's derivations (card 634): the draft both ways (the token write-only), whose models the form
// shows, why Save / Test / Connect are off, the model options.
import { describe, expect, it } from "vitest";
import {
  adopts,
  changedKeys,
  checkLine,
  checkRefusal,
  connectRefusal,
  fieldRefusal,
  fromDraft,
  modelOptions,
  modelsFor,
  modelsLine,
  saveRefusal,
  tokenLine,
  tokenPlaceholder,
  toDraft,
  type DictationData,
  type Draft,
} from "./dictationSettings";

const LIMITS: DictationData["limits"] = { timeout_seconds: [1, 300], max_seconds: [30, 600] };
const data = (over: Partial<DictationData> = {}): DictationData => ({
  revision: { id: 3, author: "op", at: 1 },
  doc: {
    enabled: true,
    url: "http://speech:8000",
    token: null,
    token_set: true,
    token_hint: "…abcd",
    model: "/models/parakeet",
    timeout_seconds: 30,
    max_seconds: 120,
  },
  models: ["llm", "/models/parakeet"],
  models_error: null,
  limits: LIMITS,
  history: [],
  revisions: 3,
  ...over,
});
const loaded = toDraft(data());
const moved: Draft = { ...loaded, url: "http://other:9000" };

describe("dictation settings", () => {
  it("drafts a revision and back, the saved token kept (null); no revision = an empty form, off, no token", () => {
    expect(loaded).toEqual({
      enabled: true,
      url: "http://speech:8000",
      token: null,
      model: "/models/parakeet",
      timeout_seconds: "30",
      max_seconds: "120",
    });
    expect(fromDraft({ ...loaded, url: " http://speech:8000 ", timeout_seconds: " 45 " })).toEqual({
      enabled: true,
      url: "http://speech:8000",
      token: null,
      model: "/models/parakeet",
      timeout_seconds: 45,
      max_seconds: 120,
    });
    expect(fromDraft({ ...loaded, max_seconds: "1.5" }).max_seconds).toBe("1.5"); // the server refuses it, said
    expect(toDraft(data({ revision: null, doc: null }))).toEqual({
      enabled: false,
      url: "",
      token: "",
      model: "",
      timeout_seconds: "",
      max_seconds: "",
    });
  });

  it('none saved: the draft holds none (""), so a new URL needs no token typed and the saved server is still its own', () => {
    const none = data({ doc: { ...data().doc!, token_set: false, token_hint: null } });
    const d = toDraft(none);
    expect(d.token).toBe("");
    expect(connectRefusal({ ...d, url: "http://other:9000" }, d)).toBeNull();
    expect(modelsFor(d, d, none, null)).toBe(none);
    expect(fromDraft(d).token).toBe("");
  });

  it("adopts the first read and a newer one while unedited — never the read it already holds (no reset loop)", () => {
    const first = data();
    expect(adopts(first, null, null)).toBe(true);
    const draft = toDraft(first);
    expect(adopts(first, draft, first)).toBe(false); // adopted: the effect stops here, a keystroke is never overwritten
    expect(adopts(first, { ...draft }, first)).toBe(false);
    const newer = data({ revision: { id: 4, author: "op", at: 2 } });
    expect(adopts(newer, draft, first)).toBe(true);
    expect(adopts(newer, { ...draft, url: "http://h" }, first)).toBe(false); // edited: kept, the page offers Load
  });

  it("names the changed keys (a typed token, even empty, is a change) and each field's refusal", () => {
    expect(changedKeys({ ...loaded, enabled: false, max_seconds: "60" }, loaded)).toEqual(["enabled", "max_seconds"]);
    expect(changedKeys({ ...loaded, token: "" }, loaded)).toEqual(["token"]);
    expect(fieldRefusal("0", [1, 300])).toBe("1–300 s");
    expect(fieldRefusal("x", [1, 300])).toBe("whole seconds, 1–300");
    expect(fieldRefusal("300", [1, 300])).toBeNull();
  });

  it("shows the saved server's models, a Connect answer only for exactly the form's server", () => {
    expect(modelsFor(loaded, loaded, data(), null)).toEqual(data());
    expect(modelsFor(moved, loaded, data(), null)).toEqual({
      models: null,
      models_error: "press Connect to read its models",
      hint: true,
    });
    const probe = { url: "http://other:9000", token: "t", models: ["x"], models_error: null };
    expect(modelsFor({ ...moved, token: "t" }, loaded, data(), probe).models).toEqual(["x"]);
    expect(modelsFor({ ...moved, token: "u" }, loaded, data(), probe).models).toBeNull(); // another token: not read
    expect(modelsFor({ ...loaded, url: "" }, loaded, data(), null).models_error).toBe("type the server's URL");
  });

  it("Connect: needs a URL, and a new server's token typed — never the saved one for a new URL", () => {
    expect(connectRefusal(loaded, loaded)).toBeNull();
    expect(connectRefusal(moved, loaded)).toBe("Token: type the new server's token (or No token)");
    expect(connectRefusal({ ...moved, token: "" }, loaded)).toBeNull();
    expect(connectRefusal({ ...loaded, url: " " }, loaded)).toBe("type the server's URL");
    expect(connectRefusal({ ...loaded, url: "speech:8000" }, loaded)).toBe("URL: http(s)://host[:port][/path]");
  });

  it("Save: off with its reason, on only for a served model of the form's server within the limits", () => {
    const list = data();
    expect(saveRefusal(loaded, loaded, data(), list)).toBe("no changes");
    expect(saveRefusal({ ...loaded, max_seconds: "60" }, loaded, data(), list, 4)).toBe("rev 4 saved since: reload");
    expect(saveRefusal({ ...loaded, max_seconds: "60" }, loaded, data(), list)).toBeNull();
    expect(saveRefusal({ ...loaded, max_seconds: "20" }, loaded, data(), list)).toBe("Longest recording: 30–600 s");
    expect(saveRefusal({ ...loaded, model: "gone" }, loaded, data(), list)).toBe("gone is not served");
    expect(saveRefusal(moved, loaded, data(), modelsFor(moved, loaded, data(), null))).toBe(
      "Token: type the new server's token (or No token)",
    );
    const fresh = { ...moved, token: "" };
    expect(saveRefusal(fresh, loaded, data(), modelsFor(fresh, loaded, data(), null))).toBe(
      "models not read: press Connect to read its models",
    );
    const down = { models: null, models_error: "speech server timed out after 10 s" };
    expect(saveRefusal({ ...loaded, max_seconds: "60" }, loaded, data(), down)).toBe(
      "models not read: speech server timed out after 10 s",
    );
    // off: no server read, the kept values still checked
    expect(saveRefusal({ ...loaded, enabled: false }, loaded, data(), down)).toBeNull();
    expect(saveRefusal({ ...loaded, enabled: false, url: "", token: "" }, loaded, data(), down)).toBeNull();
    expect(saveRefusal({ ...loaded, enabled: false, url: "", token: "t" }, loaded, data(), down)).toBe(
      "token is set but url is empty",
    );
    expect(saveRefusal({ ...moved, enabled: false }, loaded, data(), down)).toBe(
      "Token: type the new server's token (or No token)",
    );
    expect(saveRefusal({ ...loaded, enabled: false, model: "" }, loaded, data(), down)).toBe("pick a model");
    expect(saveRefusal({ ...loaded, enabled: false, timeout_seconds: "0" }, loaded, data(), down)).toBe(
      "Request timeout: 1–300 s",
    );
  });

  it("Test: needs the server and a served model, on or off", () => {
    expect(checkRefusal({ ...loaded, enabled: false }, loaded, data(), LIMITS)).toBeNull();
    expect(checkRefusal({ ...loaded, model: "" }, loaded, data(), LIMITS)).toBe("pick a model");
    expect(checkRefusal({ ...loaded, model: "gone" }, loaded, data(), LIMITS)).toBe("gone is not served");
    expect(checkRefusal(moved, loaded, data(), LIMITS)).toBe("Token: type the new server's token (or No token)");
    expect(checkRefusal({ ...loaded, timeout_seconds: "0" }, loaded, data(), LIMITS)).toBe("Request timeout: 1–300 s");
  });

  it("says what the token field holds, never the token", () => {
    expect(tokenLine(loaded, data().doc)).toBe("saved (…abcd) · leave empty to keep it");
    expect(tokenLine(loaded, { ...data().doc!, token_hint: null })).toBe("saved (hidden) · leave empty to keep it");
    expect(tokenLine(loaded, { ...data().doc!, token_set: false, token_hint: null })).toBe("none saved");
    expect(tokenLine({ ...loaded, token: "" }, data().doc)).toBe("none · no Authorization header is sent");
    expect(tokenLine({ ...loaded, token: "secret" }, data().doc)).toBe("new token · 6 characters");
    expect(tokenPlaceholder(loaded, data().doc)).toBe("•••••••• saved");
    expect(tokenPlaceholder(loaded, { ...data().doc!, token_set: false })).toBe("none · type one to set");
    expect(tokenPlaceholder({ ...loaded, token: "" }, data().doc)).toBe("optional");
  });

  it("says the speech server's state in one line: listed (plural right), the server's error, or what to do", () => {
    expect(modelsLine(data(), false)).toEqual({ tone: "ok", text: "connected · 2 models listed" });
    expect(modelsLine({ models: ["m"], models_error: null }, false).text).toBe("connected · 1 model listed");
    expect(modelsLine(data(), true)).toEqual({ tone: "muted", text: "connecting…" });
    expect(modelsLine({ models: null, models_error: "speech server unreachable: x" }, false)).toEqual({
      tone: "bad",
      text: "speech server unreachable: x",
    });
    expect(modelsLine(modelsFor(moved, loaded, data(), null), false, "Token: x")).toEqual({
      tone: "muted",
      text: "Token: x",
    });
    expect(modelsLine({ models: null, models_error: "down" }, false, "Token: x").text).toBe("down");
    expect(modelsLine(modelsFor(moved, loaded, data(), null), false)).toEqual({
      tone: "muted",
      text: "press Connect to read its models",
    });
  });

  it("offers the served models, the draft's one first when the server does not list it", () => {
    expect(modelOptions(loaded, data())).toEqual([
      { id: "llm", served: true },
      { id: "/models/parakeet", served: true },
    ]);
    expect(modelOptions({ ...loaded, model: "old" }, { models: null, models_error: "x" })).toEqual([
      { id: "old", served: null },
    ]);
    expect(modelOptions({ ...loaded, model: "gone" }, data())[0]).toEqual({ id: "gone", served: false });
  });

  it("says a Test answer in one line", () => {
    expect(checkLine({ ms: 250, text: "", words: [] })).toBe("250 ms · no speech (silence sent)");
    expect(checkLine({ ms: 9, text: " hi", words: [{ word: "hi", start: 0, end: 1 }] })).toBe("9 ms · 1 word · “hi”");
  });
});
