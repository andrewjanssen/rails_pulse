require "test_helper"

module RailsPulse
  module Middleware
    class RequestCollectorAdapterTest < ActionDispatch::IntegrationTest
      setup do
        @original_async = RailsPulse.configuration.async
        @original_request_filter = RailsPulse.configuration.request_filter
        @original_store_full_details = RailsPulse.configuration.store_full_details
        RailsPulse.configuration.async = false  # Use sync mode for tests
      end

      teardown do
        RailsPulse.configuration.async = @original_async
        RailsPulse.configuration.request_filter = @original_request_filter
        RailsPulse.configuration.store_full_details = @original_store_full_details
        RailsPulse::Tracker.reset_rollups!
      end

      # Request Filter Tests

      test "route_pattern metadata does not change default inferred path persistence" do
        RailsPulse.configuration.request_filter = nil

        get "/privacy/records/same/same.private-marker"

        assert_response :created
        assert RailsPulse::Route.exists?(
          path: "/privacy/records/same/same.private-marker", controller_action: "home#create"
        )
        assert_not RailsPulse::Route.exists?(path: "/privacy/records/:account/:id(.:format)")
      end

      test "request_filter receives trusted route patterns for full and folded recognized paths" do
        seen = []
        RailsPulse.configuration.request_filter = ->(data) do
          seen << data.dup
          data.merge(path: data.fetch(:route_pattern))
        end
        paths = {
          "/privacy/records/same/same.private-marker" => "/privacy/records/:account/:id(.:format)",
          "/privacy/files/a/private-marker/filename.txt" => "/privacy/files/*filename(.:format)"
        }

        [ :all, { above_threshold: :slow, sample_rate_below: 0 } ].each do |setting|
          RailsPulse.configuration.store_full_details = setting
          paths.each do |path, pattern|
            get path

            assert_response :created
            assert_equal pattern, seen.last[:route_pattern]
            assert_equal "home#create", seen.last[:controller_action]
          end
        end
        RailsPulse::Tracker.flush!

        assert_equal [ nil, nil, false, false ], seen.map { |data| data[:detail] }
        paths.each_value do |pattern|
          route = RailsPulse::Route.find_by!(path: pattern, controller_action: "home#create")

          assert_equal 1, RailsPulse::Request.where(route: route).count
          assert_equal 1, RailsPulse::Rollup.find_by!(rollupable: route).count
        end
        assert_not RailsPulse::Route.where("path LIKE ?", "%private-marker%").exists?
      end

      test "request_filter receives the recognized route pattern while an exception escapes" do
        seen = nil
        RailsPulse.configuration.request_filter = ->(data) do
          seen = data
          data.merge(path: data.fetch(:route_pattern))
        end

        error = assert_raises(StandardError) { post "/privacy/errors/private-marker" }
        request = RailsPulse::Request.find_by!(request_uuid: seen[:request_uuid])

        assert_equal "Simulated error raised from test app", error.message
        assert_equal "/privacy/errors/:id(.:format)", seen[:route_pattern]
        assert_equal seen[:route_pattern], request.route.path
        assert_equal 500, request.status
        assert_not RailsPulse::Route.where("path LIKE ?", "%private-marker%").exists?
      end

      test "request_filter buckets unknown routes for full and folded requests" do
        seen = []
        RailsPulse.configuration.request_filter = ->(data) do
          seen << data.dup
          data[:path] = "/unmatched" if data[:controller_action].blank?
          data
        end

        [ :all, { above_threshold: :slow, sample_rate_below: 0 } ].each do |setting|
          RailsPulse.configuration.store_full_details = setting
          get "/private-unmatched-path"

          assert_response :not_found
        end
        RailsPulse::Tracker.flush!

        route = RailsPulse::Route.find_by!(path: "/unmatched", controller_action: nil)
        request = RailsPulse::Request.find_by!(route: route)
        rollup = RailsPulse::Rollup.find_by!(rollupable: route)

        assert_equal [ nil, false ], seen.map { |data| data[:detail] }
        assert_not seen.any? { |data| data.key?(:route_pattern) }
        assert_equal [ 404, 404 ], seen.map { |data| data[:status] }
        assert_equal 404, request.status
        assert_in_delta seen.first[:duration], request.duration, 0.001
        assert_equal 1, rollup.count
        assert_equal 1, rollup.status_4xx
        assert_in_delta seen.last[:duration], rollup.sum_duration.to_f, 0.001
        assert_not RailsPulse::Route.exists?(path: "/private-unmatched-path")
      end

      test "request_filter redacts an escaping exception request without changing its exception" do
        seen = nil
        RailsPulse.configuration.request_filter = ->(data) do
          seen = data
          data.merge(path: "/redacted-error")
        end

        error = assert_raises(StandardError) { post "/errors/raise" }
        request = RailsPulse::Request.find_by!(request_uuid: seen[:request_uuid])

        assert_equal "Simulated error raised from test app", error.message
        assert_equal "/redacted-error", request.route.path
        assert_equal "home#raise_error", request.route.controller_action
        assert_equal 500, request.status
        assert request.is_error
        assert_not RailsPulse::Route.exists?(path: "/errors/raise")
      end

      test "request_filter failure does not replace an escaping host exception or log private data" do
        output = StringIO.new
        original_logger = RailsPulse.configuration.logger
        RailsPulse.configuration.logger = Logger.new(output)
        RailsPulse.configuration.request_filter = ->(data) { raise "private-filter-error: #{data.inspect}" }

        assert_no_difference "RailsPulse::Request.count" do
          error = assert_raises(StandardError) { post "/errors/raise" }

          assert_equal "Simulated error raised from test app", error.message
        end
        assert_empty output.string
      ensure
        RailsPulse.configuration.logger = original_logger
      end

      test "middleware tracks successful requests in sync mode" do
        assert_difference -> { RailsPulse::Request.count }, 1 do
          get "/"

          assert_response :success
        end

        request = RailsPulse::Request.last

        assert_equal 200, request.status
        assert_not request.is_error, "Expected is_error to be false for 200 response"
        assert_operator request.duration, :>, 0
        assert_operator request.operations.count, :>, 0
      end

      test "middleware tracks error requests in sync mode" do
        # Need a route that raises an error - using a non-existent route
        assert_difference -> { RailsPulse::Request.count }, 1 do
          get "/nonexistent"

          assert_response :not_found
        end

        request = RailsPulse::Request.last

        assert_equal 404, request.status
      end

      test "middleware records a request whose controller raises an unhandled exception" do
        # show_exceptions is :rescuable in the dummy's test environment, so the
        # StandardError reaches the test; the request must be recorded anyway.
        assert_difference -> { RailsPulse::Request.where(status: 500).count }, 1 do
          assert_raises(StandardError) { post "/errors/raise" }
        end

        request = RailsPulse::Request.order(:id).last

        assert request.is_error
        assert_equal "home#raise_error", request.route.controller_action
      end

      test "middleware passes complete tracking data to tracker" do
        captured_data = nil
        original_method = RailsPulse::Tracker.method(:track_request)

        # Intercept the tracker's track_request to see what data it receives
        RailsPulse::Tracker.define_singleton_method(:track_request) do |data|
          captured_data = data
          original_method.call(data)
        end

        begin
          get "/"

          # Verify the middleware passed all required fields
          assert_not_nil captured_data
          assert_equal "GET", captured_data[:method]
          assert_equal "/", captured_data[:path]
          assert_kind_of Numeric, captured_data[:duration]
          assert_equal 200, captured_data[:status]
          refute captured_data[:is_error]
          assert_predicate captured_data[:request_uuid], :present?
          assert_predicate captured_data[:occurred_at], :present?
          assert_kind_of Array, captured_data[:operations]
        ensure
          # Restore original method
          RailsPulse::Tracker.define_singleton_method(:track_request, original_method)
        end
      end

      test "tracking data includes response_size_bytes" do
        captured_data = nil
        original_method = RailsPulse::Tracker.method(:track_request)

        RailsPulse::Tracker.define_singleton_method(:track_request) do |data|
          captured_data = data
          original_method.call(data)
        end

        begin
          get "/api_simple", as: :json

          assert_not_nil captured_data
          assert captured_data.key?(:response_size_bytes), "tracking data should include response_size_bytes key"
        ensure
          RailsPulse::Tracker.define_singleton_method(:track_request, original_method)
        end
      end

      test "n_plus_one detection annotates repeated sql operations" do
        captured_data = nil
        original_method = RailsPulse::Tracker.method(:track_request)

        RailsPulse::Tracker.define_singleton_method(:track_request) do |data|
          captured_data = data
          original_method.call(data)
        end

        begin
          get "/"

          assert_not_nil captured_data
          sql_ops = captured_data[:operations].select { |op| op[:operation_type] == "sql" }
          repeated = sql_ops.select { |op| op[:repetition_count] }

          if repeated.any?
            repeated.each do |op|
              assert_operator op[:repetition_count], :>=, 2
              assert_not_nil op[:repeated_query_group]
            end
          end
        ensure
          RailsPulse::Tracker.define_singleton_method(:track_request, original_method)
        end
      end

      test "persists response_size_bytes on request record" do
        get "/api_simple", as: :json

        request = RailsPulse::Request.last

        assert_not_nil request.response_size_bytes
        assert_operator request.response_size_bytes, :>, 0
      end

      test "normalizes parameterized path before storing route" do
        get "/posts/42"

        route = RailsPulse::Route.find_by(controller_action: "home#index", path: "/posts/:id")

        assert_not_nil route, "route should be stored with normalized path /posts/:id"

        raw_route = RailsPulse::Route.find_by(path: "/posts/42")

        assert_nil raw_route, "raw path /posts/42 should not be stored as a separate route"
      end

      test "stores controller_action on route in lowercase controller#action format" do
        get "/posts/42"

        route = RailsPulse::Route.find_by(controller_action: "home#index", path: "/posts/:id")

        assert_not_nil route
        assert_equal "home#index", route.controller_action
      end

      test "captures controller_action in tracking data using lowercase format" do
        captured_data = nil
        original_method = RailsPulse::Tracker.method(:track_request)

        RailsPulse::Tracker.define_singleton_method(:track_request) do |data|
          captured_data = data
          original_method.call(data)
        end

        begin
          get "/"

          assert_not_nil captured_data
          assert_equal "home#index", captured_data[:controller_action],
            "controller_action should be lowercase controller#action format"
        ensure
          RailsPulse::Tracker.define_singleton_method(:track_request, original_method)
        end
      end

      test "repeated requests to different ids share the same normalized route" do
        get "/posts/1"
        get "/posts/2"
        get "/posts/3"

        assert_equal 1, RailsPulse::Route.where("path LIKE '/posts/%'").count,
          "all /posts/:id requests should share one route record"
        assert RailsPulse::Route.exists?(controller_action: "home#index", path: "/posts/:id")
      end

      test "percent-encoded ids share the same normalized route" do
        get "/posts/a%00b"
        get "/posts/%E2%80%AEabc"
        get "/posts/caf%C3%A9"

        assert_equal [ "/posts/:id" ], RailsPulse::Route.where("path LIKE '/posts/%'").pluck(:path)
      end
    end
  end
end
