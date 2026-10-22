// Load tests 1 and 2: a burst of votes against the Vote server.
// Default: 400 votes per second for 5 seconds = 2,000 votes (the brief's spike).
// With WARMUP set (load test 2), normal traffic runs first, then the burst.
import http from 'k6/http';
import { check } from 'k6';

const RATE = Number(__ENV.RATE || 400);           // burst: new votes per second
const DURATION = __ENV.DURATION || '5s';          // burst: how long
const TARGET = __ENV.TARGET || 'http://vote/';    // where to send votes; default = local compose
const WARMUP = __ENV.WARMUP || '';                // e.g. '60s' of normal traffic before the burst
const WARMUP_RATE = Number(__ENV.WARMUP_RATE || 50);
const MAX_VUS = Number(__ENV.MAX_VUS || 300);     // virtual users k6 may use for the burst
const PRE_VUS = Number(__ENV.PRE_VUS || Math.min(RATE, MAX_VUS));  // created before the test starts

const scenarios = {
  burst: {
    executor: 'constant-arrival-rate',  // a fixed number of new votes per second
    rate: RATE,
    timeUnit: '1s',
    duration: DURATION,
    startTime: WARMUP || '0s',          // the burst starts when the warm-up ends
    preAllocatedVUs: PRE_VUS,           // ready in advance: creating VUs mid-test is slow, k6 skips votes meanwhile
    maxVUs: MAX_VUS,                    // enough, so k6 never has to skip a planned vote
  },
};

if (WARMUP) {
  scenarios.warmup = {
    executor: 'constant-arrival-rate',
    exec: 'warmup',                     // runs the warmup() function below
    rate: WARMUP_RATE,
    timeUnit: '1s',
    duration: WARMUP,
    preAllocatedVUs: 20,
    maxVUs: 100,
  };
}

export const options = {
  scenarios,
  discardResponseBodies: true,          // k6 doesn't keep the pages: less memory for many VUs
  thresholds: {
    // {scenario:burst} = count only the burst, not the warm-up
    'http_req_failed{scenario:burst}': ['rate<0.01'],     // fewer than 1% errors
    'http_req_duration{scenario:burst}': ['p(95)<500'],   // 95% of votes answered within 0.5 s
    'http_reqs{scenario:burst}': ['count>0'],             // shows how many burst votes were sent
    'checks{scenario:burst}': ['rate>0.99'],              // shows how many were accepted
    // Always pass; they only make k6 print the burst's own lines for:
    'iteration_duration{scenario:burst}': ['max>=0'],       // a voter's whole wait, connecting included
    'http_req_tls_handshaking{scenario:burst}': ['max>=0'], // the HTTPS handshake part of it
  },
};

function vote(voter) {
  const res = http.post(TARGET, { vote: Math.random() < 0.5 ? 'a' : 'b' }, {
    headers: { Cookie: `voter_id=${voter}` },
  });
  check(res, { 'vote accepted (200)': (r) => r.status === 200 });
}

// Burst: a unique voter per request, so every vote becomes its own row (k6-...)
export default function () {
  vote(`k6-${__VU}-${__ITER}`);
}

// Warm-up: other voter IDs (k6w-...), so the burst can be counted on its own
export function warmup() {
  vote(`k6w-${__VU}-${__ITER}`);
}