#!/usr/bin/env ruby
# coder-notify SwiftBar plugin: shows Claude Code / Codex sessions on your
# Coder workspaces that need attention.
#
# SwiftBar runs this file and turns what it prints into a menu bar item:
# lines before the first "---" form the menu bar title, later lines the
# dropdown, "--" nests a line in a submenu, and "| key=value" sets options.
# The ".1m." in the file name is a fallback refresh every minute; the
# service also asks SwiftBar to refresh right away whenever state changes.
#
# Uses only Ruby's standard library and runs on any Ruby >= 2.6 (including
# macOS's /usr/bin/ruby), because SwiftBar doesn't load your shell setup.
#
# <xbar.title>coder-notify</xbar.title>
# <xbar.version>v1.0</xbar.version>
# <xbar.desc>Coding agents on your Coder workspaces that need attention.</xbar.desc>
# <xbar.dependencies>ruby</xbar.dependencies>
# <swiftbar.runInBash>false</swiftbar.runInBash>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>

require "json"
require "net/http"
require "time"

module CoderNotifyMenu
  SERVICE_URL = ENV.fetch("CODER_NOTIFY_URL", "http://127.0.0.1:47290")
  HOME = File.expand_path(ENV.fetch("CODER_NOTIFY_HOME", "~/.coder-notify"))
  # Menu actions run this same file again, so we need its absolute path.
  SELF = File.expand_path(__FILE__)
  # The project's README, found through the symlink SwiftBar runs us from.
  README = File.expand_path("../README.md", File.dirname(File.realpath(__FILE__)))

  MONITORING_ICONS = {
    "connected" => "checkmark.circle",
    "connecting" => "arrow.triangle.2.circlepath",
    "idle" => "moon.zzz",
    "not_enabled" => "circle.dashed"
  }.freeze

  module_function

  # Entry point. With no arguments, print the menu. Menu items call this
  # same file back with arguments to perform actions.
  def main(argv)
    case argv[0]
    when "dismiss" then request(:post, "/sessions/dismiss", "key" => argv[1])
    when "dismiss-all" then request(:post, "/sessions/dismiss", "all" => true)
    when "copy" then IO.popen(["pbcopy"], "w") { |io| io.write(argv[1].to_s) }
    else puts render(fetch_snapshot, Time.now)
    end
  end

  # Returns the parsed GET /sessions response, or { "error" => message }.
  def fetch_snapshot
    response = request(:get, "/sessions")
    return { "error" => "service returned HTTP #{response.code}" } unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue Errno::ENOENT
    { "error" => "no menu token yet; start the service once (see README)" }
  rescue SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout, JSON::ParserError => e
    { "error" => "coder-notify service is not running (#{e.class.name.split('::').last})" }
  end

  def request(method, path, body = nil)
    uri = URI(SERVICE_URL + path)
    token = File.read(File.join(HOME, "menu-token")).strip
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 1
    http.read_timeout = 2
    req = method == :get ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
    req["Authorization"] = "Bearer #{token}"
    if body
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body)
    end
    http.request(req)
  end

  # Builds the whole menu as text. Kept free of I/O so tests can call it.
  def render(snapshot, now)
    return render_error(snapshot["error"]) if snapshot["error"]

    sessions = snapshot["sessions"] || []
    attention = sessions.select { |s| s["attention"] }
    seen = sessions.select { |s| s["status"] == "waiting" && !s["attention"] }
    working = sessions.select { |s| s["status"] == "working" }
    workspaces = snapshot["workspaces"] || []
    problems = workspaces.select { |ws| problem?(ws) }
    discovery_error = (snapshot["discovery"] || {})["error"]

    lines = [title_line(attention.size, problems.any? || discovery_error), "---"]

    if attention.empty?
      lines << "No agents need you right now | sfimage=checkmark"
    else
      lines << "Needs attention (#{attention.size})"
      attention.each { |s| lines.concat(attention_item(s, now)) }
    end
    unless seen.empty?
      lines << "---" << "Seen (#{seen.size})"
      seen.each { |s| lines << "#{session_title(s)} · #{clean(s['reason_label'])} | sfimage=eye color=gray" }
    end
    unless working.empty?
      lines << "Working (#{working.size}) | sfimage=hammer"
      working.each { |s| lines << "--#{session_title(s)}" }
    end

    lines << "---" << "Workspaces"
    lines << "No workspaces found | color=gray" if workspaces.empty?
    workspaces.each { |ws| lines.concat(workspace_item(ws)) }
    lines << "⚠ Workspace discovery failed; showing last known list | color=orange" if discovery_error
    lines << "--#{clean(discovery_error)}" if discovery_error

    lines << "---"
    lines << "Dismiss all | bash=#{quote(SELF)} param1=dismiss-all terminal=false refresh=true" unless attention.empty?
    lines << "Refresh | refresh=true"
    lines << "Open README | bash=/usr/bin/open param1=#{quote(README)} terminal=false"
    lines.join("\n")
  end

  def render_error(message)
    ["| sfimage=bell.slash", "---", "#{clean(message)} | color=red",
     "Start it with: bin/coder-notify server (see README)", "Refresh | refresh=true"].join("\n")
  end

  # The menu bar itself: a bell, plus the number of agents waiting for you.
  def title_line(count, warning)
    icon = count.positive? ? "bell.badge.fill" : (warning ? "exclamationmark.triangle" : "bell")
    count.positive? ? "#{count} | sfimage=#{icon}" : "| sfimage=#{icon}"
  end

  # "Claude · api-work · main:1.0"
  def session_title(session)
    [session["agent_label"], session["workspace_name"], session["pane_label"] || session["pane_id"]]
      .map { |part| clean(part) }.join(" · ")
  end

  def attention_item(session, now)
    since = session["waiting_since"] ? " (#{ago(Time.iso8601(session['waiting_since']), now)})" : ""
    [
      "#{session_title(session)} — #{clean(session['reason_label'])}#{since} | sfimage=exclamationmark.bubble.fill",
      "--Workspace #{clean(session['workspace_name'])}, tmux pane #{clean(session['pane_label'])} (#{clean(session['pane_id'])})",
      "--Switch to that pane to clear this alert",
      "-----",
      "--Dismiss | bash=#{quote(SELF)} param1=dismiss param2=#{quote(session['key'])} terminal=false refresh=true",
      "--Copy tmux target | bash=#{quote(SELF)} param1=copy param2=#{quote(session['pane_label'])} terminal=false"
    ]
  end

  def workspace_item(workspace)
    monitoring = workspace["monitoring"] || {}
    state = monitoring["state"].to_s
    icon = problem?(workspace) ? "exclamationmark.triangle" : MONITORING_ICONS.fetch(state, "circle")
    summary = workspace["state"] == "running" ? state.tr("_", " ") : workspace["state"]
    lines = ["#{clean(workspace['name'])} — #{clean(summary)} | sfimage=#{icon}"]
    lines << "--#{clean(monitoring['detail'])}" if monitoring["detail"]
    lines << "--Retrying in #{monitoring['retry_in']}s" if monitoring["retry_in"]
    lines
  end

  # A workspace that should be monitored but isn't working right.
  def problem?(workspace)
    state = (workspace["monitoring"] || {})["state"].to_s
    workspace["state"] == "unreachable" || !%w[connected connecting idle not_enabled].include?(state)
  end

  def ago(time, now)
    seconds = (now - time).to_i
    return "just now" if seconds < 60
    return "#{seconds / 60}m" if seconds < 3600

    "#{seconds / 3600}h #{(seconds % 3600) / 60}m"
  end

  # Menu text must not contain "|" (starts options), newlines (new items) or
  # leading dashes (submenus / separators).
  def clean(text)
    text.to_s.gsub(/[[:cntrl:]]+/, " ").tr("|", "¦").sub(/\A-+/, "").strip
  end

  # Quotes a SwiftBar option value (they can't contain double quotes).
  def quote(value)
    "\"#{value.to_s.delete('"')}\""
  end
end

CoderNotifyMenu.main(ARGV) if $PROGRAM_NAME == __FILE__
