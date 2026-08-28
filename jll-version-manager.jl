#!/usr/bin/env julia
import Pkg
Pkg.instantiate()

using JSON
using Dates
using HTTP
using TOML

"""
Ensure a package name ends with `_jll`.
"""
function normalize_jll_name(package_name::String)
    return endswith(package_name, "_jll") ? package_name : package_name * "_jll"
end

"""
Strip registry build metadata (`1.73.0+0` → `1.73.0`).
"""
function strip_build_metadata(version::String)
    return String(split(version, '+'; limit=2)[1])
end

"""
Parse a version string into a `VersionNumber` for ordering.
"""
function parse_version(version::String)
    return VersionNumber(strip_build_metadata(version))
end

"""
Update a specific JLL package version in the versions JSON file.
"""
function update_jll_version(package_name::String, new_version::String, filename::String="jll-versions.json")
    # Load existing data
    if isfile(filename)
        data = JSON.parsefile(filename)
    else
        data = Dict("last_updated" => "", "versions" => Dict())
    end
    
    # Ensure package name ends with _jll
    jll_package_name = normalize_jll_name(package_name)
    
    # Update the specific package version
    data["versions"][jll_package_name] = new_version
    data["last_updated"] = string(now(UTC))
    
    # Write back to file
    open(filename, "w") do f
        JSON.print(f, data, 2)
    end
    
    println("Updated $jll_package_name to version $new_version in $filename")
    return data
end

"""
Get the cached version for a specific JLL package.
"""
function get_jll_version(package_name::String, filename::String="jll-versions.json")
    if !isfile(filename)
        println("Warning: Versions file $filename not found")
        return nothing
    end
    
    data = JSON.parsefile(filename)
    jll_package_name = normalize_jll_name(package_name)
    
    if haskey(data["versions"], jll_package_name)
        return data["versions"][jll_package_name]
    else
        println("Warning: Package $jll_package_name not found in versions cache")
        return nothing
    end
end

"""
Get the frozen coverage baseline (floor) version for a package.
"""
function get_baseline_version(package_name::String, filename::String="coverage-baseline.json")
    if !isfile(filename)
        error("Coverage baseline file $filename not found")
    end

    data = JSON.parsefile(filename)
    jll_package_name = normalize_jll_name(package_name)

    if !haskey(data["versions"], jll_package_name)
        error("Package $jll_package_name not found in coverage baseline $filename")
    end

    return String(data["versions"][jll_package_name])
end

"""
Fetch registered versions of a JLL from the General registry.
"""
function fetch_registered_versions(package_name::String)
    jll_package_name = normalize_jll_name(package_name)
    letter = uppercase(string(jll_package_name[1]))
    url = "https://raw.githubusercontent.com/JuliaRegistries/General/master/jll/$letter/$jll_package_name/Versions.toml"

    response = HTTP.get(url; status_exception=true)
    versions_toml = TOML.parse(String(response.body))

    registered = String[]
    for version_key in keys(versions_toml)
        push!(registered, strip_build_metadata(String(version_key)))
    end
    return unique(registered)
end

"""
Read upstream versions from a file (one version per line, no leading `v`).
"""
function read_upstream_versions(filepath::String)
    versions = String[]
    for line in eachline(filepath)
        version = strip(line)
        isempty(version) && continue
        startswith(version, 'v') && (version = version[2:end])
        push!(versions, version)
    end
    return unique(versions)
end

"""
List upstream versions newer than the coverage baseline that are not in General.
"""
function list_missing_versions(
    package_name::String,
    upstream_versions::Vector{String},
    baseline_file::String="coverage-baseline.json";
    registered::Union{Nothing,Vector{String}}=nothing,
)
    floor_version = parse_version(get_baseline_version(package_name, baseline_file))
    registered_versions = registered === nothing ? fetch_registered_versions(package_name) : registered
    registered_set = Set(strip_build_metadata(v) for v in registered_versions)
    registered_best = latest_registered_per_breaking_series(registered_versions)

    missing_versions = String[]
    for version in upstream_versions
        parsed = parse_version(version)
        normalized = strip_build_metadata(version)
        if parsed > floor_version && !(normalized in registered_set)
            key = breaking_compat_key(parsed)
            if haskey(registered_best, key) && parsed <= registered_best[key]
                continue
            end
            push!(missing_versions, normalized)
        end
    end

    return sort(unique(missing_versions); by=parse_version)
