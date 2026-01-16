CREATE DATABASE IF NOT EXISTS usersdb;
USE usersdb;
CREATE TABLE users (
  id INT AUTO_INCREMENT PRIMARY KEY,
  username VARCHAR(100) UNIQUE,
  password VARCHAR(100)
);
INSERT INTO users (username, password) VALUES ('admin', 'admin123');
