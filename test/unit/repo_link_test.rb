# frozen_string_literal: true

require "test_helper"
require "yaml"

# the bottom-left label linking to busyyaks's public repo (card #505): one link, opened in a new tab without an opener,
# muted text readable on the page background in both base skins, fixed bottom-left, hidden in print
class RepoLinkTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  CSS = File.read(File.join(ROOT, "public/static/app.css"))

  def test_the_label_links_to_the_public_repo_in_a_new_tab
    html = Busyyaks::RepoLink.html
    assert_equal "https://github.com/robertziel/busyyaks", Busyyaks::RepoLink::URL
    assert_includes html, %(class="repo-link")
    assert_includes html, %(href="#{Busyyaks::RepoLink::URL}")
    assert_includes html, %(target="_blank")
    assert_includes html, %(rel="noopener noreferrer")
    assert_includes html, %(<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true")
    assert_includes html, "<span>busyyaks</span>"
    assert_match(/aria-label="busyyaks on GitHub \(opens in a new tab\)"/, html)
  end

  def test_every_page_template_carries_it
    %w[app.html.erb layout.html.erb].each do |t|
      assert_includes File.read(File.join(ROOT, "app/templates", t)), "<%= h.repo_link %>", t
    end
  end

  def test_the_css_fixes_it_bottom_left_with_tokens_only
    rule = CSS[/^\.repo-link \{(.*?)^\}/m, 1]
    refute_nil rule
    assert_includes rule, "position: fixed;"
    assert_includes rule, "left: max(var(--repo-link-gutter), env(safe-area-inset-left));"
    assert_includes rule, "bottom: max(var(--repo-link-gutter), env(safe-area-inset-bottom));"
    assert_includes rule, "background: var(--mat-bar);"
    assert_includes rule, "backdrop-filter: var(--mat-blur);"
    assert_includes rule, "color: var(--ink-dim);"
    # under the waiting widget (frontend/src/styles/waiting.css z-index 15) and everything above it
    waiting = File.read(File.join(ROOT, "frontend/src/styles/waiting.css"))[/\.waiting-widget \{.*?z-index: (\d+);/m, 1]
    assert_operator rule[/z-index: (\d+);/, 1].to_i, :<, waiting.to_i
    refute_match(/#\h{3,8}\b/, rule)
    narrow = CSS[/@media \(max-width: 640px\) \{\s*\.repo-link \{.*?^\}/m] # the mark alone on a phone
    refute_nil narrow
    assert_includes narrow, "width: var(--repo-link-box);"
    assert_match(/\.repo-link span \{\s*display: none;/, narrow)
    assert_match(/\.repo-link:focus-visible \{\s*outline: 2px solid var\(--ink\);/, CSS)
    assert_match(/@media print \{\s*\.repo-link \{\s*display: none;/, CSS)
  end

  # below 760px the widest plate can reach the label: the widget rises by --repo-link-clear and the page clears it
  def test_the_waiting_widget_rises_above_the_label_below_760px
    waiting = File.read(File.join(ROOT, "frontend/src/styles/waiting.css"))
    assert_match(/:root \{\s*--ww-clear: 72px;\s*--ww-raise: 0px;\s*\}/, waiting)
    assert_match(/@media \(max-width: 760px\) \{\s*:root \{\s*--ww-raise: var\(--repo-link-clear\);\s*\}\s*\}/, waiting)
    widget = waiting[/^\.waiting-widget \{(.*?)^\}/m, 1]
    assert_includes widget, "bottom: calc(max(16px, env(safe-area-inset-bottom)) + var(--ww-raise));"
    wrap = waiting[/^\.wrap \{(.*?)^\}/m, 1]
    assert_includes wrap, "padding-bottom: calc(var(--ww-clear) + var(--ww-raise) + env(safe-area-inset-bottom));"
    assert_includes CSS, "  --repo-link-clear: calc(var(--repo-link-box) + var(--repo-link-gutter));"
    %w[--repo-link-gutter --repo-link-box].each { assert_match(/^  #{_1}: \d+px;$/, CSS) }
  end

  # the glass is half transparent: whatever is behind shows through. The worst case = every opaque colour token of the
  # skin directly behind it, no blur — the text keeps >= 4.5:1 over each
  def test_text_contrast_is_at_least_4_5_over_any_skin_colour_behind_the_glass
    %w[light dark].each do |skin|
      tokens = YAML.safe_load_file(File.join(ROOT, "skins/#{skin}.yml")).fetch("tokens")
      ink = rgba(tokens.fetch("--ink-dim"))
      glass = rgba(tokens.fetch("--mat-bar"))
      assert_operator glass[3], :<, 1, "#{skin} --mat-bar is see-through"
      behind = tokens.values.map { rgba(_1) }.select { _1 && _1[3] == 1 }
      assert_operator behind.size, :>, 10
      worst = behind.map { contrast(ink, over(glass, _1)) }.min
      assert_operator worst, :>=, 4.5, "#{skin} --ink-dim on --mat-bar over the worst colour: #{worst.round(2)}"
    end
  end

  private

  # [r, g, b, a] (0-255, alpha 0-1) of a hex or rgb()/rgba() token, nil for anything else
  def rgba(value)
    case value
    when /\A#(\h{6})\z/ then [*Regexp.last_match(1).scan(/../).map { _1.to_i(16) }, 1]
    when /\Argba?\(([^)]*)\)\z/
      r, g, b, a = Regexp.last_match(1).split(",").map(&:to_f)
      [r, g, b, a || 1]
    end
  end

  def over(top, bottom) = (0..2).map { (top[_1] * top[3]) + (bottom[_1] * (1 - top[3])) }

  def contrast(a, b)
    la, lb = [a, b].map { luminance(_1) }.sort.reverse
    (la + 0.05) / (lb + 0.05)
  end

  def luminance(rgb)
    r, g, b = rgb.first(3).map { _1 / 255.0 }
    lin = ->(c) { c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4 }
    (0.2126 * lin.(r)) + (0.7152 * lin.(g)) + (0.0722 * lin.(b))
  end
end
