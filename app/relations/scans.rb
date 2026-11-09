# frozen_string_literal: true

module Busyyaks
  module Relations
    class Scans < Busyyaks::DB::Relation
      schema :scans, infer: true
    end
  end
end
