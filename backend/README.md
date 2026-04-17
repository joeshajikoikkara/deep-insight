# Deep Insight Backend (Node.js + MySQL)

## Setup

1. Go to backend folder:
   `cd backend`
2. Create env file:
   `cp .env.example .env`
3. Edit `.env` with your MySQL credentials and table name.
4. Start server:
   `npm start`

## API

- `GET /health` - Checks API + DB connectivity
- `GET /api/records?limit=50&offset=0` - Pulls rows from `MYSQL_TABLE`
- `GET /api/records/:id` - Pulls a single row by `MYSQL_PRIMARY_KEY`
- `GET /api/results/dashboard?classId=301&examId=202601` - Aggregated dashboard data from `RESULTS_DATABASE`
- `GET /api/results/insight-summary?classId=301&examId=202601` - AI-generated summary from class dashboard data
- `POST /api/results/action-point` - Save/update action point (privileged users only)
- `POST /api/openai/chat` - Sends a prompt to OpenAI and returns model output

Example:

```bash
curl -X POST http://localhost:3000/api/openai/chat \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Summarize this in one line: Deep Insight data service"}'
```

## Notes

- `MYSQL_TABLE` and `MYSQL_PRIMARY_KEY` are required for data endpoints.
- `RESULTS_DATABASE` defaults to `DI` for result dashboard endpoints.
- The API uses a pooled MySQL connection via `mysql2/promise`.
- Set `OPENAI_API_KEY` in `.env` for OpenAI integration.
- Set `ACTION_POINT_EDITOR_EMAILS` in `.env` (comma-separated emails, or `*` for all) to control who can edit action points.
