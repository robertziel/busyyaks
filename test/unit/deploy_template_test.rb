# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "../../lib/busyyaks/deploy_template"
require_relative "../../lib/busyyaks/env_file"

# deploy/ holds templates only; every host, port and certificate path comes from .env through
# bin/render-deploy, and a missing value is an error naming it — never a blank or a default.
class DeployTemplateTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  T = Busyyaks::DeployTemplate
  ENV_EXAMPLE = Busyyaks::EnvFile.read(File.join(ROOT, ".env.example"))

  def templates = Dir[File.join(ROOT, "deploy/*.template")]

  def test_deploy_has_templates_and_no_rendered_deployment_files
    names = Dir[File.join(ROOT, "deploy/*")].map { File.basename(_1) }
    assert_includes names, "nginx-busyyaks.conf.template"
    assert_includes names, "frpc-busyyaks.ini.template"
    refute names.any? { _1.match?(/\.(conf|ini)\z/) }, "a rendered proxy file is committed: #{names}"
    assert_includes File.read(File.join(ROOT, ".gitignore")), "/deploy/rendered/"
    # rendered files hold the deployment's hosts: never baked into an image by `COPY . .`
    assert_includes File.read(File.join(ROOT, ".dockerignore")).lines.map(&:strip), "deploy/rendered"
  end

  # every placeholder is a .env.example key (or derived); the proxy keys are empty there — localhost only is the default
  def test_every_placeholder_is_documented_in_env_example
    derived = T::DERIVED.keys
    templates.each do |t|
      names = File.read(t).scan(T::PLACEHOLDER).flatten.uniq
      refute_empty names, File.basename(t)
      assert_empty names - ENV_EXAMPLE.keys - derived, File.basename(t)
    end
    %w[PUBLIC_HOST TLS_CERT_PATH TLS_KEY_PATH PROXY_UPSTREAM FRPC_SUBDOMAIN].each do |k|
      assert_equal "", ENV_EXAMPLE.fetch(k), "#{k}: optional, empty by default"
    end
  end

  def test_localhost_default_env_refuses_to_render
    err = assert_raises(T::MissingValues) do
      T.render(File.read(File.join(ROOT, "deploy/nginx-busyyaks.conf.template")), ENV_EXAMPLE)
    end
    assert_match(/PUBLIC_HOST/, err.message)
  end

  def test_render_fills_values_and_keeps_nginx_variables
    out = T.render(File.read(File.join(ROOT, "deploy/nginx-busyyaks.conf.template")),
                   ENV_EXAMPLE.merge("PUBLIC_HOST" => "dash.test", "PROXY_UPSTREAM" => "127.0.0.1:9999",
                                     "TLS_CERT_PATH" => "/c.pem", "TLS_KEY_PATH" => "/k.pem",
                                     "ATTACHMENT_MAX_BYTES" => "26214400"))
    assert_includes out, "server_name dash.test;"
    assert_includes out, "proxy_pass http://127.0.0.1:9999;"
    assert_includes out, "client_max_body_size 30m;"
    assert_includes out, "return 301 https://$host$request_uri;"
    # the TLS hop is told to the app in a header frps keeps (it rewrites X-Forwarded-Proto to http)
    assert_includes out, "proxy_set_header X-Forwarded-Ssl on;"
  end

  def test_missing_or_empty_value_is_an_error_naming_it
    err = assert_raises(T::MissingValues) { T.render("a {{PUBLIC_HOST}} {{TLS_KEY_PATH}}", { "TLS_KEY_PATH" => " " }) }
    assert_equal "missing in .env: PUBLIC_HOST, TLS_KEY_PATH", err.message
  end

  def test_upload_cap_is_derived_from_attachment_max_bytes
    assert_equal "30m", T.render("{{NGINX_MAX_BODY}}", "ATTACHMENT_MAX_BYTES" => "26214400")
    assert_equal "6m", T.render("{{NGINX_MAX_BODY}}", "ATTACHMENT_MAX_BYTES" => "1")
  end

  def test_bad_attachment_max_bytes_is_named
    [{}, { "ATTACHMENT_MAX_BYTES" => "25MB" }].each do |env|
      err = assert_raises(T::MissingValues) { T.render("{{NGINX_MAX_BODY}}", env) }
      assert_match(/ATTACHMENT_MAX_BYTES in .env must be a whole number/, err.message)
    end
  end

  def test_derived_value_set_in_env_is_refused
    err = assert_raises(T::MissingValues) do
      T.render("x", "ATTACHMENT_MAX_BYTES" => "1", "NGINX_MAX_BODY" => "99m")
    end
    assert_match(/NGINX_MAX_BODY must not be set in .env/, err.message)
  end

  def test_values_are_checked_for_their_shape_before_rendering
    { "PUBLIC_HOST" => "a; return 200", "FRPC_SUBDOMAIN" => "a.b", "PROXY_UPSTREAM" => "127.0.0.1",
      "WEB_HOST_PORT" => "80x", "TLS_CERT_PATH" => "/etc/a b.pem", "TLS_KEY_PATH" => "key.pem", }
      .to_a.concat([%w[WEB_HOST_PORT 0], %w[WEB_HOST_PORT 99999], ["PROXY_UPSTREAM", "..:80"],
                    ["PROXY_UPSTREAM", "-:80"], ["PROXY_UPSTREAM", "127.0.0.1:70000"],]).each do |k, v|
      err = assert_raises(T::MissingValues, k) { T.render("{{#{k}}}", { k => v }) }
      assert_match(/#{k} in .env must be/, err.message)
    end
    %w[[::1]:8082 127.0.0.1:8082 frps.internal:65535].each do |v|
      assert_equal v, T.render("{{PROXY_UPSTREAM}}", { "PROXY_UPSTREAM" => v })
    end
  end

  # bin/render-deploy itself, on a temp copy of the files it reads (never the real .env)
  def render_deploy(env_text, *args, extra: {}, before: nil)
    Dir.mktmpdir do |dir|
      %w[bin/render-deploy lib/busyyaks/deploy_template.rb lib/busyyaks/env_file.rb].each do |f|
        FileUtils.mkdir_p(File.join(dir, File.dirname(f)))
        FileUtils.cp(File.join(ROOT, f), File.join(dir, f))
      end
      FileUtils.mkdir_p(File.join(dir, "deploy"))
      templates.each { FileUtils.cp(_1, File.join(dir, "deploy")) }
      File.write(File.join(dir, ".env"), env_text) if env_text
      extra.each { |name, body| File.write(File.join(dir, "deploy", name), body) }
      before&.call(dir)
      out, status = Open3.capture2e(RbConfig.ruby, File.join(dir, "bin/render-deploy"), *args)
      rendered = Dir[File.join(dir, "deploy/rendered/*")].select { File.file?(_1) }.to_h { [File.basename(_1), File.read(_1)] }
      [out, status.exitstatus, rendered]
    end
  end

  FULL_ENV = <<~ENV
    WEB_HOST_PORT=4100
    ATTACHMENT_MAX_BYTES=26214400
    # the public name
    PUBLIC_HOST=busyyaks.home.test
    TLS_CERT_PATH=/c.pem
    TLS_KEY_PATH=/k.pem
    PROXY_UPSTREAM=127.0.0.1:4200
    FRPC_SUBDOMAIN=busyyaks
  ENV

  def test_render_deploy_writes_every_template
    out, code, files = render_deploy(FULL_ENV)
    assert_equal 0, code, out
    assert_equal %w[frpc-busyyaks.ini nginx-busyyaks.conf], files.keys.sort
    assert_includes files["nginx-busyyaks.conf"], "server_name busyyaks.home.test;"
    assert_includes files["frpc-busyyaks.ini"], "local_port = 4100"
  end

  def test_render_deploy_one_template_by_name
    out, code, files = render_deploy(FULL_ENV.sub(/^FRPC_SUBDOMAIN=.*\n/, ""), "nginx")
    assert_equal 0, code, out
    assert_equal %w[nginx-busyyaks.conf], files.keys
  end

  def test_render_deploy_refuses_bad_arguments
    [["ngi"], [""], %w[frpc extra]].each do |args|
      out, code, files = render_deploy(FULL_ENV, *args)
      assert_equal 1, code, "#{args.inspect}: #{out}"
      assert_empty files
    end
  end

  def test_render_deploy_missing_value_writes_nothing
    out, code, files = render_deploy(FULL_ENV.sub(/^FRPC_SUBDOMAIN=.*\n/, ""))
    assert_equal 1, code
    assert_match(/frpc-busyyaks.ini.template: missing in .env: FRPC_SUBDOMAIN/, out)
    assert_empty files
  end

  # the one .env reader: a line it would not take literally stops the render, named, nothing written
  def test_render_deploy_refuses_a_malformed_env
    out, code, files = render_deploy(FULL_ENV.sub("PUBLIC_HOST=busyyaks.home.test", "PUBLIC_HOST=busyyaks.home.test # c"))
    assert_equal 1, code
    assert_match(/\.env:4: PUBLIC_HOST: an inline comment/, out)
    assert_empty files
  end

  def test_render_deploy_without_env
    out, code, = render_deploy(nil)
    assert_equal 1, code
    assert_match(/no .env at/, out)
  end

  def test_render_deploy_lists_stale_outputs_only
    stale = lambda do |dir|
      FileUtils.mkdir_p(File.join(dir, "deploy/rendered/sub"))
      File.write(File.join(dir, "deploy/rendered/frpc-busyyaks.ini"), "old")
      File.write(File.join(dir, "deploy/rendered/.hidden"), "x")
    end
    out, code, files = render_deploy(FULL_ENV, "nginx", before: stale)
    assert_equal 0, code, out
    assert_equal "old", files["frpc-busyyaks.ini"]
    assert_equal ["deploy/rendered/nginx-busyyaks.conf",
                  "deploy/rendered/frpc-busyyaks.ini (not rendered this run, left as it was)",], out.lines.map(&:chomp)
  end

  def test_render_deploy_refuses_two_templates_with_one_name
    out, code, files = render_deploy(FULL_ENV, extra: { "nginx-mcp.conf.template" => "x" })
    assert_equal 1, code
    assert_match(/share a name before "-": nginx-busyyaks.conf.template, nginx-mcp.conf.template/, out)
    assert_empty files
  end
end
