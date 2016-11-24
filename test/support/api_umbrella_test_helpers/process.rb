require "ipaddr"

module ApiUmbrellaTestHelpers
  class Process
    EMBEDDED_ROOT = File.join(API_UMBRELLA_SRC_ROOT, "build/work/stage/opt/api-umbrella/embedded").freeze
    CONFIG_PATH = File.join(API_UMBRELLA_SRC_ROOT, "config/test.yml").freeze
    CONFIG_OVERRIDES_PATH = "/tmp/integration_test_suite_overrides.yml".freeze
    CONFIG = "#{CONFIG_PATH}:#{CONFIG_OVERRIDES_PATH}".freeze
    @@incrementing_unique_ip_addr = IPAddr.new("200.0.0.1")

    def self.start
      Minitest.after_run do
        ApiUmbrellaTestHelpers::Process.stop
      end

      start_time = Time.now.utc
      FileUtils.rm_rf("/tmp/api-umbrella-test")
      FileUtils.mkdir_p("/tmp/api-umbrella-test/var/log")

      Bundler.with_clean_env do
        $config = YAML.load_file(File.join(API_UMBRELLA_SRC_ROOT, "config/test.yml"))
        File.write(CONFIG_OVERRIDES_PATH, YAML.dump({ "version" => 0 }))

        build = ChildProcess.build("make")
        build.io.inherit!
        build.cwd = API_UMBRELLA_SRC_ROOT
        build.start
        build.wait
        if(build.crashed?)
          exit build.exit_code
        end

        progress = Thread.new do
          print "Waiting for api-umbrella to start..."
          loop do
            print "."
            sleep 2
          end
        end

        # Spin up API Umbrella and the embedded databases as a background
        # process.
        $api_umbrella_process = ChildProcess.build(File.join(API_UMBRELLA_SRC_ROOT, "bin/api-umbrella"), "run")
        $api_umbrella_process.io.inherit!
        $api_umbrella_process.environment["API_UMBRELLA_EMBEDDED_ROOT"] = EMBEDDED_ROOT
        $api_umbrella_process.environment["API_UMBRELLA_CONFIG"] = CONFIG
        $api_umbrella_process.leader = true
        $api_umbrella_process.start

        # Run the health command to wait for API Umbrella to fully startup.
        health = ChildProcess.build(File.join(API_UMBRELLA_SRC_ROOT, "bin/api-umbrella"), "health", "--wait-for-status", "green", "--wait-timeout", "90")
        health.io.inherit!
        health.environment["API_UMBRELLA_EMBEDDED_ROOT"] = EMBEDDED_ROOT
        health.environment["API_UMBRELLA_CONFIG"] = CONFIG
        health.start
        health.wait

        progress.exit

        end_time = Time.now.utc
        puts format("(%.2fs)", end_time - start_time)

        # If anything exited unsuccessfully, abort tests.
        if(health.crashed? || $api_umbrella_process.crashed?)
          raise "Did not start api-umbrella process for integration tests"
        end

        runtime_config_path = File.join($config["root_dir"], "var/run/runtime_config.yml")
        unless(File.exist?(runtime_config_path))
          raise "runtime_config.yml file not found after starting: #{runtime_config_path.inspect}"
        end
        $config = YAML.load_file(runtime_config_path)
      end
    rescue Exception => e # rubocop:disable Lint/RescueException
      self.stop
      raise e
    end

    def self.stop
      if($api_umbrella_process && $api_umbrella_process.alive?)
        puts "Stopping api-umbrella..."

        begin
          stop = ChildProcess.build(File.join(API_UMBRELLA_SRC_ROOT, "bin/api-umbrella"), "stop")
          stop.io.inherit!
          stop.environment["API_UMBRELLA_EMBEDDED_ROOT"] = EMBEDDED_ROOT
          stop.environment["API_UMBRELLA_CONFIG"] = CONFIG
          stop.start
          stop.wait
        ensure
          $api_umbrella_process.stop
        end
      end
    end

    def self.reload(flag)
      reload = ChildProcess.build(*[File.join(API_UMBRELLA_SRC_ROOT, "bin/api-umbrella"), "reload", flag].compact)
      reload.io.inherit!
      reload.environment["API_UMBRELLA_EMBEDDED_ROOT"] = EMBEDDED_ROOT
      reload.environment["API_UMBRELLA_CONFIG"] = CONFIG
      reload.start
      reload.wait
    end

    def self.wait_for_config_version(field, version, config = {})
      state = nil
      health = nil
      begin
        Timeout.timeout(10) do
          loop do
            state = self.fetch("http://127.0.0.1:9080/api-umbrella/v1/state?#{rand}", config)
            if(state[field] == version)
              health = self.fetch("http://127.0.0.1:9080/api-umbrella/v1/health?#{rand}", config)
              if(health["status"] == "green")
                break
              end
            end

            sleep 0.1
          end
        end
      rescue Timeout::Error
        raise Timeout::Error, "API Umbrella configuration changes were not detected. Waiting for version #{version}. Last seen: #{state.inspect} #{health.inspect}"
      end
    end

    def self.fetch(url, config)
      http_opts = {}

      # If we're performing global rate limit tests, use a different IP address
      # for each internal API request when trying to determine if the config is
      # published. This prevents us from accidentally hitting these global rate
      # limits in our rapid polling requests to determine if things are ready.
      if(config && config["router"] && config["router"]["global_rate_limits"])
        @@incrementing_unique_ip_addr = @@incrementing_unique_ip_addr.succ
        http_opts.deep_merge!({
          :headers => {
            "X-Forwarded-For" => @@incrementing_unique_ip_addr.to_s,
          },
        })
      end

      response = Typhoeus.get(url, http_opts)
      begin
        data = MultiJson.load(response.body)
      rescue MultiJson::ParseError => e
        raise MultiJson::ParseError, "#{e.message}: #{url} failure (#{response.code}): #{response.body}"
      end

      data
    end
  end
end
