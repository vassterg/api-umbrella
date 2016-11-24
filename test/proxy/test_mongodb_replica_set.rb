require_relative "../test_helper"

class TestProxyMongodbReplicaSet < Minitest::Test
  include ApiUmbrellaTestHelpers::Setup
  include Minitest::Hooks

  def setup
    setup_server
    once_per_class_setup do
      # Setup the replica set in mongo-orchestration.
      setup_mongo_orchestration

      # Re-configure API Umbrella to use the replica set server configuration.
      mongodb_url = "mongodb://127.0.0.1:13090,127.0.0.1:13091/api_umbrella_test"
      override_config_set({
        :gatekeeper => {
          # Disable API key caching to ensure things work across replica set
          # elections without any caching.
          :api_key_cache => false,
        },
        :mongodb => {
          :url => mongodb_url,
        },
      }, "--router")

      # Reloading API Umbrella doesn't normally restart the mora process. But
      # since we've changed the MongoDB configuration, we need to force a
      # restart of the mora process too.
      output, status = Open3.capture2e("perpctl -b #{File.join($config["root_dir"], "etc/perp")} term mora")
      assert_equal(0, status, output)

      # Re-establish the mongodb connections used in the tests to point to the
      # replica set.
      refute_match(":13001", mongodb_url)
      Mongoid::Clients.disconnect
      Mongoid::Clients.clear
      Mongoid.load_configuration({
        "clients" => {
          "default" => {
            "uri" => mongodb_url,
          },
        },
      })

      # Add a backend to the database. This helps verify API Umbrella is
      # pointing to the replica set, and also ensure that there are no
      # interruptions in the database-based backend configuration during tests.
      prepend_api_backends([
        {
          :frontend_host => "127.0.0.1",
          :backend_host => "127.0.0.1",
          :servers => [{ :host => "127.0.0.1", :port => 9444 }],
          :url_matches => [{ :frontend_prefix => "/#{unique_test_class_id}/", :backend_prefix => "/" }],
        },
      ])
    end
  end

  def after_all
    super
    override_config_reset("--router")

    # After reloading API Umbrella to reset it back to it's normal state, also
    # force restart Mora.
    output, status = Open3.capture2e("perpctl -b #{File.join($config["root_dir"], "etc/perp")} term mora")
    assert_equal(0, status, output)

    # Re-establish the mongodb connections used in the tests to point to the
    # default standalone database
    assert_match(":13001", $config["mongodb"]["url"])
    Mongoid::Clients.disconnect
    Mongoid::Clients.clear
    Mongoid.load_configuration({
      "clients" => {
        "default" => {
          "uri" => $config["mongodb"]["url"],
        },
      },
    })

    # Trigger a new database configuration against the original standalone
    # database to ensure that we wait until it's fully active.
    prepend_api_backends([])
  end

  def test_no_dropped_connections_during_replica_set_elections
    # First perform a sanity check to ensure that API key caching is disabled.
    # We test this by disabling an API key and immediately expecting it to
    # return forbidden (rather than being cached and valid for a couple sends).
    # We want to ensure key caching is disabled to ensure database connectivity
    # works across replica set elections (and things aren't just being cached).
    user = FactoryGirl.create(:api_user)
    response = Typhoeus.get("http://127.0.0.1:9080/#{unique_test_class_id}/hello?#{rand}", keyless_http_options.deep_merge({
      :headers => { "X-Api-Key" => user.api_key },
    }))
    assert_equal(200, response.code, response.body)
    user.disabled_at = Time.now.utc
    user.save!
    response = Typhoeus.get("http://127.0.0.1:9080/#{unique_test_class_id}/hello?#{rand}", keyless_http_options.deep_merge({
      :headers => { "X-Api-Key" => user.api_key },
    }))
    assert_equal(403, response.code, response.body)

    # Perform parallel requests constantly in the background of this tests.
    # This ensures that no connections are dropped during any point of the
    # replica set changes we'll make later on.
    request_thread = Thread.new do
      user = FactoryGirl.create(:api_user, {
        :settings => {
          :rate_limit_mode => "unlimited",
        },
      })

      loop do
        hydra = Typhoeus::Hydra.new(:max_concurrency => 5)
        10000.times do
          request = Typhoeus::Request.new("http://127.0.0.1:9080/#{unique_test_class_id}/hello?#{rand}", keyless_http_options.deep_merge({
            :headers => { "X-Api-Key" => user.api_key },
          }))
          request.on_complete do |resp|
            assert_equal(200, resp.code, resp.body)
          end
          hydra.queue(request)
        end
        hydra.run
      end
    end

    # Detect the initial primary server in the replica set.
    wait_for_primary_change

    # Wait to ensure we perform some successful tests before beginning our
    # replica set changes.
    wait_for_num_tests(100)

    # Force a change in the replica set primary by downgrading the priority of
    # the current primary.
    mongo_orchestration(:patch, "/v1/replica_sets/test-cluster/members/#{@initial_primary_replica_id}", {
      :rsParams => { :priority => 0.01 },
    })

    # Ensure the replica set primary did in fact change.
    wait_for_primary_change

    # Ensure we perform a number of tests against the new primary.
    wait_for_num_tests(100)

    # Force another change in the replica set primary by stopping the current
    # primary.
    mongo_orchestration(:post, "/v1/servers/#{@current_primary_server_id}", {
      :action => "stop",
    })

    # Ensure the replica set primary did in fact change.
    wait_for_primary_change

    # Ensure we perform a number of tests against the new primary.
    wait_for_num_tests(100)

    # Reset the MongoDB replica set back to the normal state after the tests are
    # finished, so we don't leave it in a strange state for subsequent tests.
    mongo_orchestration(:post, "/v1/replica_sets/test-cluster", {
      :action => "reset",
    })
    mongo_orchestration(:patch, "/v1/replica_sets/test-cluster/members/#{@initial_primary_replica_id}", {
      :rsParams => { :priority => 99 },
    })

    request_thread.exit
  end

  private

  def wait_for_primary_change
    Timeout.timeout(15) do
      loop do
        data = mongo_orchestration(:get, "/v1/replica_sets/test-cluster/primary")

        if(!@initial_primary_replica_id)
          @initial_primary_replica_id = data["_id"]
        end

        if(data["server_id"] != @current_primary_server_id)
          @current_primary_server_id = data["server_id"]
          @current_primary_replica_id = data["_id"]

          break
        end

        sleep 0.1
      end
    end
  rescue Timeout::Error
    raise Timeout::Error, "MongoDB primary server change not detected"
  end

  # In addition to the background requests being made throughout the replica
  # set changes, also ensure we can make a fixed number of tests after a
  # replica set change has been detected. This is to ensure that requests don't
  # just slow down during replica set changes (in which case the background
  # requests might not end up performing many requests).
  def wait_for_num_tests(count)
    user = FactoryGirl.create(:api_user, {
      :settings => {
        :rate_limit_mode => "unlimited",
      },
    })

    hydra = Typhoeus::Hydra.new(:max_concurrency => 5)
    count.times do
      request = Typhoeus::Request.new("http://127.0.0.1:9080/#{unique_test_class_id}/hello?#{rand}", keyless_http_options.deep_merge({
        :headers => { "X-Api-Key" => user.api_key },
      }))
      request.on_complete do |response|
        assert_equal(200, response.code, response.body)
      end
      hydra.queue(request)
    end
    hydra.run
  end

  def mongo_orchestration(http_method, path, data = {})
    http_opts = http_options.merge(:method => http_method)
    if(data.present?)
      http_opts.deep_merge!({
        :headers => { "Content-Type" => "application/json" },
        :body => MultiJson.dump(data),
      })
    end

    response = Typhoeus::Request.new("http://127.0.0.1:13089#{path}", http_opts).run
    assert_equal(200, response.code, response.body)
    assert_equal("application/json", response.headers["content-type"])

    MultiJson.load(response.body)
  end

  def setup_mongo_orchestration
    # First wait for mongo-orchestration to get started.
    begin
      Timeout.timeout(15) do
        loop do
          response = Typhoeus.get("http://127.0.0.1:13089/", http_options)
          if(response.code == 200)
            break
          end

          sleep 0.1
        end
      end
    rescue Timeout::Error
      raise Timeout::Error, "mongo-orchestration did not start"
    end

    # Once started, send our config file to configure the replica set for
    # testing.
    mongo_orchestration(:put, "/v1/replica_sets/test-cluster", MultiJson.load(File.read(File.join(API_UMBRELLA_SRC_ROOT, "test/legacy/config/mongo-orchestration.json"))))
  end
end
