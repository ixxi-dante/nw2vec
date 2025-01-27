include("utils.jl")
include("layers.jl")
include("generative.jl")
include("dataset.jl")
include("vae.jl")
using .Utils
using .Layers
using .Generative
using .Dataset
using .VAE

using Flux
using LightGraphs
using ProgressMeter
using Statistics
using Distributions
using Random
import BSON
using ArgParse
using Profile
import JLD
using NPZ
using PyCall


# Parameters
const klscale = 1f-3
const regscale = 1f-3
const profile_losses_filename = "an2vec-losses.jlprof"

"""Parse CLI arguments."""
function parse_cliargs()
    parse_settings = ArgParseSettings()
    @add_arg_table parse_settings begin
        "--dataset"
            help = "path to a npz file containing adjacency and features of a dataset"
            arg_type = String
            required = true
        "--blurring"
            help = "percentage of edges to add/remove to training dataset for reconstruction testing"
            arg_type = Float64
            # default = 0.15
            required = true
        "--diml1"
            help = "dimension of intermediary layers"
            arg_type = Int
            # default = 10
            required = true
        "--dimxiadj"
            help = "embedding dimensions for adjacency"
            arg_type = Int
            # default = 2
            required = true
        "--nepochs"
            help = "number of epochs to train for"
            arg_type = Int
            default = 1000
        "--savehistory"
            help = "file to save the training history (as npz)"
            arg_type = String
            required = true
        "--saveweights"
            help = "file to save the final model weights and creation parameters (as Bson)"
            arg_type = String
        "--profile"
            help = """
                profile n loss runs instead of training the model;
                overrides nepochs and save* options; results are saved to "$(profile_losses_filename)"."""
            arg_type = Int
    end

    parsed = parse_args(ARGS, parse_settings)
    parsed
end


"""Load the adjacency matrix and features."""
function dataset(args)
    adjfeatures = npzread(args["dataset"])

    features = transpose(adjfeatures["features"])

    # Make sure we have a non-weighted graph
    @assert Set(adjfeatures["adjdata"]) == Set([1])

    # Remove any diagonal elements in the matrix
    rows = adjfeatures["adjrow"]
    cols = adjfeatures["adjcol"]
    nondiagindices = findall(rows .!= cols)
    rows = rows[nondiagindices]
    cols = cols[nondiagindices]
    # Make sure indices start at 0
    @assert minimum(rows) == minimum(cols) == 0

    # Construct the graph
    edges = LightGraphs.SimpleEdge.(1 .+ rows, 1 .+ cols)
    g = SimpleGraphFromIterator(edges)

    # Check sizes for sanity
    @assert size(g, 1) == size(g, 2) == size(features, 2)
    g, convert(Array{Float32}, features)
end


"""Make the model."""
function make_vae(;g, feature_size, args)
    diml1, dimξadj = args["diml1"], args["dimxiadj"]

    # Encoder
    l1 = Layers.GC(g, feature_size, diml1, Flux.relu, initb = Layers.nobias)
    lμ = Layers.GC(g, diml1, dimξadj, initb = Layers.nobias)
    llogσ = Layers.GC(g, diml1, dimξadj, initb = Layers.nobias)
    enc(x) = (h = l1(x); (lμ(h), llogσ(h)))
    encparams = Flux.params(l1, lμ, llogσ)

    # Sampler
    sampleξ(μ, logσ) = μ .+ exp.(logσ) .* randn_like(μ)

    # Decoder
    decadj = Layers.Bilin()
    decparams = Flux.params(decadj)

    enc, sampleξ, decadj, encparams, decparams
end


"""Define the function compting AUC and AP scores for model predictions (adjacency only)"""
function make_perf_scorer(;enc, sampleξ, dec, greal::SimpleGraph, test_true_edges, test_false_edges)
    # Convert test edge arrays to indices
    test_true_indices = CartesianIndex.(test_true_edges[:, 1], test_true_edges[:, 2])
    test_false_indices = CartesianIndex.(test_false_edges[:, 1], test_false_edges[:, 2])

    # Prepare ground truth values for test edges
    Areal = Array(adjacency_matrix(greal))
    real_true = Areal[test_true_indices]
    @assert real_true == ones(length(test_true_indices))
    real_false = Areal[test_false_indices]
    @assert real_false == zeros(length(test_false_indices))
    real_all = vcat(real_true, real_false)

    metrics = pyimport("sklearn.metrics")

    function perf(x)
        μ = enc(x)[1]
        Alogitpred = dec(μ).data
        pred_true = Utils.threadedσ(Alogitpred[test_true_indices])
        pred_false = Utils.threadedσ(Alogitpred[test_false_indices])
        pred_all = vcat(pred_true, pred_false)

        metrics[:roc_auc_score](real_all, pred_all), metrics[:average_precision_score](real_all, pred_all)
    end

    perf
