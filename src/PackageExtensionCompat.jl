module PackageExtensionCompat

export @require_extensions

const HAS_NATIVE_EXTENSIONS = isdefined(Base, :get_extension)

@static if !HAS_NATIVE_EXTENSIONS
    using MacroTools, Requires, TOML

    @static if hasmethod(Base.include, Tuple{Function, Module, String})
        function _include(mapexpr::Function, m::Module, path::AbstractString)
            Base.include(mapexpr, m, path)
        end
    else
        function _include(mapexpr::Function, m::Module, path::AbstractString)
            path = abspath(path)
            cd(dirname(path)) do
                str = read(basename(path), String)
                pos = 1
                while true
                    (expr, pos) = Meta.parse(str, pos; raise=false)
                    expr !== nothing || break
                    m.eval(mapexpr(expr))
                end
            end
        end
    end

    function rewrite(toplevel::Module, pkgs)
        Base.Fix1(MacroTools.postwalk, block -> rewrite_block(block, toplevel, pkgs))
    end

    function rewrite_block(block, toplevel::Module, pkgs)
        if Meta.isexpr(block, :call) && block.args[1] == :include
            # inner include, rewrite it recursively
            local_mod = Expr(:macrocall, Symbol("@__MODULE__"), @__LINE__)
            Expr(:call, _include, rewrite(toplevel, pkgs), local_mod, block.args[2])
        elseif Meta.isexpr(block, [:using, :import])
            # using or import block, replace references to pkgs
            imports = map(block.args) do use
                Meta.isexpr(use, [:(:), :as]) ?
                    Expr(use.head,
                         rewrite_use(use.args[1], toplevel, pkgs),
                         use.args[2:end]...) :
                    rewrite_use(use, toplevel, pkgs)
            end
            Expr(block.head, imports...)
        else
            # leave everything else alone
            block
        end
    end

    function rewrite_use(use::Expr, toplevel::Module, pkgs)::Expr
        @assert Meta.isexpr(use, :.)
        string(use.args[1]) ∈ pkgs ? Expr(:., nameof(toplevel), use.args...) : use
    end

    macro require_extensions()
        rootdir = dirname(dirname(pathof(__module__)))
        tomlpath = nothing
        for file in ["JuliaProject.toml", "Project.toml"]
            path = joinpath(rootdir, file)
            if isfile(path)
                tomlpath = path
            end
        end
        if tomlpath === nothing
            error("Expecting Project.toml or JuliaProject.toml in $rootdir. Not a package?")
        end
        toml = open(TOML.parse, tomlpath)
        extensions = get(toml, "extensions", [])
        isempty(extensions) && error("no extensions defined in $tomlpath")
        exprs = []
        for (name, pkgs) in extensions
            if pkgs isa String
                pkgs = [pkgs]
            end
            extpath = nothing
            for path in [joinpath(rootdir, "ext", "$name.jl"),
                         joinpath(rootdir, "ext", "$name", "$name.jl")]
                if isfile(path)
                    extpath = path
                end
            end
            extpath === nothing && error("Expecting ext/$name.jl or ext/$name/$name.jl in $rootdir for extension $name.")
            __module__.include_dependency(extpath)
            # include and rewrite the extension code
            expr = :($(_include)($(rewrite(__module__, pkgs)), $__module__, $extpath))
            for pkg in pkgs
                uuid = get(get(Dict, toml, "weakdeps"), pkg, nothing)
                uuid === nothing && error("Expecting a weakdep for $pkg in $tomlpath.")
                expr = :($Requires.@require $(Symbol(pkg))=$(uuid) $expr)
            end
            push!(exprs, expr)
        end
        push!(exprs, nothing)
        esc(Expr(:block, exprs...))
    end

else
    macro require_extensions()
        nothing
    end
end

end # module PackageExtensionCompat
