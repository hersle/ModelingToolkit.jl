symconvert(::Type{Symbolics.Struct{T}}, x) where {T} = convert(T, x)
symconvert(::Type{T}, x) where {T} = convert(T, x)
symconvert(::Type{Real}, x::Integer) = convert(Float64, x)
symconvert(::Type{V}, x) where {V <: AbstractArray} = convert(V, symconvert.(eltype(V), x))

struct MTKParameters{T, D, C, N}
    tunable::T
    discrete::D
    constant::C
    nonnumeric::N
end

"""
    function MTKParameters(sys::AbstractSystem, p, u0 = Dict(); t0 = nothing)

Create an `MTKParameters` object for the system `sys`. `p` (`u0`) are symbolic maps from
parameters (unknowns) to their values. The values can also be symbolic expressions, which
are evaluated given the values of other parameters/unknowns. `u0` is only required if
the values of parameters depend on the unknowns. `t0` is the initial time, for time-
dependent systems. It is only required if the symbolic expressions also use the independent
variable of the system.

This requires that `complete` has been called on the system (usually via
`structural_simplify` or `@mtkbuild`) and the keyword `split = true` was passed (which is
the default behavior).
"""
function MTKParameters(
        sys::AbstractSystem, p, u0 = Dict(); tofloat = false, use_union = false,
        t0 = nothing)
    ic = if has_index_cache(sys) && get_index_cache(sys) !== nothing
        get_index_cache(sys)
    else
        error("Cannot create MTKParameters if system does not have index_cache")
    end
    all_ps = Set(unwrap.(parameters(sys)))
    union!(all_ps, default_toterm.(unwrap.(parameters(sys))))
    if p isa Vector && !(eltype(p) <: Pair) && !isempty(p)
        ps = parameters(sys)
        length(p) == length(ps) || error("Invalid parameters")
        p = ps .=> p
    end
    if p isa SciMLBase.NullParameters || isempty(p)
        p = Dict()
    end
    p = todict(p)
    defs = Dict(default_toterm(unwrap(k)) => v for (k, v) in defaults(sys))
    if eltype(u0) <: Pair
        u0 = todict(u0)
    elseif u0 isa AbstractArray && !isempty(u0)
        u0 = Dict(unknowns(sys) .=> vec(u0))
    elseif u0 === nothing || isempty(u0)
        u0 = Dict()
    end
    defs = merge(defs, u0)
    defs = merge(Dict(eq.lhs => eq.rhs for eq in observed(sys)), defs)
    bigdefs = merge(defs, p)
    if t0 !== nothing
        bigdefs[get_iv(sys)] = t0
    end
    p = Dict()
    missing_params = Set()
    pdeps = has_parameter_dependencies(sys) ? parameter_dependencies(sys) : nothing

    for sym in all_ps
        ttsym = default_toterm(sym)
        isarr = iscall(sym) && operation(sym) === getindex
        arrparent = isarr ? arguments(sym)[1] : nothing
        ttarrparent = isarr ? default_toterm(arrparent) : nothing
        pname = hasname(sym) ? getname(sym) : nothing
        ttpname = hasname(ttsym) ? getname(ttsym) : nothing
        p[sym] = p[ttsym] = if haskey(bigdefs, sym)
            bigdefs[sym]
        elseif haskey(bigdefs, ttsym)
            bigdefs[ttsym]
        elseif haskey(bigdefs, pname)
            isarr ? bigdefs[pname][arguments(sym)[2:end]...] : bigdefs[pname]
        elseif haskey(bigdefs, ttpname)
            isarr ? bigdefs[ttpname][arguments(sym)[2:end]...] : bigdefs[pname]
        elseif isarr && haskey(bigdefs, arrparent)
            bigdefs[arrparent][arguments(sym)[2:end]...]
        elseif isarr && haskey(bigdefs, ttarrparent)
            bigdefs[ttarrparent][arguments(sym)[2:end]...]
        end
        if get(p, sym, nothing) === nothing
            push!(missing_params, sym)
            continue
        end
        # We may encounter the `ttsym` version first, add it to `missing_params`
        # then encounter the "normal" version of a parameter or vice versa
        # Remove the old one in `missing_params` just in case
        delete!(missing_params, sym)
        delete!(missing_params, ttsym)
    end

    if pdeps !== nothing
        for eq in pdeps
            sym = eq.lhs
            expr = eq.rhs
            sym = unwrap(sym)
            ttsym = default_toterm(sym)
            delete!(missing_params, sym)
            delete!(missing_params, ttsym)
            p[sym] = p[ttsym] = expr
        end
    end

    isempty(missing_params) || throw(MissingParametersError(collect(missing_params)))

    p = Dict(unwrap(k) => fixpoint_sub(v, bigdefs) for (k, v) in p)
    for (sym, _) in p
        if iscall(sym) && operation(sym) === getindex &&
           first(arguments(sym)) in all_ps
            error("Scalarized parameter values ($sym) are not supported. Instead of `[p[1] => 1.0, p[2] => 2.0]` use `[p => [1.0, 2.0]]`")
        end
    end

    tunable_buffer = Vector{ic.tunable_buffer_size.type}(
        undef, ic.tunable_buffer_size.length)
    disc_buffer = SizedArray{Tuple{length(ic.discrete_buffer_sizes)}}([Tuple(Vector{temp.type}(
                                                                                 undef,
                                                                                 temp.length)
                                                                       for temp in subbuffer_sizes)
                                                                       for subbuffer_sizes in ic.discrete_buffer_sizes])
    const_buffer = Tuple(Vector{temp.type}(undef, temp.length)
    for temp in ic.constant_buffer_sizes)
    nonnumeric_buffer = Tuple(Vector{temp.type}(undef, temp.length)
    for temp in ic.nonnumeric_buffer_sizes)
    function set_value(sym, val)
        done = true
        if haskey(ic.tunable_idx, sym)
            idx = ic.tunable_idx[sym]
            tunable_buffer[idx] = val
        elseif haskey(ic.discrete_idx, sym)
            i, j, k = ic.discrete_idx[sym]
            disc_buffer[i][j][k] = val
        elseif haskey(ic.constant_idx, sym)
            i, j = ic.constant_idx[sym]
            const_buffer[i][j] = val
        elseif haskey(ic.nonnumeric_idx, sym)
            i, j = ic.nonnumeric_idx[sym]
            nonnumeric_buffer[i][j] = val
        elseif !isequal(default_toterm(sym), sym)
            done = set_value(default_toterm(sym), val)
        else
            done = false
        end
        return done
    end
    for (sym, val) in p
        sym = unwrap(sym)
        val = unwrap(val)
        ctype = symtype(sym)
        if symbolic_type(val) !== NotSymbolic()
            error("Could not evaluate value of parameter $sym. Missing values for variables in expression $val.")
        end
        val = symconvert(ctype, val)
        done = set_value(sym, val)
        if !done && Symbolics.isarraysymbolic(sym)
            if Symbolics.shape(sym) === Symbolics.Unknown()
                for i in eachindex(val)
                    set_value(sym[i], val[i])
                end
            else
                if size(sym) != size(val)
                    error("Got value of size $(size(val)) for parameter $sym of size $(size(sym))")
                end
                set_value.(collect(sym), val)
            end
        end
    end
    tunable_buffer = narrow_buffer_type(tunable_buffer)
    if isempty(tunable_buffer)
        tunable_buffer = SizedVector{0, Float64}()
    end
    disc_buffer = broadcast.(narrow_buffer_type, disc_buffer)
    const_buffer = narrow_buffer_type.(const_buffer)
    # Don't narrow nonnumeric types
    nonnumeric_buffer = nonnumeric_buffer

    mtkps = MTKParameters{
        typeof(tunable_buffer), typeof(disc_buffer), typeof(const_buffer),
        typeof(nonnumeric_buffer)}(tunable_buffer, disc_buffer, const_buffer,
        nonnumeric_buffer)
    return mtkps
