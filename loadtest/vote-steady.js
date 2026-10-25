// Rollout runs (#9) and node failure (#10): a steady stream of votes while something
// is updated or broken. Default: 50 votes per second for 3 minutes = 9,000 votes.
// Based on Project 1's load test 3 (same file, there 10 votes/s during the failover test).
//
// Voter IDs k6f-<RUN>-<VU>-<ITER>: each run's votes can be counted on their own in PostgreSQL
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

const accepted = new Counter('votes_accepted');        // 200: this vote must end up in PostgreSQL
const byVote = new Counter('refused_by_vote');         // error page from Vote itself
const byGateway = new Counter('refused_by_gateway');   // error page from NGINX
const noAnswer = new Counter('refused_no_answer');     // nothing came back

export const options = {
  scenarios: {
    steady: {
      executor: 'constant-arrival-rate',   // a fixed number of new votes per second, whatever happens
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: 100,                // 50/s at ~0.2 s per vote from Germany needs ~10; room for slow moments
      maxVUs: 600,
    },
  },
  // No discardResponseBodies: the body of an error page tells who answered (Vote or NGINX).
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const voter = `k6f-${RUN}-${__VU}-${__ITER}`;   // unique per vote
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
