import ast, operator
_ALLOWED_BIN = {ast.Add:operator.add, ast.Sub:operator.sub, ast.Mult:operator.mul, ast.Div:operator.truediv}
_ALLOWED_UN = {ast.UAdd:operator.pos, ast.USub:operator.neg}

def evaluate(expr: str, raw: float) -> float:
    """Evaluate a deliberately tiny arithmetic language. No calls, attributes, indexing or Python eval."""
    def ev(n):
        if isinstance(n, ast.Expression): return ev(n.body)
        if isinstance(n, ast.Constant) and isinstance(n.value,(int,float)): return n.value
        if isinstance(n, ast.Name) and n.id == 'raw': return raw
        if isinstance(n, ast.BinOp) and type(n.op) in _ALLOWED_BIN: return _ALLOWED_BIN[type(n.op)](ev(n.left),ev(n.right))
        if isinstance(n, ast.UnaryOp) and type(n.op) in _ALLOWED_UN: return _ALLOWED_UN[type(n.op)](ev(n.operand))
        raise ValueError("unsafe/unsupported formula")
    tree=ast.parse(expr, mode='eval')
    return float(ev(tree))

def evaluate_many(expr: str, raw_values):
    return [evaluate(expr,x) for x in raw_values]
