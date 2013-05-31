module ChefFunnel
  class Javascript < Base
    extension '.js'

    def install_dependencies
      @recipe.chef_gem('therubyracer')
      require 'v8'
    end

    def execute(filename)
      ctx = V8::Context.new
      ctx['debug'] = lambda {|this, msg| Chef::Log.debug(msg)}
      ctx['node'] = @recipe.node
      self.each_resource do |res_name|
        ctx[res_name] = lambda do |this, name, *args|
          attrs = args.first
          @recipe.send(res_name, name) do
            if attrs
              attrs.each do |key, value|
                if value.is_a?(V8::Object)
                  value = value.inject({}) {|memo, (subkey, subvalue)| memo[subkey] = subvalue; memo}
                end
                send(key, value)
              end
            end
          end
        end
      end
      ctx.load(filename)
    end
  end
end
