# Used by "mix format"
protocol_macros = [
  initial: 1,
  role: 1,
  track: 3,
  state: 2,
  state: 3,
  anystate: 1,
  on: 2,
  cast: 1,
  property: 2,
  # Accord.Protocol.Block (inside `on ... do` blocks)
  reply: 1,
  goto: 1,
  guard: 1,
  update: 1,
  branch: 2,
  # Accord.Protocol.Property (inside `property ... do` blocks)
  invariant: 1,
  invariant: 2,
  action: 1,
  liveness: 2,
  correspondence: 2,
  bounded: 2,
  ordered: 2,
  precedence: 2,
  reachable: 1,
  forbidden: 1
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: protocol_macros,
  export: [locals_without_parens: protocol_macros]
]
