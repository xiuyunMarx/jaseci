import re;
import from pathlib { Path }
import jaclang.jac0core.unitree as uni;
import from jaclang.jac0core.constant { Tokens as Tok }
import from jaclang.jac0core.passes { UniPass }
import from jaclang.jac0core.mtp {
    ArgFlowInfo,
    ArgOriginInfo,
    CallSiteFlowInfo,
    FunctionInfo,
    ParamInfo,
    VarInfo
}

# Fixpoint iteration cap; the env is monotone so this is a safety net,
# not a tuning knob (semstr_deduct converges in <5 rounds on its corpus).
glob MAX_FIXPOINT_ROUNDS: int = 20,
     MAX_SNIPPETS_PER_KEY: int = 3,
     MAX_SNIPPETS_PER_ARG: int = 4,
     MAX_SNIPPET_LEN: int = 160;

glob IDENT_RE: any = re.compile(r"[A-Za-z_][A-Za-z0-9_]*");


"""Normalize token-spaced unparse() text into readable source."""
def _clean_snippet(text: str) -> str {
    text = re.sub(r"\s+", " ", text).strip();
    text = text.replace(" . ", ".").replace(" ( ", "(").replace(" (", "(");
    text = text.replace("( ", "(").replace(" )", ")").replace(" ;", ";");
    text = text.replace(" ,", ",").replace(" [", "[").replace("[ ", "[");
    return text.replace(" ]", "]");
}

# names whose reads carry no user-data provenance
glob BUILTIN_NAMES: list[str] = [
         'print', 'input', 'len', 'str', 'int', 'float', 'bool', 'list',
         'dict', 'set', 'tuple', 'range', 'enumerate', 'zip', 'sorted',
         'type', 'isinstance', 'join', 'strip', 'lower', 'upper', 'format',
         'abs', 'min', 'max', 'sum', 'dbg'
     ];


impl ByLLMDataflowPass.postinit -> None {
    super.postinit();
}

impl ByLLMDataflowPass.transform(ir_in: uni.Module) -> uni.Module {
    self._env = {};
    self._sites = {};
    self._site_callee_scope = {};
    self._site_callee_info = {};
    self._assign_snippets = {};
    self._type_names = [];
    self._genai_by_name = {};
    for arch in UniPass.get_all_sub_nodes(ir_in, uni.Archetype) {
        self._type_names.append(arch.name.value);
    }
    for en in UniPass.get_all_sub_nodes(ir_in, uni.Enum) {
        self._type_names.append(en.name.value);
    }
    # index genai abilities by bare name for method-call fallback matching
    mtir_map = getattr(self.prog, "mtir_map", None);
    for nd in UniPass.get_all_sub_nodes(ir_in, uni.Ability) {
        if not nd.is_genai_ability {
            continue;
        }
        scope = self._get_scope_str(nd);
        info = mtir_map.get(scope) if mtir_map is not None else None;
        entries = self._genai_by_name.get(nd.scope_name, []);
        entries.append((scope, info));
        self._genai_by_name[nd.scope_name] = entries;
    }
    # Fixpoint: abilities execute repeatedly at runtime (walkers revisit
    # nodes, loops), so re-run the walk until the environment stops growing.
    # All updates are unions, so total origin count is a valid fixpoint test.
    for round_num in range(MAX_FIXPOINT_ROUNDS) {
        before = self._env_size();
        self._one_pass(ir_in);
        if self._env_size() == before {
            break;
        }
    }
    self._finalize();
    return ir_in;
}

impl ByLLMDataflowPass._env_size -> int {
    total = 0;
    for origins in self._env.values() {
        total += len(origins);
    }
    return total;
}

