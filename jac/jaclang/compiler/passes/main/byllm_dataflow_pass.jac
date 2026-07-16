import jaclang.jac0core.unitree as uni;
import from jaclang.jac0core.mtp {
    ArgFlowInfo,
    ArgOriginInfo,
    CallSiteFlowInfo,
    FunctionInfo,
    ParamInfo,
    VarInfo
}
import from jaclang.jac0core.passes.transform { Transform }

obj ByLLMDataflowPass(Transform[uni.Module, uni.Module]) {
    has ir_in: uni.Module,
        prog: any,
        cancel_token: any = None;

    # -- analysis state, reset per transform() --
    # environment: qualified name -> {origin key -> origin} (dict-as-set,
    # keyed by _origin_key, so ArgOriginInfo needs no __hash__)
    has _env: dict[(str, dict[(str, ArgOriginInfo)])] = {},
        # id(FuncCall node) -> its CallSiteFlowInfo (one record per AST site;
        # fixpoint re-visits refresh args instead of duplicating)
        _sites: dict[(int, CallSiteFlowInfo)] = {},
        # id(FuncCall node) -> callee mtir_map scope key / FunctionInfo
        _site_callee_scope: dict[(int, str)] = {},
        _site_callee_info: dict[(int, object)] = {},
        # qualified key -> unparsed assignment statements ("constructed by")
        _assign_snippets: dict[(str, list[str])] = {},
        # genai ability name -> [(scope, FunctionInfo)] — name-based fallback
        # for method calls (here.f/self.f) whose attribute symbol is not
        # resolved without type inference
        _genai_by_name: dict[(str, list)] = {},
        # archetype/enum names declared in the module: constructor calls and
        # enum refs are types, not data variables
        _type_names: list[str] = [],
        # -- per-ability context, set by _walk_ability --
        _walker: str = "",        # enclosing archetype name (self.x owner)
        _here_type: str = "",     # node type of `with X entry` (here.y owner)
        _scope: str = "",         # enclosing ability scope string
        _local_prefix: str = "";  # "<scope>:" prefix for ability locals

    def postinit -> None;
    def transform(ir_in: uni.Module) -> uni.Module;

    # -- fixpoint driver --
    def _one_pass(ir_in: uni.Module) -> None;
    def _env_size -> int;

    # -- statement / expression walk --
    def _walk_ability(nd: uni.Ability) -> None;
    def _walk_stmts(body: any) -> None;
    # Deep origins of an expression; registers call sites found inside.
    def _eval_expr(nd: any) -> dict[(str, ArgOriginInfo)];
    def _eval_call(
        fc: uni.FuncCall, by_target: (uni.Expr | None) = None
    ) -> dict[(str, ArgOriginInfo)];

    # -- name resolution --
    # Map an atom's source text to a qualified env key (None -> skip).
    def _qualify(text: str) -> str | None;
    # Fallback origin for a key never assigned in the walk so far.
    def _origin_for_key(key: str) -> ArgOriginInfo;
    def _lookup(key: str) -> dict[(str, ArgOriginInfo)];
    # Stable dedup key for an origin (kind + name + producer location).
    def _origin_key(origin: ArgOriginInfo) -> str;
    # Direct variable references in an expression (surface reads).
    def _toplevel_atoms(nd: any) -> list;
    # Surface reads of an expression as VarInfo (with symbol semstrs).
    def _source_vars_for(val: any) -> list[VarInfo];

    # -- call-site registration --
    # Resolve a call target to a genai ability via its symbol; returns
    # (scope_key, FunctionInfo | None) or None when not a `by llm` callee.
    def _resolve_genai_callee(fc: uni.FuncCall) -> tuple | None;
    def _register_call(
        fc: uni.FuncCall,
        callee_scope: str,
        callee_info: (FunctionInfo | None),
        by_target: (uni.Expr | None)
    ) -> ArgOriginInfo;
    def _fill_args(
        fc: uni.FuncCall,
        site: CallSiteFlowInfo,
        callee_info: (FunctionInfo | None),
        by_target: (uni.Expr | None)
    ) -> None;
    # Build one ArgFlowInfo: origins, source vars, snippets, upstream calls.
    def _make_arg_flow(matched: (ParamInfo | None), val: any) -> ArgFlowInfo;

    # -- finalization: sinks, LLM->LLM edges, stage order, attach to MTIR --
    def _finalize -> None;
    def _get_scope_str(nd: uni.UniScopeNode) -> str;
}
