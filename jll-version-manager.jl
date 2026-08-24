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
    baseline_file::String="coverage-baseline.json",
)
    floor_version = parse_version(get_baseline_version(package_name, baseline_file))
    registered = Set(fetch_registered_versions(package_name))

    missing_versions = String[]
    for version in upstream_versions
        parsed = parse_version(version)
        normalized = strip_build_metadata(version)
        if parsed > floor_version && !(normalized in registered)
            push!(missing_versions, normalized)
        end
    end

    return sort(unique(missing_versions); by=parse_version)
end

"""
Return the oldest missing upstream version above the coverage baseline, or `nothing`.
"""
function next_missing_version(
    package_name::String,
    upstream_versions::Vector{String},
    baseline_file::String="coverage-baseline.json",
)
    missing_versions = list_missing_versions(package_name, upstream_versions, baseline_file)
    return isempty(missing_versions) ? nothing : first(missing_versions)
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
Parse dependencies from a build_tarballs.jl file.
"""
function parse_dependencies(filepath::String)
    content = read(filepath, String)
    
    # Look for dependencies array
    dep_match = match(r"dependencies\s*=\s*\[(.*?)\]"s, content)
    if dep_match === nothing
        return String[]
    end
    
    dep_content = dep_match.captures[1]
    
    # Extract dependency names (both Dependency and BuildDependency)
    deps = String[]
    for m in eachmatch(r"(?:Build)?Dependency\(\"([^\"]+)\"", dep_content)
        push!(deps, m.captures[1])
    end
    
    return deps
end

"""
Update dependency versions in a build_tarballs.jl file using cached versions.
"""
function update_dependencies_in_file(filepath::String, versions_file::String="jll-versions.json")
    content = read(filepath, String)
    
    # Parse current dependencies
    current_deps = parse_dependencies(filepath)
    
    println("Found dependencies in $filepath:")
    for dep in current_deps
        println("  - $dep")
    end
    
    # Update versions for JLL dependencies
    modified = false
    for dep in current_deps
        if endswith(dep, "_jll")
            cached_version = get_jll_version(dep, versions_file)
            if cached_version !== nothing
                # Find and replace each dependency line individually
                # Look for pattern: Dependency("package_name"; compat="version")
                dep_pattern = Regex("((?:Build)?Dependency\\(\"$dep\";\\s*compat=\")([0-9]+\\.[0-9]+\\.[0-9]+)(\")")
                
                if occursin(dep_pattern, content)
                    # Replace using simple string substitution
                    old_match = match(dep_pattern, content)
                    if old_match !== nothing
                        old_full = old_match.match
                        new_full = old_match.captures[1] * cached_version * old_match.captures[3]
                        content = replace(content, old_full => new_full; count=1)
                        modified = true
                        println("  ✓ Updated $dep to $cached_version")
                    end
                else
                    println("  - No compat constraint found for $dep")
                end
            else
                println("  ✗ No cached version found for $dep")
            end
        end
    end
    
    if modified
        write(filepath, content)
        println("Updated dependencies in $filepath")
    else
        println("No dependency updates needed for $filepath")
    end
    
    return modified
end

# Main execution
if abspath(PROGRAM_FILE) == @__FILE__
    if length(ARGS) == 0
        println("Usage:")
        println("  julia jll-version-manager.jl update-deps <file> [versions_file]  # Update dependencies in a build_tarballs.jl file")
        println("  julia jll-version-manager.jl get-version <package>              # Get cached version of a package")
        println("  julia jll-version-manager.jl update-version <package> <version> # Update a specific package version")
        println("  julia jll-version-manager.jl next-missing <package> <upstream_tags_file> [baseline_file]")
        println("  julia jll-version-manager.jl list-missing <package> <upstream_tags_file> [baseline_file]")
        println("  julia jll-version-manager.jl audit-versions [versions_file] [baseline_file]")
        println("  julia jll-version-manager.jl fix-versions [versions_file] [baseline_file]")
    elseif ARGS[1] == "update-deps" && length(ARGS) >= 2
        versions_file = length(ARGS) >= 3 ? ARGS[3] : "jll-versions.json"
        update_dependencies_in_file(ARGS[2], versions_file)
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
        missing_versions = list_missing_versions(ARGS[2], upstream, baseline_file)
        if !isempty(missing_versions)
            println(stderr, "Missing versions above baseline: $(join(missing_versions, ", "))")
        else
            println(stderr, "No missing versions above baseline")
        end
        next = isempty(missing_versions) ? nothing : first(missing_versions)
        if next !== nothing
            println(next)
        end
    elseif ARGS[1] == "list-missing" && length(ARGS) >= 3
        baseline_file = length(ARGS) >= 4 ? ARGS[4] : "coverage-baseline.json"
        upstream = read_upstream_versions(ARGS[3])
        for version in list_missing_versions(ARGS[2], upstream, baseline_file)
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
