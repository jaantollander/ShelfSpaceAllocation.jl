using Parameters, JuMP, JuMP.Containers

# --- Utility ---

data(a::DenseAxisArray) = a.data
data(a::Any) = a

round_int(x::AbstractFloat) = Integer(round(x))
convert_int(x, ::Type{<:Integer}) = round_int(x)
convert_int(x, ::Type{Array{T, N}}) where T <: Integer where N = round_int.(x)
convert_int(x, ::Any) = x

"""The function queries values from the model to data type based on its field names. It extracts values from DenseAxisArray from its `data` field. Then, it converts the values to the corresponding field type. The function rounds integers before conversion because JuMP outputs integer variables as floats."""
function model_to_dtype(dtype::DataType, model::Model)
    fields = (
        value.(model[n]) |> data |> x -> convert_int(x, t)
        for (n, t) in zip(fieldnames(dtype), fieldtypes(dtype)))
    dtype(fields...)
end


# --- Model ---

"""ShelfSpaceAllocationModel type as JuMP.Model"""
const ShelfSpaceAllocationModel = Model

"""Specs"""
@with_kw struct Specs
    height_placement::Bool = true
    blocking::Bool = true
end

# TODO: I <: Integer, F <: AbstractFloat

"""Parameters"""
@with_kw struct Params
    # --- Sets and Subsets ---
    products::Array{Int, 1}
    shelves::Array{Int, 1}
    blocks::Array{Int, 1}
    modules::Array{Int, 1}
    P_b::Array{Array{Int, 1}, 1}
    S_m::Array{Array{Int, 1}, 1}
    # --- Parameters ---
    # Products
    N_p_min::Array{Float64, 1}
    N_p_max::Array{Float64, 1}
    G_p::Array{Float64, 1}
    R_p::Array{Float64, 1}
    D_p::Array{Float64, 1}
    L_p::Array{Float64, 1}
    W_p::Array{Float64, 1}
    H_p::Array{Float64, 1}
    M_p::Array{Float64, 1}
    SK_p::Array{Float64, 1}
    # Shelves
    M_s_min::Array{Float64, 1}
    M_s_max::Array{Float64, 1}
    W_s::Array{Float64, 1}
    H_s::Array{Float64, 1}
    L_s::Array{Int, 1}
    # Product-shelves
    P_ps::Array{Float64, 2}
    # Constants
    SL::Float64 = 0.0
    w1::Float64 = 0.5
    w2::Float64 = 10.0
    w3::Float64 = 0.1
end

"""Variables"""
@with_kw struct Variables
    # --- Basic Variables ---
    s_p::Array{Float64, 1}
    e_p::Array{Float64, 1}
    o_s::Array{Float64, 1}
    n_ps::Array{Int, 2}
    y_p::Array{Int, 1}
    # --- Blocking Variables ---
    b_bs::Array{Float64, 2}
    m_bm::Array{Float64, 2}
    z_bs::Array{Int, 2}
    z_bs_f::Array{Int, 2}
    z_bs_l::Array{Int, 2}
    x_bs::Array{Float64, 2}
    x_bm::Array{Float64, 2}
    w_bb::Array{Int, 2}
    v_bm::Array{Int, 2}
end

"""Objectives"""
@with_kw struct Objectives
    empty_shelf_space::Float64
    profit_loss::Float64
    height_placement_penalty::Float64
end

"""Variable values from model.

# Arguments
- `model::ShelfSpaceAllocationModel`
"""
Variables(model::ShelfSpaceAllocationModel) = model_to_dtype(Variables, model)

"""Objective values from model.

# Arguments
- `model::ShelfSpaceAllocationModel`
"""
Objectives(model::ShelfSpaceAllocationModel) = model_to_dtype(Objectives, model)

