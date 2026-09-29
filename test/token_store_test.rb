require_relative "test_helper"

class TokenStoreTest < Minitest::Test
  def store = CoderNotify::TokenStore.new(path: File.join(tmpdir, "tokens.json"))

  def test_enable_creates_a_long_random_token_once
    tokens = store
    first = tokens.enable(workspace(id: "a", name: "alpha"))
    again = tokens.enable(workspace(id: "a", name: "alpha"))

    assert_match(/\A\h{64}\z/, first.token)
    assert_equal first.token, again.token
    assert tokens.enabled?("a")
  end

  def test_each_workspace_gets_its_own_token
    tokens = store
    refute_equal tokens.enable(workspace(id: "a", name: "alpha")).token,
                 tokens.enable(workspace(id: "b", name: "beta")).token
  end

  def test_authenticate_maps_token_to_workspace
    tokens = store
    entry = tokens.enable(workspace(id: "a", name: "alpha"))

    assert_equal "a", tokens.authenticate(entry.token).workspace_id
    assert_nil tokens.authenticate("wrong")
    assert_nil tokens.authenticate("")
    assert_nil tokens.authenticate(nil)
  end

  def test_disable_revokes_the_token
    tokens = store
    entry = tokens.enable(workspace(id: "a", name: "alpha"))
    tokens.disable("a")

    assert_nil tokens.authenticate(entry.token)
    refute tokens.enabled?("a")
  end

  def test_recreated_workspace_with_same_name_replaces_the_old_token
    tokens = store
    old = tokens.enable(workspace(id: "old-id", name: "alpha"))
    tokens.enable(workspace(id: "new-id", name: "alpha"))

    assert_equal ["new-id"], tokens.entries.map(&:workspace_id)
    assert_nil tokens.authenticate(old.token)
  end

  def test_changes_made_by_another_process_are_picked_up
    server_side = store
    server_side.entries # load once, like the running service
    cli_side = store
    entry = cli_side.enable(workspace(id: "a", name: "alpha")) # e.g. `bin/coder-notify enable`

    assert_equal "a", server_side.authenticate(entry.token).workspace_id
  end

  def test_file_is_private
    store.enable(workspace)
    assert_equal 0o600, File.stat(File.join(tmpdir, "tokens.json")).mode & 0o777
  end
end
