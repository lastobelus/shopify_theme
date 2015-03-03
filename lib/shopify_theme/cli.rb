require 'thor'
require 'yaml'
YAML::ENGINE.yamler = 'syck' if defined? Syck
require 'abbrev'
require 'base64'
require 'fileutils'
require 'json'
require 'filewatcher'
require 'launchy'
require 'mimemagic'

module ShopifyTheme
  EXTENSIONS = [
    {mimetype: 'application/x-liquid', extensions: %w(liquid), parents: 'text/plain'},
    {mimetype: 'application/json', extensions: %w(json), parents: 'text/plain'},
    {mimetype: 'application/js', extensions: %w(map), parents: 'text/plain'},
    {mimetype: 'application/vnd.ms-fontobject', extensions: %w(eot)},
    {mimetype: 'image/svg+xml', extensions: %w(svg svgz)}
  ]

  def self.configureMimeMagic
    ShopifyTheme::EXTENSIONS.each do |extension|
      MimeMagic.add(extension.delete(:mimetype), extension)
    end
  end

  class Cli < Thor
    include Thor::Actions

    IGNORE = %w(config.yml)
    DEFAULT_WHITELIST = %w(layout/ assets/ config/ snippets/ templates/ locales/)
    TIMEFORMAT = "%H:%M:%S"
    PADDING = 15
    tasks.keys.abbrev.each do |shortcut, command|
      map shortcut => command.to_sym
    end

    class_option :environment, type: :string, default: 'development', desc: "which config environment to use"
    class_option :config_path, type: :string, default: 'config.yml', desc: "path to a configuration file"

    def initialize(*args)
      super
      @config = ShopifyTheme::Config.new(path: options[:config_path], environment: options[:environment])
      ShopifyTheme.config = @config
    end
    
    desc "check", "check configuration"
    def check
      if ShopifyTheme.check_config
        say("✅  Configuration [OK]", :green)
      else
        say("❌  Configuration [FAIL]", :red)
      end
    end

    desc "configure API_KEY PASSWORD STORE THEME_ID", "generate a config file for the store to connect to"
    def configure(api_key=nil, password=nil, store=nil, theme_id=nil)
      config = {:api_key => api_key, :password => password, :store => store, :theme_id => theme_id}
      create_file('config.yml', config.to_yaml)
    end

    desc "bootstrap API_KEY PASSWORD STORE THEME_NAME", "bootstrap with Timber to shop and configure local directory."
    method_option :master, :type => :boolean, :default => false
    method_option :version, :type => :string, :default => "latest"
    def bootstrap(api_key=nil, password=nil, store=nil, theme_name=nil)
      ShopifyTheme.config = {:api_key => api_key, :password => password, :store => store}

      theme_name ||= 'Timber'
      say_status(:registering, "#{theme_name} theme on #{store}")
      theme = ShopifyTheme.upload_timber(theme_name, options[:version])

      say_status(:creating,  "directory named #{theme_name}")
      empty_directory(theme_name)

      say_status(:saving, "configuration to #{theme_name}")
      ShopifyTheme.config.merge!(theme_id: theme['id'])
      create_file("#{theme_name}/config.yml", ShopifyTheme.config.to_yaml)

      say_status(:downloading, "#{theme_name} assets from Shopify")
      Dir.chdir(theme_name)
      download()
    rescue Releases::VersionError => e
      say(e.message, :red)
    end

    desc "download FILE", "download the shops current theme assets"
    method_option :quiet, :type => :boolean, :default => false
    method_option :exclude
    def download(*keys)
      assets = keys.empty? ? ShopifyTheme.asset_list : keys

      if options['exclude']
        assets = assets.delete_if { |asset| asset =~ Regexp.new(options['exclude']) }
      end

      assets.each do |asset|
        download_asset(asset)
        say_status(:downloaded, asset, quiet: quiet)
      end
      say("Done.", :green) unless options['quiet']
    end

    desc "open", "open the store in your browser"
    def open(*keys)
      if Launchy.open shop_theme_url
        say("Done.", :green)
      end
    end

    desc "upload FILE", "upload all theme assets to shop"
    method_option :quiet, :type => :boolean, :default => false
    def upload(*keys)
      assets = keys.empty? ? local_assets_list : keys
      assets.each do |asset|
        send_asset(asset, options['quiet'])
      end
      say("Done.", :green) unless options['quiet']
    end

    desc "update_since_sha [SHA1]", "sends all the files that have been changed since the specified commit."
    def update_since_sha(sha='')
      check_for_git
      changed_assets = `git diff --name-only #{sha}`
      changed_assets.lines.each do |asset|
        asset.chomp!
        next unless local_assets_list.include?(asset)
        send_asset(asset, options['quiet'])
      end
      invoke :update_git_version, []
      say("Done.", :green) unless options['quiet']
    end
    
    desc "update_git_version", "posts the current sha to the theme in snippets/git_version.liquid"
    def update_git_version
      check_for_git
      template = config[:git_version_template]
      template ||= <<-EOS
