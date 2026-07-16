
obj MTRuntime {
    has caller: Callable[(..., object)],
        args: dict[((int | str), object)],
        call_params: dict[(str, object)],
        mtir: (MTIR | None);

    static def factory(
        caller: Callable[(..., object)],
        args: dict[((int | str), object)],
        call_params: dict[(str, object)],
        mtir: (MTIR | None) = None
    ) -> MTRuntime {
        return MTRuntime(caller=caller, args=args, call_params=call_params, mtir=mtir);
    }
}

obj MTIR {
    has caller: Callable[(..., object)],
        args: dict[((int | str), object)],
        call_params: dict[(str, object)],
        ir_info: (Info | None) = None;

    has runtime: MTRuntime { getter; }
}

obj Info {
    has name: str,
        semstr: (str | None);
}

obj VarInfo(Info) {
    has type_info: (ClassInfo | str | tuple | None) = None;
}

obj ParamInfo(VarInfo) {}

obj FieldInfo(VarInfo) {}

obj EnumInfo(Info) {
    has members: list[FieldInfo];
}

obj ClassInfo(Info) {
    has fields: list[FieldInfo],
        base_classes: list[ClassInfo],
        methods: list[MethodInfo];

    def postinit -> object;
}

obj FunctionInfo(Info) {
    has params: (list[ParamInfo] | None) = None,
        return_type: (str | ClassInfo | tuple | None) = None,
        tools: (list[MethodInfo] | None) = None,
        by_call: bool = False,
        # Per-call-site dataflow context, populated by the dataflow pass.
        call_sites: (list[CallSiteFlowInfo] | None) = None;

    def postinit -> object;
}

obj MethodInfo(FunctionInfo) {
    has parent_class: (ClassInfo | None) = None;
}


"""Where a value flowing into a `by llm` argument originally came from."""
obj ArgOriginInfo {
    enum OriginType: str {
        UserInput = "user_input",        # runtime input (input(), CLI args, request payload)
        WalkerField = "walker_field",    # `has` field on a walker
        NodeField = "node_field",        # `has` field on a node (data read from the graph)
        EdgeField = "edge_field",        # `has` field on an edge
        ObjectField = "object_field",    # field on a plain obj/class instance
        GlobalVar = "global_var",        # module-level global
        FunctionParam = "function_param",# parameter of the enclosing function/ability
        LocalVar = "local_var",          # locally computed value
        GraphRef = "graph_ref",          # graph reference ([-->], `here`, `self`)
        Literal = "literal",             # constant literal in source
        LLMOutput = "llm_output",        # result of an upstream `by llm` call
        CallResult = "call_result",      # return value of a non-LLM call
        Unknown = "unknown"
    }

    has origin_type: OriginType = OriginType.Unknown,
        # The variable/field the value originates from, when resolvable.
        origin_var: (VarInfo | None) = None,
        # Scope that defines the origin (enclosing function or archetype name).
        origin_scope: (FunctionInfo | ClassInfo | str | None) = None,
        # Source location of the defining statement, "module:line".
        origin_location: (str | None) = None,
        # For LLMOutput origins: the producing call and its mtir_map scope key.
        producer_llm_call: (FunctionInfo | None) = None,
        producer_llm_scope: (str | None) = None;
}

"""Dataflow into a single argument of one `by llm` call site."""
obj ArgFlowInfo {
    has param_info: ParamInfo,
        # Resolved origins of the value, one per dataflow path reaching the arg.
        origins: list[ArgOriginInfo] = [],
        source_vars: list[VarInfo] = [],
        source_code_snippet: list[str] = [],
        # Upstream LLM calls whose output feeds this argument.
        upstream_llm_calls: list[FunctionInfo] = [],
        # mtir_map scope keys of the upstream calls.
        upstream_llm_scopes: list[str] = [];
}

"""Dataflow context surrounding one `by llm` call site."""
obj CallSiteFlowInfo {
    has call_location: str,  # location of this call site, "module:line"
        caller_scope: (FunctionInfo | str | None) = None,
        arg_flows: list[ArgFlowInfo] = [],
        result_target: (VarInfo | None) = None,
        result_sinks: list[str] = [],
        # Downstream LLM calls that consume this call's output.
        downstream_llm_calls: list[FunctionInfo] = [],
        # mtir_map scope keys of the downstream calls (see upstream_llm_scopes).
        downstream_llm_scopes: list[str] = [],
        # `visit ... by llm(...)` router form only.
        intent: str = "",
        select_targets: str = "",
        # Position in the topologically-ordered LLM pipeline (0 = unknown).
        stage: int = 0,
        stage_total: int = 0;
}

def mk_list(inner: object) -> tuple {
    return ('list', inner);
}

def mk_dict(key: object, val: object) -> tuple {
    return ('dict', key, val);
}

def mk_tuple(*types: object) -> tuple {
    return (('tuple', ) + `tuple(types));
}


def type_to_str(t: object) -> str {
    if (t is None) {
        return 'None';
    }
    if isinstance(t, str) {
        return t;
    }
    try {
        import from dataclasses { is_dataclass }
        if (is_dataclass(t) and t?.name) {
            return t.name;
        }
    } except Exception {
        ;
    }
    if isinstance(t, `tuple) {
        head = t[0];
        if (head == 'list') {
            return f"list[{type_to_str(t[1])}]";
        }
        if (head == 'dict') {
            return f"dict[{type_to_str(t[1])},{type_to_str(t[2])}]";
        }
        if (head == 'tuple') {
            return 'tuple[' + ','.join(type_to_str(x) for x in t[1:]) + ']';
        }
        if (head == 'union') {
            return '|'.join(type_to_str(x) for x in t[1:]);
        }
        return (head + '[' + ','.join(type_to_str(x) for x in t[1:]) + ']');
    }
    return str(t);
}

def fetch_mtir(func: Callable) -> Info | None {
    import sys;
    import from pathlib { Path }
    import from jaclang.jac0core.runtime { JacRuntime }
    module_name = None;
    try {
        module_name = getattr(func, "__module__");
    } except AttributeError {
        module_name = None;
    }

    if module_name and module_name == "__main__" {
        main_mod = sys.modules.get("__main__");
        main_file = main_mod?.__file__ if main_mod else None;
        if main_file {
            stem = Path(main_file).stem;

            if stem.endswith(".impl") {
                stem = stem[:-5];
            } elif stem.endswith(".cl") or stem.endswith(".sv") {
                stem = stem[:-3];
            }
            module = stem;
        } else {
            module = Path(sys.argv[0]).stem if sys.argv and sys.argv[0] else "__main__";
        }
    } elif module_name {
        module = module_name;
    } else {
        module = "__main__";
    }

    try {
        qualname = func.__qualname__;
        current_scope = ".".join([module, qualname]);
        return JacRuntime.get_mtir_from_map(current_scope);
    } except (KeyError, AttributeError) {
        return None;
    }
}
