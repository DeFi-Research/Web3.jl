"""
    Web3

A module for Ethereum connectivity.

Parse ABI files, encode/decode ABI data, and make JSON-RPC calls.
"""
module Web3

#=
Parse ABI files and encode / decode ABI data

TUPLE AND FIXED LENGTH ARRAY: [fix1 ... fixN][var1 ... varN]
for static types, fixN is the encoded data and varN is empty
for dynamic types, fixN is the length as a uint256 and varN is the encoded data

DYNAMIC ARRAY: [LEN][ARRAY ENCODING...]

UINT<M> and INT<M>: encoded as 32-byte, big-endian values, i.e. as uint256 and int256 numbers

BYTES: [len as uint256][data]

STRING: a bytes representation of the UTF-8 data

ADDRESS: a uint160, encoded as a 32-byte, big-endian value

BOOL: a uint8, encoded as a 32-byte, big-endian value

BYTES<M>: the sequence of bytes, padded with trailing zeroes to a length of 32-bytes

FUNCTION CALL: [4-byte hash][args tuple]
hash is the first 4 high-order bytes of the hash of the signature name(type,type...)

RETURN VALUE: [return tuple]

EVENT: [contract address][topics[0]: signature][topics[n]: indexed args[n - 1]][data -- unindexed args]
topics are 32-bytes; dynamic values are represented as a hash and lose information
=#

####
#### CAVEATS
####
#### 1) THIS USES THE JSON API FOR KECCAK, WHICH IS HORRIBLY INEFFICIENT
####    THIS IS ONLY DONE WHILE PARSING ABIS BUT WE SHOULD CHANGE IT TO A LOCAL CALL
####    MAYBE LINK TO THE CORRUS VERSION: https://github.com/coruus/keccak-tiny
####    THE PROBLEM IS THAT IT RELIES ON MEMSET_S WHICH IS NOT CURRENTLY AVAILABLE IN LINUX
####    SURE WOULD BE NICE TO HAVE SHAKE256 IN PURE JULIA
####    MAYBE SOMEONE WILL PORT [jsSHA](https://caligatio.github.io/jsSHA)
####

using HTTP, JSON, Core

export readABI, Web3Connection, Contract, contracts
export FunctionCall, encodefunctioncall, decodefunctioncall
export FunctionResult, encodefunctionresult, decodefunctionresult
export Event, encodeevent, decodeevent
export clientversion, eth, utils
export computetypes, ContractContext, contract, connection, functions
export sha3_224, sha3_256, sha3_384, sha3_512
export keccac224, keccac256, keccac384, keccac512

include("keccak.jl")

####################
# Web3
####################

"""
    Web3Connection

A JSON-RPC connection to an Ethereum node

```
    web3 = Web3Connection("http://localhost:8545")
    clientversion(web3) # -- return the client version
    jsonget("http://localhost:8545", :web3_clientVersion, []) # -- equivalent to clientversion(web3)
    rawjsonget("http://localhost:8545", :web3_clientVersion, []) # -- return full JSON object
```
"""
struct Web3Connection
    url
end

"""
    jsonget(url, methodname, params...)

Call a JSON-RPC method and return the result property of the JSON result
"""
#jsonget(url, method, params...) = rawjsonget(url, method, params...)["result"]
function jsonget(url, method, params...)
    rawjsonget(url, method, params...)
    println("JSON: ", repr(json))
    json["result"]
end

"""
    rawjsonget(url, method, params...)

Call a JSON-RPC method and return the full JSON result
"""
function rawjsonget(url, method, params...)
    req = JSON.json(Dict([
        :jsonrpc => "2.0"
        :method => method
        :params => params
    ]))
    if verbose
        println("REQUEST: $(repr(req))")
    end
    resp = HTTP.request("POST", url, [], req)
    if resp.status == 200
        resultstr = String(resp.body)
        result = JSON.parse(resultstr)
        if verbose
            println("RESULT JSON: $resultstr")
            println("RESULT: $(repr(result))")
        end
        result
    else
        throw(ErrorException("Error, status = $(resp.status)"))
    end
