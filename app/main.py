import os
import time
import redis
from fastapi import FastAPI, HTTPException, Depends
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from sqlalchemy import create_engine, Column, Integer, String, Boolean, text
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker, Session
from sqlalchemy.exc import OperationalError


# --- STEP 1: LOAD VARIABLES ---
# We read these first so we can decide which DB to use
db_host = os.getenv("DB_HOST")
db_user = os.getenv("DB_USER")
db_password = os.getenv("DB_PASSWORD")
db_name = os.getenv("DB_NAME")
REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = os.getenv("REDIS_PORT", 6379)

# --- STEP 2: CONFIGURE DATABASE URL ---
# This block MUST come before 'create_engine'
if db_host:
    # Kubernetes/Production (Postgres)
    DATABASE_URL = f"postgresql://{db_user}:{db_password}@{db_host}/{db_name}"
    print(f"✅ Connecting to Postgres at {db_host}...")
else:
    # Local Development (SQLite)
    DATABASE_URL = "sqlite:///./test.db"
    print("⚠️  No DB_HOST found. Using local SQLite.")

# --- STEP 3: CONNECT TO DATABASE ---
engine = create_engine(DATABASE_URL)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()

# Retry logic (Only used for Postgres connection attempts)
def wait_for_db(engine):
    retries = 10
    while retries > 0:
        try:
            with engine.connect() as connection:
                connection.execute(text("SELECT 1"))
            print("✅ Database is ready!")
            return
        except OperationalError:
            print(f"⏳ Database not ready yet... waiting 3 seconds. ({retries} left)")
            time.sleep(3)
            retries -= 1
    raise Exception("❌ Database connection failed")

# Only run the wait loop if we are NOT using SQLite
if "sqlite" not in DATABASE_URL:
    wait_for_db(engine)

try:
    # decode_responses=True ensures we deal with normal strings, not bytes
    redis_client = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)
    # Ping it to verify the connection is actually alive
    redis_client.ping() 
    print(f"✅ Connected to Redis Broker at {REDIS_HOST}:{REDIS_PORT}")
except Exception as e:
    print(f"⚠️ Could not connect to Redis: {e}")
    redis_client = None

# --- STEP 4: DEFINE MODELS ---
class TodoItem(Base):
    __tablename__ = "todos"
    id = Column(Integer, primary_key=True, index=True)
    title = Column(String, index=True)
    completed = Column(Boolean, default=False)

# Create Tables
Base.metadata.create_all(bind=engine)

# Pydantic Models
class TodoCreate(BaseModel):
    title: str

class TodoUpdate(BaseModel):
    completed: bool

class TodoResponse(BaseModel):
    id: int
    title: str
    completed: bool
    class Config:
        orm_mode = True

# --- STEP 5: API ENDPOINTS ---
app = FastAPI()

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

@app.get("/todos", response_model=list[TodoResponse])
def read_todos(db: Session = Depends(get_db)):
    return db.query(TodoItem).order_by(TodoItem.id).all()

@app.post("/todos", response_model=TodoResponse)
def create_todo(todo: TodoCreate, db: Session = Depends(get_db)):
    db_todo = TodoItem(title=todo.title)
    db.add(db_todo)
    db.commit()
    db.refresh(db_todo)
    return db_todo

@app.put("/todos/{todo_id}", response_model=TodoResponse)
def update_todo(todo_id: int, todo: TodoUpdate, db: Session = Depends(get_db)):
    db_todo = db.query(TodoItem).filter(TodoItem.id == todo_id).first()
    if not db_todo:
        raise HTTPException(status_code=404, detail="Todo not found")
    db_todo.completed = todo.completed
    db.commit()
    db.refresh(db_todo)
    return db_todo

@app.put("/todos/{todo_id}", response_model=TodoResponse)
def update_todo(todo_id: int, todo: TodoUpdate, db: Session = Depends(get_db)):
    db_todo = db.query(TodoItem).filter(TodoItem.id == todo_id).first()
    if not db_todo:
        raise HTTPException(status_code=404, detail="Todo not found")
    
    # Check if the task is actively changing from incomplete to complete
    just_completed = (not db_todo.completed) and todo.completed

    # Update the database
    db_todo.completed = todo.completed
    db.commit()
    db.refresh(db_todo)
    
    # --- SEND MESSAGE TO REDIS BROKER ---
    if just_completed and redis_client:
        try:
            payload = {
                "event": "task_completed",
                "task_id": str(todo_id)
            }
            # xadd() pushes the message to the Stream. 
            # The '*' tells Redis to auto-generate a unique timestamp ID.
            redis_client.xadd("todo_events", payload, id="*")
            print(f"🚀 Published event to Redis: {payload}")
        except Exception as e:
            print(f"⚠️ Failed to publish event to Redis: {e}")

    return db_todo

@app.delete("/todos/{todo_id}")
def delete_todo(todo_id: int, db: Session = Depends(get_db)):
    db_todo = db.query(TodoItem).filter(TodoItem.id == todo_id).first()
    if not db_todo:
        raise HTTPException(status_code=404, detail="Todo not found")
    db.delete(db_todo)
    db.commit()
    return {"message": "Todo deleted"}

app.mount("/", StaticFiles(directory="static", html=True), name="static")