class Estore
  # Catch-Up Subscriptions
  #
  # This kind of subscription specifies a starting point, in the form of an
  # event number or transaction file position. The given function will be
  # called for events from the starting point until the end of the stream,
  # and then for subsequently written events.
  #
  # For example, if a starting point of 50 is specified when a stream has 100
  # events in it, the subscriber can expect to see events 51 through 100, and
  # then any events subsequently written until such time as the subscription is
  # dropped or closed.
  class CatchUpSubscription < Subscription
    MAX_READ_BATCH = 100

    attr_reader :from, :caught_up

    def initialize(estore, stream, from, options = {})
      super(estore, stream, options)

      @from = from
      @caught_up = false
      @mutex = Mutex.new
      @queue = []
      @position = from - 1
      @batch_size = options[:batch_size] || 100
    end

    def on_catchup(&block)
      @on_catchup = block if block
    end

    def start
      subscribe
      backfill
      switch_to_live
      call_on_catchup
    end

    private

    def event_appeared(event)
      unless caught_up
        @mutex.synchronize do
          @queue.push(event) unless caught_up
        end
      end
      dispatch(event) if caught_up
    end

    def switch_to_live
      @mutex.synchronize do
        dispatch_events(received_while_backfilling)
        @queue = nil
        @caught_up = true
      end
    end

    def backfill
      loop do
        events, finished = fetch_batch(@position + 1)
        @mutex.synchronize do
          dispatch_events(events)
        end
        break if finished
      end
    end

    def dispatch_events(events)
      events.each { |e| dispatch(e) }
    end

    def fetch_batch(from)
      prom = @estore.read(stream, from, @batch_size)
      response = prom.sync
      [Array(response.events), response.is_end_of_stream]
    end

    def received_while_backfilling
      @queue.find_all { |event| event.original_event_number > @position }
    end

    def call_on_catchup
      @on_catchup.call if @on_catchup
    end
  end
end