end

"""
    apifunc

Create a call to an API func, given a function that converts inputs to JSON-ready inputs
"""
apifunc(apimethod, func) = (con::Web3Connection, args...; raw=false)-> (raw ? rawjsonget : jsonget)(con.url, apimethod, func(args...)...)

function hash end

const clientversion = apifunc(:web3_clientVersion, ()->[])
const eth = (
    gettransactioncount = apifunc(:eth_getTransactionCount, (addr, ctx)-> (addr, ctx)),
    gettransactionbyhash = apifunc(:eth_getTransactionByHash, (hash)-> (hash)),
    sendtransaction = apifunc(:eth_sendTransaction, (from, to, gas, gasprice, value, data, nonce)->
                              Dict([:from => from
                                    :to => to
                                    :gas => gas
                                    :gasprice => gasprice
                                    :value => value
                                    :data => data
                                    :nonce => nonce])))
const utils = (keccak = hash,)

# This is a separate function so that test code can override it
function hash(con::Web3Connection, str::String)
#    hex2bytes(jsonget(con.url, :web3_sha3, ("0x" * bytes2hex(Vector{UInt8}(str))))[3:end])
    keccak256(collect(UInt8, str))
end

"""
    resultbytes

Convert a JSON-RPC API call result to bytes
"""
resultbytes(func) = (args...)-> hex2bytes(func(args...)[3:end])

####################
# ABI
####################

struct Int256
    big::Int128
    little::UInt128
    Int256(i::Integer) = new(i < 0 ? -1 : 0, i)
    Int256(big::Integer, little::Unsigned) = new(big, little)
end

struct UInt256
    big::UInt128
    little::UInt128
    UInt256(i::Unsigned) = new(0, i)
    UInt256(big::Unsigned, little::Unsigned) = new(big, little)
end

struct ABIType{T}
    ABIType(arg) = new{arg}()
end

struct Decl{ENCMODE, X, Y, Z}
    name::String
    typename::String
    components::Array
    indexed::Bool
end

struct ABIFunction
    constant
    hash # first 4 bytes of keccak hash
    inputs::Array{Decl}
    name
    outputs
    payable
    signature
    statemutability
    argtypes
end

struct ABIEvent
    name
    hash
    signature
    anonymous
    inputs::Array{Decl}
end

struct FunctionCall
    decl
    inputs::Array
end

struct FunctionResult
    decl
    result
end

struct Event
    decl
    parameters::Array
end

struct Contract{Name}
    id::String
    functions
    events
    function Contract(id::String)
        id = cleanaddress(id)
        new{Symbol(id)}(id, Dict{Union{String, Vector{UInt8}}, ABIFunction}(), Dict())
    end
end

function cleanaddress(str::String)
    if match(r"^0[xX]", str) != nothing
        str = str[3:end]
    end
    @assert match(r"[0-9a-fA-F]{20}", str) != nothing
    str
end

const NumDecl = Union{Decl{T, :int} where T, Decl{T, :uint} where T}
const FunctionABI = Union{ABIType{:function}, ABIType{:constructor}, ABIType{:fallback}};

"A dictionary of contract-address => Contract structures"
const contracts = Dict()

const fixedarraypattern = r".*\[([^\]]+)\]"
const bitspattern = r"^([^[0-9]+)([0-9]*)"

##############
# ENCODING
##############

"""
    encodefunctioncall(io::IO, f::ABIFunction, inputs::Array)

Encode a call to a function
"""
function encodefunctioncall(io::IO, f::ABIFunction, inputs::Array)
    basicencodefunctioncall(io, f, inputs)
end

function encodefunctioncall(io::IOBuffer, f::ABIFunction, inputs::Array)
    basicencodefunctioncall(io, f, inputs)
    io.data
