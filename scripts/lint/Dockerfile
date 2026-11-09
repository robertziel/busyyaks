# busyyaks:lint — RuboCop + bundler-audit only: the Gemfile's :lint group, nothing else
# installed, so CI starts it in a second (the pre-commit hook runs the same gems in busyyaks:hooks). Built from the repo's Gemfile.lock; scripts/lint/image
# tags it by the hash of Gemfile + Gemfile.lock + this file and rebuilds on change. The source is bind-mounted at /src at run time.
FROM ruby:3.4-slim
# git + ca-certificates: bundle-audit --update clones rubysec/ruby-advisory-db
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /lint
COPY Gemfile Gemfile.lock ./
ENV BUNDLE_ONLY=lint BUNDLE_GEMFILE=/lint/Gemfile
RUN bundle install && bundle exec rubocop --version && bundle exec bundle-audit version
WORKDIR /src
ENTRYPOINT ["bundle", "exec", "rubocop"]
