# Writing an auth provider

Sign-in is a pluggable **auth provider**, chosen in `config/busyyaks.yml` `auth` (see the README's
[Sign-in](../README.md#sign-in)). A custom provider is `auth: { provider: <dir>, <settings…> }`: `<dir>` (relative to
the app root, e.g. `auth/myidp`) holds `provider.rb`, and the block's other keys are its settings.

A provider is a subclass of `Busyyaks::Auth::Provider` (`lib/busyyaks/auth.rb`) that ends with
`Busyyaks::Auth.provide(MyProvider)`. Its constructor gets `(settings, dir:)` and raises `Busyyaks::Auth::Invalid`
for anything it does not accept. It answers:

| Method | The core uses it for |
|---|---|
| `email(session)` | **every request**: the signed-in identity, or `nil` → pages redirect to `/login`, the API answers 401. Re-check your allowlist here: dropping someone ends their access at once |
| `login_html(helpers)` | the body of `GET /login` (inside the core's card and logo) for a signed-out browser. Once signed in, your script navigates to the card's `data-next` (`#auth-login`): the page that sent the browser to sign in, already validated as a path of this app (`/` when none was asked for) |
| `endpoint(verb, path, req, res)` | `GET`/`POST /auth/<path>`: your own endpoints (a token exchange, a script). Sign in with `Busyyaks::Auth.sign_in(res.session, email)`; return `true` when handled, `false` → 404. POSTs carry the page's CSRF token (`<meta name="csrf-token">`) as `X-CSRF-Token` |
| `scripts(page)` | script URLs (`defer`) for `:login` (the sign-in page) and `:app` (the SPA shell) |
| `csp` | extra CSP sources: `{ connect_src: [...], script_src: [...], img_src: [...] }` |
| `sign_out?` | whether the header's settings menu shows **Sign out** (`POST /logout` clears the session) |
| `qa_email` | the identity `bin/qa-cookie` mints a cookie for (read from your settings, never an argument) |

The smallest working example is the test suite's provider,
[`test/fixtures/auth_stub/provider.rb`](../test/fixtures/auth_stub/provider.rb). A provider directory may carry its
own tests in `<dir>/test/*_test.rb`; `rake test` runs them.
