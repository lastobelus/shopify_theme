require 'yaml'
module ShopifyTheme
  class Config
    attr_accessor :path
    def initialize(path:"config.yml", environment:nil)
      @path = path
      @environment = environment.to_sym
    end
    
    def config
      @base_config ||= if File.exist? self.path
        config = YAML.load(File.read(self.path))
        config
      else
        puts "#{self.path} does not exist!" unless test?
        {}
      end
      @environment ||= :development unless @base_config[:development].nil?
      @default_config ||= @base_config[:default].nil? ? @base_config : @base_config[:default]    
      @config ||= ( @environment.nil? || @base_config[@environment].nil? ) ? @default_config : @default_config.merge(@base_config[@environment])
    end
    
    def environment=(newenv)
      @environment = newenv.to_sym
      @config = nil
    end
    
    def path=(newpath)
      @path = newpath
      @base_config = nil
      @default_config = nil
    end
    
    def [](key)
      config[key]
    end
  end
end