end

function narrow_buffer_type(buffer::AbstractArray)
    type = Union{}
    for x in buffer
        type = promote_type(type, typeof(x))
    end
    return convert.(type, buffer)
end

function narrow_buffer_type(buffer::AbstractArray{<:AbstractArray})
    buffer = narrow_buffer_type.(buffer)
    type = Union{}
    for x in buffer
        type = promote_type(type, eltype(x))
    end
    return broadcast.(convert, type, buffer)
end

function buffer_to_arraypartition(buf)
    return ArrayPartition(ntuple(i -> _buffer_to_arrp_helper(buf[i]), Val(length(buf))))
end

_buffer_to_arrp_helper(v::T) where {T} = _buffer_to_arrp_helper(eltype(T), v)
_buffer_to_arrp_helper(::Type{<:AbstractArray}, v) = buffer_to_arraypartition(v)
_buffer_to_arrp_helper(::Any, v) = v

function _split_helper(buf_v::T, recurse, raw, idx) where {T}
    _split_helper(eltype(T), buf_v, recurse, raw, idx)
end

function _split_helper(::Type{<:AbstractArray}, buf_v, ::Val{N}, raw, idx) where {N}
    map(b -> _split_helper(eltype(b), b, Val(N - 1), raw, idx), buf_v)
