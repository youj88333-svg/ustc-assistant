# USTC Young Enrolment Collector Design

## Scope

Build a read-only browser collector for the USTC second-classroom page that
lists activities currently open for enrolment. The collector does not read a
student's enrolment history and does not perform enrolment, cancellation, or
any other write action.

## Browser And Authentication

The collector reuses the visible persistent Microsoft Edge profile already
used by the USTC JW prototype. It opens the stable page:

`https://young.ustc.edu.cn/login/sc-wisdom-group-learning/myproject/SignUp`

If the stored browser session is insufficient, the user completes login on the
official page. The program waits for the second-classroom application route and
never asks for, prints, or persists a password, Cookie, CAS ticket, or
`X-Access-Token`.

The observed login callback lands on `dataAnalysis/visual` instead of restoring
the originally requested SignUp route. After detecting an authenticated
second-classroom application URL on another route, the collector therefore
opens the stable SignUp URL again automatically. This retry occurs at most once
within the original login timeout.

## Collection Flow

1. Open the stable SignUp route in the persistent Edge context.
2. Wait until the page exposes the `报名中` tab, allowing time for manual login.
3. Click `报名中` and capture the matching network response.
4. Match responses only by HTTPS host, exact path, GET method, and successful
   HTTP status. Ignore `_t` and encrypted `requestParams`.
5. Validate `success`, `code`, `result.records`, `result.total`, and
   `result.pages`.
6. Ignore `result.current`, because the observed platform always returns `1`.
7. Move through later pages with the page's next control, capture one response
   per click, and merge records by activity `id`.
8. Reject duplicate IDs whose payloads disagree and reject a final unique
   count different from the reported `total`.

The first implementation uses the site's own UI so its frontend remains
responsible for generating encrypted request parameters. It does not re-create
the AES interceptor or derive keys from an access token.

## Output

The CLI writes `tmp/ustc-young-enrolment.generated.json`. The generated file
contains collection metadata and a normalized activity list suitable for the
next conversion-design step. Normalized records retain activity identity,
name, module/category labels, organizer labels, activity and application time
windows, capacity/count fields, location, format, and descriptive content.
Unknown source fields are not copied into the normal output.

With explicit `--save-raw`, the complete collected records are additionally
written to `tmp/private/ustc-young-enrolment.raw.json`. The CLI prints a privacy
warning when this option is used.

## Error Handling

User-facing errors mention only the failed stage and safe HTTP/status or count
information. They do not include full request URLs, encrypted parameters,
headers, response bodies, tokens, or activity payloads. Browser automation
errors are replaced with a generic sanitized message.

## Testing

Automated tests use fake Playwright pages, responses, and browser contexts; they
never access the school website. Tests cover exact endpoint recognition, page
validation, two-page collection, ID deduplication, conflicting duplicate
rejection, total mismatch, login waiting, visible persistent Edge settings,
sanitized failures, normalization, default output, optional raw output, and CLI
orchestration. A final manual run validates the real login and pagination DOM.
