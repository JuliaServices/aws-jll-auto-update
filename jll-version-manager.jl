#!/usr/bin/env julia
import Pkg
Pkg.instantiate()

using JSON
using Dates

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
    jll_package_name = endswith(package_name, "_jll") ? package_name : package_name * "_jll"
    
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
    jll_package_name = endswith(package_name, "_jll") ? package_name : package_name * "_jll"
    
    if haskey(data["versions"], jll_package_name)
        return data["versions"][jll_package_name]
    else
        println("Warning: Package $jll_package_name not found in versions cache")
        return nothing
    end
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
                # Update compat version in the file
                old_pattern = Regex("((?:Build)?Dependency\\(\"$dep\";\\s*compat=\")([0-9]+\\.[0-9]+\\.[0-9]+)(\")")
                new_replacement = "\\1$cached_version\\3"
                
                new_content = replace(content, old_pattern => new_replacement)
                if new_content != content
                    content = new_content
                    modified = true
                    println("  ✓ Updated $dep to $cached_version")
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
    else
        println("Unknown command or missing arguments")
        exit(1)
    end
end
