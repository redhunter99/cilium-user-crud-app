#!/bin/bash
set -e

QUAY_USER="redhunter99"
BASE="quay.io/${QUAY_USER}/cilium/app"
WORKDIR="app-images"

echo "🔨 Building images..."
rm -rf $WORKDIR && mkdir -p $WORKDIR/{db,backend,frontend}
cd $WORKDIR

# ============== DB ==============
cat > db/init.sql <<'SQL'
CREATE DATABASE IF NOT EXISTS usersdb;
USE usersdb;
CREATE TABLE users (
  id INT AUTO_INCREMENT PRIMARY KEY,
  username VARCHAR(100) UNIQUE,
  password VARCHAR(100)
);
INSERT INTO users (username, password) VALUES ('admin', 'admin123');
SQL

cat > db/Dockerfile <<'DFILE'
FROM mysql:8.0
ENV MYSQL_ROOT_PASSWORD=rootpass
ENV MYSQL_DATABASE=usersdb
COPY init.sql /docker-entrypoint-initdb.d/
DFILE

# ============== BACKEND ==============
cat > backend/app.py <<'PYFILE'
from flask import Flask, request, jsonify
from flask_cors import CORS
import mysql.connector
import os
import time
import logging

logging.basicConfig(level=logging.DEBUG)
logger = logging.getLogger(__name__)

app = Flask(__name__)
CORS(app)

DB_HOST = os.getenv("DB_HOST", "app-db.app.svc.cluster.local")
DB_USER = "root"
DB_PASS = "rootpass"
DB_NAME = "usersdb"

db = None

def connect_db():
    global db
    for i in range(60):
        try:
            logger.info(f"[{i+1}/60] Connecting to DB: {DB_HOST}...")
            db = mysql.connector.connect(
                host=DB_HOST,
                user=DB_USER,
                password=DB_PASS,
                database=DB_NAME,
                connect_timeout=5,
                autocommit=True
            )
            logger.info("✓ Connected to DB")
            return True
        except Exception as e:
            logger.warning(f"Connection failed: {e}")
            time.sleep(2)
    logger.error("FAILED to connect to DB after 60 attempts")
    return False

@app.before_request
def ensure_db():
    global db
    if db is None:
        if not connect_db():
            return jsonify({"status": "error", "msg": "Database not ready"}), 503

@app.route("/health", methods=["GET"])
def health():
    try:
        if db:
            cur = db.cursor()
            cur.execute("SELECT 1")
            cur.fetchone()
            return jsonify({"status": "ok"}), 200
    except:
        pass
    return jsonify({"status": "error"}), 503

@app.route("/signup", methods=["POST"])
def signup():
    try:
        data = request.json
        username = data.get("username", "").strip()
        password = data.get("password", "").strip()
        
        if not username or not password:
            return jsonify({"status": "error", "msg": "Username and password required"}), 400
        
        cur = db.cursor()
        cur.execute(
            "INSERT INTO users (username, password) VALUES (%s, %s)",
            (username, password)
        )
        return jsonify({"status": "success", "msg": f"User '{username}' created"}), 201
    except mysql.connector.errors.IntegrityError:
        return jsonify({"status": "error", "msg": "Username already exists"}), 409
    except Exception as e:
        logger.error(f"Signup error: {e}")
        return jsonify({"status": "error", "msg": str(e)}), 400

@app.route("/login", methods=["POST"])
def login():
    try:
        data = request.json
        username = data.get("username", "").strip()
        password = data.get("password", "").strip()
        
        cur = db.cursor()
        cur.execute(
            "SELECT id, username FROM users WHERE username=%s AND password=%s",
            (username, password)
        )
        user = cur.fetchone()
        if user:
            return jsonify({"status": "success", "msg": "Login successful", "user": {"id": user[0], "username": user[1]}}), 200
        return jsonify({"status": "error", "msg": "Invalid credentials"}), 401
    except Exception as e:
        logger.error(f"Login error: {e}")
        return jsonify({"status": "error", "msg": str(e)}), 400