<!-- 
###CURRENTCHANGES###
--------
###GITVERSION###
-->
      EOS
      asset = options[:git_version_asset] || 'snippets/git_version.liquid'
      
      git_version = template.gsub('###GITVERSION###', `git log -1`).gsub('###CURRENTCHANGES###', `git status -s`)
      File.open(asset, 'w') {|f| f.write(git_version) }
      send_asset(asset, options['quiet'])
      say("Done.", :green) unless options['quiet']
    end

    desc "replace FILE", "completely replace shop theme assets with local theme assets"
    method_option :quiet, :type => :boolean, :default => false
    def replace(*keys)
      say("Are you sure you want to completely replace your shop theme assets? This is not undoable.", :yellow)
      if ask("Continue? (Y/N): ") == "Y"
        # only delete files on remote that are not present locally
        # files present on remote and present locally get overridden anyway
        remote_assets = keys.empty? ? (ShopifyTheme.asset_list - local_assets_list) : keys
        remote_assets.each do |asset|
          delete_asset(asset, options['quiet']) unless ShopifyTheme.ignore_files.any? { |regex| regex =~ asset }
        end
        local_assets = keys.empty? ? local_assets_list : keys
        local_assets.each do |asset|
          send_asset(asset, options['quiet'])
        end
        say("Done.", :green) unless options['quiet']
      end
    end

    desc "remove FILE", "remove theme asset"
    method_option :quiet, :type => :boolean, :default => false
    def remove(*keys)
      keys.each do |key|
        delete_asset(key, options['quiet'])
      end
      say("Done.", :green) unless options['quiet']
    end

    desc "watch", "upload and delete individual theme assets as they change, use the --keep_files flag to disable remote file deletion"
    method_option :quiet, :type => :boolean, :default => false
    method_option :keep_files, :type => :boolean, :default => false
    def watch
      say("\n"+"🔍   #{options[:environment]}  🔍".center(60), :cyan, :bold)
      say("\n"+"Watching " + set_color(Dir.pwd, :black, :bold))
      watcher do |filename, event|
        filename = filename.gsub("#{Dir.pwd}/", '')

        next unless (event == :delete) || local_assets_list.include?(filename)
        action = if [:changed, :new].include?(event)
          :send_asset
        elsif event == :delete
          :delete_asset
        else
          raise NotImplementedError, "Unknown event -- #{event} -- #{filename}"
        end

        send(action, filename, options['quiet'])
      end
    end

    desc "systeminfo", "print out system information and actively loaded libraries for aiding in submitting bug reports"
    def systeminfo
      ruby_version = "#{RUBY_VERSION}"
      ruby_version += "-p#{RUBY_PATCHLEVEL}" if RUBY_PATCHLEVEL
      puts "Ruby: v#{ruby_version}"
      puts "Operating System: #{RUBY_PLATFORM}"
      %w(Thor Listen HTTParty Launchy).each do |lib|
        require "#{lib.downcase}/version"
        puts "#{lib}: v" +  Kernel.const_get("#{lib}::VERSION")
      end
    end

    desc "test_say_status", "test the output command"
    def test_say_status(what)
      show_during(:uploading, what) do
        sleep 1
      end
      say_status(:uploaded, what)
      show_during(:removing, what) do
        sleep 1
      end
      say_status(:removed, what)
      show_during(:downloading, what) do
        sleep 1
      end
      say_status(:downloaded, what)
      say_status(:error, what)
      say_status(:error, what)
      report_error("Could not upload #{what}", details:"because of some reasons", time:Time.now)
      report_warning("there should be", "three lines of", "yellow warnings")
      say_status(:unknown, "some stuff")
      say_status(:registering, "a theme on the store")
      say_status(:saving, "a thingy")
    end
    protected

    def config
      @config ||= ShopifyTheme::Config.new(path: options[:config_path], environment: options[:environment])
    end

    def shop_theme_url
      url = config[:store]
      url += "?preview_theme_id=#{config[:theme_id]}" if config[:theme_id] && config[:theme_id].to_i > 0
      url
    end

    private

    def watcher
      FileWatcher.new(Dir.pwd).watch() do |filename, event|
        yield(filename, event)
      end
    end

    def local_assets_list
      local_files.reject do |p|
        @permitted_files ||= (DEFAULT_WHITELIST | ShopifyTheme.whitelist_files).map{|pattern| Regexp.new(pattern)}
        @permitted_files.none? { |regex| regex =~ p } || ShopifyTheme.ignore_files.any? { |regex| regex =~ p }
      end
    end

    def local_files
      Dir.glob(File.join('**', '*')).reject do |f|
        File.directory?(f)
      end
    end

    def download_asset(key)
      return unless valid?(key)
      notify_and_sleep("Approaching limit of API permits. Naptime until more permits become available!") if ShopifyTheme.needs_sleep?
      asset = ShopifyTheme.get_asset(key)
      if asset['value']
        # For CRLF line endings
        content = asset['value'].gsub("\r", "")
        format = "w"
      elsif asset['attachment']
        content = Base64.decode64(asset['attachment'])
        format = "w+b"
      end

      FileUtils.mkdir_p(File.dirname(key))
      File.open(key, format) {|f| f.write content} if content
    end

    def send_asset(asset, quiet=false)
      return unless valid?(asset)
      data = {:key => asset}
      content = File.read(asset)
      if binary_file?(asset) || ShopifyTheme.is_binary_data?(content)
        content = File.open(asset, "rb") { |io| io.read }
        data.merge!(:attachment => Base64.encode64(content))
      else
        data.merge!(:value => content)
      end

      response = show_during(:uploading, asset, quiet:quiet) do
        ShopifyTheme.send_asset(data)
      end
      if response.success?
        say_status(:uploaded, asset) unless quiet
      else
        report_error("Could not upload #{asset}", response:response, time:Time.now)
      end
    end

    def delete_asset(key, quiet=false)
      return unless valid?(key)
      response = show_during(:removing, key, quiet:quiet) do
        ShopifyTheme.delete_asset(key)
      end
      if response.success?
        say_status(:removed, key, quiet: quiet)
      else
        report_error("Could not remove #{key}", response:response, time:Time.now)
      end
    end

    def notify_and_sleep(message)
      say(message, :red)
      ShopifyTheme.sleep
    end

    def valid?(key)
      return true if DEFAULT_WHITELIST.include?(key.split('/').first + "/")
      report_warning("'#{key}' is not in a valid file for theme uploads.",
        "Files need to be in one of the following subdirectories:", *DEFAULT_WHITELIST)
      false
    end

    def binary_file?(path)
      mime = MimeMagic.by_path(path)
      say("'#{path}' is an unknown file-type, uploading asset as binary", :yellow) if mime.nil? && ENV['TEST'] != 'true'
      mime.nil? || !mime.text?
    end

    def report_error(message, response:nil, details:nil, time:Time.now)
      say_status(:error, message, time:time, quiet:false)
      say(set_color(" "*23+"Details".rjust(PADDING), :yellow) + divr + details) if details
      say(set_color(" "*23+"Response:".rjust(PADDING), :yellow) + divr + errors_from_response(response)) if response
    end

    def report_warning(*msg)
      msg = [msg].flatten
      say_status(:warning, msg.shift)
      msg.each do |m|
        say(" "*(PADDING+23) + divr + m)
      end
    end

    def errors_from_response(response)
      object = {status: response.headers['status'], request_id: response.headers['x-request-id']}

      errors = response.parsed_response ? response.parsed_response["errors"] : response.body

      object[:errors] = case errors
                        when NilClass
                          ''
                        when String
                          errors.strip
                        else
                          errors.values.join(", ")
                        end
      object.delete(:errors) if object[:errors].length <= 0
      object
    end

    def show_during(verb, message = '', quiet:false, &block)
      message_during = status_line(verb, message + '...')
      print(message_during) unless quiet
      result = yield
      print("\r#{' ' * message_during.length}\r") unless quiet
      result
    end

    def timestamp(time = Time.now)
      time.strftime(TIMEFORMAT)
    end
    
    def say_status(verb, msg, time:Time.now, quiet:false)
      say status_line(verb, msg, time:time) unless quiet
    end
    
    def divr
      set_color(' | ', :black)
    end
    
    def status_line(verb, msg, time:Time.now)
      env =  set_color(" #{options[:environment]}", :black)
      verbstr = verb.to_s.capitalize.rjust(PADDING)
      verbstr = case verb.downcase.to_sym
      when :uploaded, :uploading
        set_color("▶️#{verbstr}", :green, :bold)
      when :downloading, :downloaded
        set_color("◀️#{verbstr}", :cyan, :bold)
      when :removing, :removed
        set_color("❌#{verbstr}", :magenta, :bold)
      when :error
        set_color("❗#{verbstr}", :red, :bold)
      when :warning
        set_color("⚠#{verbstr}", :yellow, :bold)
      when :registering, :saving, :creating
        set_color("➡️#{verbstr}", :blue, :bold)
      else
        set_color(" #{verbstr}", :bold)
      end
      timestr = time.nil? ? " "*8 : set_color("#{timestamp}", :black)
      "#{timestr} #{env.center(10)} #{verbstr}#{divr}#{msg}"
    end

    def check_for_git
      unless File.exist?('.git')
        say("Does not appear to be a git repo", :red)
        exit(-2)
      end
    end

  end  
end
ShopifyTheme.configureMimeMagic
