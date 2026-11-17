require "test_helper"

class RailsPulse::Tracker::RequestFilterTest < ActiveSupport::TestCase
  # An unpinned connection exercises the real async branch without stubbing the tracker.
  self.use_transactional_tests = false

  setup do
    @original_settings = %i[async request_filter].index_with do |key|
      RailsPulse.configuration.public_send(key)
    end
    RailsPulse::Current.reset
    RailsPulse::SchemaCheck.reset!
    RailsPulse::Tracker.flush!
    RailsPulse::Tracker.reset_writer!
    RailsPulse.configuration.async = true
    @writer = RailsPulse::Tracker::Writer.new(queue_size: 4, auto_start: false)
    RailsPulse::Tracker.instance_variable_set(:@writer, @writer)
  end

  teardown do
    # No worker was started and no request was persisted; discard this test's queue.
    RailsPulse::Tracker.reset_writer!
    RailsPulse::SchemaCheck.reset!
    RailsPulse::Current.reset
    @original_settings.each { |key, value| RailsPulse.configuration.public_send("#{key}=", value) }
  end

  # Queue Boundary Tests

  test "request_filter redacts full and folded requests before the writer receives them" do
    seen = []
    RailsPulse.configuration.request_filter = ->(data) do
      assert_equal seen.size, @writer.size
      seen << data[:path]
      data.merge(path: "/unmatched")
    end

    [ true, false ].each do |detail|
      RailsPulse::Tracker.track_request(path: "/private-path", controller_action: nil, detail: detail)
    end

    assert_equal [ "/private-path", "/private-path" ], seen
    assert_equal 2, @writer.size
    assert_not_predicate @writer, :running?
  end

  test "request_filter failures never enqueue or log request data" do
    output = StringIO.new
    original_logger = RailsPulse.configuration.logger
    RailsPulse.configuration.logger = Logger.new(output)
    filters = [ nil, false, true, "private-value", [], 123 ].map { |value| ->(_data) { value } }
    filters << ->(data) { raise "private-error: #{data.inspect}" }

    filters.each do |filter|
      RailsPulse.configuration.request_filter = filter
      [ true, false ].each do |detail|
        RailsPulse::Tracker.track_request(path: "/private-path", detail: detail)
      end
    end

    assert_equal 0, @writer.size
    assert_empty output.string
  ensure
    RailsPulse.configuration.logger = original_logger
  end
end
