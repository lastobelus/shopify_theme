require 'httparty'
require 'shopify_theme/config'
module ShopifyTheme
  include HTTParty
  @@current_api_call_count = 0
  @@total_api_calls = 40

  NOOPParser = Proc.new {|data, format| {} }
  TIMER_RESET = 10
  PERMIT_LOWER_LIMIT = 3

  def self.test?
    ENV['test']
  end

  def self.manage_timer(response)
    return unless response.headers['x-shopify-shop-api-call-limit']
    @@current_api_call_count, @@total_api_calls = response.headers['x-shopify-shop-api-call-limit'].split('/')
    @@current_timer = Time.now if @current_timer.nil?
  end

  def self.critical_permits?
    @@total_api_calls.to_i - @@current_api_call_count.to_i < PERMIT_LOWER_LIMIT
  end

  def self.passed_api_refresh?
    delta_seconds > TIMER_RESET
  end

  def self.delta_seconds
    Time.now.to_i - @@current_timer.to_i
  end

  def self.needs_sleep?
    critical_permits? && !passed_api_refresh?
  end

  def self.sleep
    if needs_sleep?
      Kernel.sleep(TIMER_RESET - delta_seconds)
      @current_timer = nil
    end
  end

  def self.api_usage
    "[API Limit: #{@@current_api_call_count || "??"}/#{@@total_api_calls || "??"}]"
  end


  def self.asset_list
    # HTTParty parser chokes on assest listing, have it noop
    # and then use a rel JSON parser.
    response = shopify.get(path, :parser => NOOPParser)
    manage_timer(response)

    assets = JSON.parse(response.body)["assets"].collect {|a| a['key'] }
    # Remove any .css files if a .css.liquid file exists
    assets.reject{|a| assets.include?("#{a}.liquid") }
  end

  def self.get_asset(asset)
    response = shopify.get(path, :query =>{:asset => {:key => asset}}, :parser => NOOPParser)
    manage_timer(response)

    # HTTParty json parsing is broken?
    asset = response.code == 200 ? JSON.parse(response.body)["asset"] : {}
    asset['response'] = response
    asset
  end

  def self.send_asset(data)
    response = shopify.put(path, :body =>{:asset => data})
    manage_timer(response)
    response
  end

  def self.delete_asset(asset)
    response = shopify.delete(path, :body =>{:asset => {:key => asset}})
    manage_timer(response)
    response
  end

  def self.upload_timber(name, version)
    release = Releases.new.find(version)
    response = shopify.post("/admin/themes.json", :body => {:theme => {:name => name, :src => release.zip_url, :role => 'unpublished'}})
    manage_timer(response)
    body = JSON.parse(response.body)
    if theme = body['theme']
      puts "Successfully created #{name} using Shopify Timber #{version}"
      watch_until_processing_complete(theme)
    else
      puts "Could not download theme!"
      puts body
      exit 1
    end
  end

  def self.environment=(environment)
    @config = nil
    @environment = environment
  end
  
  def self.config_path=(config_path)
    @config = nil
    @config_path = config_path
  end
  
  def self.environment
    @environment
  end
  
  def self.config_path
    @config_path
  end
  
  def self.config
    @config ||= ShopifyTheme::Config.new(path: self.config_path, environment: self.environment)
  end

  def self.config=(config)
    @config = config
  end

  def self.path
    @path ||= config[:theme_id] ? "/admin/themes/#{config[:theme_id]}/assets.json" : "/admin/assets.json"
  end

  def self.ignore_files
    (config[:ignore_files] || []).compact.map { |r| Regexp.new(r) }
  end

  def self.whitelist_files
    (config[:whitelist_files] || []).compact
  end

  def self.is_binary_data?(string)
    if string.respond_to?(:encoding)
      string.encoding == "US-ASCII"
    else
      ( string.count( "^ -~", "^\r\n" ).fdiv(string.size) > 0.3 || string.index( "\x00" ) ) unless string.empty?
    end
  end

  def self.check_config
    puts "checking config for #{self.config[:store]}"
    shopify.get(path).code == 200
  end

  private
  def self.shopify
    basic_auth config[:api_key], config[:password]
    base_uri "https://#{config[:store]}"
    ShopifyTheme
  end

  def self.watch_until_processing_complete(theme)
    count = 0
    while true do
      Kernel.sleep(count)
      response = shopify.get("/admin/themes/#{theme['id']}.json")
      theme = JSON.parse(response.body)['theme']
      return theme if theme['previewable']
      count += 5
    end
  end
end
