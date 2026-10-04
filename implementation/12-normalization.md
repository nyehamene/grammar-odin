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

## The normal form

`normalize_rule` factors a body: every alternative in the tree becomes the
productions its branches share at the start, the productions they do not share, and
the productions they share at the end.

```
use = p a q
    | p b q
    ;
```

gives a head of `p`, a body of `a` and `b`, and a tail of `q`.

A head is taken as far as it goes, so a branch it runs out of leaves an empty middle
rather than a shorter head: `a b | a b c` has a head of `a b` and a body of nothing
and `c`. The empty middle is the point at which a branch is matched by the head and
the tail alone.

An alternative is factored wherever one is written, including inside a group, a
repetition, an optional or a tag, since that is where a choice is written.

Under two distinct branches left, there is nothing to share, so `head` and `tail` are
absent and `body` holds the single branch. That covers both a rule with no `|` at all
and a rule whose branches were all the same.

### What the form preserves

The normal form preserves the language a rule matches. It does not preserve how that
language was written:

- **The number of alternatives.** Only one branch is ever reachable, so a branch equal
  to one already kept is dead and dropping it cannot change what the rule matches.
  `a | a | b` becomes a body of two branches. Branches that overlap without being
  equal are both kept, because whether the later one is reachable at all depends on
  whether a matcher backtracks into it after an earlier branch matched, which nothing
  here decides.
- **Tags**, unless the policy keeps them. See below.

### Tags

A tag names a production for a consumer that reads the grammar rather than describing
its shape, so the default drops it. `Tag_Policy` decides:

| policy | tags count for equality | tags in the result | on two branches that tag one production differently |
|---|---|---|---|
| `.Strip` (default) | no | dropped | factored as far as it goes; one tag is lost, quietly |
| `.Block` | no | dropped | factored as far as it goes; the loss is reported in `Normalize_Options.conflicts` |
| `.Keep` | yes | kept | not common, so the common prefix stops before them and nothing is lost |

`.Block` exists for a caller that cannot afford a silent loss but does not want to
give up the extra factoring.

There is no policy that factors a pair of branches tagged `name="x"` and `name="y"`
over the same production and keeps both tags, because factoring that production is
exactly where one tag has to go.

A tag annotates the whole of the branch it closes, so it can never be a shared prefix.
In

```
use = p a `name="x"`
    | p a `name="y"`
    ;
```

both branches are a single tagged production, so under `.Keep` they are equal and
collapse to one.

### The result tree

A normalized production is one of four things:

- **absent**, which is how an absent head or tail and an empty middle are written;
- a **production** standing for itself, for a leaf and for a call, since a call only
  survives an expansion that did not finish;
- a **factored alternative**, holding a head, a list of middles and a tail;
- a **grouped production**, holding normalized elements, for a sequence, a group, an
  optional, a repetition or a tagged production.

One grouped shape covers all five of those rather than adding five node types. The
tree is a parallel type rather than a variant of `Production`, which keeps the
checker's and the language server's switches over `Production` as they are: none of
them has a meaningful answer for a normalized node, since nothing consumes one yet.

### Ownership

Normalization takes the tree expansion produced over, as `expand_production` does.
Nodes are moved rather than copied, so one branch array is split three ways: what
becomes the shared head, what becomes each middle, and what becomes the shared tail.
The productions of a duplicate head or tail in a branch that is not the first are
freed rather than left behind. The caller frees one tree with
`destroy_normalized_rule`.

## Not settled

Nothing reads a normal form yet. `cmd/fmt` lays a source out from its tokens, so the
formatter cannot produce one, and `ast/printer.odin` is a debug tree. The normal form
is what a parser or matcher generator would be built from, and that consumer is what
would settle whether the three parts are the right split.

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
- [x] `ast`: the normal form, a common head and tail factored out of every
      alternative in the tree
- [x] `ast`: a duplicate branch dropped, an overlapping one kept
- [x] `ast`: three tag policies, stripping by default
- [ ] `check`: report a rule that takes part in a cycle of calls
- [ ] `grammar.txt`: parameters and calls
