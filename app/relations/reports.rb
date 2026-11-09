# frozen_string_literal: true

module Busyyaks
  module Relations
    class Reports < Busyyaks::DB::Relation
      schema :reports, infer: true
    end
  end
end