impl ByLLMDataflowPass._one_pass(ir_in: uni.Module) -> None {
    for nd in UniPass.get_all_sub_nodes(ir_in, uni.Ability) {
        # genai abilities have the `by` expr as body — nothing to walk
        if nd.is_genai_ability {
            continue;
        }
        self._walk_ability(nd);
    }
    # module-level `with entry` blocks
    module_scope = self._get_scope_str(ir_in);
    for mc in UniPass.get_all_sub_nodes(ir_in, uni.ModuleCode) {
        self._walker = "";
        self._here_type = "";
        self._scope = module_scope;
        self._local_prefix = f"{module_scope}:";
        self._walk_stmts(list(mc.body));
    }
}

impl ByLLMDataflowPass._walk_ability(nd: uni.Ability) -> None {
    body = nd.body;
    if not isinstance(body, list) or not body {
        return;
    }
    # -- set per-ability context --
    owner = None;
    parent = nd.parent;
    while parent is not None {
        if isinstance(parent, uni.Archetype) {
            owner = parent;
            break;
        }
        parent = parent.parent;
    }
    self._walker = owner.name.value if owner else "";
    self._scope = self._get_scope_str(nd);
    # scope-qualified so same-named abilities in different modules/walkers
    # don't share locals
    self._local_prefix = f"{self._scope}:";
    # `can x with NodeType entry` — `here` is NodeType inside this ability
    self._here_type = self._walker;
    sig = nd.signature;
    if isinstance(sig, uni.EventSignature) {
        tag = sig.arch_tag_info;
        if tag is not None {
            self._here_type = tag.unparse().replace(" ", "");
        }
    }
    # seed ability params as function_param origins so param-derived
    # arguments resolve instead of leaking as unresolved locals
    if isinstance(sig, uni.FuncSignature) {
        all_params: list = [];
        if sig.posonly_params {
            all_params.extend(sig.posonly_params);
        }
        if sig.params {
            all_params.extend(sig.params);
        }
        for pv in all_params {
            pname = pv.name.value;
            key = f"{self._local_prefix}{pname}";
            sym = getattr(pv, "sym", None);
            sem = getattr(sym, "semstr", "") if sym else "";
            origin = ArgOriginInfo(
                origin_type=ArgOriginInfo.OriginType.FunctionParam,
                origin_var=VarInfo(name=pname, semstr=sem if sem else None),
                origin_scope=self._scope,
            );
            merged = self._env.get(key, {});
            merged[self._origin_key(origin)] = origin;
            self._env[key] = merged;
        }
    }
    self._walk_stmts(body);
}

impl ByLLMDataflowPass._walk_stmts(body: any) -> None {
    for st in body {
        if self.is_canceled() {
            return;
        }
        if isinstance(st, uni.Assignment) {
            srcs = self._eval_expr(st.value);
            snippet = _clean_snippet(st.unparse())[:MAX_SNIPPET_LEN];
            for tgt in st.target {
                key = self._qualify(tgt.unparse());
                if key is None {
                    continue;
                }
                # union (may-analysis): keeps the fixpoint monotone, and
                # `=` inside loops/branches is a may-assignment anyway
                merged = self._env.get(key, {});
                merged.update(srcs);
                self._env[key] = merged;
                snippets = self._assign_snippets.get(key, []);
                if snippet not in snippets
                and len(snippets) < MAX_SNIPPETS_PER_KEY {
                    snippets.append(snippet);
                    self._assign_snippets[key] = snippets;
                }
            }
        } elif isinstance(st, uni.VisitStmt) {
            # registers `visit ... by llm(...)` routers found in the target
            self._eval_expr(st.target);
        } elif isinstance(st, uni.ExprStmt) {
            self._eval_expr(st.expr);
        } elif isinstance(st, uni.ReturnStmt) {
            self._eval_expr(st.expr);
        } elif (
            isinstance(st, uni.IfStmt)
            or isinstance(st, uni.WhileStmt)
            or isinstance(st, uni.IterForStmt)
            or isinstance(st, uni.InForStmt)
            or isinstance(st, uni.ElseIf)
            or isinstance(st, uni.TryStmt)
        ) {
            cond = getattr(st, "condition", None);
            if cond is None {
                cond = getattr(st, "iter", None);
            }
            if cond is not None {
                self._eval_expr(cond);
            }
            # `for x in coll` binds the loop var to the iterable's origins
            if isinstance(st, uni.InForStmt) {
                it_srcs = self._eval_expr(getattr(st, "collection", None));
                tgt = getattr(st, "target", None);
                key = self._qualify(tgt.unparse()) if tgt is not None else None;
                if key is not None {
                    merged = self._env.get(key, {});
                    merged.update(it_srcs);
                    self._env[key] = merged;
                }
            }
            self._walk_stmts(getattr(st, "body", []) or []);
            else_body = getattr(st, "else_body", None);
            if else_body is not None {
                self._walk_stmts(getattr(else_body, "body", []) or []);
            }
        } elif isinstance(st, uni.ElseStmt) {
            self._walk_stmts(getattr(st, "body", []) or []);
        }
        # other statement kinds carry no dataflow we track
    }
}

