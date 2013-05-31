module ChefFunnel
  extend self

  class Base
    def self.inherited(cls)
      @langs ||= []
      @langs << cls
    end

    def self.extension(val=nil)
      @extension = val if val
      @extension
    end

    def self.languages
      @langs || []
    end

    def initialize(recipe)
      @recipe = recipe
      self.install_dependencies
    end

    def install_dependencies
    end

    def execute(filename)
      raise NotImplementedError
    end

    # Loop over all resources in Chef
    def each_resource(&block)
      Chef::Resource.constants.each do |res_class_name|
        res_class = Chef::Resource.const_get(res_class_name)
        next unless res_class.is_a?(Class) && res_class < Chef::Resource
        res_name = @recipe.convert_to_snake_case(res_class_name.to_s)
        block.call(res_name, res_class)
      end
    end
  end

  def patch_name_resolver
    # Include the name->filename mappings for JS recipes
    Chef::CookbookVersion.instance_eval do
      old_filenames_by_name = instance_method(:filenames_by_name)
      define_method(:filenames_by_name) do |filenames|
        ret = old_filenames_by_name.bind(self).(filenames)
        @funnel_filled = true
        ::ChefFunnel::Base.languages.each do |lang|
          Dir[File.join(@root_dir, 'recipes', '*'+lang.extension)].each do |filename|
            ret[File.basename(filename, lang.extension)] = filename
          end
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
        ::ChefFunnel::Base.languages.each do |lang|
          return lang.new(self).execute(filename) if filename.end_with?(lang.extension)
        end
        # Fall back to normal
        old_from_file.bind(self).(filename)
      end
    end
  end

  def game_over_man_game_over
    patch_name_resolver
    patch_recipe_from_file
  end
end

ChefFunnel.game_over_man_game_over
