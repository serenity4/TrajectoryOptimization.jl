model, obj = Dynamics.quadrotor
N = 21
solver = Solver(model,obj,N=N)
n,m = get_sizes(solver)
U0 = 6*ones(m,N-1)
X0 = rollout(solver,U0)
cost(solver,X0,U0)
res,stats = solve(solver,U0)
stats["cost"][end]
stats["iterations"]
plot(stats["cost"],yscale=:log10)
plot(res.X)

costfun = obj.cost
model_d = Model{Discrete}(model,rk4)
U = to_dvecs(U0)
X = empty_state(n,N)
x0 = obj.x0
dt = solver.dt
C = AbstractConstraint[]
prob = Problem(model_d,costfun,x0,U,dt)

ilqr = iLQRSolver(prob)
solve!(prob,ilqr)