end

function _split_helper(::Type{<:AbstractArray}, buf_v::Tuple, ::Val{N}, raw, idx) where {N}
    ntuple(i -> _split_helper(eltype(buf_v[i]), buf_v[i], Val(N - 1), raw, idx),
        Val(length(buf_v)))
end

function _split_helper(::Type{<:AbstractArray}, buf_v, ::Val{0}, raw, idx)
    _split_helper((), buf_v, (), raw, idx)
end

function _split_helper(_, buf_v, _, raw, idx)
    res = reshape(raw[idx[]:(idx[] + length(buf_v) - 1)], size(buf_v))
    idx[] += length(buf_v)
    return res
end

function split_into_buffers(raw::AbstractArray, buf, recurse = Val(1))
    idx = Ref(1)
    ntuple(i -> _split_helper(buf[i], recurse, raw, idx), Val(length(buf)))
end

function _update_tuple_helper(buf_v::T, raw, idx) where {T}
    _update_tuple_helper(eltype(T), buf_v, raw, idx)
end

function _update_tuple_helper(::Type{<:AbstractArray}, buf_v, raw, idx)
    ntuple(i -> _update_tuple_helper(buf_v[i], raw, idx), length(buf_v))
end

function _update_tuple_helper(::Any, buf_v, raw, idx)
    copyto!(buf_v, view(raw, idx[]:(idx[] + length(buf_v) - 1)))
    idx[] += length(buf_v)
    return nothing
end

function update_tuple_of_buffers(raw::AbstractArray, buf)
    idx = Ref(1)
    ntuple(i -> _update_tuple_helper(buf[i], raw, idx), Val(length(buf)))
end

SciMLStructures.isscimlstructure(::MTKParameters) = true

SciMLStructures.ismutablescimlstructure(::MTKParameters) = true

function SciMLStructures.canonicalize(::SciMLStructures.Tunable, p::MTKParameters)
    arr = p.tunable
    repack = let p = p
        function (new_val)
            if new_val !== p.tunable
                copyto!(p.tunable, new_val)
            end
            return p
        end
    end
    return arr, repack, true
end

function SciMLStructures.replace(::SciMLStructures.Tunable, p::MTKParameters, newvals)
    @set! p.tunable = newvals
    return p
end

function SciMLStructures.replace!(::SciMLStructures.Tunable, p::MTKParameters, newvals)
    copyto!(p.tunable, newvals)
    return nothing
end

