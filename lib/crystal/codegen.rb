require 'llvm/core'
require 'llvm/execution_engine'
require 'llvm/transforms/scalar'

LLVM.init_x86

module Crystal
  class Def
    def mangled_name
      if owner
        "#{owner.name}##{name}"
      else
        name
      end
    end
  end

  def run(code)
    mod = build code

    engine = LLVM::JITCompiler.new(mod)
    engine.run_function mod.functions["main"]
  end

  def build(code)
    node = parse code
    type node

    visitor = CodeGenVisitor.new(node.type)
    node.accept visitor

    visitor.mod.verify

    visitor.mod.dump if ENV['DUMP']

    visitor.mod
  end

  class CodeGenVisitor < Visitor
    attr_reader :mod
    attr_reader :main

    def initialize(return_type)
      @mod = LLVM::Module.new("Crystal")
      @main = @mod.functions.add("main", [], return_type.llvm_type)
      entry = @main.basic_blocks.append("entry")
      @builder = LLVM::Builder.new
      @builder.position_at_end(entry)
      @funs = {}
      @vars = {}
    end

    def end_visit_expressions(node)
      @builder.ret @last
    end

    def visit_bool(node)
      @last = LLVM::Int1.from_i(node.value ? 1 : 0)
    end

    def visit_int(node)
      @last = LLVM::Int(node.value)
    end

    def visit_float(node)
      @last = LLVM::Float(node.value)
    end

    def visit_assign(node)
      node.value.accept self

      var = @vars[node.target.name]
      unless var && var[:type] == node.type
        var = @vars[node.target.name] = {
          ptr: @builder.alloca(node.type.llvm_type, node.target.name),
          type: node.type
        }
      end

      @builder.store @last, var[:ptr]

      false
    end

    def visit_var(node)
      var = @vars[node.name]
      @last = @builder.load var[:ptr], node.name
    end

    def visit_def(node)
      false
    end

    def visit_class_def(node)
      false
    end

    def visit_call(node)
      mangled_name = node.target_def.mangled_name
      unless fun = @funs[mangled_name]
        old_position = @builder.insert_block
        fun = @funs[mangled_name] = @mod.functions.add(mangled_name, [], node.target_def.body.type.llvm_type)
        entry = fun.basic_blocks.append("entry")
        @builder.position_at_end(entry)
        node.target_def.body.accept self
        @builder.position_at_end old_position
      end
      @last = @builder.call fun, mangled_name
      false
    end
  end
end