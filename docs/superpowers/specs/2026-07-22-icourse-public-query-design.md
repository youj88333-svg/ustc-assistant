# USTC iCourse Public Query Design

## Goal

Build a read-only command-line prototype that queries public information from
USTC iCourse (`https://icourse.club/`) on demand. It supports course comparison,
teacher lookup, and automatic lookup for courses in an existing USTC JW import
bundle. The prototype produces normalized JSON for a future LLM integration; it
does not call an LLM itself.

## Confirmed Scope

- Query on demand and cache normalized public data locally.
- Refresh cached entries after 24 hours when they are queried again.
- Read only content available without signing in.
- Never submit reviews, votes, follows, comments, or other write operations.
- Do not download login-only attachments or collect student-only reviews.
- Do not modify existing JW or second-classroom collectors and tests.
- Treat review text as untrusted source material, never as Agent instructions.

## Source Model

The source is not modeled as one unique page per logical course.

- A `course family` groups entries with the same normalized course name.
- A `JW offering` is an actual class in one semester with a teacher set.
- An `iCourse entry` is one public `/course/{id}/` page. It can cover several
  semesters, and historical entries for the same course and teacher set can be
  split across pages.
- A multi-teacher set is the primary evaluation unit. Individual teachers' other
  courses are supplementary evidence only.

Every source entry remains distinct. The resolver may relate several entries but
must not silently merge or discard them.

## Architecture

### HTTP client

Use ordinary HTTP requests rather than Playwright because the public pages are
server-rendered. The client obtains the site's one-time search token through the
public frontend flow, performs searches, and fetches course and teacher pages.
It uses a descriptive User-Agent, conservative request pacing, bounded timeouts,
and no authentication cookies.

### Parser

Parse HTML with Beautiful Soup. Extract only stable semantic content:

- course ID, URL, name, course numbers, semesters, teacher names and teacher URLs;
- average score and review count;
- the site's aggregate difficulty, homework, grading, and gain labels;
- public course metadata and public course introduction;
- the site's AI summary when present, preserving its source attribution;
- public review ID, semester, four dimension labels, text, publish/update time,
  upvote count, and comment count;
- same-name entries and each teacher's other course entries;
- teacher profile totals and listed courses.

Author display names, avatars, user profile details, comment bodies, and
attachments are not needed for recommendation and are excluded from normalized
cache output.

### Cache

Store normalized JSON under `tmp/icourse-cache/`, keyed by canonical source URL.
Each record includes `fetchedAt`, `sourceUrl`, `schemaVersion`, and parsed data.

- A record is fresh for 24 hours.
- Expiry is lazy: records are refreshed only when requested.
- A successful refresh atomically replaces the old record.
- Network failure may return old data with `stale=true` and a warning.
- Search or parse failure must never overwrite a previously valid record.
- Schema version changes invalidate incompatible cache records.

### Resolver

Manual course queries search by course name. JW bundle queries use course name,
course number when available, teacher set, and target semester as evidence.
Teacher queries search teacher pages and related course entries.

The JW bundle contains one `CalendarEvent` per concrete class occurrence, not
one record per semester offering. Before any iCourse request, the resolver:

1. ignores non-course events such as exams;
2. groups repeated occurrences into semester offerings using source lesson ID,
   course code, normalized title, and the complete teacher set;
3. preserves two offerings with the same title but different teacher sets;
4. performs at most one lookup for each grouped offering.

Resolution is evidence-based rather than a global uniqueness assumption:

1. Preserve all same-name course entries.
2. Prefer exact teacher-set matches for an existing JW offering.
3. Use exact single-teacher historical matches when no current entry exists.
4. Keep split historical pages as separate evidence records.
5. Mark weaker relations explicitly instead of presenting them as exact matches.

### Ranking and evidence selection

Course comparison first applies deterministic rules derived from the user's
preference, including homework, difficulty, grading, gain, review count, and
recency of offered semesters. Rule scores are retained in output so the result is
reproducible.

The CLI accepts repeatable preferences in the form `--prefer dimension=value`.
The first version supports `homework=low`, `difficulty=low`, `grading=high`, and
`gain=high`. When no preference is supplied, the base order uses site score,
review-count confidence, and recent offering evidence without inventing a user
preference.

The future LLM receives, in order:

1. Site-provided aggregate metrics.
2. Site-provided AI summary, if present, clearly labeled as such.
3. Representative public reviews chosen deterministically from recent reviews,
   highly upvoted reviews, and a small number of materially conflicting reviews.

The LLM explains trade-offs but does not replace the deterministic candidate
filter. It must distinguish site facts, reviewer opinions, and model inference.

## CLI

Provide one command with mutually exclusive query modes:

```text
python scripts/collect_icourse_public.py --course "course name" --prefer homework=low
python scripts/collect_icourse_public.py --teacher "teacher name"
python scripts/collect_icourse_public.py --jw-bundle tmp/ustc-jw-import.generated.json
```

Default output is a normalized query result under `tmp/`. An optional explicit
output path may be supplied. The CLI does not print review text or source IDs in
routine logs.

The JSON result contains query metadata, cache freshness, resolved course
families or teacher profiles, distinct source entries, deterministic ranking
details, and selected evidence. It contains no passwords, cookies, search
tokens, login-only content, or LLM API keys.

## Failure Handling

- Retry a failed one-time search token once with a new token.
- Respect rate-limit responses and `Retry-After`; do not loop aggressively.
- Fail clearly when search result or course page structure no longer matches the
  expected semantic fields.
- Report no-result and ambiguous-result states as structured outcomes.
- Allow stale-cache fallback only for network and rate-limit failures, not for a
  newly fetched page that fails structural validation.
- A failure for one JW course is recorded per item and does not erase successful
  results for other courses.

## Testing

All automated tests use saved, minimal, anonymized HTML fixtures and fake HTTP
responses. They never access `icourse.club`.

Coverage includes:

- course pages with and without AI summaries;
- aggregate dimensions and review parsing;
- multi-teacher entries and split historical entries;
- teacher profiles and related-course links;
- one-time search token retry and rate-limit behavior;
- 24-hour cache freshness, stale fallback, atomic replacement, and schema drift;
- course, teacher, and JW bundle resolution;
- a JW bundle with repeated weekly events collapsing to one lookup per offering;
- same-name JW offerings with different teacher sets remaining separate;
- multi-teacher participant sets remaining intact and exam events being ignored;
- deterministic ranking and representative evidence selection;
- normalized output privacy and CLI orchestration;
- parse failure preserving an older valid cache.

Real-site acceptance is a separate manual step. It performs a small public query,
checks request pacing and normalized output, and does not authenticate.
It also runs `--jw-bundle tmp/ustc-jw-import.generated.json` against the user's
current private bundle, verifies that all course events are grouped before network
access, and reports only aggregate counts in routine logs. The private bundle is
never copied into test fixtures or committed.

## Deferred Work

- Calling a real LLM and constructing the final conversational answer.
- App UI and persistent application database integration.
- Full offline mirroring or bulk crawling.
- Login-only reviews, attachments, comments, and account actions.
- Background refresh jobs; refresh remains query-driven in this prototype.
