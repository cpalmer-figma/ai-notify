# Rack entry point, loaded by Puma (see config/puma.rb).
require_relative "lib/coder_notify"

# Write log lines immediately, even when stdout is a file (under launchd).
$stdout.sync = true

service = CoderNotify::Service.new
service.start
# Stop the tunnels when Puma shuts down (Ctrl-C, launchctl stop, ...).
at_exit { service.stop }

run service.app