end

"""
Julia Pkg breaking-compat key: major for ≥1.0, `(major, minor)` for 0.x.
"""
function breaking_compat_key(v::VersionNumber)
    return v.major == 0 ? (v.major, v.minor) : (v.major,)
end

"""
Latest registered release within each breaking-compat series.
"""
function latest_registered_per_breaking_series(registered::Vector{String})
    best = Dict{Any,VersionNumber}()
    for version in registered
        parsed = parse_version(version)
        key = breaking_compat_key(parsed)
        if !haskey(best, key) || parsed > best[key]
            best[key] = parsed
        end
    end
    return best
end

"""
Keep only the latest version within each breaking-compat series.

For example, `4.0.0, 5.0.0, …, 5.6.0` becomes `4.0.0, 5.6.0`, and
`0.12.7, 0.12.8, 0.13.0, 0.13.1` becomes `0.12.8, 0.13.1`.
"""
function latest_per_breaking_version(versions::Vector{String})
    best = Dict{Any,String}()
    for version in versions
        normalized = strip_build_metadata(version)
        key = breaking_compat_key(parse_version(normalized))
        if !haskey(best, key) || parse_version(normalized) > parse_version(best[key])
            best[key] = normalized
        end
    end
    return sort(collect(values(best)); by=parse_version)
end

"""
Missing upstream versions collapsed to the latest release per breaking series.
"""
function coverage_target_versions(
    package_name::String,
    upstream_versions::Vector{String},
    baseline_file::String="coverage-baseline.json",
)
    return latest_per_breaking_version(
        list_missing_versions(package_name, upstream_versions, baseline_file),
    )
end

"""
Return the oldest coverage target above the baseline, or `nothing`.

Targets are the latest backward-compatible release in each missing breaking series.
"""
function next_missing_version(
    package_name::String,
    upstream_versions::Vector{String},
    baseline_file::String="coverage-baseline.json",
)
    targets = coverage_target_versions(package_name, upstream_versions, baseline_file)
    return isempty(targets) ? nothing : first(targets)
end

"""
Return the highest registered version string for a JLL in General.
"""
function latest_registered_version(package_name::String, registered::Vector{String}=fetch_registered_versions(package_name))
    if isempty(registered)
        error("No registered versions found in General for $(normalize_jll_name(package_name))")
    end
    latest = maximum(parse_version, registered)
    for version in registered
        if parse_version(version) == latest
            return version
        end
    end
    return string(latest)
end

"""
Strip `_jll` suffix for Yggdrasil / upstream package names.
"""
function package_basename(package_name::String)
    jll = normalize_jll_name(package_name)
    return endswith(jll, "_jll") ? jll[1:end-4] : jll
end

"""
True if Yggdrasil has an open PR updating `package` to `version` (in-flight registration).
"""
function has_open_yggdrasil_update_pr(
    package_name::String,
    version::String;
    repo::String="JuliaPackaging/Yggdrasil",
)
    pkg = package_basename(package_name)
    query = "repo:$repo is:pr is:open [$pkg] Update to version $version in:title"
    url = "https://api.github.com/search/issues?q=" * HTTP.escapeuri(query)
    headers = ["User-Agent" => "aws-jll-auto-update", "Accept" => "application/vnd.github+json"]
    token = get(ENV, "GITHUB_TOKEN", get(ENV, "GH_TOKEN", ""))
    if !isempty(token)
        push!(headers, "Authorization" => "Bearer $token")
    end
    response = HTTP.get(url; headers=headers, status_exception=true)
    data = JSON.parse(String(response.body))
    return get(data, "total_count", 0) > 0
end

"""
One claimed version that is not present in General.
"""
struct VersionInconsistency
    package::String
    source::String
    claimed::String
    latest::String
    inflight::Bool