for (Portion, field, recurse) in [(SciMLStructures.Discrete, :discrete, 2)
                                  (SciMLStructures.Constants, :constant, 1)
                                  (Nonnumeric, :nonnumeric, 1)]
    @eval function SciMLStructures.canonicalize(::$Portion, p::MTKParameters)
        as_vector = buffer_to_arraypartition(p.$field)
        repack = let as_vector = as_vector, p = p
            function (new_val)
                if new_val !== as_vector
                    update_tuple_of_buffers(new_val, p.$field)
                end
                p
            end
        end
        return as_vector, repack, true
    end

    @eval function SciMLStructures.replace(::$Portion, p::MTKParameters, newvals)
        @set! p.$field = $(
            if Portion == SciMLStructures.Discrete
            :(SizedVector{length(p.discrete)}(split_into_buffers(
                newvals, p.$field, Val($recurse))))
        else
            :(split_into_buffers(newvals, p.$field, Val($recurse)))
        end
        )
        p
    end

    @eval function SciMLStructures.replace!(::$Portion, p::MTKParameters, newvals)
        update_tuple_of_buffers(newvals, p.$field)
        nothing
    end
end

function Base.copy(p::MTKParameters)
    tunable = copy(p.tunable)
    discrete = typeof(p.discrete)([Tuple(eltype(buf) <: Real ? copy(buf) : copy.(buf)
                                   for buf in clockbuf) for clockbuf in p.discrete])
    constant = Tuple(eltype(buf) <: Real ? copy(buf) : copy.(buf) for buf in p.constant)
    nonnumeric = copy.(p.nonnumeric)
    return MTKParameters(
        tunable,
        discrete,
        constant,
        nonnumeric
    )
end

function SymbolicIndexingInterface.parameter_values(p::MTKParameters, pind::ParameterIndex)
    @unpack portion, idx = pind
    if portion isa SciMLStructures.Tunable
        return idx isa Int ? p.tunable[idx] : view(p.tunable, idx)
    end
    i, j, k... = idx
    if portion isa SciMLStructures.Tunable
        return isempty(k) ? p.tunable[i][j] : p.tunable[i][j][k...]
    elseif portion isa SciMLStructures.Discrete
        k, l... = k
        return isempty(l) ? p.discrete[i][j][k] : p.discrete[i][j][k][l...]
    elseif portion isa SciMLStructures.Constants
        return isempty(k) ? p.constant[i][j] : p.constant[i][j][k...]
    elseif portion === NONNUMERIC_PORTION
        return isempty(k) ? p.nonnumeric[i][j] : p.nonnumeric[i][j][k...]
    else
        error("Unhandled portion $portion")
    end
end

function SymbolicIndexingInterface.set_parameter!(
        p::MTKParameters, val, pidx::ParameterIndex)
    @unpack portion, idx, validate_size = pidx
    if portion isa SciMLStructures.Tunable
        if validate_size && size(val) !== size(idx)
            throw(InvalidParameterSizeException(size(idx), size(val)))
        end
        p.tunable[idx] = val
    else
        i, j, k... = idx
        if portion isa SciMLStructures.Discrete
            k, l... = k
            if isempty(l)
                if validate_size && size(val) !== size(p.discrete[i][j][k])
                    throw(InvalidParameterSizeException(
                        size(p.discrete[i][j][k]), size(val)))
                end
                p.discrete[i][j][k] = val
            else
                p.discrete[i][j][k][l...] = val
            end
        elseif portion isa SciMLStructures.Constants
            if isempty(k)
                if validate_size && size(val) !== size(p.constant[i][j])
                    throw(InvalidParameterSizeException(size(p.constant[i][j]), size(val)))
                end
                p.constant[i][j] = val
            else
                p.constant[i][j][k...] = val
            end
        elseif portion === NONNUMERIC_PORTION
            if isempty(k)
                p.nonnumeric[i][j] = val
            else
                p.nonnumeric[i][j][k...] = val
            end
        else
            error("Unhandled portion $portion")
        end
    end
    return nothing
end

function _set_parameter_unchecked!(
        p::MTKParameters, val, idx::ParameterIndex; update_dependent = true)
    @unpack portion, idx = idx
    if portion isa SciMLStructures.Tunable
        p.tunable[idx] = val
    else
        i, j, k... = idx
        if portion isa SciMLStructures.Discrete
            k, l... = k
            if isempty(l)
                p.discrete[i][j][k] = val
            else
                p.discrete[i][j][k][l...] = val
            end
        elseif portion isa SciMLStructures.Constants
            if isempty(k)
                p.constant[i][j] = val
            else
                p.constant[i][j][k...] = val
            end
        elseif portion === NONNUMERIC_PORTION
            if isempty(k)
                p.nonnumeric[i][j] = val
            else
                p.nonnumeric[i][j][k...] = val
            end
        else
            error("Unhandled portion $portion")
        end
    end
