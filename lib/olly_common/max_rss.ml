type t = { mutable max_rss_kb : int }

let create () = { max_rss_kb = 0 }
let set t kb = if kb > t.max_rss_kb then t.max_rss_kb <- kb
let max_rss_kb t = t.max_rss_kb
