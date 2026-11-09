# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "busyyaks/icons"

class IconsTest < Minitest::Test
  def put(root, rel, bytes = 100)
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, "x" * bytes)
  end

  def test_prefers_public_favicon_svg_over_docs_and_png
    Dir.mktmpdir do |r|
      put(r, "docs/favicon.svg")
      put(r, "worklog/previews/favicon-256.png", 9000)
      put(r, "public/favicon.ico")
      put(r, "public/favicon.svg")
      put(r, "public/apple-touch-icon.png", 4000)
      assert_equal "public/favicon.svg", Busyyaks::Icons.find(r)&.first
    end
  end

  def test_skips_dependency_trees_deep_files_empty_and_huge
    Dir.mktmpdir do |r|
      put(r, "node_modules/pkg/favicon.svg")
      put(r, "a/b/c/d/e/favicon.svg")
      put(r, "public/favicon.svg", 0)
      put(r, "static/favicon.png", Busyyaks::Icons::MAX_BYTES + 1)
      assert_nil Busyyaks::Icons.find(r)
      put(r, "app/assets/images/logo.png")
      assert_equal "app/assets/images/logo.png", Busyyaks::Icons.find(r)&.first
    end
  end

  def png(root, rel, w)
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, "\x89PNG\r\n\x1A\n".b + [13].pack("N") + "IHDR" + [w, w].pack("NN") + ("x" * 200))
  end

  def test_larger_png_beats_tiny_favicon_png
    Dir.mktmpdir do |r|
      png(r, "Public/favicon-16x16.png", 16)
      png(r, "Public/apple-touch-icon.png", 180)
      assert_equal "Public/apple-touch-icon.png", Busyyaks::Icons.find(r)&.first
    end
  end

  def test_type
    assert_equal "image/svg+xml", Busyyaks::Icons.type("x/favicon.SVG")
    assert_equal "image/x-icon", Busyyaks::Icons.type("favicon.ico")
  end
end
