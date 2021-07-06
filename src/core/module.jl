# Modules represent the top-level structure in an LLVM program.

export dispose,
       name, name!,
       triple, triple!,
       datalayout, datalayout!,
       context, inline_asm!,
       set_used!, set_compiler_used!

# forward definition of Module in src/core/value/constant.jl

function Base.unsafe_convert(::Type{API.LLVMModuleRef}, mod::Module)
    # modules can get destroyed, so be sure to check for validity
    mod.ref == C_NULL && throw(UndefRefError())
    mod.ref
end

Base.:(==)(x::Module, y::Module) = (x.ref === y.ref)

# forward declarations
@checked struct DataLayout
    ref::API.LLVMTargetDataRef
end

Module(name::String) = Module(API.LLVMModuleCreateWithName(name))
Module(name::String, ctx::Context) =
    Module(API.LLVMModuleCreateWithNameInContext(name, ctx))
Module(mod::Module) = Module(API.LLVMCloneModule(mod))

dispose(mod::Module) = API.LLVMDisposeModule(mod)

function Module(f::Core.Function, args...)
    mod = Module(args...)
    try
        f(mod)
    finally
        dispose(mod)
    end
end

function Base.show(io::IO, mod::Module)
    output = string(mod)
    print(io, output)
end

function name(mod::Module)
    out_len = Ref{Csize_t}()
    ptr = convert(Ptr{UInt8}, API.LLVMGetModuleIdentifier(mod, out_len))
    return unsafe_string(ptr, out_len[])
end
name!(mod::Module, str::String) =
    API.LLVMSetModuleIdentifier(mod, str, Csize_t(length(str)))

triple(mod::Module) = unsafe_string(API.LLVMGetTarget(mod))
triple!(mod::Module, triple) = API.LLVMSetTarget(mod, triple)

datalayout(mod::Module) = DataLayout(API.LLVMGetModuleDataLayout(mod))
datalayout!(mod::Module, layout::String) = API.LLVMSetDataLayout(mod, layout)
datalayout!(mod::Module, layout::DataLayout) =
    API.LLVMSetModuleDataLayout(mod, layout)

inline_asm!(mod::Module, asm::String) =
    API.LLVMSetModuleInlineAsm(mod, asm)

context(mod::Module) = Context(API.LLVMGetModuleContext(mod))

set_used!(mod::Module, values::GlobalVariable...) =
    API.LLVMExtraAppendToUsed(mod, collect(values), length(values))

set_compiler_used!(mod::Module, values::GlobalVariable...) =
    API.LLVMExtraAppendToCompilerUsed(mod, collect(values), length(values))


## named metadata iteration

export metadata, NamedMDNode, operands

# a named metadata note, tying together a name and a MDNode

struct NamedMDNode
    parent::LLVM.Module # not exposed by the API
    ref::API.LLVMNamedMDNodeRef
end

Base.unsafe_convert(::Type{API.LLVMNamedMDNodeRef}, node::NamedMDNode) = node.ref

function Base.getproperty(node::NamedMDNode, property::Symbol)
    if property == :name
        len = Ref{Csize_t}()
        data = API.LLVMGetNamedMetadataName(node, len)
        unsafe_string(convert(Ptr{Int8}, data), len[])
    else
        getfield(node, property)
    end
end

function Base.show(io::IO, mime::MIME"text/plain", node::NamedMDNode)
    print(io, "!$(node.name) = ")
    show(io, mime, operands(node))
    return io
end

operands(node::NamedMDNode) = NamedMDNodeOperands(node.parent, node.name)

# the metadata operands of a named metadata node

# NOTE: we don't have a simple setindex!-based API here, since LLVMAddNamedMetadataOperand
#       adds operands, and doesn't override them.

struct NamedMDNodeOperands
    mod::LLVM.Module
    name::String
end

# XXX: D47179 didn't add a NamedMDNode-based API for getting/setting metadata operands...
#      so we still use the old, Module-based API here.

function Base.collect(iter::NamedMDNodeOperands)
    nops = API.LLVMGetNamedMetadataNumOperands(iter.mod, iter.name)
    ops = Vector{API.LLVMValueRef}(undef, nops)
    if nops > 0
        API.LLVMGetNamedMetadataOperands(iter.mod, iter.name, ops)
    end
    vals = MetadataAsValue[MetadataAsValue(op) for op in ops]
    return map(Metadata, vals)
end

Base.push!(iter::NamedMDNodeOperands, val::Metadata) =
    API.LLVMAddNamedMetadataOperand(iter.mod, iter.name, Value(val))

function Base.show(io::IO, mime::MIME"text/plain", iter::NamedMDNodeOperands)
    print(io, "!{")
    for (i, op) in enumerate(collect(iter))
        i > 1 && print(io, ", ")
        show(io, mime, op)
    end
    print(io, "}")

    return io
end

# module metadata iteration

struct ModuleMetadataIterator <: AbstractDict{String,NamedMDNode}
    mod::Module
end

