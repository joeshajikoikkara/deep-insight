require("dotenv").config();

const express = require("express");
const cors = require("cors");
const { getPool } = require("./db");

const app = express();
const port = Number(process.env.PORT || 3000);

app.use(cors());
app.use(express.json());

function quoteIdentifier(identifier, label) {
  if (!identifier || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(identifier)) {
    throw new Error(`Invalid ${label}: ${identifier || "<empty>"}`);
  }
  return `\`${identifier}\``;
}

function getTableConfig() {
  const table = quoteIdentifier(process.env.MYSQL_TABLE, "MYSQL_TABLE");
  const primaryKey = quoteIdentifier(
    process.env.MYSQL_PRIMARY_KEY || "id",
    "MYSQL_PRIMARY_KEY"
  );
  return { table, primaryKey };
}

function getResultsDbName() {
  return quoteIdentifier(process.env.RESULTS_DATABASE || "DI", "RESULTS_DATABASE");
}

function getActionPointEditors() {
  const raw = (process.env.ACTION_POINT_EDITOR_EMAILS || "").trim();
  if (!raw) {
    return [];
  }
  return raw
    .split(",")
    .map((item) => item.trim().toLowerCase())
    .filter(Boolean);
}

function canEditActionPoint(userEmail) {
  const normalizedEmail =
    typeof userEmail === "string" ? userEmail.trim().toLowerCase() : "";
  if (!normalizedEmail) {
    return false;
  }

  const editors = getActionPointEditors();
  if (editors.includes("*")) {
    return true;
  }
  return editors.includes(normalizedEmail);
}

async function ensureInsightTable(pool, resultsDb) {
  await pool.query(
    `CREATE TABLE IF NOT EXISTS ${resultsDb}.class_insight_action_points (
      id INT(11) NOT NULL AUTO_INCREMENT,
      class_id INT(11) NOT NULL,
      exam_id INT(11) NOT NULL,
      summary_text TEXT DEFAULT NULL,
      action_point_text TEXT DEFAULT NULL,
      created_by VARCHAR(255) DEFAULT NULL,
      modified_by VARCHAR(255) DEFAULT NULL,
      created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
      PRIMARY KEY (id),
      UNIQUE KEY uq_class_exam (class_id, exam_id)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`
  );
}

async function generateInsightSummary(dashboard) {
  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    throw new Error("Missing OPENAI_API_KEY. Add it to backend .env.");
  }

  const model = process.env.OPENAI_MODEL || "gpt-4.1-mini";
  const prompt = `
You are an academic analytics assistant.
Create a concise class performance insight summary from the JSON data below.
Output plain text only with:
1) one short overall summary line
2) 3 bullet points
Do not include an Action line.

Data:
${JSON.stringify(dashboard, null, 2)}
`.trim();

  const openAIResponse = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      model,
      messages: [{ role: "user", content: prompt }],
      temperature: 0.3
    })
  });

  const payload = await openAIResponse.json();
  if (!openAIResponse.ok) {
    const error = new Error("OpenAI API request failed");
    error.statusCode = openAIResponse.status;
    error.payload = payload;
    throw error;
  }

  return {
    model,
    summary: payload?.choices?.[0]?.message?.content?.trim() || ""
  };
}