end

function basicencodefunctioncall(io::IO, f::ABIFunction, inputs::Array)
    write(io, f.hash)
    encode(io, f.inputs, inputs)
end

"""
    encodefunctionresult(io::IO, f::ABIFunction, outputs::Array)

Encode the results of a function
"""
function encodefunctionresult(io::IO, f::ABIFunction, outputs::Array)
    basicencodefunctionresult(io, f, outputs)
end

function encodefunctionresult(io::IOBuffer, f::ABIFunction, outputs::Array)
    basicencodefunctionresult(io, f, outputs)
    io.data
end

function basicencodefunctionresult(io::IO, f::ABIFunction, outputs::Array)
    write(io, f.hash)
    encode(io, f.outputs, outputs)
end

"""
    encodeevent(io::IO, e::ABIEvent, inputs::Array)

Encode an event
"""
function encodeevent(io::IO, e::ABIEvent, inputs::Array)
    basicencodeevent(io, e, inputs)
end

function encodeevent(io::IOBuffer, e::ABIEvent, inputs::Array)
    basicencodeevent(io, e, inputs)
    io.data
end

function basicencodeevent(io::IO, e::ABIEvent, inputs::Array)
    write(io, e.hash)
    encode(io, e.inputs, inputs)
end

function encode(io::IO, decl::Union{Decl, Array}, value)
    encodehead(io, decl, value)
    encodetail(io, decl, value)
end

# utilities
writeint(io, i::Signed) = writeints(io, Int128(i < 0 ? -1 : 0), Int128(i))
writeint(io, i::Unsigned) = writeints(io, UInt128(0), UInt128(i))
writeint(io, i::Union{Int256, UInt256}) = writeints(io, i.big, i.little)
writeints(io, ints...) = write(io, hton.(ints)...)
encodescalar(io::IO, decl::Decl{Any, :bool}, value) = writeint(io, value ? 1 : 0)
encodescalar(io::IO, decl::NumDecl, value) = writeint(io, value)

# scalar types
encodehead(io, decl::Decl{:scalar}, v) = encodescalar(io, decl, v)
encodetail(io, ::Decl{:scalar}, v) = nothing

# dynamic types
encodehead(io, ::Union{Decl{:string}, Decl{:bytes}, Decl{:dynamic}}, v) = writeuint(io, length(v))
encodetail(io, ::Union{Decl{:string}, Decl{:bytes}}, v) = write(io, v)
function encodetail(io::IO, decl::Decl{:dynamic}, values)
    for v in values
        encodescalar(decl, v)
    end
end

# array
function encodehead(io::IO, decl::Decl{:array, BASE, BITS, LENGTH}, values) where {BASE, BITS, LENGTH}
    t = arraycomptype(decl)
    for i in 1:LENGTH
        encodehead(io, t, values[i])
    end
end
function encodetail(io::IO, decl::Decl{:array}, values)
    t = arraycomptype(decl)
    for i in 1:LENGTH
        encodetail(io, t, values[i])
    end
end
function arraycomptype(decl::Decl{:array, BASE, BITS, LENGTH}) where {BASE, BITS, LENGTH}
    if decl.components != nothing
        Decl{:tuple, length(decl.components), :n, :n}(decl.name, "tuple", decl.components, false)
    else
        Decl{:scalar, BASE, BITS, :none}(decl.name, decl.typename, :nothing, false)
    end
end

# tuple
encodehead(io::IO, decl::Decl{:tuple}, values) = encodehead(io, decl.components, values)
encodetail(io::IO, decl::Decl{:tuple}, values) = encodetail(io, decl.components, values)
function encodehead(io::IO, decls::Array, values)
    for i in 1:length(decls)
        encodehead(io, decls[i], values[i])
    end
end
function encodetail(io::IO, decls::Array, values)
    for i in 1:length(decls)
        encodetail(io, decls[i], values[i])
    end