"""
    metadata(mod)

Fetch the module-level named metadata. This can be inspected using a Dict-like interface.
Mutation is different: There is no `setindex!` method, as named metadata is append-only.
Instead, fetch the relevant metadata using `getindex`, and `push!` to its `operands(...)`.
"""
metadata(mod::Module) = ModuleMetadataIterator(mod)

function Base.show(io::IO, mime::MIME"text/plain", iter::ModuleMetadataIterator)
    print(io, "ModuleMetadataIterator for module $(name(iter.mod)):")
    for (key,val) in iter
        print(io, "\n  !$key = ")
        show(io, mime, operands(val))
    end
    return io
end

function Base.iterate(iter::ModuleMetadataIterator, state=API.LLVMGetFirstNamedMetadata(iter.mod))
    if state == C_NULL
        nothing
    else
        node = NamedMDNode(iter.mod, state)
        (node.name => node, API.LLVMGetNextNamedMetadata(state))
    end
end

Base.last(iter::ModuleMetadataIterator) =
    NamedMDNode(iter.mod, API.LLVMGetLastNamedMetadata(iter.mod))

Base.isempty(iter::ModuleMetadataIterator) =
    API.LLVMGetLastNamedMetadata(iter.mod) == C_NULL

Base.IteratorSize(::ModuleMetadataIterator) = Base.SizeUnknown()

function Base.haskey(iter::ModuleMetadataIterator, name::String)
    return API.LLVMGetNamedMetadata(iter.mod, name, length(name)) != C_NULL
end

function Base.getindex(iter::ModuleMetadataIterator, name::String)
    ref = API.LLVMGetOrInsertNamedMetadata(iter.mod, name, length(name))
    @assert ref != C_NULL
    node = NamedMDNode(iter.mod, ref)
    return node
end


## global variable iteration

export globals

struct ModuleGlobalSet
    mod::Module
end

globals(mod::Module) = ModuleGlobalSet(mod)

Base.eltype(::ModuleGlobalSet) = GlobalVariable

function Base.iterate(iter::ModuleGlobalSet, state=API.LLVMGetFirstGlobal(iter.mod))
    state == C_NULL ? nothing : (GlobalVariable(state), API.LLVMGetNextGlobal(state))
end

Base.last(iter::ModuleGlobalSet) =
    GlobalVariable(API.LLVMGetLastGlobal(iter.mod))

Base.isempty(iter::ModuleGlobalSet) =
    API.LLVMGetLastGlobal(iter.mod) == C_NULL

Base.IteratorSize(::ModuleGlobalSet) = Base.SizeUnknown()

# partial associative interface

function Base.haskey(iter::ModuleGlobalSet, name::String)
    return API.LLVMGetNamedGlobal(iter.mod, name) != C_NULL
end

function Base.getindex(iter::ModuleGlobalSet, name::String)
    objref = API.LLVMGetNamedGlobal(iter.mod, name)
    objref == C_NULL && throw(KeyError(name))
    return GlobalVariable(objref)
end


## function iteration

export functions

struct ModuleFunctionSet
    mod::Module
end

functions(mod::Module) = ModuleFunctionSet(mod)

Base.eltype(::ModuleFunctionSet) = Function

function Base.iterate(iter::ModuleFunctionSet, state=API.LLVMGetFirstFunction(iter.mod))
    state == C_NULL ? nothing : (Function(state), API.LLVMGetNextFunction(state))
end

Base.last(iter::ModuleFunctionSet) =
    Function(API.LLVMGetLastFunction(iter.mod))

Base.isempty(iter::ModuleFunctionSet) =
    API.LLVMGetLastFunction(iter.mod) == C_NULL

Base.IteratorSize(::ModuleFunctionSet) = Base.SizeUnknown()

# partial associative interface

function Base.haskey(iter::ModuleFunctionSet, name::String)
    return API.LLVMGetNamedFunction(iter.mod, name) != C_NULL
end

function Base.getindex(iter::ModuleFunctionSet, name::String)
    objref = API.LLVMGetNamedFunction(iter.mod, name)
    objref == C_NULL && throw(KeyError(name))
    return Function(objref)
end


## module flag iteration
# TODO: doesn't actually iterate, since we can't list the available keys

export flags

struct ModuleFlagDict <: AbstractDict{String,Metadata}
    mod::Module
end

flags(mod::Module) = ModuleFlagDict(mod)

Base.haskey(iter::ModuleFlagDict, name::String) =
    API.LLVMGetModuleFlag(iter.mod, name, length(name)) != C_NULL

function Base.getindex(iter::ModuleFlagDict, name::String)
    objref = API.LLVMGetModuleFlag(iter.mod, name, length(name))
    objref == C_NULL && throw(KeyError(name))
    return Metadata(objref)
end

function Base.setindex!(iter::ModuleFlagDict, val::Metadata,
                        (name, behavior)::Tuple{String, API.LLVMModuleFlagBehavior})
    API.LLVMAddModuleFlag(iter.mod, behavior, name, length(name), val)
end
