import { useEffect, useState } from 'react'

// All API calls go through nginx /api/ → proxied to FastAPI backend.
// This avoids cross-origin issues and works in all environments (Compose, Kind, prod).
const API = '/api'

export default function App() {
  const [tasks, setTasks] = useState([])
  const [title, setTitle] = useState('')
  const [loading, setLoading] = useState(true)
  const [adding, setAdding] = useState(false)
  const [error, setError] = useState(null)

  const fetchTasks = () => {
    setLoading(true)
    fetch(`${API}/tasks`)
      .then(r => r.json())
      .then(data => { setTasks(data); setError(null) })
      .catch(() => setError('Could not load tasks. Is the API running?'))
      .finally(() => setLoading(false))
  }

  useEffect(() => { fetchTasks() }, [])

  const addTask = async (e) => {
    e.preventDefault()
    if (!title.trim()) return
    setAdding(true)
    try {
      const res = await fetch(`${API}/tasks?title=${encodeURIComponent(title)}`, { method: 'POST' })
      const task = await res.json()
      setTasks(prev => [...prev, task])
      setTitle('')
    } catch {
      setError('Failed to add task.')
    } finally {
      setAdding(false)
    }
  }

  const toggleTask = async (id) => {
    try {
      const res = await fetch(`${API}/tasks/${id}`, { method: 'PATCH' })
      const updated = await res.json()
      setTasks(prev => prev.map(t => t.id === id ? updated : t))
    } catch {
      setError('Failed to update task.')
    }
  }

  const deleteTask = async (id) => {
    try {
      await fetch(`${API}/tasks/${id}`, { method: 'DELETE' })
      setTasks(prev => prev.filter(t => t.id !== id))
    } catch {
      setError('Failed to delete task.')
    }
  }

  const done = tasks.filter(t => t.done).length

  return (
    <div className="app">
      <header>
        <h1>Task Manager</h1>
        <p>DevOps Demo — Docker · Kind · ArgoCD · Prometheus</p>
      </header>

      {error && <div className="error-banner">{error}</div>}

      <form className="add-form" onSubmit={addTask}>
        <input
          id="task-input"
          value={title}
          onChange={e => setTitle(e.target.value)}
          placeholder="What needs to be done?"
          autoFocus
        />
        <button className="btn" type="submit" disabled={adding || !title.trim()}>
          {adding ? '...' : 'Add'}
        </button>
      </form>

      <div className="status-bar">
        <span>{tasks.length} tasks</span>
        <span className="badge">{done} / {tasks.length} done</span>
      </div>

      {loading ? (
        <div className="empty">Loading…</div>
      ) : tasks.length === 0 ? (
        <div className="empty">No tasks yet. Add one above!</div>
      ) : (
        <ul className="task-list">
          {tasks.map(task => (
            <li key={task.id} className={`task-card ${task.done ? 'done' : ''}`}>
              <button
                id={`check-${task.id}`}
                className={`task-check ${task.done ? 'checked' : ''}`}
                onClick={() => toggleTask(task.id)}
                aria-label="Toggle done"
              />
              <span className="task-title">{task.title}</span>
              <button
                id={`del-${task.id}`}
                className="task-del"
                onClick={() => deleteTask(task.id)}
                aria-label="Delete task"
              >×</button>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
