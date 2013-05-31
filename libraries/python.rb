module ChefFunnel
  class Python < Base
    extension '.py'

    module LibC
      def self.initialize
        self.module_exec do
          extend FFI::Library
          ffi_lib FFI::Library::LIBC
          # FILE *fopen(const char *path, const char *mode);
          attach_function :fopen, [:string, :string], :pointer
          # int fclose(FILE *stream);
          attach_function :fclose, [:pointer], :int
        end unless self.methods.include?(:ffi_lib) # Only init it once
      end
    end

    module LibPy
      def self.initialize
        self.module_exec do
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
        end unless self.methods.include?(:ffi_lib) # Only init it once
      end
    end

    def install_dependencies
      @recipe.chef_gem('ffi')
      require 'ffi'
      LibC.initialize
      LibPy.initialize
    end

    def execute(filename)
      LibPy.Py_InitializeEx(0)
      chef_mod = create_module('chef')
      debug_fn = create_method('debug') do |args|
        msgptr = FFI::MemoryPointer.new(:pointer)
        LibPy.PyArg_ParseTuple(args, 's', :pointer, msgptr)
        msg = msgptr.read_pointer().read_string()
        Chef::Log.debug(msg)
      end
      LibPy.PyModule_AddObject(chef_mod, 'debug', debug_fn)
      run_file(filename)
      LibPy.Py_Finalize()
    end

    def create_module(name)
      LibPy.module_eval do
        mod = PyModule_New(name)
        modules = PyImport_GetModuleDict()
        PyDict_SetItemString(modules, name, mod)
        mod
      end
    end

    def create_method(name, &block)
      LibPy.module_eval do
        method_def = self::PyMethodDef.new
        method_def[:ml_name] = FFI::MemoryPointer.from_string(name)
        method_def[:ml_flags] = self::METH_VARARGS
        method_def[:ml_doc] = 0
        method_def[:ml_meth] = lambda do |pyself, args|
          block.call(args)
          PyInt_FromLong(0)
        end
        name_str_obj = PyString_FromString(name)
        fn = PyCFunction_NewEx(method_def, nil, name_str_obj)
        Py_DecRef(name_str_obj)
        fn
      end
    end

    def run_file(filename)
      inf = LibC.fopen(filename, 'rb')
      main_mod = LibPy.PyImport_AddModule('__main__')
      main_dict = LibPy.PyModule_GetDict(main_mod)
      LibPy.PyRun_File(inf, filename, LibPy::Py_file_input, main_dict, main_dict)
      LibC.fclose(inf)
    end
  end
end
