# Helpers for resolve_compatible_versions integration tests (local depot + registry).

const TEST_COMMON = "CompatResolveCommon"
const TEST_LEAF_A = "CompatResolveLeafA"
const TEST_LEAF_B = "CompatResolveLeafB"

const UUID_COMMON = "a1111111-1111-4111-8111-111111111111"
const UUID_LEAF_A = "a2222222-2222-4222-8222-222222222222"
const UUID_LEAF_B = "a3333333-3333-4333-8333-333333333333"
const UUID_REGISTRY = "a4444444-4444-4444-8444-444444444444"

function _git(dir, args...)
    run(Cmd(`git -C $dir $args`; env=merge(
        copy(ENV),
        Dict(
            "GIT_AUTHOR_NAME" => "test",
            "GIT_AUTHOR_EMAIL" => "test@example.com",
            "GIT_COMMITTER_NAME" => "test",
            "GIT_COMMITTER_EMAIL" => "test@example.com",
        ),
    )))
end

function _git_output(dir, args...)
    return strip(read(Cmd(`git -C $dir $args`; env=merge(
        copy(ENV),
        Dict(
            "GIT_AUTHOR_NAME" => "test",
            "GIT_AUTHOR_EMAIL" => "test@example.com",
            "GIT_COMMITTER_NAME" => "test",
            "GIT_COMMITTER_EMAIL" => "test@example.com",
        ),
    )), String))
end

function _write_package_sources!(pkg_dir::String, name::String, uuid::String, version::String)
    mkpath(joinpath(pkg_dir, "src"))
    write(
        joinpath(pkg_dir, "Project.toml"),
        """
        name = "$name"
        uuid = "$uuid"
        version = "$version"
        """,
    )
    write(joinpath(pkg_dir, "src", "$name.jl"), "module $name end\n")
end

"""
Create a local package git repo and return (repo_path, version => tree_sha1).
`versions` is a Vector of (version, mutate_fn) where mutate_fn!(dir) prepares that version.
"""
function _package_git_repo(root::String, name::String, uuid::String, versions)
    repo = joinpath(root, "packages", name)
    mkpath(repo)
    _git(repo, "init")
    _git(repo, "config", "user.name", "test")
    _git(repo, "config", "user.email", "test@example.com")

    trees = Dict{String,String}()
    for (version, mutate!) in versions
        _write_package_sources!(repo, name, uuid, version)
        mutate!(repo)
        _git(repo, "add", "-A")
        _git(repo, "commit", "-m", "v$version")
        trees[version] = _git_output(repo, "rev-parse", "HEAD^{tree}")
    end
    return repo, trees
end

function _write_registry_package!(
    reg_pkg_dir::String;
    name::String,
    uuid::String,
    repo::String,
    trees::Dict{String,String},
    deps_toml::String,
    compat_toml::String,
)
    mkpath(reg_pkg_dir)
    write(
        joinpath(reg_pkg_dir, "Package.toml"),
        """
        name = "$name"
        uuid = "$uuid"
        repo = "$(replace(repo, '\\' => '/'))"
        """,
    )
    versions_io = IOBuffer()
    for version in sort!(collect(keys(trees)); by=VersionNumber)
        println(versions_io, "[\"$version\"]")
        println(versions_io, "git-tree-sha1 = \"$(trees[version])\"")
        println(versions_io)
    end
    write(joinpath(reg_pkg_dir, "Versions.toml"), String(take!(versions_io)))
    write(joinpath(reg_pkg_dir, "Deps.toml"), deps_toml)
    write(joinpath(reg_pkg_dir, "Compat.toml"), compat_toml)
end

"""
Build an isolated registry where LeafA latest needs Common 0.13 but LeafB only
supports Common 0.12 — so resolving both must hold LeafA at 1.0.0.
"""
function setup_compat_resolve_fixture(root::String)
    packages_root = joinpath(root, "packages")
    reg = joinpath(root, "TestCompatRegistry")
    mkpath(packages_root)
    mkpath(reg)

    common_repo, common_trees = _package_git_repo(
        root,
        TEST_COMMON,
        UUID_COMMON,
        [
            ("0.12.0", _ -> nothing),
            ("0.13.0", _ -> nothing),
        ],
    )
    leaf_a_repo, leaf_a_trees = _package_git_repo(
        root,
        TEST_LEAF_A,
        UUID_LEAF_A,
        [
            ("1.0.0", _ -> nothing),
            ("1.1.0", _ -> nothing),
        ],
    )
    leaf_b_repo, leaf_b_trees = _package_git_repo(
        root,
        TEST_LEAF_B,
        UUID_LEAF_B,
        [("1.0.0", _ -> nothing)],
    )

    write(
        joinpath(reg, "Registry.toml"),
        """
        name = "TestCompatRegistry"
        uuid = "$UUID_REGISTRY"
        repo = "https://example.com/TestCompatRegistry.git"

        [packages]
        $UUID_COMMON = { name = "$TEST_COMMON", path = "C/$TEST_COMMON" }
        $UUID_LEAF_A = { name = "$TEST_LEAF_A", path = "C/$TEST_LEAF_A" }
        $UUID_LEAF_B = { name = "$TEST_LEAF_B", path = "C/$TEST_LEAF_B" }
        """,
    )

    _write_registry_package!(
        joinpath(reg, "C", TEST_COMMON);
        name=TEST_COMMON,
        uuid=UUID_COMMON,
        repo=common_repo,
        trees=common_trees,
        deps_toml="",
        compat_toml="""
        ["0"]
        julia = "1.6-1"
        """,
    )
    _write_registry_package!(
        joinpath(reg, "C", TEST_LEAF_A);
        name=TEST_LEAF_A,
        uuid=UUID_LEAF_A,
        repo=leaf_a_repo,
        trees=leaf_a_trees,
        deps_toml="""
        [1]
        $TEST_COMMON = "$UUID_COMMON"
        """,
        compat_toml="""
        ["1.0.0-1.0"]
        julia = "1.6-1"
        $TEST_COMMON = "0.12"

        ["1.1.0-1"]
        julia = "1.6-1"
        $TEST_COMMON = "0.13"
        """,
    )
    _write_registry_package!(
        joinpath(reg, "C", TEST_LEAF_B);
        name=TEST_LEAF_B,
        uuid=UUID_LEAF_B,
        repo=leaf_b_repo,
        trees=leaf_b_trees,
        deps_toml="""
        [1]
        $TEST_COMMON = "$UUID_COMMON"
        """,
        compat_toml="""
        ["1"]
        julia = "1.6-1"
        $TEST_COMMON = "0.12"
        """,
    )

    _git(reg, "init")
    _git(reg, "config", "user.name", "test")
    _git(reg, "config", "user.email", "test@example.com")
    _git(reg, "add", "-A")
    _git(reg, "commit", "-m", "init registry")

    return reg
end
