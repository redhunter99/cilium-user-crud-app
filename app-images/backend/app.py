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