end

############
# DECODING
############

const signedTypes = Dict([t.size => t for t in (Int8, Int16, Int32, Int64, Int128)])
const unsignedTypes = Dict([t.size => t for t in (UInt8, UInt16, UInt32, UInt64, UInt128)])

function readint(io::IO)
    big = read(io, Int128)
    Int256(ntoh(big), ntoh(read(io, UInt128)))
end

function readuint(io::IO)
    big = read(io, UInt128)
    Int256(ntoh(big), ntoh(read(io, UInt128)))
end

readlength(io::IO) = (read(io, UInt128);read(io, UInt128))

"""
    decodefunctioncall(io::IO, con::Contract)

Decode a function call
"""
function decodefunctioncall(io::IO, con::Contract)
    decl = con.functions[read(io, 4)]
    FunctionCall(decl, decode(io, decl.inputs))
end

"""
    decodefunctionresult(io::IO, con::Contract)

Decode a function call result
"""
function decodefunctionresult(io::IO, con::Contract)
    hash = read(io, 4)
    f = con.functions[hash]
    FunctionResult(f, decode(io, f.outputs))
end

"""
    decodeevent(io::IO, con::Contract)

Decode an event in a transaction log
"""
function decodeevent(io::IO, con::Contract)
    decl = con.events[read(io, 4)]
    Event(decl, decode(io, decl.inputs))
end

# general
decode(io::IO, decl) = decodetail(io, decl, decodehead(io, decl))

# scalar types
decodehead(io::IO, decl::Decl{:scalar}) = decodescalar(io, decl)
decodetail(io::IO, ::Decl{:scalar}, head) = head
function decodescalar(io::IO, ::Decl{T, :int, SIZE}) where {T, SIZE}
    big = ntoh(read(io, Int128))
    little = ntoh(read(io, UInt128))
    SIZE <= 128 ? smallint(SIZE, big < 0 ? -little : little) : Int256(big, little)
end
function decodescalar(io::IO, ::Decl{T, :uint, SIZE}) where {T, SIZE}
    big = ntoh(read(io, UInt128))
    little = ntoh(read(io, UInt128))
    SIZE <= 128 ? smalluint(SIZE, little) : UInt256(big, little)
end

smallint(size, value) = signedTypes[Int(2^ceil(log2(floor((33 + 7) / 8))))](value)
smalulint(size, value) = unsignedTypes[Int(2^ceil(log2(floor((33 + 7) / 8))))](value)

function decode(io::IO, ::Decl{T, :bool}) where T
    big = read(io, UInt128)
    little = read(io, UInt128)
    litle == 0 ? false : true
end

# dynamic types
decodehead(io::IO, decl::Decl{:dynamic, :bytes}) = readlength(io)
decodetail(io::IO, decl::Decl{:dynamic, :bytes}, head) = readbytes(io, head)
readbytes(io::IO, len) = read(io, len)

decodehead(io::IO, decl::Decl{:dynamic, :string}) = readlength(io)
decodetail(io::IO, decl::Decl{:dynamic, :string}, head) = readbytes(io, head)
readstring(io::IO, len) = String(read(io, len))

# array types
function decode(io::IO, decl::Decl{:array, BASE, BITS, LENGTH}) where {BASE, BITS, LENGTH}
    [decodescalar(io, decl) for i in 1:LENGTH]
end
function decode(io::IO, ::Decl{:array, :bytes, BITS, LENGTH}) where {BITS, LENGTH}
    lens = [readlength(io) for i in 1:LENGTH]
    [readbytes(io, len) for len in lens]
end
function decode(io::IO, ::Decl{:array, :string, BITS, LENGTH}) where {BITS, LENGTH}
    lens = [readlength(io) for i in 1:LENGTH]
    [String(readbytes(io, len)) for len in lens]
