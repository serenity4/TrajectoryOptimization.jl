export
    AbstractModel,
    InfeasibleModel,
    dynamics,
    discrete_dynamics,
    jacobian,
    discrete_jacobian

export
    QuadratureRule,
    RK3,
    HermiteSimpson,
    VectorPart,
    ExponentialMap,
    ModifiedRodriguesParam


""" $(TYPEDEF)
Abstraction of a model of a dynamical system of the form ẋ = f(x,u), where x is the n-dimensional state vector
and u is the m-dimensional control vector.

Any inherited type must define the following interface:
ẋ = dynamics(model, x, u)
n,m = size(model)
"""
abstract type AbstractModel end

abstract type RigidBody{R<:Rotation} <: AbstractModel end

"Integration rule for approximating the continuous integrals for the equations of motion"
abstract type QuadratureRule end
"Integration rules of the form x′ = f(x,u), where x′ is the next state"
abstract type Implicit <: QuadratureRule end
"Integration rules of the form x′ = f(x,u,x′,u′), where x′,u′ are the states and controls at the next time step."
abstract type Explicit <: QuadratureRule end
"Third-order Runge-Kutta method with zero-order-old on the controls"
abstract type RK3 <: Implicit end
"Third-order Runge-Kutta method with first-order-hold on the controls"
abstract type HermiteSimpson <: Explicit end

"Default quadrature rule"
const DEFAULT_Q = RK3

#=
Convenient methods for creating state and control vectors directly from the model
=#
for method in [:rand, :zeros, :ones]
    @eval begin
        function Base.$(method)(model::AbstractModel)
            n,m = size(model)
            x = @SVector $(method)(n)
            u = @SVector $(method)(m)
            return x, u
        end
        function Base.$(method)(::Type{T}, model::AbstractModel) where T
            n,m = size(model)
            x = @SVector $(method)(T,n)
            u = @SVector $(method)(T,m)
            return x,u
        end
    end
end
function Base.fill(model::AbstractModel, val)
    n,m = size(model)
    x = @SVector fill(val,n)
    u = @SVector fill(val,m)
    return x, u
end

"""Default size method for model (assumes model has fields n and m)"""
@inline Base.size(model::AbstractModel) = model.n, model.m

############################################################################################
#                               CONTINUOUS TIME METHODS                                    #
############################################################################################
"""```
ẋ = dynamics(model, z::KnotPoint)
```
Compute the continuous dynamics of a dynamical system given a KnotPoint"""
@inline dynamics(model::AbstractModel, z::KnotPoint) = dynamics(model, state(z), control(z), z.t)

# Default to not passing in t
@inline dynamics(model::AbstractModel, x, u, t) = dynamics(model, x, u)

"""```
∇f = jacobian(model, z::KnotPoint)
∇f = jacobian(model, z::SVector)
```
Compute the Jacobian of the continuous-time dynamics using ForwardDiff. The input can be either
a static vector of the concatenated state and control, or a KnotPoint. They must be concatenated
to avoid unnecessary memory allocations.
"""
function jacobian(model::AbstractModel, z::KnotPoint)
    ix, iu = z._x, z._u
    f_aug(z) = dynamics(model, z[ix], z[iu])
    s = z.z
    ForwardDiff.jacobian(f_aug, s)
end

function jacobian(model::AbstractModel, z::SVector)
    n,m = size(model)
    ix,iu = 1:n, n .+ (1:m)
    f_aug(z) = dynamics(model, view(z,ix), view(z,iu))
    ForwardDiff.jacobian(f_aug, z)
end

############################################################################################
#                          IMPLICIT DISCRETE TIME METHODS                                  #
############################################################################################

# Set default integrator
@inline discrete_dynamics(model::AbstractModel, z::KnotPoint) =
    discrete_dynamics(DEFAULT_Q, model, z)

""" Compute the discretized dynamics of `model` using implicit integration scheme `Q<:QuadratureRule`.

Methods:
```
x′ = discrete_dynamics(Q, model, x, u, dt)
x′ = discrete_dynamics(Q, model, z::KnotPoint)
```
"""
@inline discrete_dynamics(::Type{Q}, model::AbstractModel, z::KnotPoint) where Q<:Implicit =
    discrete_dynamics(Q, model, state(z), control(z), z.t, z.dt)

