module CoderNotify
  # Runs slow side effects (posting notifications) on a
  # background thread, so HTTP requests from remote hooks return immediately.
  #
  # Several changes in quick succession are coalesced into one run: the
  # worker only cares that "something changed", not what.
  class ChangeWorker
    def initialize(logger: nil, &work)
      @work = work
      @logger = logger
      @queue = Queue.new
    end

    def start
      @thread = Thread.new do
        loop do
          @queue.pop   # wait until something changes
          @queue.clear # drop signals that arrived meanwhile; one run covers them
          run_once
        end
      end
      self
    end

    def changed! = @queue << :changed

    def run_once
      @work.call
    rescue StandardError => e
      @logger&.error("change worker: #{e.class}: #{e.message}")
    end
  end

end
