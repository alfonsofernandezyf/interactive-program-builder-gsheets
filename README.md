Interactive Program Builder — v2.2.1

Build and validate a conference program JSON from Excel/CSV or Google Sheets.
Flexible column mapping per sheet (Program / Faculty / Sponsors), automatic time normalization, duplicate detection, and sponsor logo enrichment.

Highlights

Flexible column mapping per sheet (you decide which columns map to fields).

Google Sheets import: paste a share link (prefer “Publish to the web”).

Sponsor enrichment: program rows accept sponsor fields (sponsor, sponsor_name, sponsored_by, sponsor_id, sponsor_logo). On preview/build, sessions are enriched with sponsor_logo by matching sponsor_id or normalized sponsor name against the Sponsors sheet.

Time normalization (e.g., 11-30 → 11:30, 14:50: 15:10 → 14:50 - 15:10).

Validation: malformed rows, missing/duplicate IDs, unknown time formats, empty rows dropped, (time,title) duplicate detection within a day.

Output: JSON keyed by day (e.g., educational_day, october_16, october_17, october_18) plus optional faculty and sponsors.

Project Structure (suggested)
interactive-program-builder/
├─ backend/                 # FastAPI service (upload, fetch, preview, build)
│  ├─ app.py
│  ├─ processors.py
│  ├─ validators.py
│  ├─ requirements.txt
│  └─ .env.example
├─ frontend/                # Mapping UI (HTML/JS), talks to backend
│  ├─ index.html
│  └─ index.js
├─ embed/                   # Standalone viewer (Shadow DOM) for WordPress
│  └─ lasid-program-embed.html
├─ public/
│  ├─ program.sample.json   # Example output
│  └─ index.html            # Local demo of the viewer (optional)
└─ README.md

Run
# Backend
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
uvicorn app:app --reload


The API will be available at http://127.0.0.1:8000/.

If you serve the frontend from a different origin (e.g. a local file or a dev server), allow that origin in CORS (see below).

Frontend (mapping UI)
Open frontend/index.html in a browser or serve it with a simple static server.
If your backend isn’t on the same origin, set the API base URL in index.html/index.js (e.g., const API_BASE = "http://127.0.0.1:8000";).

Environment / CORS

Create backend/.env (optional) to tweak CORS/limits:

ALLOWED_ORIGINS=http://127.0.0.1:5500,http://localhost:5173
MAX_UPLOAD_MB=10


Make sure app.py reads ALLOWED_ORIGINS and configures CORSMiddleware accordingly.

Workflow

Upload a file (XLSX/CSV) or paste a Google Sheets share link.

Map columns for each sheet:

Mark sheet type: program | faculty | sponsors

Map fields (time, title, speaker, chair, track, room, type, notes, id, sponsor fields, etc.)

For program sheets, set the Day key (educational_day, october_16, etc.) — either one day per sheet or via a “day” column.

Click Preview & Validate to see normalized JSON, warnings, and errors.

Fix mappings or source data until clean.

Click Build JSON to export the final JSON.

Google Sheets

Recommended: File → Share → Anyone with the link (Viewer) or File → Publish to the web.

Accepted link patterns:

https://docs.google.com/spreadsheets/d/<SHEET_ID>/edit...

The backend will try:

export?format=xlsx (single file, all sheets)

or gviz API / CSV if published.

If you see 403/recaptcha from Google, use Publish to the web or download as XLSX and upload the file.

API
POST /api/upload

Upload Excel/CSV.

Content-Type: multipart/form-data

Field: file (the spreadsheet)

Response

{
  "sheets": [
    {
      "name": "october_16",
      "columns": ["Time", "Title", "Speaker", "Chair", "Room", "Sponsor ID", "Sponsor"],
      "guess": { "time":"Time", "title":"Title", "speaker":"Speaker", "chair":"Chair" }
    }
  ]
}

POST /api/fetch_google

Fetch a Google Sheets document.

Body:

{ "url": "https://docs.google.com/spreadsheets/d/XXXX/edit?usp=sharing" }


Response: same shape as /api/upload.

POST /api/preview

Build a normalized JSON without writing files.

Body (example):

{
  "sheets": [
    {
      "name": "october_16",
      "type": "program",
      "day_key": "october_16",
      "mapping": {
        "id": "ID",
        "time": "Time",
        "title": "Title",
        "speaker": "Speaker(s)",
        "chair": "Chair",
        "track": "Track",
        "room": "Room",
        "type": "Type",
        "notes": "Notes",
        "sponsor_id": "Sponsor ID",
        "sponsor_name": "Sponsor"
      },
      "options": {
        "speaker_split": ",",      // optional: split speaker string to array
        "trim_cells": true
      }
    },
    {
      "name": "sponsors",
      "type": "sponsors",
      "mapping": {
        "id": "ID",
        "name": "Name",
        "logo": "Logo URL"
      }
    }
  ]
}


Response

{
  "json": { /* normalized JSON, grouped by day + faculty/sponsors (if any) */ },
  "warnings": [
    "[october_16] Unrecognized time format: '11:10 - 11-30'",
    "[educational_day] Duplicate (time,title): | EDUCATIONAL DAY"
  ],
  "errors": []
}