async function fetchResultsDashboard(pool, resultsDb, classId, examId) {
  const [summaryRows] = await pool.query(
    `SELECT
       COUNT(*) AS totalStudents,
       SUM(CASE WHEN UPPER(COALESCE(result, '')) = 'PASS' THEN 1 ELSE 0 END) AS passedStudents,
       ROUND(AVG(CAST(NULLIF(grade_point_ave, '') AS DECIMAL(6,2))), 2) AS averageGPA,
       MAX(CAST(NULLIF(grade_point_ave, '') AS DECIMAL(6,2))) AS topGPA,
       MAX(course_name) AS courseName,
       MAX(term_number) AS termNumber,
       MAX(month_and_year) AS monthAndYear
     FROM ${resultsDb}.student_semester_marks_card
     WHERE class_id = ? AND exam_id = ?`,
    [classId, examId]
  );

  const summary = summaryRows[0] || {};
  const totalStudents = Number(summary.totalStudents || 0);
  const passedStudents = Number(summary.passedStudents || 0);
  const averageGPA = Number(summary.averageGPA || 0);
  const topGPA = Number(summary.topGPA || 0);
  const passPercentage = totalStudents > 0 ? (passedStudents / totalStudents) * 100 : 0;

  const [topperRows] = await pool.query(
    `SELECT
       first_name AS name,
       register_no AS registerNo,
       CAST(NULLIF(grade_point_ave, '') AS DECIMAL(6,2)) AS gpa
     FROM ${resultsDb}.student_semester_marks_card
     WHERE class_id = ? AND exam_id = ?
     ORDER BY gpa DESC, id ASC
     LIMIT 3`,
    [classId, examId]
  );

  const [subjectRows] = await pool.query(
    `SELECT
       subject_name AS subjectName,
       ROUND(AVG(CAST(NULLIF(total_marks_awarded, '') AS DECIMAL(6,2))), 1) AS averageMark
     FROM ${resultsDb}.student_semester_marks_card_details
     WHERE class_id = ? AND exam_id = ?
     GROUP BY subject_name
     ORDER BY MIN(subject_order) ASC`,
    [classId, examId]
  );

  return {
    classId,
    examId,
    className: summary.termNumber || `Class ${classId}`,
    examName: summary.monthAndYear || `Exam ${examId}`,
    courseName: summary.courseName || "Results",
    totalStudents,
    passedStudents,
    passPercentage: Number(passPercentage.toFixed(1)),
    averageGPA,
    topGPA,
    toppers: topperRows.map((row) => ({
      name: row.name || "-",
      registerNo: row.registerNo || "-",
      gpa: Number(row.gpa || 0)
    })),
    subjectAverages: subjectRows.map((row) => ({
      subjectName: row.subjectName || "-",
      averageMark: Number(row.averageMark || 0)
    }))
  };
}

app.get("/health", async (_req, res) => {
  try {
    const pool = getPool();
    await pool.query("SELECT 1");
    res.json({ status: "ok" });
  } catch (error) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

app.get("/api/records", async (req, res) => {
  try {
    const pool = getPool();
    const { table } = getTableConfig();

    const limit = Math.min(Math.max(Number(req.query.limit || 50), 1), 500);
    const offset = Math.max(Number(req.query.offset || 0), 0);

    const [rows] = await pool.query(
      `SELECT * FROM ${table} LIMIT ? OFFSET ?`,
      [limit, offset]
    );

    res.json({ count: rows.length, data: rows, limit, offset });
  } catch (error) {
    res.status(500).json({ message: error.message });
  }
});

app.get("/api/records/:id", async (req, res) => {
  try {
    const pool = getPool();
    const { table, primaryKey } = getTableConfig();

    const [rows] = await pool.query(
      `SELECT * FROM ${table} WHERE ${primaryKey} = ? LIMIT 1`,
      [req.params.id]
    );

    if (rows.length === 0) {
      return res.status(404).json({ message: "Record not found" });
    }

    return res.json(rows[0]);
  } catch (error) {
    return res.status(500).json({ message: error.message });
  }
});

app.post("/api/openai/chat", async (req, res) => {
  try {
    const apiKey = process.env.OPENAI_API_KEY;
    if (!apiKey) {
      return res.status(400).json({
        message: "Missing OPENAI_API_KEY. Add it to backend .env."
      });
    }

    const prompt = typeof req.body?.prompt === "string" ? req.body.prompt.trim() : "";
    if (!prompt) {
      return res.status(400).json({ message: "Request body must include a non-empty 'prompt'." });
    }

    const model =
      typeof req.body?.model === "string" && req.body.model.trim()
        ? req.body.model.trim()
        : process.env.OPENAI_MODEL || "gpt-4.1-mini";

    const openAIResponse = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        model,
        messages: [{ role: "user", content: prompt }]
      })
    });

    const payload = await openAIResponse.json();
    if (!openAIResponse.ok) {
      return res.status(openAIResponse.status).json({
        message: "OpenAI API request failed",
        error: payload
      });
    }

    const content = payload?.choices?.[0]?.message?.content ?? "";
    return res.json({
      model,
      content,
      raw: payload
    });
  } catch (error) {
    return res.status(500).json({ message: error.message });
  }
});

