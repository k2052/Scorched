module Scorched
  class Controller
    include Scorched::Options('config')
    include Scorched::Options('render_defaults')
    include Scorched::Options('conditions')
    include Scorched::Collection('middleware')
    include Scorched::Collection('before_filters')
    include Scorched::Collection('after_filters')
    include Scorched::Collection('error_filters')
    
    config << {
      :strip_trailing_slash => :redirect, # :redirect => Strips and redirects URL ending in forward slash, :ignore => internally ignores trailing slash, false => does nothing.
      :static_dir => 'public', # The directory Scorched should serve static files from. Set to false if web server or anything else is serving static files.
      :logger => nil,
      :show_exceptions => false
    }
    
    render_defaults << {
      :dir => 'views', # The directory containing all the view templates, relative to the current working directory.
      :layout => false, # The default layout template to use, relative to the view directory. Set to false for no default layout.
      :engine => :erb
    }
    
    if ENV['RACK_ENV'] == 'development'
      config[:logger] = Logger.new(STDOUT)
      config[:show_exceptions] = true
    else
      config[:static_dir] = false
    end
    
    conditions << {
      charset: proc { |charsets|
        [*charsets].any? { |charset| request.env['rack-accept.request'].charset? charset }
      },
      encoding: proc { |encodings|
        [*encodings].any? { |encoding| request.env['rack-accept.request'].encoding? encoding }
      },
      host: proc { |host| 
        (Regexp === host) ? host =~ request.host : host == request.host 
      },
      language: proc { |languages|
        [*languages].any? { |language| request.env['rack-accept.request'].language? language }
      },
      media_type: proc { |types|
        [*types].any? { |type| request.env['rack-accept.request'].media_type? type }
      },
      methods: proc { |accepts| 
        [*accepts].include?(request.request_method)
      },
      user_agent: proc { |user_agent| 
        (Regexp === user_agent) ? user_agent =~ request.user_agent : user_agent == request.user_agent 
      },
      status: proc { |statuses| 
        [*statuses].include?(response.status)
      },
    }
    
    middleware << proc { |this|
      use Rack::Head
      use Rack::MethodOverride
      use Rack::Accept
      use Scorched::Static, this.config[:static_dir] if this.config[:static_dir]
      use Rack::Logger, this.config[:logger] if this.config[:logger]
      use Rack::ShowExceptions if this.config[:show_exceptions]
    }
    
    class << self
      
      def mappings
        @mappings ||= []
      end
      
      def filters
        @filters ||= {before: before_filters, after: after_filters, error: error_filters}
      end
      
      def call(env)
        loaded = env['scorched.middleware'] ||= Set.new
        app = lambda do |env|
          instance = self.new(env)
          instance.action
        end

        builder = Rack::Builder.new
        middleware.reject{ |v| loaded.include? v }.each do |proc|
          builder.instance_exec(self, &proc)
          loaded << proc
        end
        builder.run(app)
        builder.call(env)
      end
      
      # Generates and assigns mapping hash from the given arguments.
      #
      # Accepts the following keyword arguments:
      #   :pattern - The url pattern to match on. Required.
      #   :target - A proc to execute, or some other object that responds to #call. Required.
      #   :priority - Negative or positive integer for giving a priority to the mapped item.
      #   :conditions - A hash of condition:value pairs
      # Raises ArgumentError if required key values are not provided.
      def map(pattern: nil, priority: nil, conditions: {}, target: nil)
        raise ArgumentError, "Mapping must specify url pattern and target" unless pattern && target
        priority = priority.to_i
        insert_pos = mappings.take_while { |v| priority <= v[:priority]  }.length
        mappings.insert(insert_pos, {
          pattern: compile(pattern),
          priority: priority,
          conditions: conditions,
          target: target
        })
      end
      alias :<< :map
      
      # Creates a new controller as a sub-class of self (by default), mapping it to self using the provided mapping
      # hash if one is provided. Returns the new anonymous controller class.
      #
      # Takes two optional arguments and a block: a parent class from which the generated controller class inherits
      # from, a mapping hash to automatically map the new controller, and of course a block which defines the
      # controller class.
      #
      # It's worth noting, however obvious, that the resulting class will only be a controller if the parent class is
      # (or inherits from) a Scorched::Controller.
      def controller(parent_class = self, **mapping, &block)
        c = Class.new(parent_class, &block)
        self << {pattern: '/', target: c}.merge(mapping)
        c
      end
      
      # Generates and returns a new route proc from the given block, and optionally maps said proc using the given args.
      def route(pattern = nil, priority = nil, **conds, &block)
        target = lambda do |env|
          env['scorched.response'].body = instance_exec(*env['scorched.request'].captures, &block)
          env['scorched.response']
        end
        self << {pattern: compile(pattern, true), priority: priority, conditions: conds, target: target} if pattern
        target
      end

      ['get', 'post', 'put', 'delete', 'head', 'options', 'patch'].each do |method|
        methods = (method == 'get') ? ['GET', 'HEAD'] : [method.upcase]
        define_method(method) do |*args, **conds, &block|
          conds.merge!(methods: methods)
          route(*args, **conds, &block)
        end
      end
      
      def filter(type, *args, **conds, &block)
        filters[type.to_sym] << {args: args, conditions: conds, proc: block}
      end
      
      # A bit of syntactic sugar for #filter.
      ['before', 'after', 'error'].each do |type|
        define_method(type) do |*args, &block|
          filter(type, *args, &block)
        end
      end
      
      # Called when a controller is subclassed
      # used to init class accessors and set the current app_file
      def inherited(subclass)
        sublass.extensions ||= []
        subclass.set :app_file, caller_files.first unless subclass.app_file?
        super
      end

      # Extension modules registered on this class and all superclasses.
      # Ported from sinatra
      def extensions
        if superclass.respond_to?(:extensions)
          (@extensions + superclass.extensions).uniq
        else
          @extensions
        end
      end

      # Helpers method. Ported from sinatra
      # Makes the methods defined in the block and in the Modules given
      # in `extensions` available to the handlers and templates
      def helpers(*extensions, &block)
        class_eval(&block)   if block_given?
        include(*extensions) if extensions.any?
      end
      
      # Register methods for extensions. Ported from sinatra
      # Register an extension. Alternatively take a block from which an
      # extension will be created and registered on the fly.
      def register(*extensions, &block)
        extensions << Module.new(&block) if block_given?
        @extensions += extensions
        extensions.each do |extension|
          extend extension
          extension.registered(self) if extension.respond_to?(:registered)
        end
      end
      
      # Called file handling.
      # Ported from sinatra
      CALLERS_TO_IGNORE = [ # :nodoc:
        /\/scorched(\/(controller))?\.rb$/,                 # all scorched code
        /lib\/tilt.*\.rb$/,                                 # all tilt code
        /^\(.*\)$/,                                         # generated code
        /rubygems\/(custom|core_ext\/kernel)_require\.rb$/, # rubygems require hacks
        /active_support/,                                   # active_support require hacks
        /bundler(\/runtime)?\.rb/,                          # bundler require hacks
        /<internal:/,                                       # internal in ruby >= 1.9.2
        /src\/kernel\/bootstrap\/[A-Z]/                     # maglev kernel files
      ]

      # Like Kernel#caller but excluding certain magic entries and without
      # line / method information; the resulting array contains filenames only.
      # Ported from Sinatra
      def caller_files
        cleaned_caller(1).flatten
      end

      # Like Kernel#caller but excluding certain magic entries
      # Ported from Sinatra
      def cleaned_caller(keep = 3)
        caller(1).
          map    { |line| line.split(/:(?=\d|in )/, 3)[0,keep] }.
          reject { |file, *_| CALLERS_TO_IGNORE.any? { |pattern| file =~ pattern } }
      end

    private
    
      # Parses and compiles the given URL string pattern into a regex if not already, returning the resulting regexp
      # object. Accepts an optional _match_to_end_ argument which will ensure the generated pattern matches to the end
      # of the string.
      def compile(pattern, match_to_end = false)
        return pattern if Regexp === pattern
        raise Error, "Can't compile URL of type #{pattern.class}. Must be String or Regexp." unless String === pattern
        match_to_end = !!pattern.sub!(/\$$/, '') || match_to_end
        regex_pattern = pattern.split(%r{(\*{1,2}|(?<!\\):{1,2}[^/*$]+)}).each_slice(2).map { |unmatched, match|
          Regexp.escape(unmatched) << begin
            if %w{* **}.include? match
              match == '*' ? "([^/]+)" : "(.+)"
            elsif match
              match[0..1] == '::' ? "(?<#{match[2..-1]}>.+)" : "(?<#{match[1..-1]}>[^/]+)"
            else
              ''
            end
          end
        }.join
        regex_pattern << '$' if match_to_end
        Regexp.new(regex_pattern)
      end
    end
    
    def method_missing(method, *args, &block)
      (self.class.respond_to? method) ? self.class.__send__(method, *args, &block) : super
    end
    
    def initialize(env)
      define_singleton_method :env do
        env
      end
      env['scorched.request'] ||= Request.new(env)
      env['scorched.response'] ||= Response.new
    end
    
    def action
      inner_error = nil
      rescue_block = proc do |e|
        raise unless filters[:error].any? do |f|
          (f[:args].empty? || f[:args].any? { |type| e.is_a?(type) }) && check_conditions?(f[:conditions]) && instance_exec(e, &f[:proc])
        end
      end
      
      match = matches(true).first
      begin
        catch(:halt) do
          if config[:strip_trailing_slash] == :redirect && request.path =~ %r{./$}
            redirect(request.path.chomp('/'))
          end
          
          run_filters(:before)
          if match
            request.breadcrumb << match
            # Proc's are executed in the context of this controller instance.
            target = match[:mapping][:target]
            begin
              catch(:halt) do
                response.merge! (Proc === target) ? instance_exec(request.env, &target) : target.call(request.env)
              end
            rescue => inner_error
              rescue_block.call(inner_error)
            end
          else
            response.status = 404
          end
          run_filters(:after)
        end
      rescue => outer_error
        outer_error == inner_error ? raise : rescue_block.call(outer_error)
      end
      response
    end
    
    def match?
      !matches(true).empty?
    end
    
    # Finds mappings that match the currently unmatched portion of the request path, returning an array of all matches.
    # If _short_circuit_ is set to true, it stops matching at the first positive match, returning only a single match.
    def matches(short_circuit = false)
      to_match = request.unmatched_path
      to_match = to_match.chomp('/') if config[:strip_trailing_slash] == :ignore && to_match =~ %r{./$}
      matches = []
      mappings.each do |m|
        m[:pattern].match(to_match) do |match_data|
          if match_data.pre_match == ''
            if check_conditions?(m[:conditions])
              if match_data.names.empty?
                captures = match_data.captures
              else
                captures = Hash[match_data.names.map{|v| v.to_sym}.zip match_data.captures]
              end
              matches << {mapping: m, captures: captures, path: match_data.to_s}
              break if short_circuit
            end
          end
        end
      end
      matches
    end
    
    def check_conditions?(conds)
      if !conds
        true
      else
        conds.all? { |c,v| check_condition?(c, v) }
      end
    end
    
    def check_condition?(c, v)
      raise Error, "The condition `#{c}` either does not exist, or is not a Proc object" unless Proc === self.conditions[c]
      instance_exec(v, &self.conditions[c])
    end
    
    def redirect(url, status = 307)
      response['Location'] = url
      halt(status)
    end
    
    def halt(status = 200)
      response.status = status
      throw :halt
    end
    
    # Convenience method for accessing Rack request.
    def request
      env['scorched.request']
    end
    
    # Convenience method for accessing Rack response.
    def response
      env['scorched.response']
    end
    
    # Convenience method for accessing Rack session.
    def session
      env['rack.session']
    end
    
    # Flash session storage helper.
    # Stores session data until the next time this method is called with the same arguments, at which point it's reset.
    # The typical use case is to provide feedback to the user on the previous action they performed.
    def flash(key = :flash)
      raise Error, "Flash session data cannot be used without a valid Rack session" unless session
      flash_hash = env['scorched.flash'] ||= {}
      flash_hash[key] ||= {}
      session[key] ||= {}
      unless session[key].methods(false).include? :[]=
        session[key].define_singleton_method(:[]=) do |k, v|
          flash_hash[key][k] = v
        end
      end
      session[key]
    end
    
    after do
      env['scorched.flash'].each { |k,v| session[k] = v } if session && env['scorched.flash']
    end
    
    # Serves a thin layer of convenience to Rack's built-in methods: Request#cookies, Response#set_cookie, and
    # Response#delete_cookie.
    # If only one argument is given, the specified cookie is retreived and returned.
    # If both arguments are supplied, the cookie is either set or deleted, depending on whether the second argument is
    # nil, or otherwise is a hash containing the key/value pair ``:value => nil``.
    # If you wish to set a cookie to an empty value without deleting it, you pass an empty string as the value
    def cookie(name, *value)
      name = name.to_s
      if value.empty?
        request.cookies[name]
      else
        value = Hash === value[0] ? value[0] : {value: value}
        if value[:value].nil?
          response.delete_cookie(name, value)
        else
          response.set_cookie(name, value)
        end
      end
    end
    
    # Renders the given string or file path using the Tilt templating library.
    # The options hash is merged with the controllers _render_defaults_. Unrecognised options are passed through to Tilt. 
    # The template engine is derived from file name, or otherwise as specified by the _:engine_ option. If a string is
    # given, the _:engine_ option must be set.
    #
    # Refer to Tilt documentation for a list of valid template engines.
    def render(string_or_file, options = {}, &block)
      options = render_defaults.merge(explicit_options = options)
      engine = (derived_engine = Tilt[string_or_file.to_s]) || Tilt[options[:engine]]
      raise Error, "Invalid or undefined template engine: #{options[:engine].inspect}" unless engine
      if Symbol === string_or_file
        file = string_or_file.to_s
        file = file << ".#{options[:engine]}" unless derived_engine
        file = File.join(options[:dir], file) if options[:dir]
        # Tilt still has unresolved file encoding issues. Until that's fixed, we read the file manually.
        template = engine.new(nil, nil, options) { File.read(file) }
      else
        template = engine.new(nil, nil, options) { string_or_file }
      end
      
      # The following chunk of code is responsible for preventing the rendering of layouts within views.
      options[:layout] = false if @_no_default_layout && !explicit_options[:layout]
      begin
        @_no_default_layout = true
        output = template.render(self, options[:locals], &block)
      ensure
        @_no_default_layout = false
      end
      output = render(options[:layout], options.merge(layout: false)) { output } if options[:layout]
      output
    end
    
    # Takes an optional URL, relative to the applications root, and returns a fully qualified URL.
    # Example: url('/example?show=30') #=> https://localhost:9292/myapp/example?show=30
    def url(path = nil)
      return path if path && URI.parse(path).scheme
      uri = URI::Generic.build(
        scheme: env['rack.url_scheme'],
        host: env['SERVER_NAME'],
        port: env['SERVER_PORT'].to_i,
        path: env['SCRIPT_NAME']
      )
      if path
        path[0,0] = '/' unless path[0] == '/'
        uri.to_s.chomp('/') << path
      else
        uri.to_s
      end
    end
    
    # Takes an optional path, relative to the applications root URL, and returns an absolute path.
    # Example: absolute('/style.css') #=> /myapp/style.css
    def absolute(path = nil)
      return path if path && URI.parse(path).scheme
      return_path = if path
        [request.script_name, path].join('/').gsub(%r{/+}, '/')
      else
        request.script_name
      end
      return_path[0] == '/' ? return_path : return_path.insert(0, '/')
    end
    
    if ENV['RACK_ENV'] == 'development' && 
      after do
        if response.empty?
          response.body = <<-HTML
            <!DOCTYPE html>
            <html>
            <head>
              <style type="text/css">
               @import url(http://fonts.googleapis.com/css?family=Titillium+Web|Open+Sans:300italic,400italic,700italic,400,700,300);
                html, body { height: 100%; width: 100%; margin: 0; font-family: 'Open Sans', 'Lucida Sans', 'Arial'; }
                body { color: #333; display: table; }
                #container { display: table-cell; vertical-align: middle; text-align: center; }
                #container > * { display: inline-block; text-align: center; vertical-align: middle; }
                #logo {
                  padding: 12px 24px 12px 120px; color: white; background: rgb(191, 64, 0);
                  font-family: 'Titillium Web', 'Lucida Sans', 'Arial'; font-size: 36pt;  text-decoration: none;
                }
                h1 { margin-left: 18px; font-weight: 400; }
              </style>
            </head>
            <body>
              <div id="container">
                <a id="logo" href="http://scorchedrb.com">Scorched</a>
                <h1>404 Page Not Found</h1>
              </div>
            </body>
            </html>
          HTML
        end
      end
    end

    
  private
  
    def run_filters(type)
      tracker = env['scorched.filters'] ||= {before: Set.new, after: Set.new}
      filters[type].reject{ |f| tracker[type].include? f }.each do |f|
        if check_conditions?(f[:conditions])
          tracker[type] << f
          instance_exec(&f[:proc])
        end
      end
    end
    
    def log(type, message)
      config[:logger].progname ||= 'Scorched'
      type = Logger.const_get(type.to_s.upcase)
      config[:logger].add(type, message)
    end
  end
end