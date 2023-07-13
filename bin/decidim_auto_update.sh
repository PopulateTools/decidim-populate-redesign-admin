#!/bin/bash

# handle kill signs
trap "echo; exit 1" INT TERM

function log() {
  echo -e "\n==== $1 ===="
}

log "Setup bundler and dependencies" && rm -f Gemfile.lock && bundle config --delete frozen && bundle install && bundle lock --add-platform x86_64-linux
log "Updating decidim webpacker config" && bin/rails decidim:webpacker:install
log "Installing decidim new migrations" && bin/rails decidim:choose_target_plugins && bin/rails railties:install:migrations

exit 0
