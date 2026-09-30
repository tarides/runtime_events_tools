The runtime events ring buffer is mapped into the traced process, so its
resident pages are charged to that process's RSS. run_alloc.exe keeps a live
set of a few kB but writes tens of MB of events, so it fills whatever ring it
is given and an unadjusted peak RSS grows with the ring rather than reporting
the program's own footprint.

So run it twice, once with the default ring and once with one 16x larger.
--log-wsize is per domain while the ring file is sized for the maximum domain
count, so 20 is about as far as this can go: 21 already asks for ~2GB and the
child fails to create it. (OCAMLRUNPARAM's d=, which would cap the domain
count, does not exist before OCaml 5.5.)

  $ olly gc-stats --json -o small.json ../run_alloc.exe 2> small.err || cat small.err
  $ olly gc-stats --json --log-wsize=20 -o large.json ../run_alloc.exe 2> large.err || cat large.err

  $ small=$(sed -n 's/.*"max_rss_kb": *\([0-9]*\).*/\1/p' small.json)
  $ large=$(sed -n 's/.*"max_rss_kb": *\([0-9]*\).*/\1/p' large.json)
  $ excluded=$(sed -n 's/.*"max_rss_excludes_ring": *\([a-z]*\).*/\1/p' large.json)

Where the ring's pages can be attributed to it, the reported peak must not
grow with the ring; leaving the ring in adds ~7.5MB at this size. Where they
cannot, olly says so and there is nothing to check.

  $ growth=$(( ${large:-0} - ${small:-0} ))
  $ if [ "$excluded" = false ] || [ "$growth" -lt 2000 ]; then
  >   echo ok
  > else
  >   echo "max RSS grew by ${growth}kB with a 16x larger ring"
  > fi
  ok
