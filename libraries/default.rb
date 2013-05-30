module Funnel
  class Js
    def patch_name_resolver
      # Include the name->filename mappings for JS recipes
      Chef::CookbookVersion.instance_eval do
        old_filenames_by_name = instance_method(:filenames_by_name)
        define_method(:filenames_by_name) do |filenames|
          @funnel_js_ran = true
          ret = old_filenames_by_name.bind(self).(filenames)
          Dir[File.join(@root_dir, 'recipes', '*.js')].each do |filename|
            ret[File.basename(filename, '.js')] = filename
          end
          ret
        end

        # Force names to be remapped if needed
        old_load_recipe = instance_method(:load_recipe)
        define_method(:load_recipe) do |*args|
          self.recipe_filenames = self.recipe_filenames unless @funnel_js_ran
          old_load_recipe.bind(self).call(*args)
        end
      end
    end

    def patch_recipe_from_file
      # The special magic to support JS recipe eval
      Chef::Recipe.instance_eval do
        old_from_file = instance_method(:from_file)
        define_method(:from_file) do |filename|
          if filename =~ /\.js$/
            chef_gem('therubyracer')
            # Bring on the pain
            require 'v8'
            ctx = V8::Context.new
            ctx['debug'] = lambda {|this, msg| Chef::Log.debug(msg)}
            ctx['node'] = node
            Chef::Resource.constants.each do |res_class_name|
              res_class = Chef::Resource.const_get(res_class_name)
              next unless res_class.is_a?(Class) && res_class < Chef::Resource
              res_name = convert_to_snake_case(res_class_name.to_s)
              ctx[res_name] = lambda do |this, name, attrs|
                send(res_name, name) do
                  if attrs
                    attrs.each { |key, value| send(key, value) }
                  end
                end
              end
            end
            ctx.load(filename)
          else
            old_from_file.bind(self).(filename)
          end
        end
      end
    end

    def game_over_man_game_over
      patch_name_resolver
      patch_recipe_from_file
    end
  end
end

Funnel::Js.new.game_over_man_game_over