end

function narrow_buffer_type_and_fallback_undefs(oldbuf::Vector, newbuf::Vector)
    type = Union{}
    for i in eachindex(newbuf)
        isassigned(newbuf, i) || continue
        type = promote_type(type, typeof(newbuf[i]))
    end
    if type == Union{}
        type = eltype(oldbuf)
    end
    for i in eachindex(newbuf)
        isassigned(newbuf, i) && continue
        newbuf[i] = convert(type, oldbuf[i])
    end
    return convert(Vector{type}, newbuf)
end

function validate_parameter_type(ic::IndexCache, p, index, val)
    p = unwrap(p)
    if p isa Symbol
        p = get(ic.symbol_to_variable, p, nothing)
        if p === nothing
            @warn "No matching variable found for `Symbol` $p, skipping type validation."
            return nothing
        end
    end
    (; portion) = index
    # Nonnumeric parameters have to match the type
    if portion === NONNUMERIC_PORTION
        stype = symtype(p)
        val isa stype && return nothing
        throw(ParameterTypeException(:validate_parameter_type, p, stype, val))
    end
    stype = symtype(p)
    # Array parameters need array values...
    if stype <: AbstractArray && !isa(val, AbstractArray)
        throw(ParameterTypeException(:validate_parameter_type, p, stype, val))
    end
    # ... and must match sizes
    if stype <: AbstractArray && Symbolics.shape(p) !== Symbolics.Unknown() &&
       size(val) != size(p)
        throw(InvalidParameterSizeException(p, val))
    end
    # Early exit
    val isa stype && return nothing
    if stype <: AbstractArray
        # Arrays need handling when eltype is `Real` (accept any real array)
        etype = eltype(stype)
        if etype <: Real
            etype = Real
        end
        # This is for duals and other complicated number types
        etype = SciMLBase.parameterless_type(etype)
        eltype(val) <: etype || throw(ParameterTypeException(
            :validate_parameter_type, p, AbstractArray{etype}, val))
    else
        # Real check
        if stype <: Real
            stype = Real
        end
        stype = SciMLBase.parameterless_type(stype)
        val isa stype ||
            throw(ParameterTypeException(:validate_parameter_type, p, stype, val))
    end
end

function indp_to_system(indp)
    while hasmethod(symbolic_container, Tuple{typeof(indp)})
        indp = symbolic_container(indp)
    end
    return indp
end

