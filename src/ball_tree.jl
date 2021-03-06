immutable BallTree{T <: AbstractFloat, M <: Metric} <: NNTree{T, M}
    data::Matrix{T}                       # dim x n_points array with floats
    hyper_spheres::Vector{HyperSphere{T}} # Each hyper rectangle bounds its children
    indices::Vector{Int}                  # Translates from tree index -> point index
    metric::M                             # Metric used for tree
    tree_data::TreeData                   # Some constants needed
    reordered::Bool                       # If the data has been reordered
end

# Some array buffers needed in the creation of the tree.
# Preallocated here to save memory
immutable ArrayBuffers{T <: AbstractFloat}
    left::Vector{T}
    right::Vector{T}
    v12::Vector{T}
    zerobuf::Vector{T}
end

function ArrayBuffers(T, ndim)
    ArrayBuffers{T}(zeros(T, ndim), zeros(T, ndim), zeros(T, ndim), zeros(T, ndim))
end

"""
    BallTree(data [, metric = Euclidean(), leafsize = 30]) -> balltree

Creates a `BallTree` from the data using the given `metric` and `leafsize`.
"""
function BallTree{T <: AbstractFloat, M<:Metric}(data::Matrix{T},
                                                 metric::M = Euclidean();
                                                 leafsize::Int = 30,
                                                 reorder::Bool = true)

    tree_data = TreeData(data, leafsize)
    n_d = size(data, 1)
    n_p = size(data, 2)
    array_buffs = ArrayBuffers(T, size(data, 1))
    indices = collect(1:n_p)

    # Bottom up creation of hyper spheres so need spheres even for leafs
    hyper_spheres = Array(HyperSphere{T}, tree_data.n_internal_nodes + tree_data.n_leafs)

    if reorder
       indices_reordered = Vector{Int}(n_p)
       data_reordered = Matrix{T}(n_d, n_p)
     else
       # Dummy variables
       indices_reordered = Vector{Int}(0)
       data_reordered = Matrix{T}(0, 0)
     end

    # Call the recursive BallTree builder
    build_BallTree(1, data, data_reordered, hyper_spheres, metric, indices, indices_reordered,
                   1,  size(data,2), tree_data, array_buffs, reorder)

    if reorder
       data = data_reordered
       indices = indices_reordered
    end

    BallTree(data, hyper_spheres, indices, metric, tree_data, reorder)
end


# Recursive function to build the tree.
function build_BallTree{T <: AbstractFloat}(index::Int,
                                            data::Matrix{T},
                                            data_reordered::Matrix{T},
                                            hyper_spheres::Vector{HyperSphere{T}},
                                            metric::Metric,
                                            indices::Vector{Int},
                                            indices_reordered::Vector{Int},
                                            low::Int,
                                            high::Int,
                                            tree_data::TreeData,
                                            array_buffs::ArrayBuffers{T},
                                            reorder::Bool)

    n_points = high - low + 1 # Points left
    if n_points <= tree_data.leaf_size
        if reorder
            reorder_data!(data_reordered, data, index, indices, indices_reordered, tree_data)
        end
        # Create bounding sphere of points in leaf nodeby brute force
        hyper_spheres[index] = create_bsphere(data, metric, indices, low, high)
        return
    end

    mid_idx = find_split(low, tree_data.leaf_size, n_points)

    split_dim = find_largest_spread(data, indices, low, high)

    select_spec!(indices, mid_idx, low, high, data, split_dim)

    build_BallTree(getleft(index), data, data_reordered, hyper_spheres, metric,
                   indices, indices_reordered, low, mid_idx - 1,
                   tree_data, array_buffs, reorder)

    build_BallTree(getright(index), data, data_reordered, hyper_spheres, metric,
                  indices, indices_reordered, mid_idx, high,
                  tree_data, array_buffs, reorder)

    # Finally create hyper sphere from the two children
    hyper_spheres[index]  =  create_bsphere(metric, hyper_spheres[getleft(index)],
                                            hyper_spheres[getright(index)],
                                            array_buffs)
end


function _knn{T}(tree::BallTree{T},
                 point::AbstractVector{T},
                 k::Int)
    best_idxs = [-1 for _ in 1:k]
    best_dists = [typemax(T) for _ in 1:k]
    knn_kernel!(tree, 1, point, best_idxs, best_dists)
    return best_idxs, best_dists
end

function knn_kernel!{T}(tree::BallTree{T},
                        index::Int,
                        point::AbstractArray{T},
                        best_idxs ::Vector{Int},
                        best_dists::Vector{T})
    if isleaf(tree.tree_data.n_internal_nodes, index)
        add_points_knn!(best_dists, best_idxs, tree, index, point, true)
        return
    end

    left_sphere = tree.hyper_spheres[getleft(index)]
    right_sphere = tree.hyper_spheres[getright(index)]

    left_dist = max(zero(T), evaluate(tree.metric, point, left_sphere.center) - left_sphere.r)
    right_dist = max(zero(T), evaluate(tree.metric, point, right_sphere.center) - right_sphere.r)

    if left_dist <= best_dists[1] || right_dist <= best_dists[1]
        if left_dist < right_dist
            knn_kernel!(tree, getleft(index), point, best_idxs, best_dists)
            if right_dist <=  best_dists[1]
                 knn_kernel!(tree, getright(index), point, best_idxs, best_dists)
             end
        else
            knn_kernel!(tree, getright(index), point, best_idxs, best_dists)
            if left_dist <=  best_dists[1]
                 knn_kernel!(tree, getleft(index), point, best_idxs, best_dists)
            end
        end
    end
    return
end


function _inrange{T}(tree::BallTree{T},
                     point::AbstractVector{T},
                     radius::Number)
    idx_in_ball = Int[]
    ball = HyperSphere(point, radius)
    inrange_kernel!(tree, 1, point, ball, idx_in_ball)
    return idx_in_ball
end

function inrange_kernel!{T}(tree::BallTree{T},
                            index::Int,
                            point::Vector{T},
                            query_ball::HyperSphere{T},
                            idx_in_ball::Vector{Int})
    @NODE 1
    sphere = tree.hyper_spheres[index]

    if !intersects(tree.metric, sphere, query_ball)
        return
    end

    if isleaf(tree.tree_data.n_internal_nodes, index)
        add_points_inrange!(idx_in_ball, tree, index, point, query_ball.r, true)
        return
    end

    if encloses(tree.metric, sphere, query_ball)
         addall(tree, index, idx_in_ball)
    else
        inrange_kernel!(tree,  getleft(index), point, query_ball, idx_in_ball)
        inrange_kernel!(tree, getright(index), point, query_ball, idx_in_ball)
    end
end
