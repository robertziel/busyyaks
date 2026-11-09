// ESLint for the SPA: typescript-eslint's type-checked recommended rules + the React hooks rules, over all of
// src/ INCLUDING src/vendor/ (the engine's copy passes the same config at its source; it is fixed there and re-vendored).
// Nothing of ours is ignored and no rule is switched off; a finding is fixed. The build writes to ../public/app.
//   docker run --rm -v "$PWD":/app -w /app node:22-bookworm-slim npm run lint      (CI: scripts/ci/test.sh frontend)
import js from "@eslint/js";
import tseslint from "typescript-eslint";
import reactHooks from "eslint-plugin-react-hooks";

export default tseslint.config(
  { ignores: ["node_modules/"] },
  // an eslint-disable comment has no effect and is itself reported: a finding is fixed, never silenced
  { linterOptions: { noInlineConfig: true, reportUnusedDisableDirectives: "error" } },
  js.configs.recommended,
  tseslint.configs.recommendedTypeChecked,
  {
    languageOptions: {
      parserOptions: { projectService: true, tsconfigRootDir: import.meta.dirname },
    },
  },
  {
    files: ["eslint.config.js"],
    extends: [tseslint.configs.disableTypeChecked],
  },
  {
    files: ["**/*.{ts,tsx}"],
    plugins: { "react-hooks": reactHooks },
    rules: reactHooks.configs.recommended.rules,
  },
);
