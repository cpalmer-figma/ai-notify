source "https://rubygems.org"

ruby file: ".ruby-version"

# Web framework for the small HTTP API (POST /events, GET /sessions, GET /health).
gem "sinatra", "~> 4.1"
# Application server that runs the Sinatra app. We bind it to 127.0.0.1 only.
gem "puma", "~> 7.0"
# Wraps the terminal-notifier macOS app so we can post and remove notifications.
gem "terminal-notifier", "~> 3.1"

group :test do
  gem "minitest", "~> 5.25"
  # Lets tests call the Sinatra app in-process, without a real HTTP server.
  gem "rack-test", "~> 2.2"
  gem "rake", "~> 13.0"
end