end

function format_inconsistency(inc::VersionInconsistency)
    suffix = inc.inflight ? " [in-flight Yggdrasil PR; skip fix]" : ""
    return "INCONSISTENT $(inc.package): $(inc.source)=$(inc.claimed) not in General (latest=$(inc.latest)) → suggest $(inc.latest)$suffix"
end

"""
Load the `versions` map from a JSON file, or an empty Dict if the file is missing.
"""
function load_versions_map(filename::String)
    if !isfile(filename)
        return Dict{String,Any}()
    end
    data = JSON.parsefile(filename)
    return get(data, "versions", Dict{String,Any}())
end

"""
Find cache/baseline version claims that are not registered in General.
"""
function find_version_inconsistencies(
    versions_file::String="jll-versions.json",
    baseline_file::String="coverage-baseline.json",
)
    cache_versions = load_versions_map(versions_file)
    baseline_versions = load_versions_map(baseline_file)
    packages = sort(unique(vcat(collect(keys(cache_versions)), collect(keys(baseline_versions)))))

    inconsistencies = VersionInconsistency[]
    for package in packages
        registered = fetch_registered_versions(package)
        registered_set = Set(registered)
        latest = latest_registered_version(package, registered)

        if haskey(cache_versions, package)
            claimed = strip_build_metadata(String(cache_versions[package]))
            if !(claimed in registered_set)
                inflight = has_open_yggdrasil_update_pr(package, claimed)
                push!(inconsistencies, VersionInconsistency(package, "cache", claimed, latest, inflight))
            end
        end

        if haskey(baseline_versions, package)
            claimed = strip_build_metadata(String(baseline_versions[package]))
            if !(claimed in registered_set)
                # Baseline is a registered-floor; never treat as in-flight.
                push!(inconsistencies, VersionInconsistency(package, "baseline", claimed, latest, false))
            end
        end
    end

    return inconsistencies
end

"""
Print inconsistencies. Returns the list. When `fail_on_find` is true, exit 1 if any exist.
"""
function audit_versions(
    versions_file::String="jll-versions.json",
    baseline_file::String="coverage-baseline.json";
    fail_on_find::Bool=true,
)
    inconsistencies = find_version_inconsistencies(versions_file, baseline_file)
    if isempty(inconsistencies)
        println("All JLL versions are registered in General")
        return inconsistencies
    end

    for inc in inconsistencies
        println(format_inconsistency(inc))
    end
    println("$(length(inconsistencies)) inconsistency(ies) found")
    if fail_on_find
        exit(1)
    end
    return inconsistencies
end

"""
Clamp inconsistent claims to the latest General-registered version.

Skips cache entries that have an open Yggdrasil update PR (in-flight registration).
Always clamps baseline phantoms.
"""
function fix_versions(
    versions_file::String="jll-versions.json",
    baseline_file::String="coverage-baseline.json",
)
    inconsistencies = find_version_inconsistencies(versions_file, baseline_file)
    if isempty(inconsistencies)
        println("All JLL versions are registered in General")
        return inconsistencies
    end

    for inc in inconsistencies
        println(format_inconsistency(inc))
    end
    println("$(length(inconsistencies)) inconsistency(ies) found")

    cache_fixes = Dict{String,String}()
    baseline_fixes = Dict{String,String}()
    skipped = 0
    for inc in inconsistencies
        if inc.inflight
            skipped += 1
            continue
        end
        if inc.source == "cache"
            cache_fixes[inc.package] = inc.latest
        elseif inc.source == "baseline"
            baseline_fixes[inc.package] = inc.latest
        end
    end

    if isempty(cache_fixes) && isempty(baseline_fixes)
        println("No safe clamps (all remaining inconsistencies are in-flight)")
        return inconsistencies
    end

    if !isempty(cache_fixes)
        if !isfile(versions_file)
            error("Versions file $versions_file not found")
        end
        data = JSON.parsefile(versions_file)
        for (package, version) in cache_fixes
            data["versions"][package] = version
            println("Clamped cache $package → $version")
        end
        data["last_updated"] = string(now(UTC))
        open(versions_file, "w") do f
            JSON.print(f, data, 2)
            println(f)
        end
    end

    if !isempty(baseline_fixes)
        if !isfile(baseline_file)
            error("Baseline file $baseline_file not found")
        end
        data = JSON.parsefile(baseline_file)
        for (package, version) in baseline_fixes
            data["versions"][package] = version
            println("Clamped baseline $package → $version")
        end
        open(baseline_file, "w") do f
            JSON.print(f, data, 2)
            println(f)
        end
    end

    if skipped > 0
        println("Skipped $skipped in-flight cache claim(s)")
    end

    return inconsistencies
