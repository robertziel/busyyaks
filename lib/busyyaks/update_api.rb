# frozen_string_literal: true

require_relative "launcher_client"
require_relative "setup_api"

module Busyyaks
  # Settings → Updates (card 536): this checkout vs config/busyyaks.yml updates, and the update itself — both on the
  # host (bin/launcher op `update`, which starts `bin/yaks update`), relayed here as [status, body]. The launcher
  # checks everything again; nothing is decided in the container.
  #   status            → 200 {settings, check, checking, check_error, running, last}
  #   check             → 200 {check} (a git fetch now) · 422 its refusal
  #   apply(mode:, sha:) → 200 {started} · 409 one runs · 422 not allowed (dirty, not a fast-forward, moved, …)
  module UpdateAPI
    module_function

    def status(launcher: LauncherClient) = SetupAPI.relay { launcher.update(step: "status") }
    def check(launcher: LauncherClient) = SetupAPI.relay { launcher.update(step: "check") }

    def apply(mode:, sha:, launcher: LauncherClient)
      return [400, { error: "mode must be tags or branch" }] unless %w[tags branch].include?(mode)
      return [400, { error: "sha must be the 40-hex commit shown" }] unless sha.to_s.match?(/\A\h{40}\z/)

      SetupAPI.relay { launcher.update(step: "apply", mode: mode, sha: sha) }
    end
  end
end
