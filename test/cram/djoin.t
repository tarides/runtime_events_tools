Test for GC time during Domain.join:
  $ olly gc-stats --json -o test.json ../run_domain_gc.exe
  $ ../test_gc_no_outliers.exe test.json
 
