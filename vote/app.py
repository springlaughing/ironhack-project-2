from flask import Flask, render_template, request, make_response, g
from redis import Redis, RedisError
from redis.retry import Retry
from redis.backoff import NoBackoff
import os
import socket
import random
import json
import logging

# Read options and Redis configuration from environment variables
option_a = os.getenv('OPTION_A', "Cats")
option_b = os.getenv('OPTION_B', "Dogs")
redis_host = os.getenv('REDIS_HOST', 'redis')  # Default to 'redis' for compatibility
redis_port = int(os.getenv('REDIS_PORT', 6379))  # Default Redis port is 6379
hostname = socket.gethostname()

app = Flask(__name__)

gunicorn_error_logger = logging.getLogger('gunicorn.error')
app.logger.handlers.extend(gunicorn_error_logger.handlers)
app.logger.setLevel(logging.INFO)

def get_redis():
    if not hasattr(g, 'redis'):
        g.redis = Redis(host=redis_host, port=redis_port, db=0,
                        socket_connect_timeout=2,      # give up connecting after 2 s
                        socket_timeout=2,              # give up waiting for an answer after 2 s
                        retry=Retry(NoBackoff(), 0))   # no automatic retries: fail fast, the user retries
    return g.redis

@app.route("/", methods=['POST','GET'])
@app.route("/vote", methods=['POST','GET'])
def hello():
    voter_id = request.cookies.get('voter_id')
    if not voter_id:
        voter_id = hex(random.getrandbits(64))[2:-1]

    vote = None
    error = None

    if request.method == 'POST':
        vote = request.form['vote']
        data = json.dumps({'voter_id': voter_id, 'vote': vote})
        try:
            get_redis().rpush('votes', data)
            app.logger.info('Received vote for %s', vote)
        except RedisError as e:
            # Redis is down: say so, and show no checkmark
            app.logger.error('Could not store vote: %s', e)
            vote = None
            error = "Your vote was not counted. Please try again in a moment."

    resp = make_response(render_template(
        'index.html',
        option_a=option_a,
        option_b=option_b,
        hostname=hostname,
        vote=vote,
        error=error,
    ), 503 if error else 200)
    resp.set_cookie('voter_id', voter_id)
    return resp

@app.route("/health")
def health():
    # Healthy only if Redis answers: a Vote server that can't store votes is not healthy
    try:
        get_redis().ping()
        return {"status": "ok", "redis": "ok"}, 200
    except RedisError as e:
        return {"status": "error", "redis": str(e)}, 503

if __name__ == "__main__":
    app.run(host='0.0.0.0', port=os.getenv('PORT', 80), debug=True, threaded=True)
