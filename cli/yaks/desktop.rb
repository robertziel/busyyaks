# frozen_string_literal: true

require "fileutils"
require "optparse"
require_relative "../../lib/busyyaks/dashboard_url"

module Busyyaks
  module CLI
    # `yaks desktop install --browser NAME` / `yaks desktop uninstall`: the dashboard as a desktop app on the
    # machine the operator works at — an app-menu entry that opens DashboardUrl.origin in a window of its own (the
    # browser's `--app=<url>`: no tabs, no address bar; the window takes the web app manifest's name and icon).
    #
    # Unlike the rest of `yaks` (Linux only: Host.stack!), this runs on every Unix with a desktop, one family each:
    #   XDG (Linux, FreeBSD, OpenBSD, NetBSD, DragonFly) → ~/.local/share/applications/busyyaks.desktop (Desktop Entry
    #     spec), Exec = the browser found on PATH, as its absolute path (a desktop session's PATH may differ).
    #   macOS (Darwin) → ~/Applications/busyyaks.app, a bundle whose executable starts the browser app's own binary
    #     (/Applications or ~/Applications) and whose icon is written from icon-512.png at install.
    # Either way the window is the browser's: the Dock / taskbar groups it under the browser's icon. busyyaks's own icon
    # is the launcher's (menu, Launchpad, Spotlight); its own Dock icon and badge come with the browser's install (README).
    # Any other OS → refused, naming the supported ones. The browser is the operator's choice, always named (no default,
    # no detection): a Chromium-family browser (only those take `--app`).
    #
    # Each entry records this checkout (XDG: X-Busyyaks-Checkout=<home>; macOS: Info.plist BusyyaksCheckout): install
    # rewrites only an entry of this checkout, uninstall removes only one; anything else at that path → refused,
    # untouched. Values are escaped for their format; a control character in a value → refused.
    module Desktop
      XDG_OSES = %w[Linux FreeBSD OpenBSD NetBSD DragonFly].freeze
      MAC_OS = "Darwin"
      # XDG: the browser's command on PATH
      CHROMIUM = %w[google-chrome google-chrome-stable chromium chromium-browser microsoft-edge microsoft-edge-stable
                    brave-browser vivaldi].freeze
      # macOS: the same names → the browser's app bundle (its binary = Contents/MacOS/<the bundle's name>)
      MAC_APPS = { "google-chrome" => "Google Chrome", "chromium" => "Chromium", "microsoft-edge" => "Microsoft Edge",
                   "brave-browser" => "Brave Browser", "vivaldi" => "Vivaldi", }.freeze
      ICON = "public/static/icon-512.png"
      MARK = "X-Busyyaks-Checkout"
      PLIST_MARK = "BusyyaksCheckout"
      BUNDLE_ID = "local.busyyaks.dashboard"
      # Exec's reserved characters (Desktop Entry spec, "The Exec key"): an argument holding one is quoted
      RESERVED = /[\s"'\\><~|&;$*?#()`]/

      module_function

      def run(ctx, args)
        family = family!(ctx.os)
        case (sub = args.shift)
        when "install" then install(ctx, args, family)
        when "uninstall" then uninstall(ctx, args, family)
        else raise Usage, "desktop needs install or uninstall#{" (got #{sub.inspect})" if sub}"
        end
      end

      def family!(os)
        return :xdg if XDG_OSES.include?(os)
        return :mac if os == MAC_OS

        raise Refused, "yaks desktop runs on #{(XDG_OSES + ['Darwin (macOS)']).join(', ')}; this is #{os}"
      end

      def install(ctx, args, family)
        browser = nil
        CLI.parse!(OptionParser.new { |o| o.on("--browser NAME") { browser = _1 } }, args)
        CLI.no_more!(args)
        names = family == :mac ? MAC_APPS.keys : CHROMIUM
        raise Usage, "desktop install needs --browser NAME (one of: #{names.join(', ')})" unless browser
        unless names.include?(browser)
          raise Refused, "--browser #{browser}: not a Chromium-family browser here (#{names.join(', ')}); only those " \
                         "open a window of its own with --app"
        end
        exe = family == :mac ? mac_browser!(ctx, browser) : ctx.runner.which(browser)
        raise Refused, "#{browser} not on PATH" unless exe

        icon = File.join(ctx.home, ICON)
        raise Refused, "#{ICON} missing in #{ctx.home}" unless File.file?(icon)

        origin = url(ctx)
        path = family == :mac ? install_mac(ctx, exe, origin, icon) : install_xdg(ctx, exe, origin, icon)
        ctx.out.puts "installed #{path}: busyyaks in the applications (#{browser} --app=#{origin})"
        0
      end

      def uninstall(ctx, args, family)
        CLI.no_more!(args)
        path = family == :mac ? bundle_path(ctx) : entry_path(ctx)
        raise Refused, "not installed: no #{path}" unless present?(path)

        mine!(ctx, path, family)
        FileUtils.rm_r(path)
        ctx.out.puts "removed #{path}"
        0
      end

      def home!(ctx)
        home = ctx.env["HOME"].to_s
        raise Refused, "HOME is not set" if home.empty?

        home
      end

      def entry_path(ctx) = File.join(home!(ctx), ".local/share/applications/busyyaks.desktop")
      def bundle_path(ctx) = File.join(home!(ctx), "Applications/busyyaks.app")

      # something at path (lstat: a dangling link counts); a symlink there → refused: install would write, and
      # uninstall delete, through it to wherever it points
      def present?(path)
        File.lstat(path)
        raise Refused, "#{path} is a symlink: left as is (remove it, or point it nowhere, by hand)" if File.symlink?(path)

        true
      rescue Errno::ENOENT
        false
      end

      # an entry of another checkout, or not ours at all → refused naming it
      def mine!(ctx, path, family)
        owner = family == :mac ? plist_owner(path) : xdg_owner(path)
        return if owner == ctx.home

        key = family == :mac ? PLIST_MARK : MARK
        raise Refused, "#{path} is not this checkout's entry (#{owner ? "#{key}=#{owner}" : "no #{key}"}): left as is"
      end

      def url(ctx)
        DashboardUrl.origin(ctx.dotenv)
      rescue DashboardUrl::Invalid => e
        raise Refused, ".env: #{e.message}"
      end

      def no_control!(value)
        return value unless value.match?(/[[:cntrl:]]/)

        raise Refused, "#{value.inspect}: a control character cannot go into a desktop entry"
      end

      # --- XDG: a Desktop Entry ---------------------------------------------------------------------------------------

      def install_xdg(ctx, exe, origin, icon)
        path = entry_path(ctx)
        mine!(ctx, path, :xdg) if present?(path)
        FileUtils.mkdir_p(File.dirname(path))
        tmp = "#{path}.new-#{Process.pid}"
        begin
          File.write(tmp, entry(exe, origin, icon, ctx.home))
          File.rename(tmp, path) # atomic: the old entry stays whole until the new one replaces it
        ensure
          FileUtils.rm_f(tmp)
        end
        path
      end

      def xdg_owner(path)
        File.directory?(path) ? nil : File.read(path)[/^#{MARK}=(.*)$/, 1]&.then { unescape(_1) }
      end

      def entry(exe, url, icon, home)
        <<~DESKTOP
          [Desktop Entry]
          Type=Application
          Name=busyyaks
          Comment=busyyaks dashboard
          Exec=#{string([exe, "--app=#{url}"].map { exec_arg(_1) }.join(' ').gsub('%', '%%'))}
          Icon=#{string(icon)}
          Terminal=false
          Categories=Development;
          #{MARK}=#{string(home)}
        DESKTOP
      end

      # one Exec argument: quoted when it holds a reserved character; inside the quotes ", `, $ and \ get a backslash
      def exec_arg(arg)
        return arg unless arg.match?(RESERVED)

        "\"#{arg.gsub(/["`$\\]/) { "\\#{_1}" }}\""
      end

      # a string value: \ → \\ (the spec's escapes)
      def string(value) = no_control!(value).gsub("\\", "\\\\\\\\")

      def unescape(value) = value.gsub("\\\\", "\\")

      # --- macOS: an app bundle ---------------------------------------------------------------------------------------

      def install_mac(ctx, exe, origin, icon)
        path = bundle_path(ctx)
        old = present?(path)
        mine!(ctx, path, :mac) if old
        # built beside it, then swapped in: a failure part way leaves the old bundle as it was
        tmp = File.join(File.dirname(path), ".busyyaks.app.new-#{Process.pid}")
        FileUtils.rm_rf(tmp)
        build_bundle(tmp, ctx.home, exe, origin, icon)
        swap!(tmp, path, old)
        path
      rescue StandardError
        FileUtils.rm_rf(tmp) if tmp
        raise
      end

      def build_bundle(dir, home, exe, origin, icon)
        FileUtils.mkdir_p([File.join(dir, "Contents/MacOS"), File.join(dir, "Contents/Resources")])
        File.write(File.join(dir, "Contents/Info.plist"), info_plist(home))
        File.binwrite(File.join(dir, "Contents/Resources/busyyaks.icns"), icns(File.binread(icon)))
        launcher = File.join(dir, "Contents/MacOS/busyyaks")
        File.write(launcher, launcher_script(exe, origin))
        File.chmod(0o755, launcher)
      end

      # a directory cannot be renamed over a non-empty one: the old bundle steps aside first, and comes back if the new
      # one cannot take its place
      def swap!(tmp, path, old)
        return File.rename(tmp, path) unless old

        aside = "#{File.dirname(path)}/.busyyaks.app.old-#{Process.pid}"
        File.rename(path, aside)
        begin
          File.rename(tmp, path)
        rescue StandardError
          File.rename(aside, path)
          raise
        end
        FileUtils.rm_r(aside)
      end

      # the browser's binary inside its bundle, in /Applications or ~/Applications; neither → refused naming both
      def mac_browser!(ctx, browser)
        app = MAC_APPS.fetch(browser)
        dirs = ["/Applications", File.join(home!(ctx), "Applications")]
        exe = dirs.map { File.join(_1, "#{app}.app/Contents/MacOS/#{app}") }.find { File.executable?(_1) }
        exe || raise(Refused, "#{app}.app not found in #{dirs.join(' or ')}")
      end

      def plist_owner(path)
        plist = File.join(path, "Contents/Info.plist")
        return unless File.file?(plist)

        File.read(plist)[%r{<key>#{PLIST_MARK}</key>\s*<string>([^<]*)</string>}, 1]&.then { xml_unescape(_1) }
      end

      def info_plist(home)
        keys = { "CFBundleName" => "busyyaks", "CFBundleDisplayName" => "busyyaks", "CFBundleIdentifier" => BUNDLE_ID,
                 "CFBundleExecutable" => "busyyaks", "CFBundleIconFile" => "busyyaks.icns",
                 "CFBundlePackageType" => "APPL", "CFBundleInfoDictionaryVersion" => "6.0",
                 "CFBundleShortVersionString" => "1.0", PLIST_MARK => home, }
        body = keys.map { |k, v| "  <key>#{k}</key>\n  <string>#{xml(v)}</string>\n" }.join
        <<~PLIST
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0">
          <dict>
          #{body.chomp}
          </dict>
          </plist>
        PLIST
      end

      XML = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;", "'" => "&apos;" }.freeze
      def xml(value) = no_control!(value).gsub(/[&<>"']/, XML)
      def xml_unescape(value) = value.gsub(/&(?:amp|lt|gt|quot|apos);/) { XML.key(_1) }

      # the bundle's executable: hands the URL to the browser's own binary (a running browser takes it over)
      def launcher_script(exe, url) = "#!/bin/sh\nexec #{sh(exe)} #{sh("--app=#{url}")}\n"

      def sh(value) = "'#{no_control!(value).gsub("'", %q('\\\\''))}'"

      # an .icns holding the 512 px PNG as its ic09 entry (macOS reads PNG-coded entries)
      def icns(png)
        chunk = "ic09".b + [png.bytesize + 8].pack("N") + png.b
        "icns".b + [chunk.bytesize + 8].pack("N") + chunk
      end
    end
  end
end