impl ByLLMDataflowPass._eval_expr(nd: any) -> dict[(str, ArgOriginInfo)] {
    if nd is None {
        return {};
    }
    # Name/SpecialVarRef are Tokens too, so they must be checked first
    if isinstance(nd, uni.Name) {
        key = self._qualify(nd.value);
        return self._lookup(key) if key is not None else {};
    }
    if isinstance(nd, uni.SpecialVarRef) {
        v = nd.unparse().strip();
        if v == "here" {
            label = f"node:{self._here_type}";
        } elif v == "self" {
            label = f"walker:{self._walker}";
        } else {
            label = v;
        }
        origin = ArgOriginInfo(
            origin_type=ArgOriginInfo.OriginType.GraphRef,
            origin_scope=label,
        );
        return {self._origin_key(origin): origin};
    }
    if isinstance(nd, uni.Token) {
        # literal leaves (String/Int/Float/Bool/Null/ops) carry no provenance
        return {};
    }
    if isinstance(nd, uni.FuncCall) {
        return self._eval_call(nd);
    }
    if (
        isinstance(nd, uni.BinaryExpr)
        # op can be a ConnectOp/DisconnectOp node rather than a token
        and (getattr(nd.op, "name", None) == Tok.KW_BY)
    ) {
        # `expr by llm(...)`: inline call or visit router target
        right = nd.right;
        if isinstance(right, uni.FuncCall) {
            return self._eval_call(right, by_target=nd.left);
        }
        # `expr by <model>` without a call form
        return self._eval_expr(nd.left);
    }
    if isinstance(nd, uni.AtomTrailer) {
        has_call = False;
        for k in nd.kid {
            if isinstance(k, uni.FuncCall) {
                has_call = True;
                break;
            }
        }
        if has_call {
            # method chains: origins = base object + call args
            srcs = self._eval_expr(nd.kid[0]);
            for k in nd.kid[1:] {
                if isinstance(k, uni.FuncCall) or isinstance(k, uni.IndexSlice) {
                    srcs.update(self._eval_expr(k));
                }
            }
            return srcs;
        }
        key = self._qualify(nd.unparse());
        return self._lookup(key) if key is not None else {};
    }
    compr = getattr(nd, "compr", None);
    if compr {
        # bind each loop variable to its iterable's origins, so the output
        # expression resolves through it instead of leaking an unresolved
        # local
        for ic in compr {
            it_srcs = self._eval_expr(ic.collection);
            key = self._qualify(ic.target.unparse());
            if key is not None {
                merged = self._env.get(key, {});
                merged.update(it_srcs);
                self._env[key] = merged;
            }
            cond = getattr(ic, "conditional", None);
            conds = cond if isinstance(cond, list) else ([cond] if cond else []);
            for c in conds {
                self._eval_expr(c);
            }
        }
        body = getattr(nd, "out_expr", None) or getattr(nd, "kv_pair", None);
        return self._eval_expr(body);
    }
    if isinstance(nd, uni.EdgeOpRef) or isinstance(nd, uni.EdgeRefTrailer) {
        origin = ArgOriginInfo(
            origin_type=ArgOriginInfo.OriginType.GraphRef,
            origin_scope=nd.unparse().replace(" ", ""),
        );
        return {self._origin_key(origin): origin};
    }
    # generic: fold children (covers FString, containers, BinaryExpr,
    # IfElseExpr, AtomUnit, IndexSlice, KVPair, ...)
    srcs: dict[(str, ArgOriginInfo)] = {};
    for kid in getattr(nd, "kid", []) {
        srcs.update(self._eval_expr(kid));
    }
    return srcs;
}

