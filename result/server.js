var express = require('express'),
    async = require('async'),
    { Pool } = require('pg'),
    cookieParser = require('cookie-parser'),
    path = require('path'),
    app = express(),
    server = require('http').Server(app),
    // IMPORTANT: Socket.IO path is /result/socket.io
    io = require('socket.io')(server, { path: '/result/socket.io' });

var port = process.env.PORT || 4000;

// Create two namespaces: root ("/") and "/result"
var rootNamespace = io.of('/');      // Default namespace for pages at "/"
var resultNamespace = io.of('/result'); // Namespace for pages at "/result"

// Handle connections on the default namespace
rootNamespace.on('connection', function (socket) {
  console.log("Connected on root namespace");
  socket.emit('message', { text: 'Welcome from root!' });

  socket.on('subscribe', function (data) {
    socket.join(data.channel);
  });
});

// Handle connections on the /result namespace
resultNamespace.on('connection', function (socket) {
  console.log("Connected on /result namespace");
  socket.emit('message', { text: 'Welcome from result!' });

  socket.on('subscribe', function (data) {
    socket.join(data.channel);
  });
});

// --- Example PostgreSQL logic (adjust as needed) ---
var pgHost = process.env.PG_HOST || 'db';
var pgPort = process.env.PG_PORT || 5432;
var pgUser = process.env.PG_USER || 'postgres';
var pgPassword = process.env.PG_PASSWORD;
if (!pgPassword) { console.error("PG_PASSWORD is not set"); process.exit(1); }
var pgDatabase = process.env.PG_DATABASE || 'postgres';

var connectionString = `postgresql://${pgUser}:${pgPassword}@${pgHost}:${pgPort}/${pgDatabase}`;
console.log(`Connecting to database at ${pgHost}:${pgPort}`);

var { Pool } = require('pg');
var pool = new Pool({ connectionString: connectionString });

// When the database restarts, idle connections in the pool break and the pool
// emits 'error'. Without this handler Node.js treats it as fatal (experiment 3).
pool.on('error', function (err) {
  console.error("Database connection lost: " + err.message);
});

getVotes();

function getVotes() {
  // pool.query borrows a working connection each time and opens a new one
  // if the old one broke, so a database restart only skips a few updates.
  pool.query('SELECT vote, COUNT(id) AS count FROM votes GROUP BY vote', function (err, result) {
    if (err) {
      console.error("Waiting for db: " + err.message);
    } else {
      var votes = collectVotesFromResult(result);

      // Broadcast to both namespaces
      rootNamespace.emit("scores", JSON.stringify(votes));
      resultNamespace.emit("scores", JSON.stringify(votes));
    }

    // Repeat periodically
    setTimeout(getVotes, 1000);
  });
}

function collectVotesFromResult(result) {
  var votes = { a: 0, b: 0 };
  result.rows.forEach(function (row) {
    votes[row.vote] = parseInt(row.count);
  });
  return votes;
}
// --- End DB example ---

// Basic middleware
app.use(cookieParser());
app.use(express.urlencoded({ extended: true }));

// Serve static files from the "views" folder on both "/" and "/result"
app.use(express.static(path.join(__dirname, 'views')));
app.use("/result", express.static(path.join(__dirname, 'views')));

// Serve the same index.html for both routes
app.get(['/', '/result'], function (req, res) {
  res.sendFile(path.resolve(__dirname, 'views', 'index.html'));
});

// Start server
server.listen(port, function () {
  console.log('App running on port ' + server.address().port);
});