""" Compute the discrete dynamics Jacobian of `model` using implicit integration scheme `Q<:QuadratureRule`

Methods:
```
∇f = discrete_jacobian(model, z::KnotPoint)
∇f = discrete_jacobian(model, s::SVector{NM1}, ix::SVector{N}, iu::SVector{M})
```
where `s = [x; u; dt]` and `ix` and `iu` are the indices to extract the state and controls.
"""
@inline discrete_jacobian(model::AbstractModel, z::KnotPoint) =
    discrete_jacobian(DEFAULT_Q, model, z)

function discrete_jacobian(::Type{Q}, model::AbstractModel,
        z::KnotPoint{T,N,M,NM}) where {Q<:Implicit,T,N,M,NM}
    ix,iu,idt = z._x, z._u, NM+1
    t = z.t
    fd_aug(s) = discrete_dynamics(Q, model, s[ix], s[iu], t, s[idt])
    s = [z.z; @SVector [z.dt]]
    ForwardDiff.jacobian(fd_aug, s)
end

function discrete_jacobian(::Type{Q}, model::AbstractModel,
       s::SVector{NM1}, t::T, ix::SVector{N}, iu::SVector{M}) where {Q<:Implicit,T,N,M,NM1}
    idt = NM1
    fd_aug(s) = discrete_dynamics(Q, model, s[ix], s[iu], t, s[idt])
    ForwardDiff.jacobian(fd_aug, s)
end


############################################################################################
#                               STATE DIFFERENTIALS                                        #
############################################################################################

@inline state_diff(model::AbstractModel, x, x0) = x - x0
# @inline state_diff_jacobian(model::AbstractModel, x::SVector{N,T}) where {N,T} = Diagonal(@SVector ones(T,N))
@inline state_diff_jacobian(model::AbstractModel, x::SVector{N,T}) where {N,T} = I
@inline state_diff_size(model::AbstractModel) = size(model)[1]

@inline state_diff_jacobian!(G, model::AbstractModel, Z::Traj) = nothing

function state_diff_jacobian!(G, model::RigidBody, Z::Traj)
    for k in eachindex(Z)
        G[k] = state_diff_jacobian(model, state(Z[k]))
    end
end

############################################################################################
#                               INFEASIBLE MODELS                                          #
############################################################################################

struct InfeasibleModel{N,M,D<:AbstractModel} <: AbstractModel
    model::D
    _u::SVector{M,Int}  # inds to original controls
    _ui::SVector{N,Int} # inds to infeasible controls
end

function InfeasibleModel(model::AbstractModel)
    n,m = size(model)
    _u  = SVector{m}(1:m)
    _ui = SVector{n}((1:n) .+ m)
    InfeasibleModel(model, _u, _ui)
end

function Base.size(model::InfeasibleModel)
    n,m = size(model.model)
    return n, n+m
end

dynamics(::InfeasibleModel, x, u) =
    throw(ErrorException("Cannot evaluate continuous dynamics on an infeasible model"))

@generated function discrete_dynamics(::Type{Q}, model::InfeasibleModel{N,M},
        z::KnotPoint{T,N}) where {T,N,M,Q<:Implicit}
    _u = SVector{M}((1:M) .+ N)
    _ui = SVector{N}((1:N) .+ (N+M))
    quote
        x = state(z)
        dt = z.dt
        u0 = z.z[$_u]
        ui = z.z[$_ui]
        discrete_dynamics($Q, model.model, x, u0, z.t, dt) + ui
    end
end

