external get_rss_kb : int -> int = "olly_get_rss_kb"

type t = { mutable max_rss_kb : int }

let create () = { max_rss_kb = 0 }

let sample t pid =
  let rss = get_rss_kb pid in
  if rss > t.max_rss_kb then t.max_rss_kb <- rss

let max_rss_kb t = t.max_rss_kb