impl ByLLMDataflowPass._eval_call(
    fc: uni.FuncCall, by_target: (uni.Expr | None) = None
) -> dict[(str, ArgOriginInfo)] {
    resolved = self._resolve_genai_callee(fc);
    if resolved is not None {
        (callee_scope, callee_info) = resolved;
        origin = self._register_call(fc, callee_scope, callee_info, by_target);
        return {self._origin_key(origin): origin};
    }
    if by_target is not None {
        # `<candidates> by llm(...)` router / inline-by form: the right side
        # is a model call, not a genai ability, so symbol resolution fails —
        # but the KW_BY operator itself marks this as an LLM call site.
        origin = self._register_call(fc, "", None, by_target);
        return {self._origin_key(origin): origin};
    }
    callee_txt = fc.target.unparse().replace(" ", "").replace("\n", "");
    callee = callee_txt.split(".")[-1].split("(")[0];
    if callee == "input" {
        prompt = fc.params[0].unparse().strip() if fc.params else "";
        origin = ArgOriginInfo(
            origin_type=ArgOriginInfo.OriginType.UserInput,
            origin_scope=f"input({prompt[:40]})",
            origin_location=(
                f"{self._get_scope_str(self.ir_in)}:{fc.loc.first_line}"
            ),
        );
        return {self._origin_key(origin): origin};
    }
    # ordinary call: origins = base object + all arguments, so chains
    # like input("You: ").strip() resolve structurally
    srcs = self._eval_expr(fc.target);
    for p in fc.params {
        srcs.update(
            self._eval_expr(p.value if isinstance(p, uni.KWPair) else p)
        );
    }
    return srcs;
}

impl ByLLMDataflowPass._qualify(text: str) -> str | None {
    text = text.replace(" ", "").replace("\n", "");
    m = IDENT_RE.match(text);
    if m is None {
        return None;
    }
    head = m.group(0);
    rest = text[m.end():];
    if head == "self" {
        f = IDENT_RE.match(rest[1:]) if rest.startswith(".") else None;
        return f"{self._walker}.{f.group(0)}" if f else None;
    }
    if head == "here" {
        f = IDENT_RE.match(rest[1:]) if rest.startswith(".") else None;
        return f"{self._here_type}.{f.group(0)}" if f else f"node:{self._here_type}";
    }
    if head in BUILTIN_NAMES or head in self._type_names {
        return None;
    }
    return f"{self._local_prefix}{head}";
}

impl ByLLMDataflowPass._origin_for_key(key: str) -> ArgOriginInfo {
    if key.startswith(self._local_prefix) {
        return ArgOriginInfo(
            origin_type=ArgOriginInfo.OriginType.LocalVar,
            origin_scope=key,
        );
    }
    if key.startswith("node:") or key.startswith("walker:") {
        return ArgOriginInfo(
            origin_type=ArgOriginInfo.OriginType.GraphRef,
            origin_scope=key,
        );
    }
    if "." in key {
        owner = key.split(".")[0];
        kind = ArgOriginInfo.OriginType.WalkerField
            if owner == self._walker
            else ArgOriginInfo.OriginType.NodeField;
        return ArgOriginInfo(
            origin_type=kind,
            origin_var=VarInfo(name=key.split(".")[-1], semstr=None),
            origin_scope=key,
        );
    }
    return ArgOriginInfo(
        origin_type=ArgOriginInfo.OriginType.Unknown, origin_scope=key
    );
}

