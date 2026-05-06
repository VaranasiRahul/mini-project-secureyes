-- Seed table for the Task Manager demo
CREATE TABLE IF NOT EXISTS tasks (
    id    SERIAL PRIMARY KEY,
    title TEXT NOT NULL,
    done  BOOLEAN DEFAULT false
);

-- Seed a starter task so the UI is not empty on first run
INSERT INTO tasks (title) VALUES ('Welcome to the DevOps demo!')
ON CONFLICT DO NOTHING;