end


"""Define the model losses."""
function make_losses(;g, labels, feature_size, args, enc, sampleξ, dec, paramsenc, paramsdec)
    dimξadj, = args["dimxiadj"]
    Adiag = Array{Float32}(adjacency_matrix_diag(g))
    densityA = Float32(mean(adjacency_matrix(g)))

    # Kullback-Leibler divergence
    Lkl(μ, logσ) = sum(Utils.threadedklnormal(μ, logσ))
    κkl = Float32(size(g, 1) * dimξadj)

    # Adjacency loss
    Ladj(logitApred) = (
        sum(Utils.threadedlogitbinarycrossentropy(logitApred, Adiag, pos_weight = (1f0 / densityA) - 1))
        / (2 * (1 - densityA))
    )
    κadj = Float32(size(g, 1)^2 * log(2))

    # Total loss
    function losses(x)
        μ, logσ = enc(x)
        logitApred = dec(sampleξ(μ, logσ))
        Dict("kl" => klscale * Lkl(μ, logσ) / κkl,
            "adj" => Ladj(logitApred) / κadj)
    end

    function loss(x)
        sum(values(losses(x)))
    end

    losses, loss
end


function main()
    args = parse_cliargs()
    savehistory, saveweights, profilen = args["savehistory"], args["saveweights"], args["profile"]
    if profilen != nothing
        println("Profiling $profilen loss runs. Ignoring any \"save*\" arguments.")
    else
        saveweights == nothing && println("Warning: will not save model weights after training")
    end

    println("Loading the dataset")
    g, _features = dataset(args)
    feature_size = size(features, 1)
    # Note: this is input-variable normalisation, different from the vanilla VGAE wich uses case normalisation
    features = normaliser(_features)(_features)
    gtrain, test_true_edges, test_false_edges = Dataset.make_blurred_test_set(g, args["blurring"])

    println("Making the model")
    enc, sampleξ, dec, paramsenc, paramsdec = make_vae(
        g = gtrain, feature_size = feature_size, args = args)
    losses, loss = make_losses(
        g = gtrain, labels = labels, feature_size = feature_size, args = args,
        enc = enc, sampleξ = sampleξ, dec = dec,
        paramsenc = paramsenc, paramsdec = paramsdec)
    perf = make_perf_scorer(
        enc = enc, sampleξ = sampleξ, dec = dec,
        greal = g, test_true_edges = test_true_edges, test_false_edges = test_false_edges)

    if profilen != nothing
        println("Profiling loss runs...")
        Utils.repeat_fn(1, loss, features)  # Trigger compilation
        Profile.clear()
        Profile.init(n = 10000000)
        @profile Utils.repeat_fn(profilen, loss, features)
        li, lidict = Profile.retrieve()
        println("Saving profile results to \"$(profile_losses_filename)\"")
        JLD.@save profile_losses_filename li lidict

        return
    end

    println("Training...")
    paramsvae = Flux.Params()
    push!(paramsvae, paramsenc..., paramsdec...)
    history = VAE.train_vae!(
        args = args, features = features,
        losses = losses, loss = loss, perf = perf,
        paramsvae = paramsvae)

    println("Final losses and performance metrics:")
    for (name, values) in history
        println("  $name = $(values[end])")
    end

    # Save results
    println("Saving training history to \"$savehistory\"")
    npzwrite(savehistory, Dict{String, Any}(history))
    if saveweights != nothing
        println("Saving final model weights and creation parameters to \"$saveweights\"")
        weights = Tracker.data.(paramsvae)
        BSON.@save saveweights weights args
    else
        println("Not saving model weights or creation parameters")
    end
end

main()