impl ByLLMDataflowPass._lookup(key: str) -> dict[(str, ArgOriginInfo)] {
    found = self._env.get(key);
    if found is not None {
        return dict(found);
    }
    fallback = self._origin_for_key(key);
    return {self._origin_key(fallback): fallback};
}

impl ByLLMDataflowPass._origin_key(origin: ArgOriginInfo) -> str {
    var_name = origin.origin_var.name if origin.origin_var else "";
    scope = origin.origin_scope
        if isinstance(origin.origin_scope, str)
        else (origin.origin_scope.name if origin.origin_scope else "");
    return (
        f"{origin.origin_type.value}|{scope}|{var_name}"
        f"|{origin.origin_location or ''}|{origin.producer_llm_scope or ''}"
    );
}

impl ByLLMDataflowPass._toplevel_atoms(nd: any) -> list {
    found: list = [];
    stack: list = [nd];
    while stack {
        n = stack.pop();
        if isinstance(n, uni.BuiltinType) {
            continue;
        }
        if (
            isinstance(n, uni.AtomTrailer)
            or isinstance(n, uni.Name)
            or isinstance(n, uni.SpecialVarRef)
        ) {
            found.append(n);
            continue;
        }
        stack.extend(getattr(n, "kid", []));
    }
    return found;
}

impl ByLLMDataflowPass._source_vars_for(val: any) -> list[VarInfo] {
    src_vars: list[VarInfo] = [];
    seen: list[str] = [];
    for atom in self._toplevel_atoms(val) {
        key = self._qualify(atom.unparse());
        if key is None or key in seen {
            continue;
        }
        seen.append(key);
        # semstr of the referenced symbol (rightmost name for self.x/here.y)
        name_node = atom if isinstance(atom, uni.Name) else None;
        if isinstance(atom, uni.AtomTrailer) {
            for kid in atom.kid {
                if isinstance(kid, uni.Name) {
                    name_node = kid;
                }
            }
        }
        sym = getattr(name_node, "sym", None) if name_node is not None else None;
        sem = getattr(sym, "semstr", "") if sym else "";
        src_vars.append(VarInfo(name=key, semstr=sem if sem else None));
    }
    return src_vars;
}

impl ByLLMDataflowPass._resolve_genai_callee(fc: uni.FuncCall) -> tuple | None {
    # symbol-based resolution: find the rightmost Name of the call target
    # and check whether its declaration is a genai ability
    target = fc.target;
    name_node = None;
    if isinstance(target, uni.Name) {
        name_node = target;
    } elif isinstance(target, uni.AtomTrailer) {
        for kid in target.kid {
            if isinstance(kid, uni.Name) {
                name_node = kid;
            }
        }
    }
    if name_node is None {
        return None;
    }
    sym = name_node.sym;
    if sym is not None and sym.decl {
        decl = sym.decl.name_of;
        if not isinstance(decl, uni.Ability) or not decl.is_genai_ability {
            return None;
        }
        scope = self._get_scope_str(decl);
        info = None;
        mtir_map = getattr(self.prog, "mtir_map", None);
        if mtir_map is not None {
            info = mtir_map.get(scope);
        }
        return (scope, info);
    }
    # attribute access (here.f / self.f / obj.f): the symbol is unresolved
    # without type inference — fall back to the module's genai-ability name
    # index, but only on an unambiguous match
    candidates = self._genai_by_name.get(name_node.value, []);
    if len(candidates) == 1 {
        return candidates[0];
    }
    return None;
}

