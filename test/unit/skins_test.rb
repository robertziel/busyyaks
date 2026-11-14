# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "busyyaks/skins"

# skins are files (card #361): skins/<key>.yml — light and dark, the bases (every token), and any added next to them —
# checked at boot and written into every page's <head> as a <style> and a <meta> skin.js reads.
class SkinsTest < Minitest::Test
  S = Busyyaks::Skins
  ROOT = File.expand_path("../..", __dir__)
  DUSK = { "label" => "Dusk", "base" => "dark", "tokens" => { "--bg" => "#101820", "--accent" => "#E0A" } }.freeze

  # a skins dir holding the repo's two base files and `extra` ({name => doc or raw String})
  def with_dir(extra = {})
    Dir.mktmpdir do |dir|
      %w[light dark].each { FileUtils.cp(File.join(S::DIR, "#{_1}.yml"), dir) }
      extra.each { |name, doc| File.write(File.join(dir, name), doc.is_a?(String) ? doc : YAML.dump(doc)) }
      yield dir
    end
  end

  def refused(extra)
    with_dir(extra) { |d| assert_raises(S::Invalid) { S.load(d) }.message }
  end

  def test_the_repo_ships_light_and_dark_and_the_page_head_carries_them
    keys = S.all.map { _1["key"] }
    assert_equal %w[light dark], keys.first(2)
    head = Busyyaks::Action::Helpers.skins_head
    assert_match(/\A\[\{"key":"light","label":"Light","base":"light"\},\{"key":"dark","label":"Dark","base":"dark"\}/,
                 head[:skins_meta])
    assert_match(/^:root\[data-skin="light"\] \{ --bg: #f4f3ee;/, head[:skins_css])
    assert_match(/^:root\[data-skin="dark"\] \{ --bg: #0f1115;/, head[:skins_css])
    assert_includes head[:skins_css], "--accent: #a8380a; --accent-rgb: 168, 56, 10;"
  end

  def test_an_added_skin_comes_after_the_bases_and_writes_only_its_tokens
    with_dir("dusk.yml" => DUSK, "aqua.yml" => DUSK.merge("label" => "Aqua", "base" => "light")) do |d|
      skins = S.load(d)
      assert_equal %w[light dark aqua dusk], skins.map { _1["key"] }
      assert_equal({ "--bg" => "#101820", "--accent" => "#e0a" }, skins.last["tokens"])
      assert_equal ':root[data-skin-key="dusk"] { --bg: #101820; --accent: #e0a; --accent-rgb: 238, 0, 170; }',
                   S.css(skins).lines.last
      assert_equal '{"key":"dusk","label":"Dusk","base":"dark"}', S.meta(skins)[/\{"key":"dusk"[^}]*\}/]
    end
  end

  def test_the_rgb_triple_of_a_long_hex_drops_its_alpha
    assert_equal "168, 56, 10", S.rgb("#a8380aff")
    assert_equal "255, 0, 170", S.rgb("#f0a")
  end

  def test_refusals_name_the_file_and_the_key
    assert_match(%r{skins/Dusk\.yml: the file name must match}, refused("Dusk.yml" => DUSK))
    assert_match(/auto is reserved/, refused("auto.yml" => DUSK))
    assert_match(/dusk\.yaml not a skin file/, refused("dusk.yaml" => DUSK))
    assert_match(/not YAML/, refused("dusk.yml" => "label: [unclosed"))
    assert_match(/must be a mapping \{label/, refused("dusk.yml" => "- a list"))
    assert_match(/label must be 1-40/, refused("dusk.yml" => DUSK.merge("label" => " ")))
    assert_match(/label must be 1-40/, refused("dusk.yml" => DUSK.merge("label" => "x" * 41)))
    assert_match(/base "sepia" is not one of light, dark/, refused("dusk.yml" => DUSK.merge("base" => "sepia")))
    assert_match(/exactly label, base, tokens/, refused("dusk.yml" => DUSK.merge("extra" => 1)))
    assert_match(/--sans not a skin token/, refused("dusk.yml" => DUSK.merge("tokens" => { "--sans" => "#fff" })))
    assert_match(/--accent must be a hex colour/,
                 refused("dusk.yml" => DUSK.merge("tokens" => { "--accent" => "rgb(1, 2, 3)" })))
    # a value is never free text: it would be written into a <style>
    ["red", "#ff", "#12345", "#fff;}</style><script>", "rgb(1,2,3)", "rgba(1, 2, 3, 0.5); x", "var(--ink)"].each do |v|
      assert_match(/--bg: .* is not a colour/, refused("dusk.yml" => DUSK.merge("tokens" => { "--bg" => v })), v)
    end
  end

  def test_the_bases_are_required_on_their_own_base_with_every_token
    Dir.mktmpdir do |d|
      FileUtils.cp(File.join(S::DIR, "light.yml"), d)
      assert_match(%r{skins/dark\.yml is missing}, assert_raises(S::Invalid) { S.load(d) }.message)
      File.write(File.join(d, "dark.yml"), YAML.dump(DUSK))
      assert_match(/a base skin sets every token \(missing: --panel/, assert_raises(S::Invalid) { S.load(d) }.message)
      File.write(File.join(d, "dark.yml"), YAML.dump(DUSK.merge("base" => "light")))
      assert_match(%r{skins/dark\.yml: base must be dark}, assert_raises(S::Invalid) { S.load(d) }.message)
    end
    assert_match(/directory is missing/, assert_raises(S::Invalid) { S.load("/nonexistent-skins") }.message)
  end

  # the token list is every colour token, and app.css keeps none of them (one place per value: the skin files)
  def test_the_colour_tokens_live_only_in_the_skin_files
    css = File.read(File.join(ROOT, "public/static/app.css"))
    (S::TOKENS + S::RGB_PAIRS.map { "#{_1}-rgb" }).each { |t| refute_match(/^\s*#{t}:/, css, t) }
    %w[light dark].each { |b| assert_equal S::TOKENS, S.all.find { _1["key"] == b }["tokens"].keys }
  end
end
