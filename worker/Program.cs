using System;
using System.Data.Common;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using Newtonsoft.Json;
using Npgsql;
using StackExchange.Redis;
using System.Runtime.InteropServices;

namespace Worker
{
    public class Program
    {
        // Set when docker stop sends SIGTERM; the loop checks it before each vote
        private static volatile bool stopping = false;
        public static int Main(string[] args)
        {
            try
            {
                // docker stop sends SIGTERM: finish the current vote, then exit cleanly
                using var sigterm = PosixSignalRegistration.Create(PosixSignal.SIGTERM, context =>
                {
                    context.Cancel = true;   // don't let .NET end the program right away
                    stopping = true;
                    Console.WriteLine("Shutdown requested: finishing the current vote");
                });
                // Fetch configuration from environment variables
                var dbHost = Environment.GetEnvironmentVariable("DB_HOST") ?? "db";
                var dbUsername = Environment.GetEnvironmentVariable("DB_USERNAME") ?? "postgres";
                var dbPassword = Environment.GetEnvironmentVariable("DB_PASSWORD") ?? throw new InvalidOperationException("DB_PASSWORD is not set");                var dbName = Environment.GetEnvironmentVariable("DB_NAME") ?? "postgres";
                
                var redisHost = Environment.GetEnvironmentVariable("REDIS_HOST") ?? "redis";

                // Construct the connection strings
                var pgConnectionString = $"Server={dbHost};Username={dbUsername};Password={dbPassword};Database={dbName}";
                Console.WriteLine($"Connecting to database at {dbHost} as {dbUsername}");                var redisConnectionString = redisHost;

                var pgsql = OpenDbConnection(pgConnectionString);
                var redisConn = OpenRedisConnection(redisConnectionString);
                var redis = redisConn.GetDatabase();



                var definition = new { vote = "", voter_id = "" };

                // Each Worker container gets its own in-progress list, named after its hostname
                var processingList = $"votes:processing:{Environment.MachineName}";
                Console.WriteLine($"In-progress list: {processingList}");

                // Votes this container took before a crash: save them first
                FinishUnfinished(redis, pgsql, processingList);

                                while (!stopping)
                {
                    // Reconnect redis if down
                    if (redisConn == null || !redisConn.IsConnected)
                    {
                        Console.WriteLine("Reconnecting Redis");
                        redisConn = OpenRedisConnection(redisConnectionString);
                        redis = redisConn.GetDatabase();
                    }

                    // Move one vote from the queue into my in-progress list, in one atomic step
                    string? json = redis.ListMove("votes", processingList, ListSide.Left, ListSide.Right);
                    if (json == null)
                    {
                        // Queue is empty: pause briefly instead of asking Redis nonstop
                        Thread.Sleep(100);
                        continue;
                    }

                    var vote = JsonConvert.DeserializeAnonymousType(json, definition);
                    Console.WriteLine($"Processing vote for '{vote.vote}' by '{vote.voter_id}'");

                    try
                    {
                        UpdateVote(pgsql, vote.voter_id, vote.vote);
                    }
                    catch (Exception e) when (e is NpgsqlException || e is InvalidOperationException)
                    {
                        // The database restarted or the connection broke: reconnect instead of crashing.
                        // The vote is still in my in-progress list, so FinishUnfinished saves it now.
                        Console.WriteLine($"Database connection lost ({e.Message}), reconnecting");
                        pgsql.Dispose();
                        pgsql = OpenDbConnection(pgConnectionString);
                        FinishUnfinished(redis, pgsql, processingList);
                        continue;
                    }

                    // Saved: only now remove it from my in-progress list
                    redis.ListRemove(processingList, json, 1);
                }
                Console.WriteLine("Stopped cleanly");
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine(ex.ToString());
                return 1;
            }
        }

        private static NpgsqlConnection OpenDbConnection(string connectionString)
        {
            NpgsqlConnection connection;

            while (true)
            {
                try
                {
                    connection = new NpgsqlConnection(connectionString);
                    connection.Open();
                    break;
                }
                catch (SocketException)
                {
                    Console.Error.WriteLine("Waiting for db");
                    Thread.Sleep(1000);
                }
                catch (DbException)
                {
                    Console.Error.WriteLine("Waiting for db");
                    Thread.Sleep(1000);
                }
            }

            Console.Error.WriteLine("Connected to db");

            var command = connection.CreateCommand();
            command.CommandText = @"CREATE TABLE IF NOT EXISTS votes (
                                        id VARCHAR(255) NOT NULL UNIQUE,
                                        vote VARCHAR(255) NOT NULL
                                    )";
            command.ExecuteNonQuery();

            return connection;
        }

        private static ConnectionMultiplexer OpenRedisConnection(string hostname)
        {
            // Use IP address to workaround https://github.com/StackExchange/StackExchange.Redis/issues/410
            var ipAddress = GetIp(hostname);
            Console.WriteLine($"Found redis at {ipAddress}");

            while (true)
            {
                try
                {
                    Console.Error.WriteLine("Connecting to redis");
                    return ConnectionMultiplexer.Connect(ipAddress);
                }
                catch (RedisConnectionException)
                {
                    Console.Error.WriteLine("Waiting for redis");
                    Thread.Sleep(1000);
                }
            }
        }

        private static string GetIp(string hostname)
            => Dns.GetHostEntryAsync(hostname)
                .Result
                .AddressList
                .First(a => a.AddressFamily == AddressFamily.InterNetwork)
                .ToString();

                private static void FinishUnfinished(IDatabase redis, NpgsqlConnection pgsql, string processingList)
        {
            var definition = new { vote = "", voter_id = "" };
            var leftovers = redis.ListRange(processingList);
            if (leftovers.Length > 0)
                Console.WriteLine($"Finishing {leftovers.Length} unfinished vote(s)");

            foreach (var item in leftovers)
            {
                string json = item.ToString();
                var vote = JsonConvert.DeserializeAnonymousType(json, definition);
                UpdateVote(pgsql, vote.voter_id, vote.vote);
                redis.ListRemove(processingList, json, 1);
            }
        }
        private static void UpdateVote(NpgsqlConnection connection, string voterId, string vote)
        {
            using var command = connection.CreateCommand();
            command.CommandText = @"INSERT INTO votes (id, vote) VALUES (@id, @vote)
                                    ON CONFLICT (id) DO UPDATE SET vote = EXCLUDED.vote";
            command.Parameters.AddWithValue("@id", voterId);
            command.Parameters.AddWithValue("@vote", vote);
            command.ExecuteNonQuery();
        }
    }
}
