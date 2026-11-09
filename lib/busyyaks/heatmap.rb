# frozen_string_literal: true

require "date"
require "erb"

module Busyyaks
  # GitHub-style contribution graph as inline SVG: 53 weeks × 7 days ending today, five levels by quartile.
  module Heatmap
    CELL = 11
    GAP = 3
    module_function

    def svg(counts, today: Date.today)
      start = today - 364 - ((today.wday - 0) % 7) # a Sunday, so columns are whole weeks
      max = counts.values.max.to_i
      days = (start..today).to_a
      weeks = days.each_slice(7).to_a
      step = CELL + GAP
      label_w = 28
      month_h = 14
      cells = weeks.each_with_index.flat_map do |week, wi|
        week.map do |d|
          n = counts[d.iso8601].to_i
          lvl = n.zero? || max.zero? ? 0 : [((n.to_f / max) * 4).ceil, 4].min
          x = label_w + (wi * step)
          y = month_h + (d.wday * step)
          tip = "#{n} commit#{n == 1 ? '' : 's'} on #{d.strftime('%b %-d, %Y')}"
          %(<rect x="#{x}" y="#{y}" width="#{CELL}" height="#{CELL}" rx="2.5" class="l#{lvl}"><title>#{tip}</title></rect>)
        end
      end
      months = weeks.each_with_index.filter_map do |week, wi|
        first = week.find { |d| d.day == 1 } # the week a month starts in carries its label
        next unless first && wi < weeks.size - 2

        %(<text x="#{label_w + (wi * step)}" y="10">#{first.strftime('%b')}</text>)
      end
      dows = { 1 => "Mon", 3 => "Wed", 5 => "Fri" }.map { |i, t| %(<text x="0" y="#{month_h + (i * step) + 9}">#{t}</text>) }
      w = label_w + (weeks.size * step)
      h = month_h + (7 * step)
      %(<svg class="heatmap" viewBox="0 0 #{w} #{h}" width="#{w}" height="#{h}" ) \
        "role=\"img\" aria-label=\"Commits per day, last year\">#{months.join}#{dows.join}#{cells.join}</svg>"
    end

    def total(counts, today: Date.today)
      from = (today - 364).iso8601
      counts.sum { |d, n| d >= from ? n : 0 }
    end
  end
end