end
function decode(io::IO, decl::Decl{:array, :tuple, BITS, LENGTH}) where {BITS, LENGTH}
    decodetail(io::IO, decl.components, decodehead(io::IO, decl.components))
end

# tuple
decode(io::IO, decl::Decl{:tuple}) = decodetail(io, decl.components)
decode(io::IO, decls::Array) = decodetail(io, decls, decodehead(io, decls))
decodehead(io::IO, decls::Array) = [decodehead(io, head) for head in decls]
decodetail(io::IO, decls::Array, heads) = [decodetail(io, decls[i], heads[i]) for i in 1:length(decls)]

####################
# DECL PARSING
####################

rows(array) = [array[row, :] for row in 1:size(a)[1]]

# Make conversion mapping given specs:
#   (Solidity-prefix, Julia type, byte length)
conversions(rows) = vcat([["$stype$(bytes * 8)" => jtype for bytes in rng] for (stype, jtype, rng) in rows]...)

const soliditytojulia = Dict(conversions([
    # Solidity-prefix, Julia type, bytes
    ("int", Int8, [8])
    ("uint", UInt8, [8])
    ("int", Int16, [16])
    ("uint", UInt16, [16])
    ("int", Int32, 3:4)
    ("uint", UInt32, 3:4)
    ("int", Int64, 5:8)
    ("uint", UInt64, 5:8)
    ("int", Int128, 9:16)
    ("uint", UInt128, 9:16)
    ("int", BigInt, 17:32)
    ("uint", BigInt, 17:32)
]))

parseABI(connection::Web3Connection, json) = parseABI(connection, ABIType(Symbol(get(json, "type", "function"))), json)
function parseABI(connection::Web3Connection, ::FunctionABI, func)
    name = func["name"]
    args = join((arg-> arg["type"]).(func["inputs"]), ",")
    sig = "$name($args)"
    inputs = parseargs(func["inputs"])
    ABIFunction(
        func["constant"],
        utils.keccak(connection, sig)[1:4],
        inputs,
        name,
        haskey(func, "outputs") ? parseargs(func["outputs"]) : [],
        func["payable"],
        sig,
        func["stateMutability"],
        computetypes(name, inputs)
    )
end

function parseABI(connection::Web3Connection, ::ABIType{:event}, evt)
    name = evt["name"]
    args = join((arg-> arg["type"]).(evt["inputs"]), ",")
    sig = "$name($args)"
    ABIEvent(evt["name"], utils.keccak(connection, sig)[1:4], sig, get(evt, "anonymous", false), parseargs(evt["inputs"]))
end

computetype(decl::Decl{T, :int, SIZE}) where {T, SIZE} = soliditytojulia["int$SIZE"]
computetype(decl::Decl{T, :uint, SIZE}) where {T, SIZE} = soliditytojulia["uint$SIZE"]
computetype(decl::Decl{:tuple, SIZE}) where {T, SIZE} = "tuple[$SIZE]"
computetype(decl::Decl{:array, BASE, BITS, LENGTH}) where {BASE, BITS, LENGTH} = "array[LENGTH] of $BASE"
computetype(decl::Decl{T, :bool} where {T}) = Bool
computetype(decl::Decl{:string}) = String
computetype(decl::Decl{:bytes}) = Vector{UInt8}
computetype(decl::Decl{:dynamic, TYPE}) where TYPE = "array of $TYPE"

computetypes(func::ABIFunction) = computetypes(func.name, func.inputs)
function computetypes(name, decls::Array{T} where T <: Decl)
    computetype.(decls)
end

