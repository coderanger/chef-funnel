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
          attach_function :Py_IncRef, [:pointer], :void
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
          # typedef PyObject *(*PyCFunctionWithKeywords)(PyObject *, PyObject *, PyObject *);
          callback :pycfunctionwithkeywords, [:pointer, :pointer, :pointer], :pointer
          pycfunctionwithkeywords = find_type :pycfunctionwithkeywords
          # struct PyMethodDef {
          pymethoddef = Class.new(::FFI::Struct) do
            # const char  *ml_name; /* The name of the built-in function/method */
            layout :ml_name, :pointer,
            # PyCFunction  ml_meth; /* The C function that implements it */
                   :ml_meth, pycfunctionwithkeywords,
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
          const_set :METH_KEYWORDS, 2
          pyobject = Class.new(::FFI::Struct) do
            layout :ob_refcnt, LibPy.ssize_t_type, :ob_type, :pointer
          end
          const_set :PyObject, pyobject
          attach_variable :None, :_Py_NoneStruct, :pointer
          # PyAPI_FUNC(void) PyErr_Print(void);
          attach_function :PyErr_Print, [], :void
          #  PyObject* PyObject_GetAttrString(PyObject *o, const char *attr_name)
          attach_function :PyObject_GetAttrString, [:pointer, :string], :pointer
          # int PyDict_Next(PyObject *p, Py_ssize_t *ppos, PyObject **pkey, PyObject **pvalue)
          attach_function :PyDict_Next, [:pointer, :pointer, :pointer, :pointer], :int
          # int PyString_AsStringAndSize(PyObject *obj, char **buffer, Py_ssize_t *length)
          attach_function :PyString_AsStringAndSize, [:pointer, :pointer, :pointer], :int
          # long PyInt_AsLong(PyObject *io)
          attach_function :PyInt_AsLong, [:pointer], :long
          # double PyFloat_AsDouble(PyObject *pyfloat)
          attach_function :PyFloat_AsDouble, [:pointer], :double
          # PyObject* PyObject_GetIter(PyObject *o)
          attach_function :PyObject_GetIter, [:pointer], :pointer
          # PyObject* PyIter_Next(PyObject *o)
          attach_function :PyIter_Next, [:pointer], :pointer
          attach_variable :PyString_Type, pyobject
          attach_variable :PyInt_Type, pyobject
          attach_variable :PyFloat_Type, pyobject
          attach_variable :PyDict_Type, pyobject
        end unless self.methods.include?(:ffi_lib) # Only init it once
      end

      def self.ruby_fns
        @ruby_fns ||= []
      end

      def self.repr(obj)
        repr_str_obj = PyObject_Repr(obj)
        repr_str = PyString_AsString(repr_str_obj).dup
        Py_DecRef(repr_str_obj)
        repr_str
      end

      def self.none
        builtins = PyImport_AddModule('__builtins__')
        PyObject_GetAttrString(builtins, '__doc__')
      end

      def self.ssize_t_type
        @ssize_t_type ||= "int#{find_type(:size_t).size * 8}".to_sym
      end

      module ConvertTypes
        extend self

        def convert(obj)
          pyobj = LibPy::PyObject.new(obj)
          case pyobj.values[1] # ob_type
          when LibPy.PyString_Type.pointer
            str(obj)
          when LibPy.PyInt_Type.pointer
            LibPy.PyInt_AsLong(obj)
          when LibPy.PyFloat_Type.pointer
            LibPy.PyFloat_AsDouble(obj)
          when LibPy.PyDict_Type.pointer
            dict(obj)
          else
            iterator = LibPy.PyObject_GetIter(obj)
            if iterator.null?
              nil # Default mapped value
            else
              ret = iterable(iterator, obj)
              LibPy.Py_DecRef(iterator)
              ret
            end
          end
        end

        def str(obj)
          buffer = FFI::MemoryPointer.new(:pointer)
          length = FFI::MemoryPointer.new(LibPy.ssize_t_type)
          LibPy.PyString_AsStringAndSize(obj, buffer, length)
          buffer.read_pointer.read_string(length.send("read_#{LibPy.ssize_t_type}"))
        end

        def dict(obj)
          ret = {}
          ppos = FFI::MemoryPointer.new(LibPy.ssize_t_type)
          ppos.send("write_#{LibPy.ssize_t_type}", 0)
          pkey = FFI::MemoryPointer.new(:pointer)
          pvalue = FFI::MemoryPointer.new(:pointer)
          while LibPy.PyDict_Next(obj, ppos, pkey, pvalue) == 1
            key = convert(pkey.read_pointer)
            value = convert(pvalue.read_pointer)
            ret[key] = value
          end
          ret
        end

        def iterable(iterator, obj)
          ret = []
          while (itobj = LibPy.PyIter_Next(iterator)) && !itobj.null?
            ret << convert(itobj)
            LibPy.Py_DecRef(itobj)
          end
          ret
        end
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
        Chef::Log.debug(args[0])
        nil
      end
      LibPy.PyModule_AddObject(chef_mod, 'debug', debug_fn)
      each_resource do |res_name|
        res_fn = create_method(res_name) do |args, kwargs|
          @recipe.send(res_name, args[0]) do
            kwargs.each do |key, value|
              send(key, value)
            end if kwargs
          end
          nil
        end
        LibPy.PyModule_AddObject(chef_mod, res_name, res_fn)
      end
      run_file(filename)
      LibPy.Py_Finalize()
      LibPy.ruby_fns.clear
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
        method_def[:ml_flags] = self::METH_KEYWORDS | self::METH_VARARGS
        method_def[:ml_doc] = 0
        ruby_fn = lambda do |pyself, args, kwargs|
          args = self::ConvertTypes.convert(args)
          kwargs = kwargs.null? ? nil :  self::ConvertTypes.convert(kwargs)
          ret = block.call(args, kwargs)
          ret = none if ret.nil?
          ret
        end
        ruby_fns << ruby_fn # To prevent GC
        method_def[:ml_meth] = ruby_fn
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
      ret = LibPy.PyRun_File(inf, filename, LibPy::Py_file_input, main_dict, main_dict)
      if ret.null?
        # Something went wrong
        LibPy.PyErr_Print()
        raise 'Exception from Python'
      end
      LibC.fclose(inf)
    end
  end
end
