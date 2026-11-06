Olly should not tokenize inside the string "42 43", and thus should raise [Failure("int_of_string")]:
  $ olly trace out.json -- ../run_exit.exe "42 43"
  Fatal error: exception Failure("int_of_string")
  olly: Child exited with code 2
  [124]

Same but without -- :
  $ olly trace out.json -- ../run_exit.exe "42 43"
  Fatal error: exception Failure("int_of_string")
  olly: Child exited with code 2
  [124]
