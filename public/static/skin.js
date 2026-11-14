/* busyyaks skins (card #361): every skin is a file of the repo, skins/<key>.yml — light (the default), dark and any added
   next to them — listed by the page in <meta name="skins"> ({key, label, base}, before this script), their colour tokens
   in the page's <style id="skins-css">: a base skin's on :root[data-skin="<base>"], any other's on
   :root[data-skin-key="<key>"] (Busyyaks::Skins). A skin is shown as data-skin=<its base> + data-skin-key=<key>, so every
   rule for its base applies too. Choices: light · dark · auto (the system's light or dark, followed live) · the other
   skins. This browser's choice is localStorage `busyyaks.skin` = one of them; nothing stored = light, the default.
   Loaded render-blocking in <head> of every page so the skin is on <html> before first paint. A stored value that is no
   choice of this page (a skin file removed since) is reported in the console and removed (light) — the page never
   guesses a skin from it. The header control (frontend Skin.tsx) calls window.busyyaksSkin.set(choice) and listens for
   the `busyyaks:skin` event. */
(function () {
  "use strict";
  var KEY = "busyyaks.skin";
  var BASES = ["light", "dark"];
  var AUTO = "auto";
  var DEFAULT = "light"; // what nothing stored means; choosing it again clears the key
  var mq = window.matchMedia("(prefers-color-scheme: dark)");

  function find(key) {
    for (var i = 0; i < skins.length; i++) if (skins[i].key === key) return skins[i];
    return null;
  }

  // the page's skins: a page without the list, or a malformed one, is broken — thrown, never read as "no skins"
  var tag = document.querySelector('meta[name="skins"]');
  if (!tag) throw new Error('busyyaks: the page has no <meta name="skins"> (app/templates/*.html.erb)');
  var skins = JSON.parse(tag.getAttribute("content"));
  if (!Array.isArray(skins)) throw new Error("busyyaks: skins must be a list of {key, label, base}");
  skins.forEach(function (s) {
    if (!s || typeof s.key !== "string" || typeof s.label !== "string" || BASES.indexOf(s.base) < 0)
      throw new Error("busyyaks: bad skin " + JSON.stringify(s));
    if (s.key === AUTO) throw new Error("busyyaks: no skin may be called auto");
  });
  BASES.forEach(function (b) {
    if (!find(b)) throw new Error("busyyaks: the page lists no " + b + " skin (skins/" + b + ".yml)");
  });

  // the switch's order: light (the default), dark, auto, then the other skins as the page lists them
  var CHOICES = BASES.concat(
    [AUTO],
    skins
      .filter(function (s) {
        return BASES.indexOf(s.key) < 0;
      })
      .map(function (s) {
        return s.key;
      }),
  );

  function stored() {
    var v = null;
    try {
      v = localStorage.getItem(KEY);
    } catch (e) {
      return DEFAULT;
    }
    if (v == null) return DEFAULT;
    if (CHOICES.indexOf(v) < 0) {
      console.error(
        "busyyaks: stored skin " +
          JSON.stringify(v) +
          " is not one of " +
          CHOICES.join(", ") +
          " — removed, the " +
          DEFAULT +
          " skin",
      );
      try {
        localStorage.removeItem(KEY);
      } catch (e) {
        /* this browser keeps nothing */
      }
      return DEFAULT;
    }
    return v;
  }

  var choice = stored();

  function apply() {
    var shown = find(choice === AUTO ? (mq.matches ? "dark" : "light") : choice);
    var root = document.documentElement;
    root.setAttribute("data-skin", shown.base);
    root.setAttribute("data-skin-key", shown.key);
    root.setAttribute("data-skin-choice", choice);
    root.style.colorScheme = shown.base;
    document.dispatchEvent(new CustomEvent("busyyaks:skin", { detail: { choice: choice, skin: shown.key } }));
  }

  mq.addEventListener("change", function () {
    if (choice === AUTO) apply();
  });

  window.busyyaksSkin = {
    choices: CHOICES.slice(),
    label: function (c) {
      return c === AUTO ? "Auto" : find(c).label;
    },
    get: function () {
      return choice;
    },
    set: function (next) {
      if (CHOICES.indexOf(next) < 0) throw new Error("busyyaks: unknown skin " + JSON.stringify(next));
      choice = next;
      try {
        if (next === DEFAULT) localStorage.removeItem(KEY);
        else localStorage.setItem(KEY, next);
      } catch (e) {
        console.error("busyyaks: this browser keeps no skin choice — " + next + " for this visit only");
      }
      apply();
    },
  };

  apply();
})();
