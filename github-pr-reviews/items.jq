# Shapes `gh api graphql --paginate` output into pastor lines. The input is
# slurped: an array of pages, each holding a page of open pull requests with
# their reviews and review threads. Every review submitted since the cursor
# moves it, whoever wrote it and whether or not it makes an item, so a run
# never looks at the same reviews twice. The exception is a pull request
# whose nested lists were cut short: see $held below.
include "branch" {search: "./"};

def location: .path + (if (.line // .originalLine) then ":\(.line // .originalLine)" else "" end);

# What of a pull request's nested lists was not read, if anything.
def truncated:
  [ (if .reviews.pageInfo.hasNextPage then "reviews" else empty end),
    (if .reviewThreads.pageInfo.hasNextPage then "review threads" else empty end),
    (if any(.reviewThreads.nodes[]; .comments.pageInfo.hasNextPage) then "thread comments" else empty end) ];

[.[].data.repository.pullRequests.nodes[] | . + {truncated: truncated}] as $prs
| [ $prs[] as $pr
    | $pr.reviews.nodes[]
    # A pending review has no submittedAt; it is not written yet.
    | select(.submittedAt != null and .submittedAt >= $since)
    | {pr: $pr, review: .} ]
| sort_by(.review.submittedAt) as $new
# Moving the cursor past a cut-short pull request would lose what was not
# read. Missing reviews come after the ones read, at an unknown time, so they
# hold the cursor where it was; missing threads or comments may belong to
# any of its new reviews, so they hold it at the first one.
| [ $prs[] | select(.truncated | length > 0) | . as $pr
    | if .truncated | index("reviews") then $since
      else ([$new[] | select(.pr.number == $pr.number) | .review.submittedAt] | min)
      end
    | values ] as $held
| [ $new[]
    | select(.pr.truncated == [])
    | select(.pr.headRefName | safe_branch)
    | select((.review.author.login // "") | test($reviewer; "i"))
    | .review as $r
    # A thread belongs to the review that opened it, but replies in it come
    # from other reviews: keep only this review's comments.
    | [ .pr.reviewThreads.nodes[]
        | select(.isResolved | not)
        | .comments.nodes[]
        | select(.pullRequestReview.fullDatabaseId == $r.fullDatabaseId) ] as $open
    | select(($open | length) > 0 or ($only_with_findings | not))
    | {
        type: "item",
        key: ($r.fullDatabaseId | tostring),
        pr: .pr.number,
        title: .pr.title,
        branch: .pr.headRefName,
        head: .pr.headRefOid,
        review_url: $r.url,
        body: ($open | map("## \(.fullDatabaseId)\n\(location)\n\(.body)") | join("\n\n"))
      } ]
| {
    type: "log",
    level: "info",
    message: "\(length) reviews by \($reviewer) on \($prs | length) open pull requests in \($repo), submitted since \($since)"
  },
  ($prs[]
    | select(.truncated | length > 0)
    | {type: "log", level: "warn", message: "pull request #\(.number) has more \(.truncated | join(" and ")) than one query reads; it makes no items and holds the cursor until it closes"}),
  ($prs[]
    | select(.headRefName | safe_branch | not)
    | {type: "log", level: "warn", message: "pull request #\(.number) has head branch \(.headRefName | tojson), which is not shell-safe; its reviews make no items"}),
  .[],
  # The newest review seen, unless a cut-short pull request holds it back;
  # the next run looks from here on.
  (if ($new | length) > 0 then {type: "cursor", value: ([$new[-1].review.submittedAt] + $held | min)} else empty end)
