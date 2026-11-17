require "test_helper"

class OperationSubscriberTest < ActiveSupport::TestCase
  def setup
    # Use existing fixture data
    @request = rails_pulse_requests(:users_request_1)

    # Setup request context for operation tracking
    RailsPulse::Current.rails_pulse_request_id = @request.id
    RailsPulse::Current.rails_pulse_job_run_id = nil
    RailsPulse::Current.rails_pulse_operations = []

    @original_capture_actual_sql = RailsPulse.configuration.capture_actual_sql
    @original_operation_filter = RailsPulse.configuration.operation_filter
    RailsPulse.configuration.capture_actual_sql = true

    super
  end

  def teardown
    RailsPulse.configuration.capture_actual_sql = @original_capture_actual_sql
    RailsPulse.configuration.operation_filter = @original_operation_filter
    RailsPulse::Current.reset
    super
  end

  # Operation Filter Tests

  test "operation_filter redacts SQL and labels before buffering on both capture paths" do
    RailsPulse.configuration.operation_filter = ->(operation) do
      if operation[:operation_type] == "sql"
        operation.merge(label: "[FILTERED]", actual_sql: "SELECT ?")
      else
        operation.merge!(label: "[FILTERED]", actual_sql: "SELECT ?")
      end
    end

    publish_event("sql.active_record", { sql: "SELECT 'private-value'", row_count: 3 })
    publish_event("request.net_http", { method: "GET", uri: "https://example.test/private-value" })

    operations = RailsPulse::Current.rails_pulse_operations

    assert_equal [ "sql", "http" ], operations.map { |op| op[:operation_type] }
    operations.each do |operation|
      assert_equal "[FILTERED]", operation[:label]
      assert_equal "SELECT ?", operation[:actual_sql]
      assert_equal @request.id, operation[:request_id]
      assert_in_delta 5, operation[:duration], 0.001
    end
    assert_equal 3, operations.first[:row_count]
    assert_not_includes operations.inspect, "private-value"
  end

  test "operation_filter can retain only SQL and controllers in request and job buffers" do
    seen = []
    RailsPulse.configuration.operation_filter = ->(operation) do
      seen << operation
      operation if %w[sql controller].include?(operation[:operation_type])
    end

    [ :rails_pulse_request_id, :rails_pulse_job_run_id ].each do |context|
      RailsPulse::Current.rails_pulse_request_id = nil
      RailsPulse::Current.rails_pulse_job_run_id = nil
      RailsPulse::Current.public_send("#{context}=", "filter-context")
      RailsPulse::Current.rails_pulse_operations = []

      publish_event("cache_read.active_support", { key: "private-cache", hit: true })
      publish_event("cache_write.active_support", { key: "private-cache" })
      publish_event("request.net_http", { method: "GET", uri: "https://example.test/private-url" })
      publish_event("service_upload.active_storage", { key: "private-storage" })
      publish_event("sql.active_record", { sql: "SELECT 1", row_count: 2 })
      publish_event("process_action.action_controller", { controller: "UsersController", action: "index" })

      operations = RailsPulse::Current.rails_pulse_operations

      assert_equal [ "sql", "controller" ], operations.map { |op| op[:operation_type] }
      assert_equal "SELECT 1", operations.first[:actual_sql]
      assert_equal "UsersController#index", operations.last[:label]
      assert_equal "filter-context", operations.first[context.to_s.delete_prefix("rails_pulse_").to_sym]
      assert_not_includes operations.inspect, "private-"
    end

    assert_equal %w[cache_read cache_write http storage sql controller] * 2,
      seen.map { |op| op[:operation_type] }
    assert seen.first[:cache_hit]
    assert_equal 2, seen[4][:row_count]
    assert_not_nil seen.first[:codebase_location]
  end

  test "operation_filter drops SQL before raw SQL can enter a buffer" do
    seen_sql = nil
    RailsPulse.configuration.operation_filter = ->(operation) do
      seen_sql = operation[:actual_sql]
      nil
    end
    RailsPulse::Current.rails_pulse_operations = nil

    publish_event("sql.active_record", { sql: "SELECT 'private-value'" })

    assert_equal "SELECT 'private-value'", seen_sql
    assert_nil RailsPulse::Current.rails_pulse_operations
  end

  test "operation_filter drops invalid returns and exceptions without logging sensitive data" do
    output = StringIO.new
    original_logger = RailsPulse.configuration.logger
    RailsPulse.configuration.logger = Logger.new(output)
    filters = [ false, true, "private-value", [], 123 ].map { |value| ->(_operation) { value } }
    filters << ->(operation) { raise "private-error: #{operation.inspect}" }

    filters.each do |filter|
      RailsPulse.configuration.operation_filter = filter
      publish_event("sql.active_record", { sql: "SELECT 'private-value'" })
      publish_event("request.net_http", { method: "GET", uri: "https://example.test/private-value" })

      assert_empty RailsPulse::Current.rails_pulse_operations
    end

    assert_empty output.string
  ensure
    RailsPulse.configuration.logger = original_logger
  end

  test "nil operation_filter preserves SQL and HTTP operation data" do
    RailsPulse.configuration.operation_filter = nil
    RailsPulse.configuration.capture_actual_sql = false

    publish_event("sql.active_record", { sql: "SELECT 'unchanged'", row_count: 4 })
    publish_event("request.net_http", { method: "GET", uri: "https://example.test/unchanged" })

    sql, http = RailsPulse::Current.rails_pulse_operations

    assert_equal "SELECT 'unchanged'", sql[:actual_sql]
    assert_nil sql[:label]
    assert_equal 4, sql[:row_count]
    assert_equal "GET https://example.test/unchanged", http[:label]
    assert_not http.key?(:actual_sql)
  end

  test "subscriber module should exist" do
    assert defined?(RailsPulse::Subscribers::OperationSubscriber)
    assert_respond_to RailsPulse::Subscribers::OperationSubscriber, :subscribe!
  end

  test "should capture SQL operations" do
    payload = {
      sql: "SELECT * FROM users WHERE id = ?",
      name: "User Load"
    }

    publish_event("sql.active_record", payload)

    operations = RailsPulse::Current.rails_pulse_operations

    assert_equal 1, operations.size

    operation = operations.first

    assert_equal "sql", operation[:operation_type]
    assert_equal "SELECT * FROM users WHERE id = ?", operation[:actual_sql]
    assert_nil operation[:label]
    assert_operator operation[:duration], :>=, 0, "Duration should be non-negative, got: #{operation[:duration]}"
    assert_equal @request.id, operation[:request_id]
  end

  test "should filter out schema SQL queries" do
    schema_queries = [
      { sql: "SHOW FULL FIELDS FROM `users`", name: "SCHEMA" },
      { sql: "SELECT sql FROM sqlite_master", name: "SCHEMA" },
      { sql: "PRAGMA table_info(`users`)", name: "SCHEMA" }
    ]

    schema_queries.each do |payload|
      publish_event("sql.active_record", payload)
    end

    operations = RailsPulse::Current.rails_pulse_operations

    assert_equal 0, operations.size, "Schema queries should be filtered out"
  end

  test "should filter out RailsPulse SQL queries" do
    payload = {
      sql: "SELECT * FROM rails_pulse_requests WHERE id = ?",
      name: "RailsPulse::Request Load"
    }

    publish_event("sql.active_record", payload)

    operations = RailsPulse::Current.rails_pulse_operations

    assert_equal 0, operations.size, "RailsPulse queries should be filtered out"
  end

  test "should filter out cached SQL queries" do
    payload = {
      sql: "SELECT * FROM users WHERE id = ?",
      name: "User Load",
      cached: true
    }

    publish_event("sql.active_record", payload)

    operations = RailsPulse::Current.rails_pulse_operations

    assert_equal 0, operations.size, "Cached queries should be filtered out"
  end

  test "should capture uncached SQL queries with cached false" do
    payload = {
      sql: "SELECT * FROM users WHERE id = ?",
      name: "User Load",
      cached: false
    }

    publish_event("sql.active_record", payload)

    operations = RailsPulse::Current.rails_pulse_operations

    assert_equal 1, operations.size
  end

  test "should filter out queries matching a string ignored_queries pattern" do
    original = RailsPulse.configuration.ignored_queries
    RailsPulse.configuration.ignored_queries = [ "SELECT 1" ]

    payload = { sql: "SELECT 1", name: "SQL" }

    publish_event("sql.active_record", payload)

    operations = RailsPulse::Current.rails_pulse_operations

    assert_equal 0, operations.size, "Queries matching an ignored_queries string should be filtered out"
  ensure
    RailsPulse.configuration.ignored_queries = original
  end

  test "should filter out queries matching a regexp ignored_queries pattern" do
    original = RailsPulse.configuration.ignored_queries
    RailsPulse.configuration.ignored_queries = [ %r{FROM \"?schema_migrations\"?} ]

    payload = { sql: "SELECT * FROM \"schema_migrations\"", name: "SQL" }

    publish_event("sql.active_record", payload)

    operations = RailsPulse::Current.rails_pulse_operations

    assert_equal 0, operations.size, "Queries matching an ignored_queries regexp should be filtered out"
  ensure
    RailsPulse.configuration.ignored_queries = original
  end

  test "should not filter queries that do not match ignored_queries patterns" do
    original = RailsPulse.configuration.ignored_queries
    RailsPulse.configuration.ignored_queries = [ "SELECT 1" ]

    payload = { sql: "SELECT * FROM users", name: "User Load" }

    publish_event("sql.active_record", payload)

    operations = RailsPulse::Current.rails_pulse_operations

    assert_equal 1, operations.size
  ensure
    RailsPulse.configuration.ignored_queries = original
  end

  test "should capture template rendering operations" do
    payload = {
      identifier: "/app/views/users/show.html.erb"
    }

    publish_event("render_template.action_view", payload)

    operations = RailsPulse::Current.rails_pulse_operations

    assert_equal 1, operations.size

    operation = operations.first

    assert_equal "template", operation[:operation_type]
    assert_equal "/app/views/users/show.html.erb", operation[:label]
    assert_operator operation[:duration], :>=, 0
  end

  test "should capture controller action operations" do
    payload = {
      controller: "UsersController",
      action: "show"
    }

    publish_event("process_action.action_controller", payload)

    operations = RailsPulse::Current.rails_pulse_operations

    assert_equal 1, operations.size

    operation = operations.first

    assert_equal "controller", operation[:operation_type]
    assert_equal "UsersController#show", operation[:label]
    assert_operator operation[:duration], :>=, 0
  end

  test "duration is clamped to zero when finish precedes start due to time travel mid-request" do
    # A host-app test that calls Timecop.freeze or travel_to after a page visit
    # but while an in-flight AJAX request is still being handled can cause the
    # process_action.action_controller notification to capture start at real
    # wall-clock time and finish at the frozen (past) time. With finish < start,
    # (finish - start) * 1000 produces a value like -99,732,412,858 ms (~3 years),
    # which overflows the duration column's numeric(15, 6) constraint (max ~10^9).
    real_time = Time.current
    past_time = real_time - 3.years

    payload = { controller: "UsersController", action: "index" }

    RailsPulse::Subscribers::OperationSubscriber.send(
      :capture_operation,
      "process_action.action_controller",
      real_time,
      past_time,
      payload,
      "controller",
      :controller
    )

    operation = RailsPulse::Current.rails_pulse_operations.first

    assert_not_nil operation
    assert_operator operation[:duration], :>=, 0,
      "Duration was #{operation[:duration]}ms — must be clamped to zero when " \
      "finish precedes start (clock moved backward via time travel mid-request)"
  end

  test "should capture partial rendering operations" do
    payload = {
      identifier: "/app/views/users/_user.html.erb"
    }

    publish_event("render_partial.action_view", payload)

    operations = RailsPulse::Current.rails_pulse_operations

    assert_equal 1, operations.size

    operation = operations.first

    assert_equal "partial", operation[:operation_type]
    assert_equal "/app/views/users/_user.html.erb", operation[:label]
  end

  test "should capture cache operations" do
    payload = {
      key: "user/123/profile"
    }

    publish_event("cache_read.active_support", payload)

    operations = RailsPulse::Current.rails_pulse_operations

    assert_equal 1, operations.size

    operation = operations.first

    assert_equal "cache_read", operation[:operation_type]
    assert_equal "user/123/profile", operation[:label]
  end

  test "should capture operations with proper metadata" do
    payload = {
      sql: "SELECT * FROM users WHERE id = ?",
      name: "User Load"
    }

    start_time = Time.current
    publish_event("sql.active_record", payload)

    operations = RailsPulse::Current.rails_pulse_operations

    assert_equal 1, operations.size

    operation = operations.first

    assert_equal "sql", operation[:operation_type]
    assert_equal "SELECT * FROM users WHERE id = ?", operation[:actual_sql]
    assert_nil operation[:label]
    assert_operator operation[:duration], :>=, 0
    assert_equal @request.id, operation[:request_id]
    assert_kind_of Float, operation[:start_time]
    assert_operator operation[:occurred_at], :>=, start_time
    assert_kind_of Time, operation[:occurred_at]
  end

  test "should not capture operations without request context" do
    RailsPulse::Current.rails_pulse_request_id = nil
    RailsPulse::Current.rails_pulse_job_run_id = nil

    payload = {
      sql: "SELECT * FROM users",
      name: "User Load"
    }

    publish_event("sql.active_record", payload)

    operations = RailsPulse::Current.rails_pulse_operations

    assert_equal 0, operations.size
  end

  test "should capture operations for background job context" do
    job_run = rails_pulse_job_runs(:mailer_run_success)

    RailsPulse::Current.rails_pulse_request_id = nil
    RailsPulse::Current.rails_pulse_job_run_id = job_run.id
    RailsPulse::Current.rails_pulse_operations = []

    payload = { sql: "SELECT 1", name: "Job SQL" }

    publish_event("sql.active_record", payload)

    operations = RailsPulse::Current.rails_pulse_operations

    assert_equal 1, operations.size
    assert_nil operations.first[:request_id]
    assert_equal job_run.id, operations.first[:job_run_id]
  end

  test "should clean SQL labels by removing Rails comments" do
    payload = {
      sql: "/*action='search',application='Dummy',controller='home'*/ SELECT * FROM users",
      name: "User Load"
    }

    publish_event("sql.active_record", payload)

    operations = RailsPulse::Current.rails_pulse_operations

    assert_not_empty operations, "Expected SQL operation to be captured"
    assert_equal "SELECT * FROM users", operations.first[:actual_sql]
    assert_nil operations.first[:label]
  end

  test "should handle HTTP client operations" do
    payload = {
      method: "GET",
      uri: "https://api.example.com/users"
    }

    publish_event("request.net_http", payload)

    operations = RailsPulse::Current.rails_pulse_operations

    assert_equal 1, operations.size

    operation = operations.first

    assert_equal "http", operation[:operation_type]
    assert_equal "GET https://api.example.com/users", operation[:label]
  end

  test "does not record HTTP operations while Rails Pulse activity is suppressed" do
    RailsPulse::Current.skip_recording_rails_pulse_activity = true

    ActiveSupport::Notifications.instrument("request.net_http", method: "GET", uri: "https://api.example.com/users") { }

    assert_empty RailsPulse::Current.rails_pulse_operations
  ensure
    RailsPulse::Current.skip_recording_rails_pulse_activity = false
  end

  test "should handle Active Job operations" do
    job_class = Class.new do
      def self.name
        "TestJob"
      end
    end

    payload = {
      job: job_class.new
    }

    publish_event("perform.active_job", payload)

    operations = RailsPulse::Current.rails_pulse_operations

    assert_equal 1, operations.size

    operation = operations.first

    assert_equal "job", operation[:operation_type]
    assert_equal "TestJob", operation[:label]
  end

  test "should handle exceptions gracefully" do
    # The subscriber should handle nil SQL gracefully and still capture it
    payload = { sql: nil, name: "User Load" }

    assert_nothing_raised do
      publish_event("sql.active_record", payload)
    end

    # Should have captured the operation even with nil SQL
    operations = RailsPulse::Current.rails_pulse_operations

    assert_equal 1, operations.size
    operation = operations.first

    assert_nil operation[:actual_sql]
    assert_nil operation[:label]
  end

  test "should capture start time and occurred_at" do
    payload = {
      sql: "SELECT * FROM users",
      name: "User Load"
    }

    start_time = Time.current
    publish_event("sql.active_record", payload)

    operations = RailsPulse::Current.rails_pulse_operations
    operation = operations.first

    assert_kind_of Float, operation[:start_time]
    assert_kind_of Time, operation[:occurred_at]
    assert_operator operation[:occurred_at], :>=, start_time
  end

  # row_count Tests

  test "captures row_count from SQL payload" do
    payload = { sql: "SELECT * FROM users", name: "User Load", row_count: 42 }

    publish_event("sql.active_record", payload)

    operation = RailsPulse::Current.rails_pulse_operations.first

    assert_equal 42, operation[:row_count]
  end

  test "row_count is nil when not present in SQL payload" do
    payload = { sql: "SELECT * FROM users", name: "User Load" }

    publish_event("sql.active_record", payload)

    operation = RailsPulse::Current.rails_pulse_operations.first

    assert_nil operation[:row_count]
  end

  test "row_count zero is captured correctly" do
    payload = { sql: "SELECT * FROM users WHERE id = 99999", name: "User Load", row_count: 0 }

    publish_event("sql.active_record", payload)

    operation = RailsPulse::Current.rails_pulse_operations.first

    assert_equal 0, operation[:row_count]
  end

  test "non-SQL operations do not have row_count" do
    payload = { identifier: "/app/views/users/index.html.erb" }

    publish_event("render_template.action_view", payload)

    operation = RailsPulse::Current.rails_pulse_operations.first

    assert_equal "template", operation[:operation_type]
    assert_nil operation[:row_count]
  end

  # cache_hit Tests

  test "captures cache_hit true when cache read hits" do
    payload = { key: "users/count", hit: true }

    publish_event("cache_read.active_support", payload)

    operation = RailsPulse::Current.rails_pulse_operations.first

    assert_equal "cache_read", operation[:operation_type]
    assert operation[:cache_hit]
  end

  test "captures cache_hit false when cache read misses" do
    payload = { key: "users/count", hit: false }

    publish_event("cache_read.active_support", payload)

    operation = RailsPulse::Current.rails_pulse_operations.first

    refute operation[:cache_hit]
  end

  test "cache_hit is nil when not present in cache_read payload" do
    payload = { key: "users/count" }

    publish_event("cache_read.active_support", payload)

    operation = RailsPulse::Current.rails_pulse_operations.first

    assert_nil operation[:cache_hit]
  end

  test "cache_write operations do not have cache_hit" do
    payload = { key: "users/count" }

    publish_event("cache_write.active_support", payload)

    operation = RailsPulse::Current.rails_pulse_operations.first

    assert_equal "cache_write", operation[:operation_type]
    assert_nil operation[:cache_hit]
  end

  # extra: merge Tests

  test "extra data is merged into operation for SQL" do
    payload = { sql: "SELECT 1", name: "Test", row_count: 5 }

    publish_event("sql.active_record", payload)

    operation = RailsPulse::Current.rails_pulse_operations.first

    assert_equal 5, operation[:row_count]
    assert_equal "sql", operation[:operation_type]
    assert_operator operation[:duration], :>=, 0
  end

  test "extra data does not overwrite core operation fields" do
    original = RailsPulse.configuration.capture_actual_sql
    RailsPulse.configuration.capture_actual_sql = true

    payload = { sql: "SELECT * FROM users", name: "User Load", row_count: 10 }

    publish_event("sql.active_record", payload)

    operation = RailsPulse::Current.rails_pulse_operations.first

    assert_equal "sql", operation[:operation_type]
    assert_equal "SELECT * FROM users", operation[:actual_sql]
    assert_nil operation[:label]
    assert_equal @request.id, operation[:request_id]
  ensure
    RailsPulse.configuration.capture_actual_sql = original
  end

  test "actual_sql is captured in memory even when capture_actual_sql is disabled" do
    original = RailsPulse.configuration.capture_actual_sql
    RailsPulse.configuration.capture_actual_sql = false

    payload = { sql: "SELECT * FROM users", name: "User Load" }

    publish_event("sql.active_record", payload)

    operation = RailsPulse::Current.rails_pulse_operations.first

    assert_equal "sql", operation[:operation_type]
    # actual_sql is always captured in memory (needed for query normalization
    # in Operation.persist_bulk). It is cleared at persistence time when
    # capture_actual_sql is false.
    assert_equal "SELECT * FROM users", operation[:actual_sql]
  ensure
    RailsPulse.configuration.capture_actual_sql = original
  end
  private

  # Deliver an event with a fixed 5 ms duration. Instrumenting a block around
  # sleep made every test wait on the clock and only proved the duration was
  # non-negative; a published event proves the subscriber records what it was
  # given.
  def publish_event(name, payload, duration: 0.005)
    started = Time.current
    ActiveSupport::Notifications.publish(name, started, started + duration, SecureRandom.hex(5), payload)
  end
end
