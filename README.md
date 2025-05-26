# AWS JLL Auto-Update

This repository contains GitHub Actions workflows and utilities for automatically updating AWS CRT library JLL packages in the Julia ecosystem.

## Strategy

### Problem
Previously, when updating a library (e.g., `aws_c_cal` from version 0.9.0 to 0.9.1), the workflow would:
1. Update the library's `build_tarballs.jl` 
2. Update ALL other `build_tarballs.jl` files that depend on this library to use the new version

This caused a cascade of unnecessary rebuilds in Yggdrasil, since every change to a `build_tarballs.jl` file requires incrementing the version and rebuilding.

### Solution
The new strategy focuses on updating dependencies **within** the library being updated, rather than updating dependents:

1. **When updating a library**: Update its own dependencies to use the latest available JLL versions
2. **Maintain a JLL versions cache**: Keep a `jll-versions.json` file with the latest known versions of all AWS-related JLL packages
3. **Dynamic dependency resolution**: When updating a library's `build_tarballs.jl`, automatically fetch and update its dependencies to the latest versions

## Components

### 1. JLL Versions Cache (`jll-versions.json`)
A JSON file containing the latest known versions of all AWS-related JLL packages:

```json
{
  "last_updated": "2025-05-26T00:00:00Z",
  "versions": {
    "aws_c_auth_jll": "0.8.1",
    "aws_c_cal_jll": "0.9.1",
    "aws_c_common_jll": "0.12.3",
    ...
  }
}
```

This cache is updated periodically by the GitHub Actions workflow.

### 2. JLL Version Manager (`jll-version-manager.jl`)
A Julia utility script that:
- Queries Julia registries and GitHub for latest JLL package versions
- Updates the versions cache
- Parses `build_tarballs.jl` files and updates dependency versions
- Provides a CLI interface for version management

Usage:
```bash
julia jll-version-manager.jl update-cache                    # Update the versions cache
julia jll-version-manager.jl update-deps build_tarballs.jl   # Update dependencies in a file
julia jll-version-manager.jl get-version aws_c_common_jll    # Get latest version of a package
```

### 3. GitHub Actions Workflow
The workflow runs hourly and:
1. **Updates the JLL cache** with latest versions from Julia registries
2. **Checks each AWS library** for new releases
3. **When a new release is found**:
   - Updates the library version and SHA in its `build_tarballs.jl`
   - Updates all dependencies in that file to use the latest available versions
   - Creates a PR with the changes

## Benefits

1. **Fewer unnecessary rebuilds**: Only the updated library gets rebuilt, not all its dependents
2. **Always up-to-date dependencies**: When a library is updated, it automatically gets the latest dependency versions
3. **Cached version lookups**: Fast dependency resolution using the maintained cache
4. **Fallback to live queries**: If cache is stale, automatically queries for latest versions
5. **Comprehensive dependency management**: Handles both `Dependency` and `BuildDependency` declarations

## Example

When `aws_c_common` is updated from 0.12.2 to 0.12.3:

**Old approach**: 
- Update `aws_c_common/build_tarballs.jl` to version 0.12.3
- Find and update ~10 other libraries that depend on `aws_c_common_jll` 
- All ~10 libraries get rebuilt unnecessarily

**New approach**:
- Update `aws_c_common/build_tarballs.jl` to version 0.12.3  
- Update any dependencies within `aws_c_common` to their latest versions
- Only `aws_c_common` gets rebuilt
- Other libraries will pick up the new version naturally when they're next updated

This results in significantly fewer spurious rebuilds while keeping the ecosystem current.