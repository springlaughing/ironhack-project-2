// Rollout runs (#9) and node failure (#10): a steady stream of votes while something
// is updated or broken. Default: 50 votes per second for 3 minutes = 9,000 votes.
// Based on Project 1's load test 3 (same file, there 10 votes/s during the failover test).
// With BURST_AT set, a spike comes on top: e.g. BURST_AT=60s gives 400 votes/s for 5 s
// (the brief's 2,000 votes) starting 60 s in, the moment rollout-test.sh starts the update.
//
// Voter IDs k6f-<RUN>-<VU>-<ITER> (burst: k6f-<RUN>-b-<VU>-<ITER>): each run's votes can be
// counted on their own in PostgreSQL
//   SELECT COUNT(*) FROM votes WHERE id LIKE 'k6f-A-%'
// Every vote that is not accepted is printed with its time, status and WHO answered:
//   Vote     the page came back with an error status but it is Vote's own page ("Cats"),
//            e.g. 503 "Your vote was not counted" when Redis is unreachable
//   Gateway  an error page without "Cats": NGINX answered itself, because it could not
//            reach a Vote pod (502 Bad Gateway, 503, 504)
//   none     no answer at all within 10 s (timeout, connection reset): status 0
import http from 'k6/http';
import { Counter } from 'k6/metrics';

const RUN = __ENV.RUN || 'X';                                     // A, B, C, D (#9), N (#10)
const RATE = Number(__ENV.RATE || 50);                            // new votes per second
const DURATION = __ENV.DURATION || '3m';                          // how long
const TARGET = __ENV.TARGET || 'https://k8s.springlaughing.dev/';
const BURST_AT = __ENV.BURST_AT || '';                            // e.g. '60s'; empty = no burst
const BURST_RATE = Number(__ENV.BURST_RATE || 400);
const BURST_DURATION = __ENV.BURST_DURATION || '5s';

const accepted = new Counter('votes_accepted');        // 200: this vote must end up in PostgreSQL
const byVote = new Counter('refused_by_vote');         // error page from Vote itself
const byGateway = new Counter('refused_by_gateway');   // error page from NGINX
const noAnswer = new Counter('refused_no_answer');     // nothing came back

const scenarios = {
  steady: {
    executor: 'constant-arrival-rate',     // a fixed number of new votes per second, whatever happens
    rate: RATE,
    timeUnit: '1s',
    duration: DURATION,
    preAllocatedVUs: 100,                  // 50/s at ~0.2 s per vote from Germany needs ~10; room for slow moments
    maxVUs: 600,
  },
};
const thresholds = {};
if (BURST_AT) {
  scenarios.burst = {
    executor: 'constant-arrival-rate',
    exec: 'burst',                         // runs the burst() function below
    rate: BURST_RATE,
    timeUnit: '1s',
    duration: BURST_DURATION,
    startTime: BURST_AT,
    preAllocatedVUs: 800,                  // as in the spike tests: enough waiting voters, created in advance
    maxVUs: 1200,
  };
  // Always pass; they only make k6 print the burst's own lines in its summary
  for (const m of ['http_req_duration', 'http_req_tls_handshaking', 'iteration_duration']) {
    thresholds[`${m}{scenario:burst}`] = ['max>=0'];
  }
  for (const m of ['http_reqs', 'votes_accepted', 'refused_by_vote', 'refused_by_gateway', 'refused_no_answer']) {
    thresholds[`${m}{scenario:burst}`] = ['count>=0'];
  }
}

export const options = {
  scenarios,
  thresholds,
  // No discardResponseBodies: the body of an error page tells who answered (Vote or NGINX).
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
};

function vote(voter) {
  const res = http.post(TARGET, { vote: Math.random() < 0.5 ? 'a' : 'b' }, {
    headers: { Cookie: `voter_id=${voter}` },
    timeout: '10s',                        // give up after 10 s (default 60 s), so errors show up quickly
  });
  if (res.status === 200) {
    accepted.add(1);
    return;
  }
  let source;
  if (res.status === 0) {
    noAnswer.add(1);
    source = 'none';
  } else if (res.body && res.body.includes('Cats')) {
    byVote.add(1);
    source = 'Vote';
  } else {
    byGateway.add(1);
    source = 'Gateway';
  }
  console.warn(`${new Date().toISOString()} refused ${voter}: status ${res.status} from ${source} ${res.error || ''}`);
}

// Steady stream: unique voter per vote
export default function () {
  vote(`k6f-${RUN}-${__VU}-${__ITER}`);
}

// Burst on top: -b- in the ID, so its votes can also be counted on their own (LIKE 'k6f-A-b-%')
export function burst() {
  vote(`k6f-${RUN}-b-${__VU}-${__ITER}`);
}
