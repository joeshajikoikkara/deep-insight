const mysql = require("mysql2/promise");

let pool;

function getRequiredEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function getPool() {
  if (!pool) {
    pool = mysql.createPool({
      host: getRequiredEnv("MYSQL_HOST"),
      port: Number(process.env.MYSQL_PORT || 3306),
      user: getRequiredEnv("MYSQL_USER"),
      password: getRequiredEnv("MYSQL_PASSWORD"),
      database: getRequiredEnv("MYSQL_DATABASE"),
      waitForConnections: true,
      connectionLimit: Number(process.env.MYSQL_POOL_LIMIT || 10),
      queueLimit: 0
    });
  }
  return pool;
}

module.exports = { getPool };
