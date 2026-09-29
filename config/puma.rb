# Puma settings for the coder-notify service.
#
# Bind to loopback only: nothing on your network can reach the service. The
# workspaces reach it through their SSH reverse tunnels, which also end on
# 127.0.0.1.
port = Integer(ENV.fetch("CODER_NOTIFY_PORT", "47290"))
bind "tcp://127.0.0.1:#{port}"

# One process (no cluster workers): the tunnel supervisor and discovery loop
# run as threads inside it, and the state lives in its memory.
workers 0
threads 1, 5

environment "production"
