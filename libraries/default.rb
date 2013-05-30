require 'pry'
module ChefFunnel
  extend self

  # For later
  module Libc
  end
  module Python
  end

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
        Dir[File.join(@root_dir, 'recipes', '*.py')].each do |filename|
          ret[File.basename(filename, '.py')] = filename
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
        elsif filename =~ /\.py$/
          chef_gem('ffi')
          require 'ffi'
          ChefFunnel::Libc.module_exec do
            extend FFI::Library
            ffi_lib FFI::Library::LIBC
            # FILE *fopen(const char *path, const char *mode);
            attach_function :fopen, [:string, :string], :pointer
            # int fclose(FILE *stream);
            attach_function :fclose, [:pointer], :int
          end unless ChefFunnel::Libc.methods.include?(:ffi_lib) # Only init it once
          ChefFunnel::Python.module_exec do
            extend FFI::Library
            ffi_lib 'python'
            attach_function :Py_InitializeEx, [:int], :void
            attach_function :Py_Finalize, [], :void
            attach_function :Py_GetVersion, [], :string
            attach_function :PyRun_SimpleString, [ :string ], :int
            # PyObject* PyRun_File(FILE *fp, const char *filename, int start, PyObject *globals, PyObject *locals)
            attach_function :PyRun_File, [:pointer, :string, :int, :pointer, :pointer], :pointer
            attach_function :Py_DecRef, [:pointer], :void
            attach_function :PyString_FromString, [:string], :pointer
            attach_function :PyModule_New, [:string], :pointer # new ref
            attach_function :PyModule_AddObject, [:pointer, :string, :pointer], :int # Steals ref to value
            # PyObject* PyModule_GetDict(PyObject *module)
            attach_function :PyModule_GetDict, [:pointer], :pointer
            attach_function :PyImport_GetModuleDict, [], :pointer # borrowed ref
            # PyObject* PyImport_AddModule(const char *name)
            attach_function :PyImport_AddModule, [:string], :pointer
            # int PyDict_SetItemString(PyObject *p, const char *key, PyObject *val)
            attach_function :PyDict_SetItemString, [:pointer, :string, :pointer], :int
            # typedef PyObject *(*PyCFunction)(PyObject *, PyObject *);
            callback :pycfunction, [:pointer, :pointer], :pointer
            pycfunction = find_type :pycfunction
            # struct PyMethodDef {
            pymethoddef = Class.new(::FFI::Struct) do
              # const char  *ml_name; /* The name of the built-in function/method */
              layout :ml_name, :pointer,
              # PyCFunction  ml_meth; /* The C function that implements it */
                     :ml_meth, pycfunction,
              #     int    ml_flags;  /* Combination of METH_xxx flags, which mostly
              #                          describe the args expected by the C func */
                     :ml_flags, :int,
              # const char  *ml_doc;  /* The __doc__ attribute, or NULL */
                     :ml_doc, :pointer
            end
            const_set :PyMethodDef, pymethoddef
            # PyObject *PyCFunction_NewEx(PyMethodDef *ml, PyObject *self, PyObject *module)
            attach_function :PyCFunction_NewEx, [pymethoddef, :pointer, :pointer], :pointer
            # int PyArg_ParseTuple(PyObject *args, const char *format, ...)
            attach_function :PyArg_ParseTuple, [:pointer, :string, :varargs], :int
            # PyObject* PyObject_Repr(PyObject *o)
            attach_function :PyObject_Repr, [:pointer], :pointer
            # char* PyString_AsString(PyObject *string)
            attach_function :PyString_AsString, [:pointer], :string
            # PyObject* PyInt_FromLong(long ival)
            attach_function :PyInt_FromLong, [:long], :pointer
            const_set :Py_file_input, 257
            const_set :METH_VARARGS, 1
          end unless ChefFunnel::Python.methods.include?(:ffi_lib) # Only init it once
          Python.Py_InitializeEx(0)
          chef_mod = Python.PyModule_New('chef')
          modules = Python.PyImport_GetModuleDict()
          Python.PyDict_SetItemString(modules, 'chef', chef_mod)
          debugdef = Python::PyMethodDef.new
          #binding.pry
          debugdef[:ml_name] = FFI::MemoryPointer.from_string('debug')
          debugdef[:ml_flags] = Python::METH_VARARGS
          debugdef[:ml_doc] = 0
          debugdef[:ml_meth] = lambda do |pyself, args|
            msgptr = FFI::MemoryPointer.new(:pointer)
            Python.PyArg_ParseTuple(args, 's', :pointer, msgptr)
            msg = msgptr.read_pointer().read_string()
            Chef::Log.debug(msg)
            Python.PyInt_FromLong(0)
          end
          nameobj = Python.PyString_FromString('debug')
          debugfn = Python.PyCFunction_NewEx(debugdef, nil, nameobj)
          Python.Py_DecRef(nameobj)
          Python.PyModule_AddObject(chef_mod, 'debug', debugfn)
          inf = Libc.fopen(filename, 'rb')
          mainmod = Python.PyImport_AddModule('__main__')
          maindict = Python.PyModule_GetDict(mainmod)
          Python.PyRun_File(inf, filename, Python::Py_file_input, maindict, maindict)
          Libc.fclose(inf)
          Python.Py_Finalize()
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

ChefFunnel.game_over_man_game_over
