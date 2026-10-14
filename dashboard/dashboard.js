/* Private data comes from the authenticated API, never from the public HTML. */
const byId = id => document.getElementById(id);
let refreshing = false;

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

async function api(path, body) {
  const response = await fetch(path, {
    method: body ? 'POST' : 'GET', credentials: 'same-origin', cache: 'no-store',
    headers: body ? { 'Content-Type': 'application/json' } : {},
    body: body ? JSON.stringify(body) : undefined
  });
  if (response.status === 401) throw new Error('Open this dashboard with bin/coder-notify browser to connect securely.');
  if (!response.ok) throw new Error(`The service returned HTTP ${response.status}.`);
  return response.json();
}

function machineColor(state) {
  if (state === 'running') return 'green';
  if (['stopped', 'failed', 'deleting'].includes(state)) return 'red';
  if (['starting', 'unreachable'].includes(state)) return 'yellow';
  return '';
}

function render(snapshot) {
  const workspaces = snapshot.workspaces || [];
  const sessions = snapshot.sessions || [];
  byId('total').textContent = workspaces.length;
  byId('running').textContent = workspaces.filter(ws => ws.state === 'running').length;
  byId('waiting').textContent = snapshot.attention_count;
  byId('machines').replaceChildren();
  for (const ws of [...workspaces].sort((a, b) => a.name.localeCompare(b.name))) {
    const row = element('div', 'machine');
    const description = element('div');
    const name = element('div', 'machine-name');
    name.append(element('span', `dot ${machineColor(ws.state)}`), document.createTextNode(ws.name));
    description.append(name);
    const monitoring = ws.monitoring || {};
    const state = (monitoring.state || 'unknown').replaceAll('_', ' ');
    description.append(element('div', 'detail', `Notifications: ${state}`));
    if (monitoring.detail) description.title = monitoring.detail;
    row.append(description, element('span', `status ${machineColor(ws.state) ? ws.state : ''}`, ws.state));
    byId('machines').append(row);
  }
  if (!workspaces.length) byId('machines').append(element('div', 'empty', 'No machines discovered yet. Check that coder list works on this Mac.'));

  byId('sessions').replaceChildren();
  for (const session of [...sessions].sort((a, b) => Number(b.attention) - Number(a.attention))) {
    const row = element('div', 'session');
    const description = element('div');
    description.append(element('strong', '', `${session.agent_label} · ${session.workspace_name}`));
    const status = session.attention ? 'Needs attention' : session.status === 'waiting' ? 'Seen' : 'Working';
    description.append(element('p', '', `${session.pane_label || session.pane_id} · ${status} · ${session.reason_label}`));
    row.append(description);
    if (session.attention) {
      const dismiss = element('button', '', 'Dismiss');
      dismiss.addEventListener('click', () => dismissSessions({ key: session.key }));
      row.append(dismiss);
    }
    byId('sessions').append(row);
  }
  if (!sessions.length) byId('sessions').append(element('div', 'empty', 'No agent activity yet. Enable a workspace and install its remote hooks to receive alerts.'));
  byId('dismiss-all').hidden = !snapshot.attention_count;
  const discovery = snapshot.discovery || {};
  byId('notice').textContent = discovery.error ? `Discovery failed; showing the last known machine list. ${discovery.error}` : '';
  const checked = discovery.checked_at ? new Date(discovery.checked_at).toLocaleTimeString() : 'pending';
  byId('updated').textContent = `Last machine discovery: ${checked} · Dashboard refreshes every 5 seconds · Discovery runs every minute`;
}

async function refresh() {
  if (refreshing) return;
  refreshing = true;
  byId('refresh').disabled = true;
  try { render(await api('/sessions')); }
  catch (error) { byId('notice').textContent = error.message; }
  finally { refreshing = false; byId('refresh').disabled = false; }
}

async function dismissSessions(body) {
  try { await api('/sessions/dismiss', body); await refresh(); }
  catch (error) { byId('notice').textContent = error.message; }
}

async function start() {
  let token = new URLSearchParams(location.hash.slice(1)).get('token');
  // Fragments aren't sent to the server. Remove the credential from the URL immediately.
  if (location.hash) history.replaceState(null, '', location.pathname);
  if (token) {
    try {
      const response = await fetch('/browser-session', { method: 'POST', headers: { Authorization: `Bearer ${token}` } });
      if (!response.ok) throw new Error('Could not connect. Run bin/coder-notify browser again.');
    } catch (error) { byId('notice').textContent = error.message; return; }
    finally { token = null; }
  }
  byId('refresh').addEventListener('click', refresh);
  byId('dismiss-all').addEventListener('click', () => dismissSessions({ all: true }));
  await refresh();
  setInterval(refresh, 5000);
}

start();
