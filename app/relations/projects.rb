# frozen_string_literal: true

module Busyyaks
  module Relations
    class Projects < Busyyaks::DB::Relation
      schema :projects, infer: true
    end
  end
end
