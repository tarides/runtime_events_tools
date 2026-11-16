Decoded trace from the fuchsia backend, driven directly with every kind of event olly emits:

  $ ../gen_fxt_trace.exe simple simple.fxt
  $ ../dump_fxt_trace.exe simple.fxt
  ticks per second: 1000000000
  10197 0/0 begin "sample_span_one"
  10518 0/0 begin "sample_span_two"
  10839 0/0 end "sample_span_two"
  11160 0/0 end "sample_span_one"
  11481 0/1 begin "sample_span_one"
  11802 0/1 begin "sample_span_two"
  12123 0/1 end "sample_span_two"
  12444 0/1 end "sample_span_one"
  12765 0/127 begin "sample_span_one"
  13086 0/127 begin "sample_span_two"
  13407 0/127 end "sample_span_two"
  13728 0/127 end "sample_span_one"
  14049 0/0 counter "sample_counter_one" v=0 counter_id=0
  14370 0/1 counter "sample_counter_one" v=42 counter_id=0
  14691 0/1 counter "sample_counter_two" v=2147483647 counter_id=0
  15012 0/1 counter "sample_counter_two" v=2147483648 counter_id=0
  15333 0/127 counter "sample_counter_three" v=1099511627776 counter_id=0
  15654 0/0 counter "custom_int" v=7 counter_id=0
  15975 0/1 instant "custom_unit"

Enough events to span several buffer flushes:

  $ ../gen_fxt_trace.exe long_repeat long_repeat.fxt
  $ ../dump_fxt_trace.exe long_repeat.fxt > long_repeat.txt
  $ awk 'NR % 5000 == 1' long_repeat.txt
  ticks per second: 1000000000
  1614876 0/2 counter "test_counter" v=1666 counter_id=0
  3219876 0/1 begin "test_span"
  4824876 0/3 end "test_span"
  6429876 0/2 counter "test_counter" v=6666 counter_id=0
  8034876 0/1 begin "test_span"
  9639876 0/3 end "test_span"
  11244876 0/2 counter "test_counter" v=11666 counter_id=0
  12849876 0/1 begin "test_span"
  14454876 0/3 end "test_span"
  16059876 0/2 counter "test_counter" v=16666 counter_id=0
  17664876 0/1 begin "test_span"
  19269876 0/3 end "test_span"
  20874876 0/2 counter "test_counter" v=21666 counter_id=0
  22479876 0/1 begin "test_span"
  24084876 0/3 end "test_span"
  25689876 0/2 counter "test_counter" v=26666 counter_id=0
  27294876 0/1 begin "test_span"
  28899876 0/3 end "test_span"
  30504876 0/2 counter "test_counter" v=31666 counter_id=0
  32109876 0/1 begin "test_span"
  33714876 0/3 end "test_span"
  35319876 0/2 counter "test_counter" v=36666 counter_id=0
  36924876 0/1 begin "test_span"
  38529876 0/3 end "test_span"
  40134876 0/2 counter "test_counter" v=41666 counter_id=0
  41739876 0/1 begin "test_span"
  43344876 0/3 end "test_span"
  44949876 0/2 counter "test_counter" v=46666 counter_id=0
  46554876 0/1 begin "test_span"
  48159876 0/3 end "test_span"
  49764876 0/2 counter "test_counter" v=51666 counter_id=0
  51369876 0/1 begin "test_span"
  52974876 0/3 end "test_span"
  54579876 0/2 counter "test_counter" v=56666 counter_id=0
  56184876 0/1 begin "test_span"
  57789876 0/3 end "test_span"
  $ tail -n +2 long_repeat.txt | cut -d' ' -f3,4 | sort | uniq -c | sed 's/^ *//'
  60000 begin "test_span"
  60000 counter "test_counter"
  60000 end "test_span"

Many names to exercise table allocation:

  $ ../gen_fxt_trace.exe many_names many_names.fxt
  $ ../dump_fxt_trace.exe many_names.fxt > many_names.txt
  $ awk 'NR % 5000 == 1' many_names.txt
  ticks per second: 1000000000
  1614876 0/0 counter "counter_4999" v=4999 counter_id=0
  3219876 0/0 counter "counter_9999" v=9999 counter_id=0
  4824876 0/0 counter "counter_14999" v=14999 counter_id=0
  6429876 0/0 counter "counter_19999" v=19999 counter_id=0
  8034876 0/0 counter "counter_24999" v=24999 counter_id=0
  9639876 0/0 counter "counter_29999" v=29999 counter_id=0
  11244876 0/0 counter "counter_34999" v=34999 counter_id=0
  12849876 0/0 counter "counter_39999" v=39999 counter_id=0
  14454876 0/0 counter "counter_44999" v=44999 counter_id=0
  16059876 0/0 counter "counter_49999" v=49999 counter_id=0
  17664876 0/0 counter "counter_54999" v=54999 counter_id=0
  19269876 0/0 counter "counter_59999" v=59999 counter_id=0
  20874876 0/0 counter "counter_64999" v=64999 counter_id=0
  22479876 0/0 counter "counter_69999" v=69999 counter_id=0
  24084876 0/0 counter "counter_74999" v=74999 counter_id=0
  25689876 0/0 counter "counter_79999" v=79999 counter_id=0
  27294876 0/0 counter "counter_84999" v=84999 counter_id=0
  28899876 0/0 counter "counter_89999" v=89999 counter_id=0
  30504876 0/0 counter "counter_94999" v=94999 counter_id=0
  32109876 0/0 counter "counter_99999" v=99999 counter_id=0
  33714876 0/0 counter "counter_104999" v=104999 counter_id=0
  35319876 0/0 counter "counter_109999" v=109999 counter_id=0
  36924876 0/0 counter "counter_114999" v=114999 counter_id=0
  38529876 0/0 counter "counter_119999" v=119999 counter_id=0
  40134876 0/0 counter "counter_124999" v=124999 counter_id=0
  $ tail -n +2 many_names.txt | cut -d' ' -f4 | sort -u | wc -l | tr -d ' '
  128001