@generated function discrete_jacobian(::Type{Q}, model::InfeasibleModel{N,M},
        z::KnotPoint{T,N,NM,L}) where {T,N,M,NM,L,Q<:Implicit}

    ∇ui = [(@SMatrix zeros(N,N+M)) Diagonal(@SVector ones(N)) @SVector zeros(N)]
    _x = SVector{N}(1:N)
    _u = SVector{M}((1:M) .+ N)
    _z = SVector{N+M}(1:N+M)
    _ui = SVector{N}((1:N) .+ (N+M))
    zi = [:(z.z[$i]) for i = 1:N+M]
    NM1 = N+M+1
    ∇u0 = @SMatrix zeros(N,N)

    quote
        # Build KnotPoint for original model
        s0 = SVector{$NM1}($(zi...), z.dt)

        u0 = z.z[$_u]
        ui = z.z[$_ui]
        ∇f = discrete_jacobian($Q, model.model, s0, z.t, $_x, $_u)::SMatrix{N,NM+1}
        ∇dt = ∇f[$_x, N+M+1]
        [∇f[$_x, $_z] $∇u0 ∇dt] + $∇ui
    end
end



"Calculate a dynamically feasible initial trajectory for an infeasible problem, given a
desired trajectory"
function infeasible_trajectory(model::InfeasibleModel{n,m}, Z0::Vector{<:KnotPoint{T,n,m}}) where {T,n,m}
    x,u = zeros(model)
    ui = @SVector zeros(n)
    Z = [KnotPoint(state(z), [control(z); ui], z.dt) for z in Z0]
    N = length(Z0)
    for k = 1:N-1
        propagate_dynamics(RK3, model, Z[k+1], Z[k])
        x′ = state(Z[k+1])
        u_slack = state(Z0[k+1]) - x′
        u = [control(Z0[k]); u_slack]
        set_control!(Z[k], u)
        set_state!(Z[k+1], x′ + u_slack)
    end
    return Z
end



"Generate discrete dynamics function for a dynamics model using RK3 integration"
function rk3_gen(model::AbstractModel)
       # Runge-Kutta 3 (zero order hold)
   @eval begin
       function discrete_dynamics(model::$(typeof(model)), x, u, dt)
           k1 = dynamics(model, x, u)*dt;
           k2 = dynamics(model, x + k1/2, u)*dt;
           k3 = dynamics(model, x - k1 + 2*k2, u)*dt;
           x + (k1 + 4*k2 + k3)/6
       end
       # @inline function discrete_dynamics(model::$(typeof(model)), Z::KnotPoint)
       #     discrete_dynamics(model, state(Z), control(Z), Z.dt)
       # end
   end
end


"""
Generate the continuous dynamics Jacobian for a dynamics model.
The resulting function should be non-allocating if the original dynamics function is non-allocating
"""
function generate_jacobian(model::M) where {M<:AbstractModel}
    n,m = size(model)
    ix,iu = 1:n, n .+ (1:m)
    f_aug(z) = dynamics(model, view(z,ix), view(z,iu))
    ∇f(z) = ForwardDiff.jacobian(f_aug,z)
    ∇f(x::SVector,u::SVector) = ∇f([x;u])
    ∇f(x,u) = begin
        z = zeros(n+m)
        z[ix] = x
        z[iu] = u
        ∇f(z)
    end
    @eval begin
        jacobian(model::$(M), x, u) = $(∇f)(x, u)
        jacobian(model::$(M), z) = $(∇f)(z)
    end
end

"""
Generate the discrete dynamics Jacobian for a dynamics model
"""
function generate_discrete_jacobian(model::M) where {M<:AbstractModel}
    n,m = size(model)
    ix,iu,idt = 1:n, n .+ (1:m), n+m+1
    fd_aug(z) = discrete_dynamics(model, view(z,ix), view(z,iu), z[idt])
    ∇fd(z) = ForwardDiff.jacobian(fd_aug, z)
    ∇fd(z,dt) = ForwardDiff.jacobian(fd_aug, [z; @SVector [dt]])
    ∇fd(x,u::SVector,dt) = ∇fd([x;u; @SVector [dt]])
    ∇fd(x,u,dt) = begin
        z = zeros(n+m)
        z[ix] = x
        z[iu] = u
        z[idt] = dt
        ∇fd(z)
    end
    @eval begin
        discrete_jacobian(model::$(M), x, u, dt) = $(∇fd)(x, u, dt)
        discrete_jacobian(model::$(M), z::AbstractVector) = $(∇fd)(z)
        discrete_jacobian(model::$(M), z, dt) = $(∇fd)(z, dt)
    end
end