function SymbolicIndexingInterface.remake_buffer(indp, oldbuf::MTKParameters, vals::Dict)
    newbuf = @set oldbuf.tunable = Vector{Any}(undef, length(oldbuf.tunable))
    @set! newbuf.discrete = SizedVector{length(newbuf.discrete)}([Tuple(Vector{Any}(undef,
                                                                            length(buf))
                                                                  for buf in clockbuf)
                                                                  for clockbuf in newbuf.discrete])
    @set! newbuf.constant = Tuple(Vector{Any}(undef, length(buf))
    for buf in newbuf.constant)
    @set! newbuf.nonnumeric = Tuple(Vector{Any}(undef, length(buf))
    for buf in newbuf.nonnumeric)

    syms = collect(keys(vals))
    vals = Dict{Any, Any}(vals)
    for sym in syms
        symbolic_type(sym) == ArraySymbolic() || continue
        is_parameter(indp, sym) && continue
        stype = symtype(unwrap(sym))
        stype <: AbstractArray || continue
        Symbolics.shape(sym) == Symbolics.Unknown() && continue
        for i in eachindex(sym)
            vals[sym[i]] = vals[sym][i]
        end
    end

    # If the parameter buffer is an `MTKParameters` object, `indp` must eventually drill
    # down to an `AbstractSystem` using `symbolic_container`. We leverage this to get
    # the index cache.
    ic = get_index_cache(indp_to_system(indp))
    for (p, val) in vals
        idx = parameter_index(indp, p)
        if idx !== nothing
            validate_parameter_type(ic, p, idx, val)
            _set_parameter_unchecked!(
                newbuf, val, idx; update_dependent = false)
        elseif symbolic_type(p) == ArraySymbolic()
            for (i, j) in zip(eachindex(p), eachindex(val))
                pi = p[i]
                idx = parameter_index(indp, pi)
                validate_parameter_type(ic, pi, idx, val[j])
                _set_parameter_unchecked!(
                    newbuf, val[j], idx; update_dependent = false)
            end
        end
    end

    @set! newbuf.tunable = narrow_buffer_type_and_fallback_undefs(
        oldbuf.tunable, newbuf.tunable)
    @set! newbuf.discrete = SizedVector{length(newbuf.discrete)}([narrow_buffer_type_and_fallback_undefs.(
                                                                      oldclockbuf,
                                                                      newclockbuf)
                                                                  for (oldclockbuf, newclockbuf) in zip(
        oldbuf.discrete, newbuf.discrete)])
    @set! newbuf.constant = narrow_buffer_type_and_fallback_undefs.(
        oldbuf.constant, newbuf.constant)
    @set! newbuf.nonnumeric = narrow_buffer_type_and_fallback_undefs.(
        oldbuf.nonnumeric, newbuf.nonnumeric)
    return newbuf
end

struct NestedGetIndex{T}
    x::T
end

function Base.getindex(ngi::NestedGetIndex, idx::Tuple)
    i, j, k... = idx
    return ngi.x[i][j][k...]
end

# Required for DiffEqArray constructor to work during interpolation
Base.size(::NestedGetIndex) = ()

function SymbolicIndexingInterface.with_updated_parameter_timeseries_values(
        ::AbstractSystem, ps::MTKParameters, args::Pair{A, B}...) where {
        A, B <: NestedGetIndex}
    for (i, val) in args
        ps.discrete[i] = val.x
    end
    return ps
end

function SciMLBase.create_parameter_timeseries_collection(
        sys::AbstractSystem, ps::MTKParameters, tspan)
    ic = get_index_cache(sys) # this exists because the parameters are `MTKParameters`
    has_discrete_subsystems(sys) || return nothing
    (dss = get_discrete_subsystems(sys)) === nothing && return nothing
    _, _, _, id_to_clock = dss
    buffers = []

    for (i, partition) in enumerate(ps.discrete)
        clock = id_to_clock[i]
        @match clock begin
            PeriodicClock(dt, _...) => begin
                ts = tspan[1]:(dt):tspan[2]
                push!(buffers, DiffEqArray(NestedGetIndex{typeof(partition)}[], ts, (1, 1)))
            end
            &SolverStepClock => push!(buffers,
                DiffEqArray(NestedGetIndex{typeof(partition)}[], eltype(tspan)[], (1, 1)))
            &Continuous => continue
            _ => error("Unhandled clock $clock")
        end
    end

    return ParameterTimeseriesCollection(Tuple(buffers), copy(ps))
end

function SciMLBase.get_saveable_values(ps::MTKParameters, timeseries_idx)
    return NestedGetIndex(deepcopy(ps.discrete[timeseries_idx]))
end

function DiffEqBase.anyeltypedual(
        p::MTKParameters, ::Type{Val{counter}} = Val{0}) where {counter}
    DiffEqBase.anyeltypedual(p.tunable)
end
function DiffEqBase.anyeltypedual(p::Type{<:MTKParameters{T}},
        ::Type{Val{counter}} = Val{0}) where {counter} where {T}
    DiffEqBase.__anyeltypedual(T)
end