@app.route("/users", methods=["GET"])
def list_users():
    try:
        cur = db.cursor()
        cur.execute("SELECT id, username FROM users")
        users = cur.fetchall()
        return jsonify({"status": "success", "users": [{"id": u[0], "username": u[1]} for u in users]}), 200
    except Exception as e:
        logger.error(f"List users error: {e}")
        return jsonify({"status": "error", "msg": str(e)}), 400

@app.route("/user/<int:user_id>", methods=["PUT"])
def update_user(user_id):
    try:
        data = request.json
        username = data.get("username", "").strip()
        
        if not username:
            return jsonify({"status": "error", "msg": "Username required"}), 400
        
        cur = db.cursor()
        cur.execute(
            "UPDATE users SET username=%s WHERE id=%s",
            (username, user_id)
        )
        
        if cur.rowcount == 0:
            return jsonify({"status": "error", "msg": "User not found"}), 404
        
        return jsonify({"status": "success", "msg": f"User {user_id} updated"}), 200
    except Exception as e:
        logger.error(f"Update error: {e}")
        return jsonify({"status": "error", "msg": str(e)}), 400

@app.route("/user/<int:user_id>", methods=["DELETE"])
def delete_user(user_id):
    try:
        cur = db.cursor()
        cur.execute("DELETE FROM users WHERE id=%s", (user_id,))
        
        if cur.rowcount == 0:
            return jsonify({"status": "error", "msg": "User not found"}), 404
        
        return jsonify({"status": "success", "msg": f"User {user_id} deleted"}), 200
    except Exception as e:
        logger.error(f"Delete error: {e}")
        return jsonify({"status": "error", "msg": str(e)}), 400

if __name__ == "__main__":
    if connect_db():
        logger.info("Starting Flask app...")
        app.run(host="0.0.0.0", port=5000, debug=False)
    else:
        logger.error("Cannot start app without DB connection")
        exit(1)
PYFILE

cat > backend/Dockerfile <<'DFILE'
FROM python:3.11-slim
WORKDIR /app
RUN pip install flask flask-cors mysql-connector-python
COPY app.py .
EXPOSE 5000
CMD ["python", "app.py"]
DFILE