end

"""
Parse all Dependency / BuildDependency names from a build_tarballs.jl file.
"""
function parse_dependencies(filepath::String)
    content = read(filepath, String)

    dep_match = match(r"dependencies\s*=\s*\[(.*?)\]"s, content)
    if dep_match === nothing
        return String[]
    end

    dep_content = dep_match.captures[1]
    deps = String[]
    for m in eachmatch(r"(?:Build)?Dependency\(\"([^\"]+)\"", dep_content)
        push!(deps, m.captures[1])
    end
    return deps
end

"""
Parse runtime `Dependency` names only (excludes `BuildDependency`).
"""
function parse_runtime_dependencies(filepath::String)
    content = read(filepath, String)

    dep_match = match(r"dependencies\s*=\s*\[(.*?)\]"s, content)
    if dep_match === nothing
        return String[]
    end

    dep_content = dep_match.captures[1]
    deps = String[]
    for m in eachmatch(r"(Build)?Dependency\(\"([^\"]+)\"", dep_content)
        m.captures[1] !== nothing && continue
        push!(deps, m.captures[2])
    end
    return deps
end

"""
Runtime `*_jll` dependencies that already have a `compat=` pin in the recipe.
"""
function runtime_deps_with_compat(filepath::String)
    content = read(filepath, String)
    deps = String[]
    for name in parse_runtime_dependencies(filepath)
        if endswith(name, "_jll") &&
           occursin(Regex("Dependency\\(\"$name\";\\s*compat=\""), content)
            push!(deps, name)
        end
    end
    return deps
end

"""
Read direct-dependency versions from a Pkg Manifest.toml.
"""
function read_manifest_direct_versions(
    manifest_file::String,
    dep_names::AbstractVector{<:AbstractString},
)
    man = TOML.parsefile(manifest_file)
    deps = get(man, "deps", Dict{String,Any}())
    result = Dict{String,String}()
    for name in dep_names
        if !haskey(deps, name)
            error("Resolved manifest missing dependency $name")
        end
        entries = deps[name]
        entry = entries isa AbstractVector ? first(entries) : entries
        if !(entry isa AbstractDict) || !haskey(entry, "version")
            error("Manifest entry for $name has no version")
        end
        result[String(name)] = strip_build_metadata(String(entry["version"]))
    end
    return result
end

"""
Resolve mutually compatible versions for `dep_names` via a temporary Pkg env.

Optional `depot` / `registry` isolate resolution for tests (fresh depot + one local
registry path). When unset, uses the active Julia depot and its registries.
"""
function resolve_compatible_versions(
    dep_names::Vector{String};
    depot::Union{Nothing,AbstractString}=nothing,
    registry::Union{Nothing,AbstractString}=nothing,
)
    isempty(dep_names) && return Dict{String,String}()

    project_dir = mktempdir()
    previous_project = Base.active_project()
    saved_depot_path = copy(Base.DEPOT_PATH)
    try
        if depot !== nothing
            empty!(Base.DEPOT_PATH)
            push!(Base.DEPOT_PATH, abspath(depot))
            mkpath(joinpath(Base.DEPOT_PATH[1], "registries"))
        end
        if registry !== nothing
            Pkg.Registry.add(Pkg.RegistrySpec(; path=abspath(registry)))
        end
        Pkg.activate(project_dir)
        Pkg.add([Pkg.PackageSpec(; name=name) for name in dep_names])
        manifest_file = joinpath(project_dir, "Manifest.toml")
        if !isfile(manifest_file)
            error("Pkg.add did not produce a Manifest.toml in $project_dir")
        end
        return read_manifest_direct_versions(manifest_file, dep_names)
    finally
        empty!(Base.DEPOT_PATH)
        append!(Base.DEPOT_PATH, saved_depot_path)
        if previous_project !== nothing && isfile(previous_project)
            Pkg.activate(previous_project)
        end
    end
