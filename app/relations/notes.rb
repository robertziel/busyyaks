# frozen_string_literal: true

module Busyyaks
  module Relations
    class Notes < Busyyaks::DB::Relation
      schema :notes, infer: true
    end
  end
end
