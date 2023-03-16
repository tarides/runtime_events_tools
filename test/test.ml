open Runtime_events

type User.tag += Custom

let ev = User.register "fib" Custom Type.span

let rec fib b =
  match b with
  | 0 -> 0
  | 1 -> 1
  | b ->
    User.write ev Begin;
    Unix.sleepf 0.0001;
    let v1 = fib (b-1) in
    Unix.sleepf 0.00005;
    let v2 = fib (b-2) in
    User.write ev End;
    v1 + v2

let _ = fib 5