impl ByLLMDataflowPass._register_call(
    fc: uni.FuncCall,
    callee_scope: str,
    callee_info: (FunctionInfo | None),
    by_target: (uni.Expr | None)
) -> ArgOriginInfo {
    site_id = id(fc);
    site = self._sites.get(site_id);
    if site is None {
        module_scope = self._get_scope_str(self.ir_in);
        site = CallSiteFlowInfo(
            call_location=f"{module_scope}:{fc.loc.first_line}",
            caller_scope=self._scope,
        );
        self._sites[site_id] = site;
        self._site_callee_scope[site_id] = callee_scope;
        self._site_callee_info[site_id] = callee_info;
    } else {
        # fixpoint re-visit: refresh args with the richer environment
        # instead of appending duplicates
        site.arg_flows = [];
    }
    self._fill_args(fc, site, callee_info, by_target);
    return ArgOriginInfo(
        origin_type=ArgOriginInfo.OriginType.LLMOutput,
        origin_location=site.call_location,
        producer_llm_call=callee_info,
        producer_llm_scope=callee_scope,
    );
}

impl ByLLMDataflowPass._fill_args(
    fc: uni.FuncCall,
    site: CallSiteFlowInfo,
    callee_info: (FunctionInfo | None),
    by_target: (uni.Expr | None)
) -> None {
    params = list(callee_info.params) if (callee_info and callee_info.params) else [];
    pos = 0;
    for p in fc.params {
        if isinstance(p, uni.KWPair) {
            pname = p.key.unparse().strip() if p.key else "?";
            val = p.value;
            if by_target is not None and pname == "intent" {
                site.intent = val.unparse().strip().strip('"');
                continue;
            }
            if by_target is not None and pname == "select" {
                continue;
            }
            matched = None;
            for cand in params {
                if cand.name == pname {
                    matched = cand;
                    break;
                }
            }
        } else {
            val = p;
            matched = params[pos] if pos < len(params) else None;
            pos += 1;
        }
        site.arg_flows.append(self._make_arg_flow(matched, val));
    }
    if by_target is not None {
        # `visit <candidates> by llm(...)` router form: record the
        # candidate set as the first arg flow
        site.select_targets = _clean_snippet(by_target.unparse());
        cand = self._make_arg_flow(
            ParamInfo(name="candidates", semstr=None), by_target
        );
        site.arg_flows.insert(0, cand);
    }
}

impl ByLLMDataflowPass._make_arg_flow(
    matched: (ParamInfo | None), val: any
) -> ArgFlowInfo {
    origins = self._eval_expr(val);
    source_vars = self._source_vars_for(val);
    # expression text + reaching assignment statements ("constructed by")
    snippets: list[str] = [_clean_snippet(val.unparse())[:MAX_SNIPPET_LEN]];
    for sv in source_vars {
        for sn in self._assign_snippets.get(sv.name, []) {
            if sn not in snippets and len(snippets) < MAX_SNIPPETS_PER_ARG {
                snippets.append(sn);
            }
        }
    }
    upstream_calls: list = [];
    upstream_scopes: list[str] = [];
    for origin in origins.values() {
        if (
            origin.origin_type == ArgOriginInfo.OriginType.LLMOutput
            and origin.producer_llm_scope
            and origin.producer_llm_scope not in upstream_scopes
        ) {
            upstream_scopes.append(origin.producer_llm_scope);
            if origin.producer_llm_call is not None {
                upstream_calls.append(origin.producer_llm_call);
            }
        }
    }
    return ArgFlowInfo(
        param_info=matched or ParamInfo(name="?", semstr=None),
        origins=list(origins.values()),
        source_vars=source_vars,
        source_code_snippet=snippets,
        upstream_llm_calls=upstream_calls,
        upstream_llm_scopes=upstream_scopes,
    );
}