end

"""
A direct dependency pinned below the latest known version.
"""
struct HeldBackDependency
    name::String
    resolved::String
    latest::String
end

"""
Latest known version: max of versions-cache entry and General registration (when available).
"""
function latest_known_version(
    package_name::String,
    versions_file::String;
    use_general::Bool=true,
)
    candidates = String[]
    jll_package_name = normalize_jll_name(package_name)
    versions = load_versions_map(versions_file)
    if haskey(versions, jll_package_name)
        push!(candidates, strip_build_metadata(String(versions[jll_package_name])))
    end
    if use_general
        try
            push!(candidates, latest_registered_version(package_name))
        catch e
            @warn "Could not fetch General versions for $package_name" exception = e
        end
    end
    isempty(candidates) && return nothing
    best = maximum(parse_version, candidates)
    for candidate in candidates
        if parse_version(candidate) == best
            return candidate
        end
    end
    return string(best)
end

"""
Deps whose resolved pin is strictly older than the latest known version.
"""
function held_back_dependencies(
    resolved::Dict{String,String},
    versions_file::String;
    use_general::Bool=true,
)
    held = HeldBackDependency[]
    for name in sort!(collect(keys(resolved)))
        latest = latest_known_version(name, versions_file; use_general=use_general)
        latest === nothing && continue
        resolved_ver = resolved[name]
        if parse_version(resolved_ver) < parse_version(latest)
            push!(held, HeldBackDependency(name, resolved_ver, latest))
        end
    end
    return held
end

"""
Markdown fragment describing resolved pins and anything held back from latest.
"""
function format_dependency_pins_report(
    resolved::Dict{String,String},
    held::Vector{HeldBackDependency},
)
    io = IOBuffer()
    if isempty(resolved)
        println(io, "No runtime JLL dependencies with compat pins.")
        return String(take!(io))
    end
    if isempty(held)
        println(io, "All runtime deps pinned at latest known.")
        for name in sort!(collect(keys(resolved)))
            println(io, "- `$name`: $(resolved[name])")
        end
    else
        println(io, "### Held back from latest")
        for h in held
            println(io, "- `$(h.name)`: using **$(h.resolved)** (latest known **$(h.latest)**)")
        end
        held_names = Set(h.name for h in held)
        at_latest = sort([n for n in keys(resolved) if !(n in held_names)])
        if !isempty(at_latest)
            println(io)
            println(io, "### At latest")
            for name in at_latest
                println(io, "- `$name`: $(resolved[name])")
            end
        end
    end
    return String(take!(io))
end

