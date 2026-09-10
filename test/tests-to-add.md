# Integration tests to add

Gaps between what `fmsg-spec/SPEC.md` mandates and what `test/tests/` currently
proves. Cross an item off (`- [x]`) when its test lands in `test/tests/`.

Baseline coverage as of test 011: happy paths only — new thread, reply, add-to
(65 path, three variants), attachments, deflate, watch/WebSocket. No test
asserts a per-recipient response code, exercises same-domain delivery, or sends
to more than one recipient.

## Tier 1 — uncovered spec paths, cheap to write

- [x] **012 — per-recipient reject codes 100/101/102** (SPEC §10.4 step 6, §8)
  The whole `validateMsgRecvForAddr` ladder (`fmsgd/cmd/fmsgd/host.go:1200`) is
  untested end to end.
  - `100 user unknown`: alice sends to `@dave@example.com` (never seeded).
  - `102 user not accepting`: set `accepting_new=false` for carol via psql on
    `example-postgres-1`, send, restore.
  - `101 user full`: set `limit_recv_count_per_1d=0` (or
    `limit_recv_size_per_msg`), send, restore.
  Assert non-delivery and the recorded `msg_to.response_code` on the sender.
  Pins the code-105 substitution rule too.
  **Done:** `test/tests/012-per-recipient-reject-codes.sh`. Asserts each code
  twice — `msg_to.response_code` on hairpin and `to_delivery[].response_code`
  from `GET /fmsg/:id` — via the new `api_json_get` helper in `test-lib.sh`.
  Non-delivery is asserted only for the terminal 102 case (101 is retryable).

- [x] **013 — multi-recipient, multi-domain fan-out** (SPEC §10.2)
  Every existing test sends to exactly one recipient. `draft create` +
  `update --to @alice@hairpin.local,@carol@example.com` (CLI `--to` is a
  StringSlice) + `draft send`. Asserts per-domain delivery and per-recipient
  code stream ordering with >1 recipient.
  **Done:** `test/tests/013-multi-recipient-fan-out.sh`. Pairs the unseeded
  dave (100) with bob (200) on one domain and sends them in BOTH orders, so a
  one-byte stream misalignment cannot pass; plus a two-domain message whose
  remote outcome comes from fmsgd and whose local one comes from webapi's
  resolveLocalDelivery. Also asserts receiving hosts retain the complete _to_
  list (SPEC §11), which folds in most of what 014 was for.

- [x] **014 — same-domain / local delivery** (bob -> carol, both `@example.com`)
  *Reduced by 013, which already covers a local recipient alongside a remote
  one. What remains untested is a message with ONLY local recipients, which
  never reaches fmsgd's outbound sender at all.*
  Exercises `resolveLocalDelivery`
  (`fmsg-webapi/internal/handlers/messages.go:97`), which bypasses the fmsgd
  wire and is covered by nothing today.

- [x] **015 — notification-only add-to, code 11** (SPEC §10.4 step 1, §12, §11)
  Tests 004/009/010 all take the **65** path. Setup: alice(hairpin) ->
  bob(example); then **bob** adds `@carol@example.com`, so hairpin.local hosts
  only `from` and must respond 11 and record the batch. Key assertion: alice can
  then reply against that batch hash — proving 11-path hosts can reconstruct it.

- [ ] **016 — case-insensitive addressing** (SPEC §1, §2 field 5)
  Seeds store mixed case (`@ALICE@hairpin.local`, `@Bob@example.com`) yet every
  test sends lowercase. Send to `@BOB@example.com`, reply to
  `@Alice@hairpin.local`; assert delivery and case-folded distinctness.

## Tier 2 — protocol encodings never exercised

- [ ] **017 — non-common media type + binary body** (SPEC §2 field 10, §4)
  All current messages are `text/plain` (common ID 56). The length-prefixed
  ASCII type string is never written and no binary body is ever sent. Round-trip
  a custom type (e.g. `application/x-fmsg-test`) plus a common-ID attachment
  (`image/png` = 38). Optional: unmapped common ID rejected with code 1
  (needs header injection).

- [ ] **018 — `important` / `no reply` flags** (flags bits 3 & 4)
  `fmsg send --important` / `--no-reply` are never used by any test. Assert the
  flags survive the wire and surface via `fmsg get`. Catches flag-byte packing
  regressions that would corrupt bit 5 (deflate).

- [ ] **019 — too big, code 4** (SPEC §10.3 step 5, §13)
  `FMSG_MAX_MSG_SIZE` defaults to 10240; test 006's "large" payload is ~1.2 KB,
  so the guard has never fired. Send >10 KB incompressible
  (`head -c 20000 /dev/urandom | base64`); assert code 4 before data download.
  Variant: compressible body over `FMSG_MAX_EXPANDED_SIZE` (decompression-bomb
  guard, a security requirement with no test).

- [ ] **020 — time rejections, codes 7 / 8 / 9** (SPEC §10.3 steps 6, 7)
  Inject a pending outbound row with a doctored `time` (technique established by
  test 009). Older than `FMSG_MAX_PAST_TIME_DELTA` -> 7; beyond
  `FMSG_MAX_FUTURE_TIME_DELTA` -> 8; reply timestamped before its parent -> 9.

## Tier 3 — higher cost, still worth it

- [ ] **021 — duplicate detection, codes 10 and 103** (SPEC §10.4 step 2, §13)
  Re-deliver an already-accepted message (duplicate the pending outbound row):
  assert 10 for the header / 103 per recipient. Counterpart: re-issuing the same
  add-to addresses at a **new** time is a distinct batch, not a duplicate
  (§12, batch identity covers `time`) — asserted nowhere today.

- [ ] **022 — challenge flow** (SPEC §6, §7, §10.5)
  Nothing asserts a challenge ever happens. Cheap version: grep fmsgd container
  logs for the `--> CHALLENGE` / `<-- CHALLENGE RESP` pair after first contact
  (default mode `HAS_NOT_PARTICIPATED`), then assert a same-thread reply does
  not challenge. Stronger: stacks with `FMSG_CHALLENGE_MODE=ALWAYS` / `NEVER`,
  gated behind an env flag (needs a compose restart).

- [ ] **023 — deferred delivery and retry** (SPEC §10.2 step 1)
  `docker stop example-fmsgd-1`, send from alice, assert pending, restart,
  assert delivery within `FMSG_RETRY_INTERVAL + FMSG_POLL_INTERVAL`. Covers the
  retry/backoff loop and the `-1` retryable sentinel. Slowest and most
  flake-prone — run last, generous timeout.

- [ ] **024 — non-participant reply rejected, code 1** (SPEC §10.3 step 7)
  Carol replies with a pid for a message she is not a participant of. Needs pid
  injection (same shape as 020), but it is the one check preventing thread
  hijacking.

## Standing caveat

Tests 019, 020, 021 and 024 need header/timestamp control the webapi does not
expose, so they follow test 009's precedent of injecting a pending outbound row
directly into the sender's database. Those tests will break whenever
`fmsgd/dd.sql` changes shape — a deliberate maintenance cost, currently paid
once.

Tests `009` and `015-message-sha256.sh` cover API batch-hash replies, local-only
identities and subsequent federation, and compressed notification-only add-to.
Run with `FMSG_CHALLENGE_MODE=ALWAYS` to assert challenge-response coverage.