"""Mixed Integer Linear Program (MILP) formulation of the Shelf Space Allocation
Problem (SSAP).

# Arguments
- `parameters::Params`
- `specs::Specs`
"""
function ShelfSpaceAllocationModel(parameters::Params, specs::Specs)
    # Unpack parameters values
    @unpack products, shelves, blocks, modules, P_b, S_m, N_p_min, N_p_max,
            G_p, R_p, D_p, L_p, W_p, H_p, M_p, SK_p, M_s_min, M_s_max, W_s,
            H_s, L_s, P_ps, SL, w1, w2, w3 = parameters

    # Initialize the model
    model = ShelfSpaceAllocationModel()

    # --- Basic Variables ---
    @variable(model, s_p[products] ≥ 0)
    @variable(model, e_p[products] ≥ 0)
    @variable(model, o_s[shelves] ≥ 0)
    @variable(model, n_ps[products, shelves] ≥ 0, Int)
    @variable(model, y_p[products], Bin)

    # --- Block Variables ---
    @variable(model, b_bs[blocks, shelves] ≥ 0)
    @variable(model, m_bm[blocks, modules] ≥ 0)
    @variable(model, z_bs[blocks, shelves], Bin)
    @variable(model, z_bs_f[blocks, shelves], Bin)
    @variable(model, z_bs_l[blocks, shelves], Bin)
    @variable(model, x_bs[blocks, shelves] ≥ 0)
    @variable(model, x_bm[blocks, modules] ≥ 0)
    @variable(model, w_bb[blocks, blocks], Bin)
    @variable(model, v_bm[blocks, modules], Bin)

    # --- Height and weight constraints ---
    for p in products, s in shelves
        if (H_p[p] > H_s[s]) | (M_p[p] > M_s_max[s])
            fix(n_ps[p, s], 0, force=true)
        end
    end

    # --- Objective ---
    @expression(model, empty_shelf_space,
        sum(o_s[s] for s in shelves))
    @expression(model, profit_loss,
        sum(G_p[p] * e_p[p] for p in products))
    if specs.height_placement
        @expression(model, height_placement_penalty,
            sum(L_p[p] * L_s[s] * n_ps[p, s] for p in products for s in shelves))
    else
        @expression(model, height_placement_penalty, AffExpr(0.0))
    end
    @objective(model, Min,
        w1 * empty_shelf_space +
        w2 * profit_loss +
        w3 * height_placement_penalty
    )

    # --- Basic constraints ---
    @constraints(model, begin
        [p = products],
        s_p[p] ≤ sum(30 / R_p[p] * P_ps[p, s] * n_ps[p, s] for s in shelves)
        [p = products],
        s_p[p] ≤ D_p[p]
    end)
    @constraint(model, [p = products],
        s_p[p] + e_p[p] == D_p[p])
    @constraint(model, [p = products],
        sum(n_ps[p, s] for s in shelves) ≥ y_p[p])
    @constraints(model, begin
        [p = products],
        N_p_min[p] * y_p[p] ≤ sum(n_ps[p, s] for s in shelves)
        [p = products],
        sum(n_ps[p, s] for s in shelves) ≤ N_p_max[p] * y_p[p]
    end)
    @constraint(model, [s = shelves],
        sum(W_p[p] * n_ps[p, s] for p in products) + o_s[s] == W_s[s])

    # --- Block constraints ---
    if specs.blocking
        @constraint(model, [s = shelves, b = blocks],
            sum(W_p[p] * n_ps[p, s] for p in P_b[b]) ≤ b_bs[b, s])
        @constraint(model, [s = shelves],
            sum(b_bs[b, s] for b in blocks) ≤ W_s[s])
        @constraint(model, [b = blocks, m = modules, s = S_m[m]],
            b_bs[b, s] ≥ m_bm[b, m] - W_s[s] * (1 - z_bs[b, s]) - SL)
        @constraint(model, [b = blocks, m = modules, s = S_m[m]],
            b_bs[b, s] ≤ m_bm[b, m] + W_s[s] * (1 - z_bs[b, s]) + SL)
        @constraint(model, [b = blocks, s = shelves],
            b_bs[b, s] ≤ W_s[s] * z_bs[b, s])
        # ---
        @constraint(model, [b = blocks, s = 1:length(shelves)-1],
            z_bs_f[b, s+1] + z_bs[b, s] == z_bs[b, s+1] + z_bs_l[b, s])
        @constraint(model, [b = blocks],
            sum(z_bs_f[b, s] for s in shelves) ≤ 1)
        @constraint(model, [b = blocks],
            sum(z_bs_l[b, s] for s in shelves) ≤ 1)
        @constraint(model, [b = blocks],
            z_bs_f[b, 1] == z_bs[b, 1])
        @constraint(model, [b = blocks],
            z_bs_l[b, end] == z_bs[b, end])
        # ---
        @constraint(model, [b = blocks, s = shelves],
            sum(n_ps[p, s] for p in P_b[b]) ≥ z_bs[b, s])
        @constraint(model, [b = blocks, s = shelves, p = P_b[b]],
            n_ps[p, s] ≤ N_p_max[p] * z_bs[b, s])
        # ---
        @constraint(model, [b = blocks, b′ = filter(a->a≠b, blocks), s = shelves],
            x_bs[b, s] + W_s[s] * (1 - z_bs[b, s]) ≥ x_bs[b′, s] + b_bs[b, s] - W_s[s] * (1 - w_bb[b, b′]))
        @constraint(model, [b = blocks, b′ = filter(a->a≠b, blocks), s = shelves],
            x_bs[b′, s] + W_s[s] * (1 - z_bs[b′, s]) ≥ x_bs[b, s] + b_bs[b, s] - W_s[s] * w_bb[b, b′])
        @constraint(model, [b = blocks, m = modules, s = S_m[m]],
            x_bm[b, m] ≥ x_bs[b, s] - W_s[s] * (1 - z_bs[b, s]) - SL)
        @constraint(model, [b = blocks, m = modules, s = S_m[m]],
            x_bm[b, m] ≤ x_bs[b, s] + W_s[s] * (1 - z_bs[b, s]) + SL)
        @constraint(model, [b = blocks, s = shelves],
            x_bs[b, s] ≤ W_s[s] * z_bs[b, s])
        @constraint(model, [b = blocks, s = shelves],
            x_bs[b, s] + b_bs[b, s] ≤ W_s[s])
        # ---
        @constraint(model, [b = blocks, m = modules, s = S_m[m], p = P_b[b]],
            n_ps[p, s] ≤ N_p_max[p] * v_bm[b, m])
        @constraint(model, [b = blocks],
            sum(v_bm[b, m] for m in modules) ≤ 1)
    end

    return model
end
