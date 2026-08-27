using Test
using TOML

include(joinpath(@__DIR__, "..", "jll-version-manager.jl"))
include(joinpath(@__DIR__, "compat_resolve_fixture.jl"))

@testset "strip_build_metadata" begin
    @test strip_build_metadata("0.3.2+0") == "0.3.2"
    @test strip_build_metadata("1.73.0") == "1.73.0"
end

@testset "breaking_compat_key" begin
    @test breaking_compat_key(v"0.12.7") == (0, 12)
    @test breaking_compat_key(v"0.13.0") == (0, 13)
    @test breaking_compat_key(v"4.0.0") == (4,)
    @test breaking_compat_key(v"5.6.0") == (5,)
end

@testset "latest_per_breaking_version" begin
    @test latest_per_breaking_version([
        "4.0.0",
        "5.0.0",
        "5.1.0",
        "5.2.0",
        "5.3.0",
        "5.4.0",
        "5.5.0",
        "5.6.0",
    ]) == ["4.0.0", "5.6.0"]

    @test latest_per_breaking_version([
        "0.12.7",
        "0.12.8",
        "0.13.0",
        "0.13.1",
        "0.14.5",
    ]) == ["0.12.8", "0.13.1", "0.14.5"]

    @test latest_per_breaking_version(String[]) == String[]
    @test latest_per_breaking_version(["1.2.3"]) == ["1.2.3"]
end

@testset "read_manifest_direct_versions" begin
    manifest = joinpath(@__DIR__, "fixtures", "sample-Manifest.toml")
    versions = read_manifest_direct_versions(
        manifest,
        ["aws_c_compression_jll", "aws_c_io_jll"],
    )
    @test versions["aws_c_compression_jll"] == "0.3.2"
    @test versions["aws_c_io_jll"] == "0.26.3"
end

@testset "parse_runtime_dependencies excludes BuildDependency" begin
    recipe = """
    dependencies = [
        Dependency("aws_c_io_jll"; compat="0.26.3"),
        Dependency("aws_c_compression_jll"; compat="0.3.2"),
        BuildDependency("aws_lc_jll"),
    ]
    """
    path = tempname()
    write(path, recipe)
    try
        @test parse_runtime_dependencies(path) ==
              ["aws_c_io_jll", "aws_c_compression_jll"]
        @test runtime_deps_with_compat(path) ==
              ["aws_c_io_jll", "aws_c_compression_jll"]
        @test "aws_lc_jll" in parse_dependencies(path)
    finally
        rm(path; force=true)
    end
end

@testset "held_back_dependencies vs cache" begin
    cache = tempname()
    write(
        cache,
        """
        {
          "versions": {
            "aws_c_compression_jll": "0.3.3",
            "aws_c_io_jll": "0.26.3"
          }
        }
        """,
    )
    try
        resolved = Dict(
            "aws_c_compression_jll" => "0.3.2",
            "aws_c_io_jll" => "0.26.3",
        )
        held = held_back_dependencies(resolved, cache; use_general=false)
        @test length(held) == 1
        @test held[1].name == "aws_c_compression_jll"
        @test held[1].resolved == "0.3.2"
        @test held[1].latest == "0.3.3"

        report = format_dependency_pins_report(resolved, held)
        @test occursin("Held back from latest", report)
        @test occursin("aws_c_compression_jll", report)
        @test occursin("0.3.2", report)
        @test occursin("0.3.3", report)
        @test occursin("At latest", report)
        @test occursin("aws_c_io_jll", report)
    finally
        rm(cache; force=true)
    end
end

@testset "held_back empty when at latest" begin
    cache = tempname()
    write(
        cache,
        """
        {
          "versions": {
            "aws_c_io_jll": "0.26.3"
          }
        }
        """,
    )
    try
        resolved = Dict("aws_c_io_jll" => "0.26.3")
        held = held_back_dependencies(resolved, cache; use_general=false)
        @test isempty(held)
        report = format_dependency_pins_report(resolved, held)
        @test occursin("All runtime deps pinned at latest known", report)
    finally
        rm(cache; force=true)
    end
end

@testset "compat pin rewrite and held-back report" begin
    resolved = Dict(
        "aws_c_compression_jll" => "0.3.2",
        "aws_c_io_jll" => "0.26.3",
    )
    content = """
    dependencies = [
        Dependency("aws_c_compression_jll"; compat="0.3.1"),
        Dependency("aws_c_io_jll"; compat="0.26.0"),
        BuildDependency("aws_lc_jll"),
    ]
    """
    for (dep, new_version) in resolved
        dep_pattern = Regex("(Dependency\\(\"$dep\";\\s*compat=\")([0-9]+\\.[0-9]+\\.[0-9]+)(\")")
        m = match(dep_pattern, content)
        @test m !== nothing
        content = replace(
            content,
            m.match => m.captures[1] * new_version * m.captures[3];
            count=1,
        )
    end
    @test occursin("compat=\"0.3.2\"", content)
    @test occursin("compat=\"0.26.3\"", content)
    @test occursin("BuildDependency(\"aws_lc_jll\")", content)

    cache = tempname()
    write(
        cache,
        """
        {
          "versions": {
            "aws_c_compression_jll": "0.3.3",
            "aws_c_io_jll": "0.26.3"
          }
        }
        """,
    )
    try
        held = held_back_dependencies(resolved, cache; use_general=false)
        report_text = format_dependency_pins_report(resolved, held)
        @test occursin("aws_c_compression_jll", report_text)
        @test occursin("latest known **0.3.3**", report_text)
    finally
        rm(cache; force=true)
    end
end

@testset "resolve_compatible_versions empty" begin
    @test resolve_compatible_versions(String[]) == Dict{String,String}()
end

@testset "resolve_compatible_versions local registry" begin
    root = mktempdir()
    depot = mktempdir()
    try
        registry = setup_compat_resolve_fixture(root)

        both = resolve_compatible_versions(
            [TEST_LEAF_A, TEST_LEAF_B];
            depot=depot,
            registry=registry,
        )
        @test both[TEST_LEAF_A] == "1.0.0"
        @test both[TEST_LEAF_B] == "1.0.0"

        alone = resolve_compatible_versions(
            [TEST_LEAF_A];
            depot=depot,
            registry=registry,
        )
        @test alone[TEST_LEAF_A] == "1.1.0"
    finally
        rm(root; force=true, recursive=true)
        rm(depot; force=true, recursive=true)
    end
end
