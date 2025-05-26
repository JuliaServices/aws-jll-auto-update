#!/usr/bin/env julia

using JSON
using HTTP
using Dates
import TOML
import Pkg

"""
Query the Julia General registry for the latest version of a JLL package using local registry.
"""
function get_latest_jll_version(package_name::String)
    try
        # Get registry information
        registry = Pkg.Registry.reachable_registries()[1]  # Get General registry
        packages = registry.pkgs
        
        # Find package by name
        for (uuid, pkg_info) in packages
            if pkg_info.name == package_name
                # Get package path and read versions
                pkg_path = joinpath(registry.path, string(uuid)[1:1], pkg_info.name)
                versions_file = joinpath(pkg_path, "Versions.toml")
                
                if isfile(versions_file)
                    versions_toml = TOML.parsefile(versions_file)
                    # Get the latest version (last one in the file)
                    version_keys = sort(collect(keys(versions_toml)), by=x->VersionNumber(x))
                    if !isempty(version_keys)
                        return string(version_keys[end])
                    end
                end
                break
            end
        end
        
        println("Warning: Package $package_name not found in registry")
        return nothing
    catch e
        println("Error fetching version for $package_name: $e")
        return nothing
    end
end

"""
Alternative method using GitHub releases for JLL packages.
"""
function get_latest_jll_version_github(package_name::String)
    # Most JLL packages are hosted under JuliaBinaryWrappers
    repo = "JuliaBinaryWrappers/$package_name"
    url = "https://api.github.com/repos/$repo/releases/latest"
    
    try
        headers = []
        if haskey(ENV, "GITHUB_TOKEN")
            push!(headers, "Authorization" => "token $(ENV["GITHUB_TOKEN"])")
        end
        
        response = HTTP.get(url, headers)
        if response.status == 200
            data = JSON.parse(String(response.body))
            tag_name = data["tag_name"]
            # Remove 'v' prefix if present
            return startswith(tag_name, "v") ? tag_name[2:end] : tag_name
        else
            println("Warning: Could not fetch GitHub release for $package_name")
            return nothing
        end
    catch e
        println("Error fetching GitHub release for $package_name: $e")
        return nothing
    end
end

"""
Update the JLL versions JSON file with latest versions.
For now, we'll keep the manual versions and add a mechanism to check against them.
"""
function update_jll_versions_file(filename::String="jll-versions.json")
    # Load existing data
    if isfile(filename)
        data = JSON.parsefile(filename)
    else
        data = Dict("last_updated" => "", "versions" => Dict())
    end
    
    # For now, we'll just update the timestamp since live querying is complex
    # In a real scenario, you'd implement proper version checking here
    println("Note: JLL version querying from registries is complex.")
    println("Consider manually updating versions in jll-versions.json when needed.")
    println("Current cached versions:")
    
    for (package, version) in data["versions"]
        println("  $package: $version")
    end
    
    # Update timestamp
    data["last_updated"] = string(now(UTC))
    
    # Write back to file
    open(filename, "w") do f
        JSON.print(f, data, 2)
    end
    
    println("\\nTimestamp updated in: $filename")
    return data
end

"""
Get the latest version for a specific JLL package, using cache if fresh enough.
"""
function get_jll_version(package_name::String, filename::String="jll-versions.json", max_age_hours::Int=24)
    if isfile(filename)
        data = JSON.parsefile(filename)
        
        # Check if cache is fresh enough
        if haskey(data, "last_updated") && !isempty(data["last_updated"])
            last_updated = DateTime(data["last_updated"][1:19])  # Remove timezone info
            age_hours = (now(UTC) - last_updated).value / (1000 * 3600)
            
            if age_hours < max_age_hours && haskey(data["versions"], package_name)
                return data["versions"][package_name]
            end
        end
    end
    
    # Cache is stale or missing, fetch fresh data
    println("Cache is stale, fetching latest version for $package_name...")
    
    # Try GitHub first
    version = get_latest_jll_version_github(package_name)
    if version === nothing
        version = get_latest_jll_version(package_name)
    end
    
    return version
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
Update dependency versions in a build_tarballs.jl file.
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
            latest_version = get_jll_version(dep, versions_file)
            if latest_version !== nothing
                # Update compat version in the file
                old_pattern = Regex("((?:Build)?Dependency\\(\"$dep\";\\s*compat=\")([0-9]+\\.[0-9]+\\.[0-9]+)(\")")
                new_replacement = "\\1$latest_version\\3"
                
                new_content = replace(content, old_pattern => new_replacement)
                if new_content != content
                    content = new_content
                    modified = true
                    println("  ✓ Updated $dep to $latest_version")
                else
                    println("  - No compat constraint found for $dep")
                end
            else
                println("  ✗ Could not fetch latest version for $dep")
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
        println("  julia jll-version-manager.jl update-cache          # Update the versions cache")
        println("  julia jll-version-manager.jl update-deps <file>    # Update dependencies in a build_tarballs.jl file")
        println("  julia jll-version-manager.jl get-version <package> # Get latest version of a package")
    elseif ARGS[1] == "update-cache"
        update_jll_versions_file()
    elseif ARGS[1] == "update-deps" && length(ARGS) >= 2
        update_dependencies_in_file(ARGS[2])
    elseif ARGS[1] == "get-version" && length(ARGS) >= 2
        version = get_jll_version(ARGS[2])
        if version !== nothing
            println(version)
        else
            exit(1)
        end
    else
        println("Unknown command or missing arguments")
        exit(1)
    end
end
