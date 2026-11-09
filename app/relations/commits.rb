# frozen_string_literal: true

module Busyyaks
  module Relations
    class Commits < Busyyaks::DB::Relation
      schema :commits, infer: true
    end
  end
end