"""
Update dependency compat pins using Pkg-resolved mutually compatible versions.
"""
function update_dependencies_in_file(
    filepath::String,
    versions_file::String="jll-versions.json";
    report_file::Union{String,Nothing}=nothing,
    use_general::Bool=true,
)
    content = read(filepath, String)
    deps = runtime_deps_with_compat(filepath)

    println("Found runtime JLL dependencies with compat in $filepath:")
    for dep in deps
        println("  - $dep")
    end

    if isempty(deps)
        report = format_dependency_pins_report(Dict{String,String}(), HeldBackDependency[])
        println(report)
        if report_file !== nothing
            write(report_file, report)
        end
        println("No dependency updates needed for $filepath")
        return false
    end

    println("Resolving mutually compatible versions with Pkg...")
    resolved = resolve_compatible_versions(deps)

    modified = false
    for dep in deps
        new_version = resolved[dep]
        dep_pattern = Regex("(Dependency\\(\"$dep\";\\s*compat=\")([0-9]+\\.[0-9]+\\.[0-9]+)(\")")
        old_match = match(dep_pattern, content)
        if old_match === nothing
            println("  - No compat constraint found for $dep (skipped)")
            continue
        end
        old_version = old_match.captures[2]
        if old_version == new_version
            println("  - $dep already at $new_version")
            continue
        end
        old_full = old_match.match
        new_full = old_match.captures[1] * new_version * old_match.captures[3]
        content = replace(content, old_full => new_full; count=1)
        modified = true
        println("  ✓ Updated $dep: $old_version → $new_version")
    end

    if modified
        write(filepath, content)
        println("Updated dependencies in $filepath")
    else
        println("No dependency text changes needed for $filepath")
    end

    held = held_back_dependencies(resolved, versions_file; use_general=use_general)
    report = format_dependency_pins_report(resolved, held)
    println(report)
    if report_file !== nothing
        write(report_file, report)
        println("Wrote dependency pins report to $report_file")
    end

    return modified
end

# Main execution
if abspath(PROGRAM_FILE) == @__FILE__
    if length(ARGS) == 0
        println("Usage:")
        println("  julia jll-version-manager.jl update-deps <file> [versions_file] [report_file]")
        println("  julia jll-version-manager.jl get-version <package>              # Get cached version of a package")
        println("  julia jll-version-manager.jl update-version <package> <version> # Update a specific package version")
        println("  julia jll-version-manager.jl next-missing <package> <upstream_tags_file> [baseline_file]")
        println("  julia jll-version-manager.jl list-missing <package> <upstream_tags_file> [baseline_file]")
        println("  julia jll-version-manager.jl audit-versions [versions_file] [baseline_file]")
        println("  julia jll-version-manager.jl fix-versions [versions_file] [baseline_file]")
    elseif ARGS[1] == "update-deps" && length(ARGS) >= 2
        versions_file = length(ARGS) >= 3 ? ARGS[3] : "jll-versions.json"
        report_file = length(ARGS) >= 4 ? ARGS[4] : nothing
        update_dependencies_in_file(ARGS[2], versions_file; report_file=report_file)
    elseif ARGS[1] == "get-version" && length(ARGS) >= 2
        version = get_jll_version(ARGS[2])
        if version !== nothing
            println(version)
        else
            exit(1)
        end
    elseif ARGS[1] == "update-version" && length(ARGS) >= 3
        update_jll_version(ARGS[2], ARGS[3])
    elseif ARGS[1] == "next-missing" && length(ARGS) >= 3
        baseline_file = length(ARGS) >= 4 ? ARGS[4] : "coverage-baseline.json"
        upstream = read_upstream_versions(ARGS[3])
        targets = coverage_target_versions(ARGS[2], upstream, baseline_file)
        if !isempty(targets)
            println(stderr, "Coverage targets (latest per breaking series): $(join(targets, ", "))")
        else
            println(stderr, "No missing versions above baseline")
        end
        next = isempty(targets) ? nothing : first(targets)
        if next !== nothing
            println(next)
        end
    elseif ARGS[1] == "list-missing" && length(ARGS) >= 3
        baseline_file = length(ARGS) >= 4 ? ARGS[4] : "coverage-baseline.json"
        upstream = read_upstream_versions(ARGS[3])
        for version in coverage_target_versions(ARGS[2], upstream, baseline_file)
            println(version)
        end
    elseif ARGS[1] == "audit-versions"
        versions_file = length(ARGS) >= 2 ? ARGS[2] : "jll-versions.json"
        baseline_file = length(ARGS) >= 3 ? ARGS[3] : "coverage-baseline.json"
        audit_versions(versions_file, baseline_file)
    elseif ARGS[1] == "fix-versions"
        versions_file = length(ARGS) >= 2 ? ARGS[2] : "jll-versions.json"
        baseline_file = length(ARGS) >= 3 ? ARGS[3] : "coverage-baseline.json"
        fix_versions(versions_file, baseline_file)
    else
        println("Unknown command or missing arguments")
        exit(1)
    end
end