impl ByLLMDataflowPass._finalize -> None {
    # -- result sinks: every env key holding a given site's output --
    for (site_id, site) in self._sites.items() {
        for (key, origins) in self._env.items() {
            for origin in origins.values() {
                if (
                    origin.origin_type == ArgOriginInfo.OriginType.LLMOutput
                    and origin.origin_location == site.call_location
                    and key not in site.result_sinks
                ) {
                    site.result_sinks.append(key);
                }
            }
        }
    }
    # -- LLM -> LLM edges: producer's downstream = consumers of its output --
    site_by_location: dict[(str, CallSiteFlowInfo)] = {};
    for site in self._sites.values() {
        site_by_location[site.call_location] = site;
    }
    edge_pairs: list = [];
    for (site_id, site) in self._sites.items() {
        consumer_info = self._site_callee_info.get(site_id);
        consumer_scope = self._site_callee_scope.get(site_id, "");
        for arg_flow in site.arg_flows {
            for origin in arg_flow.origins {
                producer = site_by_location.get(origin.origin_location or "");
                if (
                    origin.origin_type != ArgOriginInfo.OriginType.LLMOutput
                    or producer is None
                    or producer is site
                ) {
                    continue;
                }
                pair = (producer.call_location, site.call_location);
                if pair not in edge_pairs {
                    edge_pairs.append(pair);
                }
                if consumer_scope
                and consumer_scope not in producer.downstream_llm_scopes {
                    producer.downstream_llm_scopes.append(consumer_scope);
                    if consumer_info is not None {
                        producer.downstream_llm_calls.append(consumer_info);
                    }
                }
            }
        }
    }
    # -- pipeline stages: Kahn's topological order over the edges --
    indeg: dict[(str, int)] = {};
    adj: dict[(str, list[str])] = {};
    for site in self._sites.values() {
        indeg[site.call_location] = 0;
        adj[site.call_location] = [];
    }
    for (prod_loc, cons_loc) in edge_pairs {
        adj[prod_loc].append(cons_loc);
        indeg[cons_loc] += 1;
    }
    order: list[str] = [];
    queue: list[str] = [loc for (loc, d) in indeg.items() if d == 0];
    while queue {
        loc = queue.pop(0);
        order.append(loc);
        for nxt in adj[loc] {
            indeg[nxt] -= 1;
            if indeg[nxt] == 0 {
                queue.append(nxt);
            }
        }
    }
    # cycles (e.g. a call feeding its own accumulator field): append the
    # rest in source order
    for loc in indeg.keys() {
        if loc not in order {
            order.append(loc);
        }
    }
    total = len(order);
    for (i, loc) in enumerate(order) {
        site_by_location[loc].stage = i + 1;
        site_by_location[loc].stage_total = total;
    }

    # -- attach each site to its callee's FunctionInfo in the MTIR map --
    for (site_id, site) in self._sites.items() {
        info = self._site_callee_info.get(site_id);
        if info is None {
            # router sites (no callee FunctionInfo) and cross-module callees:
            # the latter live in another module's mtir_map. TODO(phase 2):
            # record under a caller-module key and merge at import time
            # (meta_importer re-key hook).
            continue;
        }
        if info.call_sites is None {
            info.call_sites = [];
        }
        replaced = False;
        for (idx, existing) in enumerate(info.call_sites) {
            if existing.call_location == site.call_location {
                # recompile of the same module: refresh the stored site
                info.call_sites[idx] = site;
                replaced = True;
                break;
            }
        }
        if not replaced {
            info.call_sites.append(site);
        }
    }
}

impl ByLLMDataflowPass._get_scope_str(nd: uni.UniScopeNode) -> str {
    # same keying as MTIRGenPass._get_scope_str so scope keys match the
    # MTIR map. TODO: factor into a shared module-level helper.
    import from jaclang.jac0core.ext_registry { STEM_REKEY_SUFFIXES }

    if isinstance(nd, uni.Module) {
        mod_path = nd.loc.mod_path;
        if mod_path {
            stem = Path(mod_path).stem;
            for suf in STEM_REKEY_SUFFIXES {
                if stem.endswith(suf) {
                    stem = stem[:-len(suf)];
                    break;
                }
            }
            return stem;
        }
        return nd.scope_name;
    }
    self_name = nd.scope_name;
    if nd.parent_scope and isinstance(nd.parent_scope, uni.UniScopeNode) {
        return f"{self._get_scope_str(nd.parent_scope)}.{self_name}";
    }
    return self_name;
}
