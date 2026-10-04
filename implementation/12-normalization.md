# Normalization

Reduce a rule body that calls other rules to a body that names none of them.

## Expansion

`expand_rule` replaces every call in a rule body with the body of the rule the call
names, with the call's arguments substituted for the callee's parameters.

```
item   x  = x { x };
wrap   x y = <item x> y;
use      = <wrap "p" "q"> "z";
```

`use` expands to the equivalent of

```
use = "p" { "p" } "q" "z";
```

A call anywhere in a body is expanded, not only one standing on its own, and a
callee body that comes out as a sequence is spliced into the body that called it
rather than nested inside it, so a sequence never nests inside another. That is the
invariant the parser keeps with `unpack_sequence`, and an expansion that broke it
would hand the rest of the tool a shape it cannot produce.

An alternative is the exception: its elements are whole branches, so a callee body
that comes out as a sequence stays one branch and does not join the alternatives
beside it. `choice = <pair "a" "b"> | "c";` expands to `( "a" "b" ) | "c"`, not to
`"a" | "b" | "c"`.

### What a use of a parameter is

A parameter is substituted wherever it is a reference: as a production, as a call
argument, and as the receiver of a member access. The member name itself is not a
reference, so `ns.Rule` never has its `Rule` substituted, while the `ns` in front of
it may be a parameter:

```
p ns = <ns.Rule "a">;
```

A parameter in the callee position of a bare call is left alone, since the callee of
a call names a rule and a parameter there is a mistake the checker already reports.

### Calls that cannot be expanded

`expand_rule` also reports whether every call in the body was expanded. A call is
left in place, and reported, when

1. the scope does not declare the rule it names, or
2. the rule it names is in another namespace. A scope covers one namespace, so a
   qualified callee such as `<Z.Rule>` is not in it. Resolving one means holding a
   scope per namespace, which is not built yet.
3. the chain of calls is deeper than `MAX_EXPANSION_DEPTH`. Rules that call each
   other in a cycle never run out of calls, so the bound is what makes expansion
   terminate. The bound is a stop, not a diagnosis: a rule that hits it has a shape
   the checker should reject, since the checker is what tells a user their grammar
   is recursive.

The call is left in the body rather than dropped, so the caller can point at it.

A call that passes the wrong number of arguments is an error the checker reports
before normalization runs, so expansion pairs the arguments off as far as they go
and a parameter left over keeps its own name in the body.

## Ownership

`expand_production` takes its argument over: the result is built from what the
argument held, whatever the argument owned is freed along the way, and the result
belongs to the caller, who frees it with `destroy_expr`. `expand_rule` returns a
rule that owns its parameter list and its body outright.

This is what lets one rule be expanded more than once. Expansion substitutes into a
body, so a rule expanded in place would leave the scope holding a body already
rewritten for the first call site, and a second call site of the same rule would
then expand the wrong thing:

```
item    x = x { x };
first      = <item "a">;
second     = <item "b">;
```

`first` expands to `"a" { "a" }` and `second` to `"b" { "b" }`, and neither disturbs
`item`. The scope is therefore read-only as far as expansion is concerned, which is
also what lets a language server expand on every keystroke without accumulating
state.

## Not settled

`Normalized_Rule` is the shape a normalized body is meant to take, and it is
undecided. Expansion is the prerequisite: it is what a normal form is computed from,
and it is useful on its own for a rule that has to be read without following calls.
The open question is what the three parts are, and whether the split is per rule
after expansion or a flattening of nested alternatives.

`grammar.txt` still describes a rule as `ident "=" production ";"` with no
parameters, and does not describe `<...>` calls at all, so the surface this works
over is not written down yet either.

## Checklist

- [x] `ast`: expansion of a call anywhere in a body, with sequences spliced rather
      than nested
- [x] `ast`: a parameter substituted as a production, as a call argument, and as a
      receiver
- [x] `ast`: an expanded rule owns its body, and the scope is left untouched
- [x] `ast`: an unresolvable, cross-namespace or cyclic call reported instead of
      expanded
- [ ] `ast`: the normal form itself, `Normalized_Rule`
- [ ] `check`: report a rule that takes part in a cycle of calls
- [ ] `grammar.txt`: parameters and calls
