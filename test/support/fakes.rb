# Fakes shared by several tests.

# Records notifications instead of showing them.
class FakeNotifierBackend
  attr_reader :posted, :removed

  def initialize
    @posted = []
    @removed = []
  end

  def notify(group:, title:, subtitle:, message:)
    @posted << { group: group, title: title, subtitle: subtitle, message: message }
  end

  def remove(group) = @removed << group
end

# Returns whatever discovery result the test sets.
class FakeDiscovery
  attr_accessor :result

  def call = result
end

# Never starts real processes.
class NullSpawner
  def spawn(*, **) = Object.new
  def stop(_handle) = nil
end
