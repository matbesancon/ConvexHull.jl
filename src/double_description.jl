using LinearAlgebra

mutable struct DoubleDescription{T<:Real,C}
    A::Matrix{T}
    R::Vector{C}
    K::Set{Int}
    adj::Dict{Tuple{Int,Int},Bool}
    num_rays::Int
end

function double_description(ine::LiftedHRepresentation{T}) where {T}
    if !isempty(ine.linset)
        error("Linearity currently unsupported by ConvexHull.")
    end
    # FIXME add support for linearity
    dd = double_description(ine.A)
    R = Matrix{T}(undef, length(dd.R), fulldim(ine)+1)
    for (i,r) in enumerate(dd.R)
        R[i,:] = r.v
    end
    return LiftedVRepresentation{T}(R)
end

function double_description(ext::LiftedVRepresentation{T}) where {T}
    if !isempty(ext.linset)
        error("Linearity currently unsupported by ConvexHull.")
    end
    # FIXME add support for linearity
    dd = double_description(ext.R)
    A = Matrix{T}(undef, length(dd.R), fulldim(ext)+1)
    for (i,r) in enumerate(dd.R)
        A[i,:] = r.v
    end
    return LiftedHRepresentation(A)
end

struct CountedVector{T<:Real}
    v::Vector{T}
    Av::Vector{T}
    id::Int

    function CountedVector{T}(v::Vector{T}, A, id) where {T}
        canonicalize!(v)
        new{T}(v, A*v, id)
    end
end

CountedVector(v::Vector{T}, A, id) where {T} = CountedVector{T}(v, A, id)

Base.vec(c::CountedVector) = c.v

function initial_description(A::Matrix{T}) where {T<:Real}
    m,n = size(A)
    B = rref(Matrix(A'))
    # find pivots
    r = 1
    K = Set{Int}()
    for i in 1:m
        comp = zeros(n)
        comp[r] = 1
        if B[:,i] == comp
            r += 1
            push!(K, i)
        end
        r > n && break
    end
    cK = sort(collect(K))
    Ak = A[cK,:]
    if eltype(Ak) <: AbstractFloat
        R = Ak \ Matrix(LinearAlgebra.I, n, n)
    else
        # Ak \ eye(n,n) creates BigFloat from Rational{BigInt} while inv keeps Rational{BigInt}
        R = inv(Ak)
    end
    Rk = [CountedVector{T}(R[:,i],A,i) for i in 1:n]
    dd = DoubleDescription(A,Rk,K,Dict{Tuple{Int,Int},Bool}(),n)
    for i in 1:n
        # Ar = Rk[i].Av[cK]
        for j in (i+1):n
            # As = Rk[j].Av[cK]
            id = extrema([Rk[i].id,Rk[j].id])
            cache_adjacency!(dd, n, Rk[i].Av[cK], Rk[j].Av[cK], id)
        end
    end
    return dd
end

function double_description(A::Matrix{T}) where {T<:Real}
    A = [zeros(T,1,size(A,2)); A]
    A[1,1] = one(T)
    m, n = size(A)
    dd = initial_description(A)
    Kᶜ = setdiff(1:m, dd.K)
    while !isempty(Kᶜ)
        i = pop!(Kᶜ)
        # length(dd.K) == 31 && break
        update!(dd, i)
    end
    return dd
end

function is_approx_included(haystack, needle)
    n = length(needle)
    diff = zeros(n)
    for h in haystack
        diff = norm(vec(h)-needle)
        diff < n*ε && return true
    end
    return false
end

function canonicalize!(v::Vector{T}) where {T<:Real}
    n = length(v)
    val = abs(v[1])
    if val < ε
        val = abs(v[findfirst(abs.(v) .> ε)])
    end
    for i in 1:n
        v[i] = v[i] / val
    end
    return v
end

# use Lemma 8 from Fukuda (1996) to update the double description
function update!(dd::DoubleDescription{T}, i) where {T<:Real}
    m, n = size(dd.A)
    Aᵢ = reshape(dd.A[i,:], (n,))
    Rⁿᵉʷ = CountedVector{T}[]
    R⁺, R⁰, R⁻ = partition_rays(dd.R, Aᵢ)
    for r in R⁺, s in R⁻
        if isadjacent(dd,r,s)
            w = dot(Aᵢ,vec(r))*vec(s) - dot(Aᵢ,vec(s))*vec(r)
            dd.num_rays += 1
            v = CountedVector(w,dd.A,dd.num_rays)
            if sum(abs.(w)) > n*ε &&
               !is_approx_included(R⁰,   vec(w)) &&
               !is_approx_included(Rⁿᵉʷ, vec(w))
                dd.num_rays += 1
                push!(Rⁿᵉʷ, v)
            end
        end
    end
    dd.R = vcat(R⁺, R⁰, Rⁿᵉʷ)
    push!(dd.K, i)
    cK = sort(collect(dd.K))
    Ak = dd.A[cK,:]
    # should really add a test right about here to ensure
    # that old rays do not become adjacent...I think this
    # can only happen if both v,w ∈ R⁰

    # If eltype(Ak) is Rational{BigInt}, LinearAlgebra.jl is needed
    d = rank(Ak)
    for s in Rⁿᵉʷ
        # As = s.Av[cK]#Ak*vec(s)
        for r in dd.R
            r.id == s.id && continue
            # Ar = r.Av[cK]#Ak*vec(r)
            id = extrema([r.id, s.id])
            cache_adjacency!(dd, d, r.Av[cK], s.Av[cK], id)
        end
    end
    nothing
end

function partition_rays(R::Vector{CountedVector{T}}, a::Vector{T}) where T<:Real
    R⁺, R⁰, R⁻ = CountedVector{T}[], CountedVector{T}[], CountedVector{T}[]
    n = length(a)
    for r in R
        if sum(abs.(vec(r))) < n*ε
            println("have a zero vector!")
            continue
        end
        val = dot(a,vec(r))
        if val > ε
            push!(R⁺, r)
        elseif val < -ε
            push!(R⁻, r)
        else
            push!(R⁰, r)
        end
    end
    return R⁺, R⁰, R⁻
end

isadjacent(dd, r, s) = dd.adj[extrema([r.id,s.id])]

function cache_adjacency!(dd, d, Ar, As, id::Tuple{Int,Int})
    Z = active_sets(dd, Ar, As)
    if length(Z) < d - 2
        val = false
    elseif length(intersect(Z,dd.K)) ≥ d - 2
        val = true
    else
        val = (rank(dd.A[sort(collect(dd.K)),:][Z,:]) == d - 2)
    end
    dd.adj[id] = val
    return val
end

function active_sets(dd, Ar, As)
    Z = Int[]
    m = length(Ar)
    sizehint!(Z,m)
    for i in 1:m
        if abs(Ar[i]) ≤ ε && abs(As[i]) ≤ ε
            push!(Z, i)
        end
    end
    return Z
end
