require "ipaddr"
require "json"
require "sinatra/base"
require_relative "event"
require_relative "notifier"

module CoderNotify
  # The HTTP API. Puma binds it to 127.0.0.1 only; see config/puma.rb.
  #
  #   POST /events           - remote hook scripts report agent events (workspace token)
  #   GET  /                 - local browser dashboard (no private data)
  #   POST /browser-session - exchange the dashboard token for a browser cookie
  #   GET  /sessions         - the dashboard reads current state (menu token)
  #   POST /sessions/dismiss - the dashboard's "Dismiss" actions (menu token)
  #   GET  /health           - liveness; with a workspace token it also says which workspace
  #
  # Use App.with_context(service) to get a configured copy. The context is the
  # Service (see service.rb), which holds the stores the routes need.
  class App < Sinatra::Base
    MAX_BODY_BYTES = 64 * 1024

    configure do
      # Reject requests whose Host header isn't loopback. This blocks "DNS
      # rebinding", where a web page tricks your browser into calling a
      # localhost service.
      set :host_authorization, { permitted_hosts: ["localhost", IPAddr.new("127.0.0.1"), IPAddr.new("::1")] }
      # Return JSON errors instead of Sinatra's HTML error pages, but still
      # write the details of unexpected errors to the log.
      set :show_exceptions, false
      set :raise_errors, false
      set :dump_errors, true
    end

    # Returns a subclass whose routes use +context+. (Not called "build":
    # Sinatra already has a class method with that name.)
    def self.with_context(context)
      Class.new(self) { set :context, context }
    end

    before { content_type :json }

    get "/" do
      content_type :html
      headers "Cache-Control" => "no-store", "Referrer-Policy" => "no-referrer",
              "Content-Security-Policy" => "default-src 'self'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'"
      File.read(File.expand_path("../../dashboard/index.html", __dir__))
    end

    get "/dashboard.js" do
      content_type "application/javascript"
      File.read(File.expand_path("../../dashboard/dashboard.js", __dir__))
    end

    post "/browser-session" do
      # Bootstrap must use the explicit token, not an existing cookie.
      require_menu_token!(allow_cookie: false)
      response.set_cookie("coder_notify_browser", value: context.menu_token, httponly: true,
                          same_site: :strict, path: "/")
      headers "Cache-Control" => "no-store"
      JSON.generate(ok: true)
    end

    get "/health" do
      body = { ok: true, service: "coder-notify" }
      # Lets remote scripts verify their token works through the tunnel.
      entry = context.tokens.authenticate(bearer_token)
      body[:workspace] = workspace_name_for(entry) if entry
      JSON.generate(body)
    end

    post "/events" do
      entry = context.tokens.authenticate(bearer_token)
      halt_json 401, "missing or unknown workspace token" unless entry
      halt_json 415, "Content-Type must be application/json" unless request.media_type == "application/json"

      event = Event.from_payload(parse_json_body)
      workspace_name = workspace_name_for(entry)
      if event.workspace_name && event.workspace_name != workspace_name
        halt_json 409, "this token belongs to workspace #{workspace_name.inspect}, " \
                       "but the event came from #{event.workspace_name.inspect}"
      end

      outcome = context.sessions.apply(event, workspace_id: entry.workspace_id, workspace_name: workspace_name)
      context.changed! if outcome == :applied
      JSON.generate(result: outcome)
    rescue Event::Invalid => e
      halt_json 422, e.errors
    end

    get "/sessions" do
      require_menu_token!
      headers "Cache-Control" => "no-store"
      JSON.generate(context.snapshot)
    end

    post "/sessions/dismiss" do
      require_menu_token!
      payload = parse_json_body
      outcome = payload["all"] == true ? context.sessions.dismiss_all : context.sessions.dismiss(payload["key"].to_s)
      context.changed! if outcome == :applied
      JSON.generate(result: outcome)
    end

    not_found { JSON.generate(error: "not found") }
    error { JSON.generate(error: "internal error") }

    private

    def context = settings.context

    def bearer_token
      request.env["HTTP_AUTHORIZATION"].to_s[/\ABearer (\S+)\z/, 1]
    end

    def require_menu_token!(allow_cookie: true)
      token = (bearer_token || (request.cookies["coder_notify_browser"] if allow_cookie)).to_s
      return if Rack::Utils.secure_compare(context.menu_token, token)

      halt_json 401, "missing or wrong menu token"
    end

    # Reads the body with a size limit, then parses it as JSON.
    def parse_json_body
      raw = request.body.read(MAX_BODY_BYTES + 1).to_s
      halt_json 413, "body larger than #{MAX_BODY_BYTES} bytes" if raw.bytesize > MAX_BODY_BYTES
      JSON.parse(raw)
    rescue JSON::ParserError
      halt_json 400, "body is not valid JSON"
    end

    # Prefer the current name from `coder list` (workspaces can be renamed).
    def workspace_name_for(entry)
      context.workspaces.find(entry.workspace_id)&.name || entry.workspace_name
    end

    def halt_json(status, error)
      halt status, JSON.generate(error: error)
    end
  end
end