# ============== FRONTEND ==============
cat > frontend/index.html <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>User Management - K8s App</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }

        .navbar {
            background: rgba(255,255,255,0.95);
            padding: 20px 40px;
            border-radius: 12px;
            box-shadow: 0 4px 20px rgba(0,0,0,0.15);
            margin-bottom: 30px;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }

        .navbar h1 {
            color: #667eea;
            font-size: 24px;
            margin: 0;
        }

        .navbar-info {
            color: #666;
            font-size: 13px;
        }

        .container {
            max-width: 1200px;
            margin: 0 auto;
        }

        .tabs {
            display: flex;
            gap: 10px;
            margin-bottom: 20px;
            flex-wrap: wrap;
        }

        .tab-btn {
            padding: 12px 24px;
            border: 2px solid rgba(255,255,255,0.3);
            background: rgba(255,255,255,0.1);
            color: white;
            border-radius: 8px;
            cursor: pointer;
            font-weight: 600;
            transition: all 0.3s;
            font-size: 14px;
        }

        .tab-btn:hover {
            background: rgba(255,255,255,0.2);
            border-color: rgba(255,255,255,0.5);
        }

        .tab-btn.active {
            background: white;
            color: #667eea;
            border-color: white;
            box-shadow: 0 4px 15px rgba(0,0,0,0.2);
        }

        .content {
            background: white;
            border-radius: 12px;
            padding: 40px;
            box-shadow: 0 10px 40px rgba(0,0,0,0.15);
        }

        .tab-content {
            display: none;
        }

        .tab-content.active {
            display: block;
            animation: fadeIn 0.3s ease-in;
        }

        @keyframes fadeIn {
            from { opacity: 0; transform: translateY(10px); }
            to { opacity: 1; transform: translateY(0); }
        }

        .section-title {
            color: #667eea;
            font-size: 20px;
            margin-bottom: 20px;
            border-bottom: 2px solid #667eea;
            padding-bottom: 10px;
        }

        .form-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 15px;
            margin-bottom: 15px;
        }

        input {
            padding: 12px;
            border: 1px solid #ddd;
            border-radius: 6px;
            font-size: 14px;
            transition: all 0.3s;
            font-family: inherit;
        }

        input:focus {
            outline: none;
            border-color: #667eea;
            box-shadow: 0 0 0 3px rgba(102, 126, 234, 0.1);
        }

        input::placeholder {
            color: #999;
        }

        button {
            padding: 12px 24px;
            border: none;
            border-radius: 6px;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.25s;
            font-size: 14px;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }

        button:active {
            transform: scale(0.98);
        }

        button:disabled {
            opacity: 0.6;
            cursor: not-allowed;
        }

        .btn-primary { background: #667eea; color: white; }
        .btn-primary:hover:not(:disabled) { background: #5568d3; box-shadow: 0 5px 15px rgba(102, 126, 234, 0.3); }

        .btn-success { background: #48bb78; color: white; }
        .btn-success:hover:not(:disabled) { background: #38a169; box-shadow: 0 5px 15px rgba(72, 187, 120, 0.3); }

        .btn-danger { background: #f56565; color: white; }
        .btn-danger:hover:not(:disabled) { background: #e53e3e; box-shadow: 0 5px 15px rgba(245, 101, 101, 0.3); }

        .btn-info { background: #4299e1; color: white; }
        .btn-info:hover:not(:disabled) { background: #3182ce; box-shadow: 0 5px 15px rgba(66, 153, 225, 0.3); }

        .output {
            background: #f7fafc;
            border: 2px solid #e2e8f0;
            border-radius: 6px;
            padding: 20px;
            font-family: 'Courier New', monospace;
            font-size: 12px;
            max-height: 400px;
            overflow-y: auto;
            color: #2d3748;
            line-height: 1.6;
            white-space: pre-wrap;
            word-break: break-all;
            margin-top: 20px;
        }

        .output.success {
            border-color: #48bb78;
            background: #f0fff4;
            color: #22543d;
        }

        .output.error {
            border-color: #f56565;
            background: #fff5f5;
            color: #742a2a;
        }

        .spinner {
            display: inline-block;
            width: 14px;
            height: 14px;
            border: 2px solid #667eea;
            border-top-color: transparent;
            border-radius: 50%;
            animation: spin 0.6s linear infinite;
            margin-right: 8px;
        }

        @keyframes spin {
            to { transform: rotate(360deg); }
        }

        .users-table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 20px;
        }

        .users-table th {
            background: #f0f0f0;
            padding: 12px;
            text-align: left;
            font-weight: 600;
            color: #333;
            border-bottom: 2px solid #ddd;
        }

        .users-table td {
            padding: 12px;
            border-bottom: 1px solid #ddd;
        }

        .users-table tr:hover {
            background: #f9f9f9;
        }

        .action-btns {
            display: flex;
            gap: 8px;
        }

        .action-btns button {
            padding: 8px 12px;
            font-size: 12px;
            flex: 1;
        }

        .badge {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 20px;
            font-size: 12px;
            font-weight: 600;
        }

        .badge-success {
            background: #c6f6d5;
            color: #22543d;
        }

        .badge-danger {
            background: #fed7d7;
            color: #742a2a;
        }
    </style>
</head>
<body>
    <div class="navbar">
        <h1>👤 User Management System</h1>
        <div class="navbar-info">K8s + Cilium Demo Application</div>
    </div>

    <div class="container">
        <div class="tabs">
            <button class="tab-btn active" onclick="switchTab('signup')">📝 Sign Up</button>
            <button class="tab-btn" onclick="switchTab('login')">🔐 Login</button>
            <button class="tab-btn" onclick="switchTab('users')">👥 Users</button>
            <button class="tab-btn" onclick="switchTab('update')">✏️ Update</button>
            <button class="tab-btn" onclick="switchTab('delete')">🗑️ Delete</button>
        </div>

        <div class="content">
            <!-- SIGNUP TAB -->
            <div id="signup" class="tab-content active">
                <h2 class="section-title">Create New User Account</h2>
                <div class="form-grid">
                    <input type="text" id="signupUsername" placeholder="Username">
                    <input type="password" id="signupPassword" placeholder="Password">
                </div>
                <button class="btn-primary" onclick="signup()" id="signupBtn">Create Account</button>
                <div id="signupOutput" class="output"></div>
            </div>

            <!-- LOGIN TAB -->
            <div id="login" class="tab-content">
                <h2 class="section-title">Login to Your Account</h2>
                <div class="form-grid">
                    <input type="text" id="loginUsername" placeholder="Username">
                    <input type="password" id="loginPassword" placeholder="Password">
                </div>
                <button class="btn-success" onclick="login()" id="loginBtn">Login</button>
                <div id="loginOutput" class="output"></div>
            </div>

            <!-- USERS TAB -->
            <div id="users" class="tab-content">
                <h2 class="section-title">All Users</h2>
                <button class="btn-info" onclick="listUsers()" id="listBtn">Load Users</button>
                <div id="usersOutput" class="output"></div>
            </div>

            <!-- UPDATE TAB -->
            <div id="update" class="tab-content">
                <h2 class="section-title">Update User Information</h2>
                <div class="form-grid">
                    <input type="number" id="updateId" placeholder="User ID">
                    <input type="text" id="updateUsername" placeholder="New Username">
                </div>
                <button class="btn-primary" onclick="updateUser()" id="updateBtn">Update User</button>
                <div id="updateOutput" class="output"></div>
            </div>

            <!-- DELETE TAB -->
            <div id="delete" class="tab-content">
                <h2 class="section-title">Delete User Account</h2>
                <div class="form-grid">
                    <input type="number" id="deleteId" placeholder="User ID">
                </div>
                <button class="btn-danger" onclick="deleteUser()" id="deleteBtn">Delete User</button>
                <div id="deleteOutput" class="output"></div>
            </div>
        </div>
    </div>

    <script>
        const API_BASE = window.location.origin;

        function switchTab(tab) {
            document.querySelectorAll('.tab-content').forEach(el => el.classList.remove('active'));
            document.querySelectorAll('.tab-btn').forEach(el => el.classList.remove('active'));
            document.getElementById(tab).classList.add('active');
            event.target.classList.add('active');
        }

        function log(outputId, data, isError = false) {
            const output = document.getElementById(outputId);
            output.className = isError ? 'output error' : 'output success';
            output.textContent = typeof data === 'string' ? data : JSON.stringify(data, null, 2);
        }

        function setLoading(btnId, loading) {
            const button = document.getElementById(btnId);
            button.disabled = loading;
            if (loading) {
                button.innerHTML = '<span class="spinner"></span>Processing...';
            } else {
                button.innerHTML = button.dataset.original || button.textContent;
            }
        }

        document.querySelectorAll('button[onclick]').forEach(btn => {
            btn.dataset.original = btn.innerHTML;
        });

        async function signup() {
            const username = document.getElementById('signupUsername').value.trim();
            const password = document.getElementById('signupPassword').value.trim();
            
            if (!username || !password) {
                log('signupOutput', '⚠️ Enter username and password', true);
                return;
            }
            
            setLoading('signupBtn', true);
            try {
                const res = await fetch(`${API_BASE}/signup`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ username, password })
                });
                const data = await res.json();
                log('signupOutput', data, res.status !== 201);
                if (res.ok) {
                    document.getElementById('signupUsername').value = '';
                    document.getElementById('signupPassword').value = '';
                }
            } catch (e) {
                log('signupOutput', `❌ Error: ${e.message}`, true);
            } finally {
                setLoading('signupBtn', false);
            }
        }

        async function login() {
            const username = document.getElementById('loginUsername').value.trim();
            const password = document.getElementById('loginPassword').value.trim();
            
            if (!username || !password) {
                log('loginOutput', '⚠️ Enter username and password', true);
                return;
            }
            
            setLoading('loginBtn', true);
            try {
                const res = await fetch(`${API_BASE}/login`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ username, password })
                });
                const data = await res.json();
                log('loginOutput', data, res.status !== 200);
            } catch (e) {
                log('loginOutput', `❌ Error: ${e.message}`, true);
            } finally {
                setLoading('loginBtn', false);
            }
        }

        async function listUsers() {
            setLoading('listBtn', true);
            try {
                const res = await fetch(`${API_BASE}/users`);
                const data = await res.json();
                log('usersOutput', data, res.status !== 200);
            } catch (e) {
                log('usersOutput', `❌ Error: ${e.message}`, true);
            } finally {
                setLoading('listBtn', false);
            }
        }

        async function updateUser() {
            const id = document.getElementById('updateId').value.trim();
            const username = document.getElementById('updateUsername').value.trim();
            
            if (!id || !username) {
                log('updateOutput', '⚠️ Enter user ID and new username', true);
                return;
            }
            
            setLoading('updateBtn', true);
            try {
                const res = await fetch(`${API_BASE}/user/${id}`, {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ username })
                });
                const data = await res.json();
                log('updateOutput', data, res.status !== 200);
                if (res.ok) {
                    document.getElementById('updateId').value = '';
                    document.getElementById('updateUsername').value = '';
                }
            } catch (e) {
                log('updateOutput', `❌ Error: ${e.message}`, true);
            } finally {
                setLoading('updateBtn', false);
            }
        }

        async function deleteUser() {
            const id = document.getElementById('deleteId').value.trim();
            
            if (!id) {
                log('deleteOutput', '⚠️ Enter user ID', true);
                return;
            }
            
            if (!confirm('Are you sure you want to delete this user?')) return;
            
            setLoading('deleteBtn', true);
            try {
                const res = await fetch(`${API_BASE}/user/${id}`, {
                    method: 'DELETE'
                });
                const data = await res.json();
                log('deleteOutput', data, res.status !== 200);
                if (res.ok) {
                    document.getElementById('deleteId').value = '';
                }
            } catch (e) {
                log('deleteOutput', `❌ Error: ${e.message}`, true);
            } finally {
                setLoading('deleteBtn', false);
            }
        }
    </script>