# for compiling callbacks
# getindex indexes the vectors, setindex! linearly indexes values
# it's inconsistent, but we need it to be this way
@generated function Base.getindex(
        ps::MTKParameters{T, D, C, N}, idx::Int) where {T, D, C, N}
    paths = []
    if !(T <: SizedVector{0, Float64})
        push!(paths, :(ps.tunable))
    end
    for i in 1:length(D)
        for j in 1:fieldcount(eltype(D))
            push!(paths, :(ps.discrete[$i][$j]))
        end
    end
    for i in 1:fieldcount(C)
        push!(paths, :(ps.constant[$i]))
    end
    for i in 1:fieldcount(N)
        push!(paths, :(ps.nonnumeric[$i]))
    end
    expr = Expr(:if, :(idx == 1), :(return $(paths[1])))
    curexpr = expr
    for i in 2:length(paths)
        push!(curexpr.args, Expr(:elseif, :(idx == $i), :(return $(paths[i]))))
        curexpr = curexpr.args[end]
    end
    return Expr(:block, expr, :(throw(BoundsError(ps, idx))))
end

@generated function Base.length(ps::MTKParameters{T, D, C, N}) where {T, D, C, N}
    len = 0
    if !(T <: SizedVector{0, Float64})
        len += 1
    end
    if length(D) > 0
        len += length(D) * fieldcount(eltype(D))
    end
    len += fieldcount(C) + fieldcount(N)
    return len
end

Base.getindex(p::MTKParameters, pind::ParameterIndex) = parameter_values(p, pind)

Base.setindex!(p::MTKParameters, val, pind::ParameterIndex) = set_parameter!(p, val, pind)

function Base.iterate(buf::MTKParameters, state = 1)
    total_len = length(buf)
    if state <= total_len
        return (buf[state], state + 1)
    else
        return nothing
    end
end

function Base.:(==)(a::MTKParameters, b::MTKParameters)
    return a.tunable == b.tunable && a.discrete == b.discrete &&
           a.constant == b.constant && a.nonnumeric == b.nonnumeric
end

# to support linearize/linearization_function
function jacobian_wrt_vars(pf::F, p::MTKParameters, input_idxs, chunk::C) where {F, C}
    tunable, _, _ = SciMLStructures.canonicalize(SciMLStructures.Tunable(), p)
    T = eltype(tunable)
    tag = ForwardDiff.Tag(pf, T)
    dualtype = ForwardDiff.Dual{typeof(tag), T, ForwardDiff.chunksize(chunk)}
    p_big = SciMLStructures.replace(SciMLStructures.Tunable(), p, dualtype.(tunable))
    p_closure = let pf = pf,
        input_idxs = input_idxs,
        p_big = p_big

        function (p_small_inner)
            for (i, val) in zip(input_idxs, p_small_inner)
                _set_parameter_unchecked!(p_big, val, i)
            end
            return if pf isa SciMLBase.ParamJacobianWrapper
                buffer = Array{dualtype}(undef, size(pf.u))
                pf(buffer, p_big)
                buffer
            else
                pf(p_big)
            end
        end
    end
    p_small = parameter_values.((p,), input_idxs)
    cfg = ForwardDiff.JacobianConfig(p_closure, p_small, chunk, tag)
    ForwardDiff.jacobian(p_closure, p_small, cfg, Val(false))
end

function as_duals(p::MTKParameters, dualtype)
    tunable = dualtype.(p.tunable)
    discrete = dualtype.(p.discrete)
    return MTKParameters{typeof(tunable), typeof(discrete)}(tunable, discrete)
end

const MISSING_PARAMETERS_MESSAGE = """
                                Some parameters are missing from the variable map.
                                Please provide a value or default for the following variables:
                                """

struct MissingParametersError <: Exception
    vars::Any
end

function Base.showerror(io::IO, e::MissingParametersError)
    println(io, MISSING_PARAMETERS_MESSAGE)
    println(io, e.vars)
end

function InvalidParameterSizeException(param, val)
    DimensionMismatch("InvalidParameterSizeException: For parameter $(param) expected value of size $(size(param)). Received value $(val) of size $(size(val)).")
end

function InvalidParameterSizeException(param::Tuple, val::Tuple)
    DimensionMismatch("InvalidParameterSizeException: Expected value of size $(param). Received value of size $(val).")
end

function ParameterTypeException(func, param, expected, val)
    TypeError(func, "Parameter $param", expected, val)
end
