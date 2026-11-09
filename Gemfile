# frozen_string_literal: true

source "https://rubygems.org"

gem "hanami", "~> 2.3"
gem "hanami-controller", "~> 2.3"
gem "hanami-db", "~> 2.3"
gem "hanami-router", "~> 2.3"
gem "hanami-view", "~> 2.3"

gem "dry-types", "~> 1.7"
gem "puma", ">= 7.1"
gem "rake"
gem "sqlite3", "~> 2.1"
gem "pg", "~> 1.6"            # database.adapter postgresql (lib/busyyaks/database.rb); precompiled with its libpq
gem "jwt", "~> 3.0"            # for auth providers (auth/<dir>) that verify JWT access tokens against an issuer's JWKS
gem "commonmarker", "~> 2.0"   # report markdown → HTML; raw HTML in the source is NOT rendered (unsafe: false)
# libgit2 for every read of a scanned repo (bin/git-read only, never loaded by a long-lived process): built against the
# image's own libgit2 (Dockerfile stage libgit2: pinned version + checksum + build flags), never rugged's bundled copy
gem "rugged", "1.9.6"

group :cli, :development, :test do
  gem "minitest", "~> 5.0"
  gem "rack-test"
end

# coverage: the parallel suite's workers each record a SimpleCov result, `rake test:parallel` merges them
# and fails below the floor (test/support/coverage.rb)
group :test do
  gem "simplecov", "0.22.0", require: false
end

# style gate: `.rubocop.yml` = Cookpad's style guide (config/rubocop/cookpad.yml); run by CI
# (scripts/ci/test.sh lint, busyyaks:lint image) and by the overcommit pre-commit hook (busyyaks:hooks image);
# bundler-audit = CI's `audit` stage (scripts/ci/test.sh audit), busyyaks:lint image
group :lint do
  gem "rubocop", "1.92.2", require: false
  gem "rubocop-performance", "1.27.0", require: false     # the four plugin departments, enabled in .rubocop.yml
  gem "rubocop-rake", "0.7.1", require: false
  gem "rubocop-sequel", "0.4.1", require: false
  gem "rubocop-thread_safety", "0.8.0", require: false
  gem "bundler-audit", "0.9.3", require: false
  gem "overcommit", "0.75.0", require: false              # the git hook manager (.overcommit.yml, scripts/hooks/run)
end
