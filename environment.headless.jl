using Pkg
Pkg.add([
    PackageSpec("ArgParse"),
    PackageSpec("BSON"),
    PackageSpec("Colors"),
    PackageSpec("CSV"),
    PackageSpec("DataFrames"),
    PackageSpec("Distributions"),
    PackageSpec("FileIO"),
    PackageSpec("Flux"),
    PackageSpec("GraphPlot"),
    PackageSpec("GZip"),
    PackageSpec("IJulia"),
    PackageSpec("Images"),
    PackageSpec("JLD"),
    PackageSpec("Juno"),
    PackageSpec("LightGraphs"),
    PackageSpec("LinearAlgebra"),
    PackageSpec("MetaGraphs"),
    PackageSpec("MLBase"),
    PackageSpec(name = "AbstractPlotting", rev = "master"),
    PackageSpec(name = "CairoMakie", rev = "master"),
    # PackageSpec(name = "GLMakie", rev = "master"),
    PackageSpec(name = "Makie", rev = "master"),
    PackageSpec("NPZ"),
    PackageSpec("Printf"),
    PackageSpec("Profile"),
    PackageSpec("ProgressMeter"),
    PackageSpec("PyCall"),
    PackageSpec("Random"),
    PackageSpec("ScikitLearn"),
    PackageSpec("SparseArrays"),
    PackageSpec("Statistics"),
    PackageSpec("StatsBase"),
])
