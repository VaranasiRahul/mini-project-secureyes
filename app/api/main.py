from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from starlette.responses import Response
import psycopg2
import os
import time

app = FastAPI(title="Task API", version="1.0.0")

# Allow frontend origin in CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# --- Prometheus metrics ---
REQUEST_COUNT = Counter(
    "api_requests_total",
    "Total API requests",
    ["method", "endpoint", "status"]
)
REQUEST_LATENCY = Histogram(
    "api_request_duration_seconds",
    "API request latency",
    ["endpoint"]
)


def get_conn():
    """Return a psycopg2 connection using DATABASE_URL env var."""
    return psycopg2.connect(os.environ["DATABASE_URL"])


@app.on_event("startup")
def create_table():
    """Ensure the tasks table exists on startup."""
    conn = get_conn()
    cur = conn.cursor()
    cur.execute("""
        CREATE TABLE IF NOT EXISTS tasks (
            id    SERIAL PRIMARY KEY,
            title TEXT NOT NULL,
            done  BOOLEAN DEFAULT false
        )
    """)
    conn.commit()
    cur.close()
    conn.close()


@app.get("/healthz")
def health():
    """Liveness/readiness probe endpoint."""
    return {"status": "ok"}


@app.get("/metrics")
def metrics():
    """Prometheus scrape endpoint."""
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/tasks")
def list_tasks():
    start = time.time()
    conn = get_conn()
    cur = conn.cursor()
    cur.execute("SELECT id, title, done FROM tasks ORDER BY id")
    rows = cur.fetchall()
    cur.close()
    conn.close()
    REQUEST_COUNT.labels(method="GET", endpoint="/tasks", status="200").inc()
    REQUEST_LATENCY.labels(endpoint="/tasks").observe(time.time() - start)
    return [{"id": r[0], "title": r[1], "done": r[2]} for r in rows]


@app.post("/tasks", status_code=201)
def create_task(title: str):
    if not title.strip():
        REQUEST_COUNT.labels(method="POST", endpoint="/tasks", status="400").inc()
        raise HTTPException(status_code=400, detail="Title cannot be empty")
    start = time.time()
    conn = get_conn()
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO tasks (title, done) VALUES (%s, false) RETURNING id",
        (title,)
    )
    task_id = cur.fetchone()[0]
    conn.commit()
    cur.close()
    conn.close()
    REQUEST_COUNT.labels(method="POST", endpoint="/tasks", status="201").inc()
    REQUEST_LATENCY.labels(endpoint="/tasks").observe(time.time() - start)
    return {"id": task_id, "title": title, "done": False}


@app.patch("/tasks/{task_id}")
def toggle_task(task_id: int):
    conn = get_conn()
    cur = conn.cursor()
    cur.execute(
        "UPDATE tasks SET done = NOT done WHERE id = %s RETURNING id, title, done",
        (task_id,)
    )
    row = cur.fetchone()
    conn.commit()
    cur.close()
    conn.close()
    if not row:
        raise HTTPException(status_code=404, detail="Task not found")
    REQUEST_COUNT.labels(method="PATCH", endpoint="/tasks/{id}", status="200").inc()
    return {"id": row[0], "title": row[1], "done": row[2]}


@app.delete("/tasks/{task_id}", status_code=204)
def delete_task(task_id: int):
    conn = get_conn()
    cur = conn.cursor()
    cur.execute("DELETE FROM tasks WHERE id = %s RETURNING id", (task_id,))
    row = cur.fetchone()
    conn.commit()
    cur.close()
    conn.close()
    if not row:
        raise HTTPException(status_code=404, detail="Task not found")
    REQUEST_COUNT.labels(method="DELETE", endpoint="/tasks/{id}", status="204").inc()
