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

1. **When updating a library**: Resolve its runtime JLL dependencies with Pkg (mutually compatible set) and pin those versions in `build_tarballs.jl`
2. **Maintain a JLL versions cache**: Keep a `jll-versions.json` file with the latest known versions of all AWS-related JLL packages (coverage / bookkeeping; not the sole source of recipe pins)
3. **Held-back reporting**: If Pkg pins a dep below the latest known version, list it in the Yggdrasil PR description
4. **Coverage-based catch-up**: Open Yggdrasil PRs for missing upstream releases above a frozen baseline, collapsing each breaking-compat series to its latest version (one target at a time, including backfill if the recipe jumped ahead)

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

This cache is updated by the GitHub Actions workflow when a coverage target or artificial bump is processed. It is used for coverage tracking and for comparing resolved pins against “latest known” in PR reports.

### 2. Coverage baseline (`coverage-baseline.json`)
A **frozen** floor of JLL versions that were registered when coverage catch-up started. The main updater never advances this file as part of coverage catch-up.

Upstream tags at or below the baseline are ignored. Only newer tags missing from General are considered coverage gaps. The audit workflow may clamp baseline entries that are not actually registered in General.

### 3. JLL Version Manager (`jll-version-manager.jl`)
A Julia utility script that:
- Updates the versions cache
- Parses `build_tarballs.jl` files and updates dependency compat pins via a temporary `Pkg.add` resolve
- Reports dependencies held back from latest known (for Yggdrasil PR bodies)
- Computes coverage targets: latest release per missing breaking-compat series above the baseline
- Audits / clamps cache and baseline versions that are missing from General

Usage:
```bash
julia jll-version-manager.jl update-deps build_tarballs.jl [versions_file] [report_file]
julia jll-version-manager.jl get-version aws_c_common_jll    # Get cached version of a package
julia jll-version-manager.jl update-version aws_c_common 0.12.7
julia jll-version-manager.jl next-missing aws_lc upstream-tags.txt
julia jll-version-manager.jl list-missing aws_lc upstream-tags.txt
julia jll-version-manager.jl audit-versions                  # Exit 1 if cache/baseline not in General
julia jll-version-manager.jl fix-versions                    # Clamp phantoms (skips in-flight Yggdrasil PRs)
```

### 4. GitHub Actions Workflow
The workflow:
1. Fetches upstream `v*` tags for each AWS library
2. Selects coverage targets: for each missing breaking series (Julia SemVer: major for ≥1.0, minor for 0.x), keep only the latest version; then take the oldest such target
3. When that target differs from the Yggdrasil recipe (including when the recipe is **ahead** of the gap):
   - Updates `jll-versions.json` to the target
   - Rewrites that library's `build_tarballs.jl` to the target version/SHA
   - Resolves runtime dependency pins with Pkg and writes them into the recipe
   - Opens a Yggdrasil PR (or refreshes the existing PR), including a dependency-pins / held-back section in the body
4. If coverage is complete and the recipe version is artificially above all upstream tags, only updates `jll-versions.json`

## Benefits

1. **Fewer unnecessary rebuilds**: Only the updated library gets rebuilt, not all its dependents
2. **Resolvable dependency sets**: Pins come from Pkg’s mutually compatible resolve, so mid-stack breaking bumps (e.g. `aws_c_common` 0.12 vs 0.13) do not produce unsatisfiable recipes
3. **Visible holdbacks**: Yggdrasil PRs list any dep kept below latest known
4. **Skip redundant compatible releases**: Catch-up registers only the latest release in each breaking series (e.g. `5.6.0` instead of every `5.x`)
5. **Backfill support**: If Yggdrasil already points at a newer tag, the workflow still opens a PR for an older missing gap

## Example

When missing upstream versions are `4.0.0, 5.0.0, …, 5.6.0`:

- Coverage targets collapse to `4.0.0, 5.6.0`
- First PR targets `4.0.0`; after that is registered, the next run targets `5.6.0`

For `0.x` packages (e.g. `aws_c_common` with gaps `0.12.7`, `0.12.8`, `0.13.0`, `0.13.1`, `0.14.5`), targets are `0.12.8, 0.13.1, 0.14.5` — one per minor series.
