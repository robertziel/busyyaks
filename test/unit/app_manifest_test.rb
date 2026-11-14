# frozen_string_literal: true

require "test_helper"
require "yaml"
require "busyyaks/app_manifest"

# The SPA installable as a desktop app: the web app manifest's content and the PNG icons it names.
class AppManifestTest < Minitest::Test
  M = Busyyaks::AppManifest
  ROOT = File.expand_path("../..", __dir__)

  # a PNG's width × height, read from its IHDR chunk
  def png_size(path)
    bytes = File.binread(path, 24)
    assert_equal "\x89PNG\r\n\x1A\n".b, bytes[0, 8], "#{path}: not a PNG"
    bytes[16, 8].unpack("NN")
  end

  def test_manifest_is_installable_standalone_from_the_root
    m = M.build
    assert_equal "busyyaks", m[:name]
    assert_equal "standalone", m[:display]
    assert_equal "/", m[:start_url]
    assert_equal "/", m[:scope]
  end

  def test_colours_are_the_default_skins_background
    bg = YAML.safe_load_file(File.join(ROOT, "skins/light.yml")).fetch("tokens").fetch("--bg")
    assert_equal bg, M.build[:background_color]
    assert_equal bg, M.build[:theme_color]
  end

  # the install prompt needs a 192 and a 512 PNG: each named file exists at its stated size (scripts/icons/render-png)
  def test_every_png_icon_exists_at_its_size
    pngs = M.build[:icons].select { _1[:type] == "image/png" }
    assert_equal %w[192x192 512x512], pngs.map { _1[:sizes] }
    pngs.each do |icon|
      w, h = icon[:sizes].split("x").map(&:to_i)
      assert_equal [w, h], png_size(File.join(ROOT, "public", icon[:src])), icon[:src]
    end
  end

  def test_every_icon_is_a_static_file
    M.build[:icons].each { |i| assert File.file?(File.join(ROOT, "public", i[:src])), i[:src] }
  end
end