"""
    readABI(con::Web3Connection, contractname::String, stream::IO)

Read an ABI file for a contract
"""
function readABI(connection::Web3Connection, contractname::String, stream::IO)
    contract = Contract(contractname)
    d = JSON.parse(stream)
    close(stream)
    for json in (haskey(d, "abi") ? d["abi"] : d)
        obj = parseABI(connection, json)
        if isa(obj, ABIFunction)
            contract.functions[obj.name] = contract.functions[obj.hash] = obj
            if verbose
                println("$(bytes2hex(obj.hash)) $(obj.signature) $(repr(obj)) $(bytes2hex(utils.keccak(connection, obj.signature)))")
            end
        elseif isa(obj, ABIEvent)
            contract.events[obj.name] = contract.events[obj.hash] = obj
            if verbose
                println("$(bytes2hex(obj.hash)) $(obj.signature) $(repr(obj)) $(bytes2hex(utils.keccak(connection, obj.signature)))")
            end
        elseif verbose
            println(repr(obj))
        end
    end
    contracts[contractname] = contract
end

function basetypefor(typename)
    m = match(bitspattern, typename)
    (Symbol(m[1]), m[2] == "" ? 256 : parse(Int, m[2]))
end

function typefor(typename, arg)
    atype = arg["type"]
    if endswith(atype, "[]")
        (:dynamic, basetypefor(typename)..., :none)
    elseif endswith(atype, "]")
        m = match(fixedarraypattern, typename)
        (:array, basetypefor(typename)..., parse(Int, m[1]))
    elseif atype == "tuple"
        (:tuple, length(arg["components"]), :none, :none)
    elseif atype in ["string", "bytes"]
        (Symbol(atype), :none, :none, :none)
    else
        (:scalar, basetypefor(typename)..., :none)
    end
end

function parsearg(arg)
    typename = arg["type"]
    (enctype, atype, bits, len) = typefor(typename, arg)
    Decl{enctype, atype, bits, len}(
        arg["name"],
        typename,
        haskey(arg, "components") ? parseargs(arg["components"]) : [],
        get(arg, "indexed", false)
    )
end

parseargs(args) = parsearg.(args)

####################
# UTILS
####################

global verbose = false

struct ContractContext{contractid}
    connection
    contract
end

connection(con::ContractContext) = getfield(con, :connection)

contract(con::ContractContext) = getfield(con, :contract)

functions(con::ContractContext) = contract(con).functions

struct Val{Name} end

function gen(contract, con)
    funcs = collect(filter(p-> isa(p[1], String), contract.functions))
    methods = map(funcs) do ((name, func))
        argnames = map(a-> Symbol("a$a"), 1:length(func.argtypes))
        args = map(((name, type)::Tuple)-> :($name::$type), zip(argnames, func.argtypes))
        :($(Symbol(name)) = ($(args...),)-> (
            send = (from; options...)-> send(context, $name, from, ($(argnames...),); options...),
            call = ()-> (),
            estimategas = ()-> (),
            encodeabi = ()-> ()
        ))
    end
    type = ContractContext{Symbol(contract.id)}
    eval(:(Base.getproperty(context::$type, prop::Symbol) = ($(methods...),)[prop]))
end

"""
    send(id, data; options)

options are: gasprice, gas, value, nonce, chain, hardfork, common
"""
function send(context::ContractContext, name, from, args, options...)
    println("Call $name in contract $(contract(context).id)\nfrom account $(from)")
    transaction = merge!(Dict([
        :to => contract(context).id
        :from => from
        :data=> encodearguments(args)]), pairs(options))
    result = rawjsonget(connection(context).url, :eth_sendTransaction, transaction)
    if haskey(result, "error")
        err = result["error"]
        println("ERROR: $(err["message"])\n$(err["data"]["stack"])")
    end
    println("JSON: $(repr(result))")
    result
end

encodearguments(args) = :ENCODED_ARGUMENTS

ContractContext(con::Web3Connection, contract::String, filename::String) = ContractContext(con, contract, open(filename))

function ContractContext(con::Web3Connection, contractid::String, file::IO)
    contract = readABI(con, contractid, file)
    gen(contract, con)
    ContractContext{Symbol(contract.id)}(con, contract)
end

function setverbose(v)
    global verbose
    verbose = v
end


end # module
