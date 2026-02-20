import os
import time
import redis
import psycopg2
from psycopg2 import OperationalError

# --- STEP 1: LOAD VARIABLES ---
REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = os.getenv("REDIS_PORT", 6379)

DB_HOST = os.getenv("DB_HOST", "localhost")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASSWORD = os.getenv("DB_PASSWORD", "mysecretpassword")
DB_NAME = os.getenv("DB_NAME", "analytics_db")

STREAM_KEY = "todo_events"
CONSUMER_GROUP = "analytics_group"
CONSUMER_NAME = "worker-1" # In a scaled environment, each pod needs a unique name (e.g., using hostname)

# --- STEP 2: CONNECT TO DATABASES ---
print(f"✅ Connecting to Redis at {REDIS_HOST}:{REDIS_PORT}...")
r = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)

def get_db_connection():
    """Establish connection to PostgreSQL with retry logic."""
    retries = 10
    while retries > 0:
        try:
            conn = psycopg2.connect(
                host=DB_HOST,
                database=DB_NAME,
                user=DB_USER,
                password=DB_PASSWORD
            )
            print("✅ PostgreSQL Database is ready!")
            return conn
        except OperationalError:
            print(f"⏳ Database not ready yet... waiting 3 seconds. ({retries} left)")
            time.sleep(3)
            retries -= 1
    raise Exception("❌ Database connection failed")

pg_conn = get_db_connection()

# --- STEP 3: INITIALIZE DATABASE TABLE ---
# Ensure our analytics table actually exists before we try to update it
def init_db():
    with pg_conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS metrics (
                event_type VARCHAR(50) PRIMARY KEY,
                count INT DEFAULT 0
            );
        """)
        # Insert a starting row if it doesn't exist
        cur.execute("""
            INSERT INTO metrics (event_type, count) 
            VALUES ('task_completed', 0) 
            ON CONFLICT (event_type) DO NOTHING;
        """)
    pg_conn.commit()

init_db()

# --- STEP 4: SETUP REDIS CONSUMER GROUP ---
try:
    # mkstream=True creates the stream if it doesn't exist yet
    r.xgroup_create(STREAM_KEY, CONSUMER_GROUP, id="0", mkstream=True)
    print(f"✅ Created Consumer Group: {CONSUMER_GROUP}")
except redis.exceptions.ResponseError as e:
    if "BUSYGROUP Consumer Group name already exists" in str(e):
        print(f"ℹ️  Consumer Group {CONSUMER_GROUP} already exists.")
    else:
        raise e

# --- STEP 5: THE EVENT LOOP ---

print("🚀 Worker started. Listening for messages...")

while True:
    try:
        # Read 1 message from the stream, waiting up to 5000ms (5 seconds)
        messages = r.xreadgroup(
            groupname=CONSUMER_GROUP, 
            consumername=CONSUMER_NAME, 
            streams={STREAM_KEY: ">"}, # ">" means "give me messages that haven't been delivered to anyone else"
            count=1, 
            block=5000
        )

        if messages:
            # Parse the nested Redis response
            # Format: [['todo_events', [('1611593593691-0', {'event': 'task_completed', 'task_id': '104'})]]]
            stream_name, message_list = messages[0]
            message_id, payload = message_list[0]

            print(f"📥 Received event: {payload}")

            # Only process if it's the right event
            if payload.get("event") == "task_completed":
                with pg_conn.cursor() as cur:
                    # Increment the counter
                    cur.execute("""
                        UPDATE metrics 
                        SET count = count + 1 
                        WHERE event_type = 'task_completed';
                    """)
                pg_conn.commit()
                print("📈 Updated Postgres analytics counter!")

            # VERY IMPORTANT: Acknowledge the message so Redis knows it's fully processed
            r.xack(STREAM_KEY, CONSUMER_GROUP, message_id)

    except Exception as e:
        print(f"⚠️ Error processing stream: {e}")
        # If Postgres drops the connection, attempt to reconnect
        if isinstance(e, psycopg2.OperationalError):
            pg_conn = get_db_connection()
        time.sleep(2)