POST /api/build

Same input as /api/preview, but returns the final JSON (and may also persist a file depending on your implementation).

Mapping Reference
Program sheet (type: "program")

Recommended fields:

id (string, unique across all sessions)

time (e.g. 09:00 - 09:30, 14:50–15:10; normalization handles common typos)

title

speaker (string or list; you can split by , or ;)

chair (moderator)

track, room, type, notes

Sponsor fields (any of these):

sponsor_id

sponsor_name (or sponsor/sponsored_by)

sponsor_logo (direct URL; overrides logo enrichment)

Day assignment:

via day_key per sheet (e.g., all rows map to october_16), or

map a day column and let the backend group (requires enabling that mode).

Sponsors sheet (type: "sponsors")

id (string)

name

logo (URL to image)

Faculty sheet (type: "faculty")

id, name, bio, photo (URL), optionally affiliation, email (not required by the viewer)

Output JSON (example)
{
  "educational_day": [
    {
      "id": "ed-101",
      "time": "09:00 - 09:30",
      "title": "Welcome & Opening",
      "speaker": ["Name A", "Name B"],
      "chair": "Dr. X",
      "track": "Main Hall",
      "room": "Auditorium",
      "type": "Keynote",
      "notes": "",
      "sponsor_logo": "https://cdn.example.com/logos/acme.png"
    }
  ],
  "october_16": [ /* ... */ ],
  "october_17": [ /* ... */ ],
  "october_18": [ /* ... */ ],
  "faculty": [
    { "id":"spk-1", "name":"Name A", "bio":"...", "photo":"https://..." }
  ],
  "sponsors": [
    { "id":"sp-1", "name":"Acme", "logo":"https://..." }
  ]
}


Notes

A “day” is any top-level key whose value is an array of sessions (objects with at least title or time).

speaker may be output as a list (if you split it) or as a string (if you don’t).

sponsor_logo is set from the row if provided; otherwise it is enriched from the Sponsors sheet by sponsor_id or normalized name.

Validations & Normalization

Time: trims spaces; standardizes separators (-, –, —, : punctuation); tries to coerce to HH:MM or HH:MM - HH:MM. Unknown formats yield warnings.

Empty rows: dropped (rows with no time and no title).

Duplicates: detects repeated (time,title) within the same day; warns.

NaN / floats: treated as empty (prevents .strip() errors).

IDs: warns on missing or duplicate id in Program/Faculty/Sponsors.

Sponsor enrichment:

Match sponsor_id with sponsors.id.

Else, match normalized sponsor_name with sponsors.name.

If both fail and the row has sponsor_logo, that value is used; otherwise no logo.

Troubleshooting

405 Method Not Allowed on /api/upload
Ensure you are using POST with multipart/form-data and the field name is file.

AttributeError: 'float' object has no attribute 'strip'
Fixed in v2.2.1 by coercing non-strings to "" before trimming. Upgrade and retry.

Unrecognized time format warnings
The normalizer auto-fixes common typos (11-30 → 11:30, 14:50: 15:10 → 14:50 - 15:10). Edit outliers in your sheet or map a custom column.

Preview returns {}
Make sure you:

Selected at least one Program sheet,

Mapped title or time, and

Assigned a day (either day_key per sheet or a day column).

Google Sheets 500 / CAPTCHA
Use Publish to the web or download XLSX and use /api/upload. Ensure “Anyone with the link → Viewer”.

CORS error
Add your frontend origin to ALLOWED_ORIGINS (comma-separated) and restart the backend.

Viewer Embed (WordPress)

Use embed/lasid-program-embed.html in a Custom HTML block.
Edit the line:

const JSON_URL = "https://your-site/wp-content/uploads/json/program_lasid_2025_updated.json";


Styles/colors live inside the embed (Shadow DOM).

Sponsor logos are shown at the bottom-right of each card with max-height: 32px.

Favorite sessions persist in localStorage under lasid_favs.

Release Notes

v2.2.1

Robust type coercion (no .strip() on floats).

Time normalization expanded (handles 11-30, 14:50: 15:10, en-dash, em-dash).

Sponsor enrichment by sponsor_id or normalized name.

Better warnings for duplicates/unknown time formats.

Roadmap

WordPress plugin: admin settings (JSON URL), style overrides, auto-refresh from Sheets.

Authenticated Sheets fetch (Service Account).

CLI: batch build from XLSX to JSON.

i18n for validator messages.

License

MIT (see LICENSE if included).

# Interactive Program Builder — v2.2.1

Highlights
- Program rows accept sponsor fields (`sponsor`, `sponsor_name`, `sponsored_by`, `sponsor_id`, `sponsor_logo`).
- On preview/build, sessions are enriched with `sponsor_logo` by matching `sponsor_id` or sponsor `name` with a sponsors sheet.
- Time normalization (e.g., `11-30` → `11:30`, `14:50: 15:10` → `14:50 - 15:10`).

## Run
```bash
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
uvicorn app:app --reload