</body>
</html>
HTML

cat > frontend/nginx.conf <<'CONF'
server {
    listen 80;
    
    location / {
        root /usr/share/nginx/html;
        index index.html;
        try_files $uri /index.html;
    }
    
    location /signup {
        proxy_pass http://app-backend.app.svc.cluster.local:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 30s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
    }
    
    location /login {
        proxy_pass http://app-backend.app.svc.cluster.local:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 30s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
    }
    
    location /users {
        proxy_pass http://app-backend.app.svc.cluster.local:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 30s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
    }
    
    location /user/ {
        proxy_pass http://app-backend.app.svc.cluster.local:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 30s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
    }
}
CONF

cat > frontend/Dockerfile <<'DFILE'
FROM nginx:alpine
COPY index.html /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/conf.d/default.conf
DFILE

# ============== BUILD & PUSH ==============
echo "🐳 Building & pushing images..."
podman build -t app-db:v1 db && podman tag app-db:v1 ${BASE}/app-db:v1 && podman push ${BASE}/app-db:v1
podman build -t app-backend:v1 backend && podman tag app-backend:v1 ${BASE}/app-backend:v1 && podman push ${BASE}/app-backend:v1
podman build -t app-frontend:v1 frontend && podman tag app-frontend:v1 ${BASE}/app-frontend:v1 && podman push ${BASE}/app-frontend:v1

echo "✅ Done!"
echo "   - ${BASE}/app-db:v1"
echo "   - ${BASE}/app-backend:v1"
echo "   - ${BASE}/app-frontend:v1"

