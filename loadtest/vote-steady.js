// Load test 3 (#21): a steady stream of votes during the failover test (#20).
// Default: 10 votes per second for 15 minutes = 9,000 votes.
// Voter IDs k6f-..., so these votes can be counted on their own in the database.
// Every refused vote is printed with its time, so it can be matched to the failover steps.
import http from 'k6/http';
import { Counter } from 'k6/metrics';

const RATE = Number(__ENV.RATE || 10);                               // new votes per second
const DURATION = __ENV.DURATION || '15m';                            // how long
const TARGET = __ENV.TARGET || 'https://vote.springlaughing.dev/';

const accepted = new Counter('votes_accepted');   // Vote answered 200: this vote must end up in the database
const refused = new Counter('votes_refused');     // anything else: the voter saw an error

export const options = {
  scenarios: {
    steady: {
      executor: 'constant-arrival-rate',   // a fixed number of new votes per second, whatever happens
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: 50,                 // plenty for 10/s, even if some answers are slow
      maxVUs: 200,
    },
  },
  discardResponseBodies: true,
};

export default function () {
  const voter = `k6f-${__VU}-${__ITER}`;   // unique per vote
  const res = http.post(TARGET, { vote: Math.random() < 0.5 ? 'a' : 'b' }, {
    headers: { Cookie: `voter_id=${voter}` },
    timeout: '10s',                        // give up after 10 s (default 60 s), so errors show up quickly
  });
  if (res.status === 200) {
    accepted.add(1);
  } else {
    refused.add(1);
    console.warn(`${new Date().toISOString()} refused ${voter}: status ${res.status} ${res.error || ''}`);
  }
}