app.get("/api/results/dashboard", async (req, res) => {
  try {
    const pool = getPool();
    const resultsDb = getResultsDbName();
    const classId = Number(req.query.classId || 301);
    const examId = Number(req.query.examId || 202601);

    if (!Number.isInteger(classId) || !Number.isInteger(examId)) {
      return res.status(400).json({ message: "classId and examId must be integers" });
    }

    const dashboard = await fetchResultsDashboard(pool, resultsDb, classId, examId);
    return res.json(dashboard);
  } catch (error) {
    return res.status(500).json({ message: error.message });
  }
});

app.get("/api/results/insight-summary", async (req, res) => {
  try {
    const pool = getPool();
    const resultsDb = getResultsDbName();
    const classId = Number(req.query.classId || 301);
    const examId = Number(req.query.examId || 202601);
    const forceRefresh = req.query.forceRefresh === "1";
    const userEmail =
      typeof req.query.userEmail === "string" ? req.query.userEmail.trim() : "";
    const canEdit = canEditActionPoint(userEmail);

    if (!Number.isInteger(classId) || !Number.isInteger(examId)) {
      return res.status(400).json({ message: "classId and examId must be integers" });
    }

    await ensureInsightTable(pool, resultsDb);
    const dashboard = await fetchResultsDashboard(pool, resultsDb, classId, examId);
    const [storedRows] = await pool.query(
      `SELECT summary_text AS summary, action_point_text AS actionPoint
       FROM ${resultsDb}.class_insight_action_points
       WHERE class_id = ? AND exam_id = ?
       LIMIT 1`,
      [classId, examId]
    );

    let summary = storedRows[0]?.summary || "";
    let actionPoint = storedRows[0]?.actionPoint || "";
    let model = process.env.OPENAI_MODEL || "gpt-4.1-mini";

    if (!summary || forceRefresh) {
      try {
        const generated = await generateInsightSummary(dashboard);
        summary = generated.summary;
        model = generated.model;
      } catch (error) {
        if (error.statusCode) {
          return res.status(error.statusCode).json({
            message: error.message,
            error: error.payload
          });
        }
        throw error;
      }

      await pool.query(
        `INSERT INTO ${resultsDb}.class_insight_action_points
           (class_id, exam_id, summary_text, action_point_text, created_by, modified_by)
         VALUES (?, ?, ?, ?, ?, ?)
         ON DUPLICATE KEY UPDATE
           summary_text = VALUES(summary_text),
           action_point_text = COALESCE(NULLIF(action_point_text, ''), VALUES(action_point_text)),
           modified_by = VALUES(modified_by),
           updated_at = CURRENT_TIMESTAMP`,
        [classId, examId, summary, actionPoint, userEmail || null, userEmail || null]
      );
    }

    return res.json({
      classId,
      examId,
      model,
      summary,
      actionPoint,
      canEditActionPoint: canEdit
    });
  } catch (error) {
    return res.status(500).json({ message: error.message });
  }
});

app.post("/api/results/action-point", async (req, res) => {
  try {
    const pool = getPool();
    const resultsDb = getResultsDbName();
    const classId = Number(req.body?.classId);
    const examId = Number(req.body?.examId);
    const actionPoint =
      typeof req.body?.actionPoint === "string" ? req.body.actionPoint.trim() : "";
    const userEmail =
      typeof req.body?.userEmail === "string" ? req.body.userEmail.trim() : "";

    if (!Number.isInteger(classId) || !Number.isInteger(examId)) {
      return res.status(400).json({ message: "classId and examId must be integers" });
    }

    if (!canEditActionPoint(userEmail)) {
      return res.status(403).json({ message: "You do not have permission to edit action points." });
    }

    await ensureInsightTable(pool, resultsDb);
    await pool.query(
      `INSERT INTO ${resultsDb}.class_insight_action_points
         (class_id, exam_id, action_point_text, created_by, modified_by)
       VALUES (?, ?, ?, ?, ?)
       ON DUPLICATE KEY UPDATE
         action_point_text = VALUES(action_point_text),
         modified_by = VALUES(modified_by),
         updated_at = CURRENT_TIMESTAMP`,
      [classId, examId, actionPoint, userEmail || null, userEmail || null]
    );

    return res.json({
      classId,
      examId,
      actionPoint,
      updatedBy: userEmail || null
    });
  } catch (error) {
    return res.status(500).json({ message: error.message });
  }
});

app.listen(port, () => {
  console.log(`Backend running on http://localhost:${port}`);
});
