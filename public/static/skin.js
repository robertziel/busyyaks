/* busyyaks skins: two skins, Light and Dark, tokens in app.css under :root (light) and :root[data-skin="dark"].
   This browser's choice is localStorage `busyyaks.skin` = "light" | "dark" | "auto"; nothing stored = light, the
   default (auto = the system appearance, followed live). Loaded render-blocking in <head> of every page so the skin is
   on <html> before first paint. A stored value that is none of the three is reported in the console and removed
   (light) — the page never guesses a skin from it. The header control (frontend Skin.tsx) calls
   window.busyyaksSkin.set(choice) and listens for the `busyyaks:skin` event. */
(function () {
  "use strict";
  var KEY = "busyyaks.skin";
  var CHOICES = ["light", "dark", "auto"]; // the header menu's order: the default first
  var DEFAULT = "light"; // what nothing stored means; choosing it again clears the key
  var mq = window.matchMedia("(prefers-color-scheme: dark)");

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
    var skin = choice === "auto" ? (mq.matches ? "dark" : "light") : choice;
    var root = document.documentElement;
    root.setAttribute("data-skin", skin);
    root.setAttribute("data-skin-choice", choice);
    root.style.colorScheme = skin;
    document.dispatchEvent(new CustomEvent("busyyaks:skin", { detail: { choice: choice, skin: skin } }));
  }

  mq.addEventListener("change", function () {
    if (choice === "auto") apply();
  });

  window.busyyaksSkin = {
    choices: CHOICES.slice(),
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
