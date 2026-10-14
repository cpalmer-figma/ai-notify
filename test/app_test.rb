require_relative "test_helper"
require "rack/test"

class AppTest < Minitest::Test
  include Rack::Test::Methods

  # Requests look like they come from 127.0.0.1 (see host authorization).
  def default_host = "127.0.0.1"

  def setup
    @service = build_service(tmpdir)
    @service.workspaces.apply(CoderNotify::WorkspaceDiscovery::Result.new(
      workspaces: [workspace(id: "ws-1", name: "alpha"), workspace(id: "ws-2", name: "beta")], error: nil
    ))
    @token = @service.tokens.enable(@service.workspaces.find("ws-1")).token
  end

  def app = @service.app

  def post_event(body, token: @token, content_type: "application/json")
    header "Authorization", "Bearer #{token}" if token
    header "Content-Type", content_type
    post "/events", body.is_a?(String) ? body : JSON.generate(body)
  end

  def json = JSON.parse(last_response.body)

  def menu_get(path)
    header "Authorization", "Bearer #{@service.menu_token}"
    get path
  end

  # --- /health ------------------------------------------------------------

  def test_health_is_public
    get "/health"
    assert_equal 200, last_response.status
    assert_equal({ "ok" => true, "service" => "coder-notify" }, json)
  end

  def test_dashboard_shell_contains_no_credentials_or_workspace_data
    get "/"
    assert_equal 200, last_response.status
    assert_match(/text\/html/, last_response.content_type)
    assert_includes last_response.body, "Your workspaces"
    refute_includes last_response.body, @service.menu_token
    refute_includes last_response.body, @token
    refute_includes last_response.body, "alpha"
    assert_includes last_response.headers["content-security-policy"], "frame-ancestors 'none'"
  end

  def test_browser_session_requires_menu_token_and_sets_private_cookie
    header "Authorization", "Bearer #{@token}"
    post "/browser-session"
    assert_equal 401, last_response.status

    header "Authorization", "Bearer #{@service.menu_token}"
    post "/browser-session"
    assert_equal 200, last_response.status
    cookie = last_response.headers["set-cookie"]
    assert_match(/httponly/i, cookie)
    assert_match(/samesite=strict/i, cookie)

    header "Authorization", nil
    get "/sessions"
    assert_equal 200, last_response.status
    assert_equal 2, json["workspaces"].size
    header "Content-Type", "application/json"
    post "/sessions/dismiss", JSON.generate(all: true)
    assert_equal 200, last_response.status
    post "/browser-session"
    assert_equal 401, last_response.status, "bootstrap cannot use a cookie"
  end

  def test_dashboard_javascript_is_served
    get "/dashboard.js"
    assert_equal 200, last_response.status
    assert_match(/javascript/, last_response.content_type)
  end

  def test_health_names_the_workspace_for_a_valid_token
    header "Authorization", "Bearer #{@token}"
    get "/health"
    assert_equal "alpha", json["workspace"]
  end

  # --- POST /events -------------------------------------------------------

  def test_valid_event_is_recorded_for_the_tokens_workspace
    post_event(payload(type: "waiting"))

    assert_equal 200, last_response.status
    assert_equal "applied", json["result"]
    session = @service.sessions.sessions.fetch(0)
    assert_equal "ws-1", session.workspace_id
    assert_equal "alpha", session.workspace_name
  end

  def test_duplicate_event_is_accepted_but_not_applied_twice
    body = payload(type: "waiting", event_id: "once")
    post_event(body)
    post_event(body)
    assert_equal 200, last_response.status
    assert_equal "duplicate", json["result"]
  end

  def test_missing_or_unknown_token_is_rejected
    post_event(payload, token: nil)
    assert_equal 401, last_response.status

    post_event(payload, token: "not-a-real-token")
    assert_equal 401, last_response.status
    assert_empty @service.sessions.sessions
  end

  def test_menu_token_cannot_post_events
    post_event(payload, token: @service.menu_token)
    assert_equal 401, last_response.status
  end

  def test_wrong_content_type_is_rejected
    post_event(JSON.generate(payload), content_type: "text/plain")
    assert_equal 415, last_response.status
  end

  def test_invalid_json_is_rejected
    post_event("{not json")
    assert_equal 400, last_response.status
  end

  def test_invalid_payload_lists_errors
    post_event(payload(agent: "nope"))
    assert_equal 422, last_response.status
    assert_includes json["error"], "agent must be one of claude, codex"
  end

  def test_oversized_body_is_rejected
    post_event(payload(padding: "x" * 70_000))
    assert_equal 413, last_response.status
  end

  def test_token_copied_to_the_wrong_workspace_is_caught
    post_event(payload(workspace_name: "beta"))
    assert_equal 409, last_response.status
    assert_match(/belongs to workspace "alpha"/, json["error"])
  end

  def test_non_loopback_host_header_is_rejected
    header "Host", "evil.example.com"
    get "/health"
    assert_equal 403, last_response.status
  end

  # --- GET /sessions and dismiss -------------------------------------------

  def test_sessions_requires_the_menu_token
    get "/sessions"
    assert_equal 401, last_response.status

    header "Authorization", "Bearer #{@token}" # a workspace token is not enough
    get "/sessions"
    assert_equal 401, last_response.status
  end

  def test_sessions_snapshot
    post_event(payload(type: "waiting", reason: "permission"))
    menu_get "/sessions"

    assert_equal 200, last_response.status
    assert_equal 1, json["attention_count"]
    session = json["sessions"].fetch(0)
    assert_equal "Claude", session["agent_label"]
    assert_equal "Needs permission", session["reason_label"]
    assert_equal "main:1.0", session["pane_label"]

    monitoring = json["workspaces"].to_h { |ws| [ws["name"], ws["monitoring"]["state"]] }
    assert_equal({ "alpha" => "connecting", "beta" => "not_enabled" }, monitoring)
  end

  def test_dismiss_one_and_all
    post_event(payload(type: "waiting", pane_id: "%1", session_id: "a"))
    post_event(payload(type: "waiting", pane_id: "%2", session_id: "b"))

    header "Authorization", "Bearer #{@service.menu_token}"
    header "Content-Type", "application/json"
    post "/sessions/dismiss", JSON.generate(key: "ws-1|%1|claude|a")
    assert_equal ["b"], @service.sessions.attention.map(&:session_id)

    post "/sessions/dismiss", JSON.generate(all: true)
    assert_empty @service.sessions.attention
  end

  def test_unknown_route
    get "/nope"
    assert_equal 404, last_response.status
    assert_equal "not found", json["error"]
  end
end
