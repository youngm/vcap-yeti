require "cfoundry"
require "rest-client"

module BVT::Harness
  class App
    attr_reader :name, :manifest

    def initialize(app, session, domain=nil)
      @app      = app
      @name     = @app.name
      @session  = session
      @client   = @session.client
      @log      = @session.log
      @domain   = domain
    end

    def inspect
      "#<BVT::Harness::App '#@name' '#@manifest'>"
    end

    def guid
      @app.guid
    end

    def push(services = nil, appid = nil, need_check = true, no_start = false)
      load_manifest(appid)
      @app = @session.client.app_by_name(@name)
      if @app
        sync_app(@app, @manifest['path'])
        restart(need_check) if (@app.started? && (no_start == false))
      else
        create_app(@name, @manifest['path'], services, need_check, no_start)
      end
    end

    def delete
      @log.info("Delete App: #{@app.name}")
      begin
        @app.routes.each do |r|
          @log.debug("Delete route #{r.name} from app: #{@app.name}")
          r.delete!
        end
        @app.delete! :recursive => true
      rescue Exception
        @log.error "Delete App: #{@app.name} failed. "
        raise
      end
    end

    def routes
      begin
        @app.routes
      rescue Exception
        @log.error "Get routes failed. App: #{@app.name}"
        raise
      end
    end

    def update!
      @log.info("Update App: #{@app.name}")

      begin
        @app.update!(&staging_callback)
      rescue Exception => e
        @log.error "Update App: #{@app.name} failed.\n#{e.to_s}\n#{@session.print_client_logs}"
        raise
      end
    end

    def restart(need_check = true)
      stop
      start(need_check = true)
    end

    def stop
      unless @app.exists?
        @log.error "Application: #{@app.name} does not exist!"
        raise RuntimeError, "Application: #{@app.name} does not exist!"
      end

      unless @app.stopped?
        @log.info "Stop App: #{@app.name}"
        begin
          @app.stop!
        rescue
          @log.error "Stop App: #{@app.name} failed.\n#{@session.print_client_logs}"
          raise
        end
      end
    end

    def start(need_check = true, &blk)
      unless @app.exists?
        @log.error "Application: #{@app.name} does not exist!"
        raise
      end

      unless @app.running?
        @log.info "Start App: #{@app.name}"
        timeout_retries_remaining = 5

        begin
          @app.start!(&staging_callback(blk))

        # When ccng/dea_ng are overloaded app staging will result
        # in nginx cutting off api request. Goal here is to make
        # tests resilient to such failure; however, we want to
        # report such failures at the end.
        rescue CFoundry::Timeout => e
          @log.error("Timed out: #{e}")
          timeout_retries_remaining -= 1
          timeout_retries_remaining > 0 ? retry : raise

        rescue Exception => e
          # Use e.inspect to capture both message and error class
          msg = <<-MSG.gsub(/^\s+/, "")
            Start App: #{@app.name} failed.
            #{e.inspect}
            #{@session.print_client_logs}
          MSG
          @log.error(msg)
          raise
        end

        check_application if need_check
      end
    end

    def bind(service, restart_app = true)
      unless @session.services.collect(&:name).include?(service.name)
        @log.error("Fail to find service: #{service.name}")
        raise RuntimeError, "Fail to find service: #{service.name}"
      end
      begin
        @log.info("Application: #{@app.name} bind Service: #{service.name}")
        @app.bind(service.instance)
      rescue Exception => e
        @log.error("Fail to bind Service: #{service.name} to Application:" +
                       " #{@app.name}\n#{e.to_s}")
        raise
      end
      restart if restart_app
    end

    def unbind(service, restart_app = true)
      unless @app.services.collect(&:name).include?(service.name)
        @log.error("Fail to find service: #{service.name} binding to " +
                       "application: #{@app.name}")
        raise RuntimeError, "Fail to find service: #{service.name} binding to " +
            "application: #{@app.name}"
      end

      begin
        @log.info("Application: #{@app.name} unbind Service: #{service.name}")
        @app.unbind(service.instance)
        restart if restart_app
      rescue
        @log.error("Fail to unbind service: #{service.name} for " +
                       "application: #{@app.name}")
        raise
      end
    end

    def stats
      unless @app.exists?
        @log.error "Application: #{@app.name} does not exist!"
        raise RuntimeError, "Application: #{@app.name} does not exist!"
      end

      begin
        @log.info("Display application: #{@app.name} status")
        @app.stats
      rescue CFoundry::StatsError
	      "Application #{@app.name} is not running."
      end
    end

    def map(url)
      @log.info("Map URL: #{url} to Application: #{@app.name}.")
      simple = url.sub(/^https?:\/\/(.*)\/?/i, '\1')
      begin
        host, domain_name = simple.split(".", 2)

        domain = @session.current_space.domain_by_name(domain_name, :depth => 0)

        unless domain
          @log.error("Invalid domain '#{domain_name}, please check your input url: #{url}")
          raise RuntimeError, "Invalid domain '#{domain_name}, please check your input url: #{url}"
        end

        route = @session.client.routes_by_host(host, :depth => 0).find do |r|
          r.domain == domain
        end

        unless route
          route = @session.client.route
          route.host = host
          route.domain = domain
          route.space = @session.current_space
          route.create!
        end

        @log.debug("Binding #{simple} to application: #{@app.name}")
        @app.add_route(route)
      rescue Exception => e
        @log.error("Fail to map url: #{simple} to application: #{@app.name}!\n#{e.to_s}")
        raise
      end

      @log.debug("Application: #{@app.name}, URLs: #{@app.urls}")

    end

    def unmap(url, options={})
      @log.info("Unmap URL: #{url} to Application: #{@app.name}")
      simple = url.sub(/^https?:\/\/(.*)\/?/i, '\1')
      begin
        host, domain_name = simple.split(".", 2)

        # New routes might have been added!
        @app.invalidate!

        route = @app.routes.find do |r|
          r.host == host && r.domain.name == domain_name
        end

        unless route
          @log.error("Invalid route '#{simple}', please check your input url: #{url}")
          raise RuntimeError, "Invalid route '#{simple}', please check your input url: #{url}"
        end

        @log.debug("Removing route #{simple}")
        @app.remove_route(route)
        route.delete! if options[:delete]
      rescue Exception => e
        @log.error("Fail to unmap url: #{simple} to application: #{@app.name}!\n#{e.to_s}")
        raise
      end
      @log.debug("Application: #{@app.name}, URLs: #{@app.urls}")
    end

    def urls
      @log.debug("List URLs: #{@app.urls} of Application: #{@app.name}")
      @app.urls
    end

    def files(path)
      unless @app.exists?
        @log.error "Application: #{@app.name} does not exist!"
        raise RuntimeError, "Application: #{@app.name} does not exist!"
      end
      begin
        @log.info("Examine an application: #{@app.name} files")
        @app.files(path)
      rescue Exception => e
        @log.error("Fail to examine an application: #{@app.name} files!\n#{e.to_s}")
        raise
      end
    end

    def file(path)
      unless @app.exists?
        @log.error "Application: #{@app.name} does not exist!"
        raise RuntimeError, "Application: #{@app.name} does not exist!"
      end
      begin
        @log.info("Examine an application: #{@app.name} file")
        @app.file(path)
      rescue Exception => e
        @log.error("Fail to examine an application: #{@app.name} file!\n#{e.to_s}")
        raise
      end
    end

    def scale(instance, memory = nil)
      unless @app.exists?
        @log.error "Application: #{@app.name} does not exist!"
        raise RuntimeError, "Application: #{@app.name} does not exist!"
      end
      begin
        @log.info("Update the instances/memory: #{instance}/#{memory} " +
                      "for Application: #{@app.name}")
        @app.total_instances = instance.to_i
        @app.memory = memory if memory
        @app.update!(&staging_callback)
      rescue
        @log.error("Fail to Update the instances/memory limit for " +
                   "Application: #{@app.name}!")
        raise
      end
    end

    def instances
      unless @app.exists?
        @log.error "Application: #{@app.name} does not exist!"
        raise RuntimeError, "Application: #{@app.name} does not exist!"
      end
      begin
        @log.debug("Get application: #{@app.name} instances list")
        @app.instances
      rescue
        @log.error("Fail to list the instances for Application: #{@app.name}!")
        raise
      end
    end

    def total_instances=(val)
      unless @app.exists?
        @log.error "Application: #{@app.name} does not exist!"
        raise RuntimeError, "Application: #{@app.name} does not exist!"
      end
      begin
        @log.debug("Set application: #{@app.name} total instances #{val}")
        @app.total_instances = val
      rescue
        @log.error("Fail to set the total instances for Application: #{@app.name}!")
        raise
      end
    end

    def total_instances
      unless @app.exists?
        @log.error "Application: #{@app.name} does not exist!"
        raise RuntimeError, "Application: #{@app.name} does not exist!"
      end
      begin
        @log.debug("Get application: #{@app.name} total instances")
        @app.total_instances
      rescue
        @log.error("Fail to get the total instances for Application: #{@app.name}!")
        raise
      end
    end

    def env
      unless @app.exists?
        @log.error "Application: #{@app.name} does not exist!"
        raise RuntimeError, "Application: #{@app.name} does not exist!"
      end
      begin
        @log.debug("Get application: #{@app.name} env")
        @app.env
      rescue
        @log.error("Fail to get the env for Application: #{@app.name}!")
        raise
      end
    end

    def env=(val)
      unless @app.exists?
        @log.error "Application: #{@app.name} does not exist!"
        raise RuntimeError, "Application: #{@app.name} does not exist!"
      end
      begin
        @log.debug("Set application: #{@app.name} env #{val}")
        @app.env = val
      rescue
        @log.error("Fail to set the env for Application: #{@app.name}!")
        raise
      end
    end

    def services
      unless @app.exists?
        @log.error "Application: #{@app.name} does not exist!"
        raise RuntimeError, "Application: #{@app.name} does not exist!"
      end
      begin
        @log.debug("Get application: #{@app.name} services list")
        @app.services
      rescue
        @log.error("Fail to list the services for Application: #{@app.name}!")
        raise
      end
    end

    # only retrieve logs of instance #0
    def logs
      unless @app.exists?
        @log.error "Application: #{@app.name} does not exist!"
        raise RuntimeError, "Application: #{@app.name} does not exist!"
      end

      begin
        instance = @app.instances[0]
        body = ""
        instance.files("logs").each do |log|
          body += instance.file(*log)
        end
      rescue Exception => e
        @log.error("Fail to get logs for Application: #{@app.name}!")
        raise
      end
      @log.debug("=============== Get Application #{@app.name}, logs contents: #{body}")
      body
    end

    def crashlogs
      @app.crashes.each do |instance|
        instance.files("logs").each do |logfile|
          content = instance.file(*logfile)
          unless content.empty?
            puts "\n======= Crashlogs: #{logfile.join("/")} ======="
            puts content
            puts "=" * 80
          end
        end
      end
    rescue CFoundry::FileError
      # Could not get crash logs
    end

    def healthy?
      h = @app.healthy?
      unless h
        sleep(0.1)
        h = @app.healthy?
      end
      h
    end

    # method should be REST method, only [:get, :put, :post, :delete] is supported
    def get_response(method, relative_path = "/", data = '', second_domain = nil, timeout = nil)
      unless [:get, :put, :post, :delete].include?(method)
        @log.error("REST method #{method} is not supported")
        raise RuntimeError, "REST method #{method} is not supported"
      end

      path = relative_path.start_with?("/") ? relative_path : "/" + relative_path

      url = get_url(second_domain) + path
      puts "request to '#{url}'"
      begin
        resource = RestClient::Resource.new(url, :timeout => timeout, :open_timeout => timeout)
        case method
          when :get
            @log.debug("Get response from URL: #{url}")
            r = resource.get
          when :put
            @log.debug("Put data: #{data} to URL: #{url}")
            r = resource.put data
          when :post
            @log.debug("Post data: #{data} to URL: #{url}")
            r = resource.post data
          when :delete
            @log.debug("Delete URL: #{url}")
            r = resource.delete
          else nil
        end
        # Time dependency
        # Some app's post is async. Sleep to ensure the operation is done.
        sleep 0.1
        return r
      rescue RestClient::Exception => e
        begin
          RestResult.new(e.http_code, e.http_body)
        rescue
          @log.error("Cannot #{method} response from/to #{url}\n#{e.to_s}")
          raise
        end
      end
    end

    def get(path, domain=nil)
      get_response(:get, path, "", domain).to_str
    end

    def load_manifest(appid = nil)
      if !@manifest || appid
        unless VCAP_BVT_APP_ASSETS.is_a?(Hash)
          @log.error("Invalid config file format, #{VCAP_BVT_APP_CONFIG}")
          raise RuntimeError, "Invalid config file format, #{VCAP_BVT_APP_CONFIG}"
        end
        appid ||= @app.name.split('-', 2).last

        unless VCAP_BVT_APP_ASSETS.has_key?(appid)
          @log.error("Cannot find application #{appid} in #{VCAP_BVT_APP_CONFIG}")
          raise RuntimeError, "Cannot find application #{appid} in #{VCAP_BVT_APP_CONFIG}"
        end

        app_manifest = VCAP_BVT_APP_ASSETS[appid].dup
        app_manifest['instances'] = 1 unless app_manifest['instances']

        unless app_manifest['path'] =~ /^\//
          app_manifest['path']      =
            File.join(File.dirname(__FILE__), "../..", app_manifest['path'])
        end

        @manifest = app_manifest
      end
    end

    def get_url(second_domain = nil)
      # URLs synthesized from app names containing '_' are not handled well
      # by the Lift framework.
      # So we used '-' instead of '_'
      # '_' is not a valid character for hostname according to RFC 822,
      # use '-' to replace it.
      second_domain = "-#{second_domain}" if second_domain
      "#{@name.gsub("_", "-")}#{second_domain}.#{@session.get_target_domain}"
    end

    def check_application
      # Wait initially since app most likely
      # will not complete staging and start under 10secs
      sleep(seconds = 10)

      until application_is_really_running?
        sleep 1
        seconds += 1

        if seconds > VCAP_BVT_APP_ASSETS['timeout_secs']
          @log.error "Application: #{@app.name} cannot be started in #{VCAP_BVT_APP_ASSETS['timeout_secs']} seconds"

          raise RuntimeError, "Application: #{@app.name} cannot be started in #{VCAP_BVT_APP_ASSETS['timeout_secs']} seconds.\n#{@session.print_client_logs}"
        end
      end
    end

    def application_is_really_running?
      instances_are_all_running? && instances_are_all_running_for_a_bit?
    end

    def instances_are_all_running_for_a_bit?
      3.times.map {
        sleep(1)
        instances_are_all_running?
      }.all?
    end

    def instances_are_all_running?
      not_staged_retry = 0
      instances = @app.instances
      states = instances.map(&:state)
      puts "       CHECKING LOG => #{states}"
      states.uniq == ["RUNNING"]
    rescue CFoundry::APIError => e
      if e.error_code != 170002
        @log.error("App failed to stage: #{e.inspect}")
        raise
      end

      # Still pending, i.e. downloading the staged app to CC. The app will start "starting" soon
      not_staged_retry += 1
      sleep 0.2
      not_staged_retry < 3 ? retry : raise
    rescue CFoundry::Timeout
      false
    end

    def sync_app(app, path)
      upload_app(app, path)

      app.memory = @manifest['memory']
      app.total_instances = @manifest['instances']
      app.command = @manifest['command']
      app.buildpack = @manifest['buildpack']
      app.env = @manifest['env'] unless @manifest['env'].nil?

      if app.changed?
        app.changes.each do |name, change|
          old, new = change
          @log.debug("Application: #{app.name}, #{name} changed: #{old} -> #{new}")
        end

        begin
          app.update!(&staging_callback)
        rescue Exception => e
          @log.error("Fail to update Application: #{app.name}\n#{e.inspect}")
          raise
        end
      end
    end

    def create_app(name, path, services, need_check, no_start = false)
      app = @session.client.app
      app.name = name
      app.space = @session.current_space if @session.current_space
      app.total_instances = @manifest['instances']
      app.production = @manifest['plan'] if @manifest['plan']

      app.command = @manifest['command']
      app.buildpack = @manifest['buildpack']
        
      app.env = @manifest['env'] unless @manifest['env'].nil?

      if @domain
        url = "#{@name}.#{@domain}"
      else
        url = get_url
      end

      @manifest['uris'] = [url,]

      app.memory = @manifest['memory']
      begin
        app.create!
      rescue Exception => e
        @log.error("Fail to create Application: #{app.name}\n#{e.inspect}")
        raise
      end

      @app = app

      map(url) if !@manifest['no_url']

      services.each { |service| bind(service, false)} if services
      upload_app(app, path)

      start(need_check) unless (no_start || @manifest["no_start"])
    end

    def upload_app(app, path)
      begin
        app.upload(path)
      rescue Exception => e
        @log.error("Fail to push/upload file path: #{path} for Application: #{app.name}\n#{e.inspect}")
        raise
      end
    end

    # TODO: maybe App#stream_update_log really just belongs on client
    def stream_log(url, &blk)
      @app.stream_update_log(url, &blk)
    end

    def events
      @app.invalidate!
      @app.events
    end

    def get_file(path, headers = {})
      url = "#{@session.api_endpoint}/v2/apps/#{@app.guid}/instances/0/files/#{path}"
      hdrs = headers.merge("AUTHORIZATION" => @session.token.auth_header)
      RestClient.get(url, hdrs)
    end

    private

    def staging_callback(blk = nil)
      proc do |url|
        next unless url

        puts "Staging #{@app.name} - #{url}"

        if blk
          blk.call(url)
        elsif url
          @app.stream_update_log(url) do |chunk|
            puts "       STAGE LOG => #{chunk}"
          end
        end
      end
    end
  end

  class RestResult
    attr_reader :code
    attr_reader :to_str

    def initialize(code, to_str)
      @code = code
      @to_str = to_str
    end
  end
end
