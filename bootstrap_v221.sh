#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
echo "Bootstrap in $ROOT"

mkdir -p backend frontend tests

cat > backend/requirements.txt <<'EOF'
fastapi==0.115.0
uvicorn==0.30.6
pandas==2.2.2
openpyxl==3.1.5
python-multipart==0.0.9
pydantic==2.8.2
requests==2.32.3
pytest==8.3.2
EOF

cat > backend/models.py <<'EOF'
from typing import Dict, List, Optional, Any
from pydantic import BaseModel, Field

class SheetMapping(BaseModel):
    name: str
    key: str
    slug: str
    date_label: Optional[str] = ""
    sheet_type: str = Field(default="program", description="program|faculty|sponsors")
    id_strategy: str = Field(default="slug-index", description="slug-index | uid-column")
    uid_column: Optional[str] = None
    mapping: Dict[str, Optional[str]] = Field(default_factory=dict)
    options: Dict[str, Any] = Field(default_factory=lambda: {
        "chair_from_speaker": True,
        "chair_prefix_regex": r"^\s*chair:?\s*",
        "split_speakers_by": None,
    })

class BuildConfig(BaseModel):
    sheets: List[SheetMapping]

class PreviewResponse(BaseModel):
    data: Dict[str, List[Dict[str, Any]]]
    warnings: List[str] = []
    errors: List[str] = []

class GoogleFetchRequest(BaseModel):
    url: str
EOF

cat > backend/processors.py <<'EOF'
import os
import re
from typing import Dict, List, Any, Tuple
import pandas as pd

DEFAULT_TARGET_FIELDS = [
    "time","title","speaker","chair","track","type","room","notes",
    "sponsor","sponsor_name","sponsored_by","sponsor_id","sponsor_logo"
]

def slugify(text: str) -> str:
    text = re.sub(r'[^a-zA-Z0-9]+', '-', str(text).strip().lower())
    return re.sub(r'-{2,}', '-', text).strip('-')

def clean_str(x) -> str:
    if pd.isna(x):
        return ""
    return str(x).strip()

def normalize_time(raw) -> str:
    if raw is None:
        return ""
    s = str(raw).strip()
    if not s or s.lower() == "nan":
        return ""
    s = s.replace("–", "-").replace("—", "-")
    if re.match(r'^\d{1,2}:\d{2}$', s):
        return re.sub(r'^(\d{1,2}):(\d{2})$', lambda m: f"{int(m.group(1)):02d}:{m.group(2)}", s)
    token_re = re.compile(r'(\d{1,2})\s*[:.\-h]\s*(\d{2})')
    tokens = token_re.findall(s)
    if not tokens:
        m = re.match(r'^(\d{1,2})(\d{2})$', s)
        if m:
            return f"{int(m.group(1)):02d}:{m.group(2)}"
        return ""
    norm = [f"{int(h):02d}:{m}" for (h,m) in tokens[:2]]
    if len(norm) == 1:
        return norm[0]
    return f"{norm[0]} - {norm[1]}"

def guess_columns(df: pd.DataFrame) -> Dict[str, str]:
    lower_cols = {str(c).strip().lower(): c for c in df.columns}
    mapping = {}
    candidates_map = {
        "time":   ["hora","horario","time","schedule","start","start time","inicio"],
        "title":  ["tema","título","titulo","title","subject","session","topic"],
        "speaker":["ponente","speaker","presenter","author","speakers"],
        "chair":  ["chair","moderator","chairperson","moderador"],
        "track":  ["track","room","salon","salón","track/room"],
        "type":   ["type","session type","category","categoría"],
        "room":   ["room","salon","salón"],
        "notes":  ["notes","note","remarks","comentarios","notas"],
        "sponsor":       ["sponsor","patrocinador","sponsored by","sponsored_by","sponsor name","sponsor_name"],
        "sponsor_name":  ["sponsor name","sponsor_name","patrocinador"],
        "sponsored_by":  ["sponsored by","sponsored_by","patrocinador"],
        "sponsor_id":    ["sponsor id","sponsor_id","id patrocinador","id sponsor","sponsor code","sponsor_code"],
        "sponsor_logo":  ["sponsor logo","sponsor_logo","logo sponsor","logo patrocinador","logo"]
    }
    for target, candidates in candidates_map.items():
        for cand in candidates:
            key = cand.lower()
            if key in lower_cols:
                mapping[target] = lower_cols[key]
                break
    return mapping

def load_spreadsheet(path: str) -> Dict[str, pd.DataFrame]:
    ext = os.path.splitext(path)[1].lower()
    if ext in (".xlsx",".xlsm",".xls"):
        xl = pd.ExcelFile(path)
        return {name: xl.parse(name) for name in xl.sheet_names}
    elif ext == ".csv":
        df = pd.read_csv(path)
        return {os.path.basename(path): df}
    else:
        raise ValueError(f"Unsupported file type: {ext}")

def resolve_column(df: pd.DataFrame, col_name):
    if col_name is None or col_name == "":
        return None
    if col_name in df.columns:
        return col_name
    for c in df.columns:
        if str(c).strip() == str(col_name).strip():
            return c
    return None

def apply_mapping(df: pd.DataFrame, mapping: Dict[str, str]) -> pd.DataFrame:
    out = pd.DataFrame()
    for target, col in mapping.items():
        resolved = resolve_column(df, col)
        if resolved is not None:
            out[target] = df[resolved].apply(clean_str)
        else:
            out[target] = ""
    for t in DEFAULT_TARGET_FIELDS:
        if t not in out.columns:
            out[t] = ""
    return out

def extract_chair_and_speaker(row: pd.Series, chair_from_speaker: bool, chair_prefix_regex: str) -> Tuple[str, str]:
    speaker = row.get("speaker", "") or ""
    chair = row.get("chair", "") or ""
    if chair_from_speaker and speaker:
        m = re.match(chair_prefix_regex, speaker, flags=re.I)
        if m:
            chair = re.sub(chair_prefix_regex, "", speaker, flags=re.I).strip()
            speaker = ""
    return chair, speaker

def split_speakers(speaker: str, delim: str | None):
    if not speaker:
        return ""
    if delim:
        parts = [s.strip() for s in speaker.split(delim) if s.strip()]
        return parts
    return speaker

def build_sessions(df: pd.DataFrame, slug: str, mapping: Dict[str, str], options: Dict[str, Any], id_strategy: str, uid_column: str | None) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for idx, _ in df.iterrows():
        r = df.loc[idx]
        chair, speaker = extract_chair_and_speaker(r, options.get("chair_from_speaker", True), options.get("chair_prefix_regex", r"^\s*chair:?\s*"))
        speaker_val = split_speakers(speaker, options.get("split_speakers_by"))
        item = {
            "time": normalize_time(r.get("time", "")),
            "title": r.get("title", ""),
            "speaker": speaker_val,
            "chair": chair,
            "track": r.get("track", ""),
            "type": r.get("type", ""),
            "room": r.get("room", ""),
            "notes": r.get("notes", ""),
            "sponsor": r.get("sponsor", "") or r.get("sponsor_name","") or r.get("sponsored_by",""),
            "sponsor_name": r.get("sponsor_name", ""),
            "sponsored_by": r.get("sponsored_by", ""),
            "sponsor_id": r.get("sponsor_id", ""),
            "sponsor_logo": r.get("sponsor_logo", ""),
        }
        if id_strategy == "uid-column" and uid_column and uid_column in df.columns and r.get(uid_column):
            item_id = slugify(r.get(uid_column))
        else:
            item_id = f"{slug}-{idx}"
        item["id"] = item_id
        if any(str(item.get(k, "")).strip() for k in ["time","title","speaker","chair","track","type","room","notes","sponsor","sponsor_logo"]):
            rows.append(item)
    return rows

def build_generic_items(df: pd.DataFrame, keep_fields: List[str], slug: str, id_strategy: str, uid_column: str | None) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for idx, _ in df.iterrows():
        r = df.loc[idx]
        item = {}
        for k in keep_fields:
            item[k] = r.get(k, "")
        if id_strategy == "uid-column" and uid_column and uid_column in df.columns and r.get(uid_column):
            item_id = slugify(r.get(uid_column))
        else:
            item_id = f"{slug}-{idx}"
        item["id"] = item_id
        if any(str(item.get(k, "")).strip() for k in keep_fields):
            rows.append(item)
    return rows
EOF

cat > backend/validators.py <<'EOF'
import re
from typing import Dict, List, Any, Tuple

TIME_RE = re.compile(r"^\s*(\d{1,2}:\d{2})(\s*-\s*(\d{1,2}:\d{2}))?\s*$")

def _text(x) -> str:
    try:
        if x is None:
            return ""
        s = str(x).strip()
        return "" if s.lower() == "nan" else s
    except Exception:
        return ""

def validate_sessions(data: Dict[str, List[Dict[str, Any]]]) -> Tuple[list, list]:
    warnings: list = []
    errors: list = []

    seen_ids = set()
    seen_pairs = set()

    for day_key, sessions in data.items():
        for s in sessions:
            sid = _text(s.get("id"))
            if not sid:
                errors.append(f"[{day_key}] Missing id")
            elif sid in seen_ids:
                errors.append(f"[{day_key}] Duplicate id: {sid}")
            else:
                seen_ids.add(sid)

            time = _text(s.get("time"))
            title = _text(s.get("title"))
            if time and title:
                pair = (day_key, time, title)
                if pair in seen_pairs:
                    warnings.append(f"[{day_key}] Duplicate (time,title): {time} | {title}")
                else:
                    seen_pairs.add(pair)

            if time and not TIME_RE.match(time.replace('.', ':')):
                warnings.append(f"[{day_key}] Unrecognized time format: '{time}'")

            if (_text(s.get("chair")) and not title and not _text(s.get("speaker"))):
                warnings.append(f"[{day_key}] Row with Chair only (possible section header): id={sid}")

    return warnings, errors

def validate_people(items: List[Dict[str, Any]], key_label="faculty") -> Tuple[list, list]:
    warnings, errors = [], []
    seen_ids = set()
    for it in items:
        iid = _text(it.get("id"))
        name = _text(it.get("name"))
        if not iid:
            errors.append(f"[{key_label}] Missing id")
        elif iid in seen_ids:
            errors.append(f"[{key_label}] Duplicate id: {iid}")
        else:
            seen_ids.add(iid)
        if not name:
            errors.append(f"[{key_label}] Missing name for id={iid or '(no id)'}")
    return warnings, errors

def validate_sponsors(items: List[Dict[str, Any]], key_label="sponsors") -> Tuple[list, list]:
    warnings, errors = [], []
    seen_ids = set()
    for it in items:
        iid = _text(it.get("id"))
        name = _text(it.get("name"))
        if not iid:
            errors.append(f"[{key_label}] Missing id")
        elif iid in seen_ids:
            errors.append(f"[{key_label}] Duplicate id: {iid}")
        else:
            seen_ids.add(iid)
        if not name:
            errors.append(f"[{key_label}] Missing name for id={iid or '(no id)'}")
    return warnings, errors
EOF

cat > backend/app.py <<'EOF'
import os
import re
import tempfile
import json
from typing import Dict, List, Any
import requests
from fastapi import FastAPI, UploadFile, File
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware

from models import BuildConfig, PreviewResponse, GoogleFetchRequest
from processors import load_spreadsheet, guess_columns, apply_mapping, build_sessions, build_generic_items
from validators import validate_sessions, validate_people, validate_sponsors

APP_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(APP_DIR)
FRONT_DIR = os.path.join(ROOT_DIR, "frontend")

app = FastAPI(title="Interactive Program Builder v2.2.1")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

_STATE: Dict[str, Any] = {"path": None, "sheets": {}}

def _parse_sheet_id(url: str) -> str | None:
    m = re.search(r"/spreadsheets/d/([a-zA-Z0-9-_]+)", url)
    return m.group(1) if m else None

def _download_gsheet_xlsx(sheet_id: str) -> str:
    url = f"https://docs.google.com/spreadsheets/d/{sheet_id}/export?format=xlsx"
    resp = requests.get(url, timeout=45)
    if resp.status_code == 403:
        raise PermissionError("Google Sheets returned 403. Share as 'Anyone with the link (Viewer)' or 'Publish to the web'.")
    resp.raise_for_status()
    fd, path = tempfile.mkstemp(prefix="_gsheet_", suffix=".xlsx")
    with os.fdopen(fd, "wb") as f:
        f.write(resp.content)
    return path

@app.post("/api/upload")
async def upload(file: UploadFile = File(...)):
    suffix = os.path.splitext(file.filename)[1] or ".xlsx"
    with tempfile.NamedTemporaryFile(delete=False, prefix="_uploaded_", suffix=suffix) as tmp:
        tmp.write(await file.read())
        dest = tmp.name
    _STATE["path"] = dest
    _STATE["sheets"].clear()
    dfs = load_spreadsheet(dest)
    info = []
    for name, df in dfs.items():
        _STATE["sheets"][name] = df
        cols = list(df.columns)
        info.append({"name": name, "columns": cols, "guess": guess_columns(df)})
    return {"sheets": info}

@app.post("/api/fetch_google")
async def fetch_google(req: GoogleFetchRequest):
    sheet_id = _parse_sheet_id(req.url)
    if not sheet_id:
        return JSONResponse({"error": "Could not extract Google Sheet ID from URL."}, status_code=400)
    try:
        xlsx_path = _download_gsheet_xlsx(sheet_id)
    except PermissionError as e:
        return JSONResponse({"error": str(e)}, status_code=403)
    except Exception as e:
        return JSONResponse({"error": f"Failed to download spreadsheet: {e}"}, status_code=400)
    _STATE["path"] = xlsx_path
    _STATE["sheets"].clear()
    dfs = load_spreadsheet(xlsx_path)
    info = []
    for name, df in dfs.items():
        _STATE["sheets"][name] = df
        cols = list(df.columns)
        info.append({"name": name, "columns": cols, "guess": guess_columns(df)})
    return {"sheets": info, "sheet_id": sheet_id}

@app.get("/api/sheets")
def list_sheets():
    if not _STATE["path"]:
        return {"sheets": []}
    info = []
    for name, df in _STATE["sheets"].items():
        info.append({"name": name, "columns": list(df.columns), "guess": guess_columns(df)})
    return {"sheets": info}

def _build_sponsor_index(other_out: Dict[str, list]) -> dict | None:
    for key, arr in other_out.items():
        if not isinstance(arr, list) or not arr:
            continue
        first = arr[0]
        if isinstance(first, dict) and ("logo" in first or "logo_url" in first or "image" in first):
            by_id = {}
            by_name = {}
            for sp in arr:
                sid = str(sp.get("id") or sp.get("name") or "").strip().lower()
                name = str(sp.get("name") or "").strip().lower()
                logo = sp.get("logo") or sp.get("logo_url") or sp.get("image") or ""
                if sid: by_id[sid] = logo
                if name: by_name[name] = logo
            return {"by_id": by_id, "by_name": by_name}
    return None

def _enrich_sessions_with_sponsor_logos(program_out: Dict[str, list], other_out: Dict[str, list]):
    sidx = _build_sponsor_index(other_out)
    if not sidx:
        return
    for day_key, sessions in program_out.items():
        for s in sessions:
            if str(s.get("sponsor_logo","")).strip():
                continue
            sid = str(s.get("sponsor_id","")).strip().lower()
            if sid and sid in sidx["by_id"]:
                s["sponsor_logo"] = sidx["by_id"][sid]
                continue
            sname = (s.get("sponsor") or s.get("sponsored_by") or s.get("sponsor_name") or "").strip().lower()
            if sname and sname in sidx["by_name"]:
                s["sponsor_logo"] = sidx["by_name"][sname]

@app.post("/api/preview")
async def preview(config: BuildConfig):
    if not _STATE["path"]:
        return JSONResponse({"error": "No file provided. Upload a file or fetch from Google Sheets."}, status_code=400)
    program_out: Dict[str, List[Dict[str, Any]]] = {}
    other_out: Dict[str, List[Dict[str, Any]]] = {}
    warnings_all, errors_all = [], []
    for s in config.sheets:
        df = _STATE["sheets"].get(s.name)
        if df is None:
            warnings_all.append(f"[config] Sheet '{s.name}' not found in workbook")
            continue
        mapped = apply_mapping(df, s.mapping)
        if s.sheet_type == "program":
            sessions = build_sessions(mapped, s.slug, s.mapping, s.options, s.id_strategy, s.uid_column)
            if len(df) > 0 and not sessions:
                warnings_all.append(f"[{s.key}] No program rows produced — check mapping for time/title/speaker/…")
            program_out[s.key] = sessions
        elif s.sheet_type == "faculty":
            keep_fields = [k for k, v in s.mapping.items() if v]
            items = build_generic_items(mapped, keep_fields, s.slug, s.id_strategy, s.uid_column)
            if len(df) > 0 and not items:
                warnings_all.append(f"[{s.key}] No faculty rows produced — check mapping (e.g., name, bio, photo).")
            other_out[s.key] = items
        elif s.sheet_type == "sponsors":
            keep_fields = [k for k, v in s.mapping.items() if v]
            items = build_generic_items(mapped, keep_fields, s.slug, s.id_strategy, s.uid_column)
            if len(df) > 0 and not items:
                warnings_all.append(f"[{s.key}] No sponsor rows produced — check mapping (e.g., name, logo, url).")
            other_out[s.key] = items
        else:
            keep_fields = [k for k, v in s.mapping.items() if v]
            items = build_generic_items(mapped, keep_fields, s.slug, s.id_strategy, s.uid_column)
            if len(df) > 0 and not items:
                warnings_all.append(f"[{s.key}] No rows produced for custom type — check mapping.")
            other_out[s.key] = items
    _enrich_sessions_with_sponsor_logos(program_out, other_out)
    w1, e1 = validate_sessions(program_out)
    warnings_all += w1; errors_all += e1
    for key, items in other_out.items():
        if key.lower().startswith("faculty"):
            w, e = validate_people(items, key_label=key)
        elif key.lower().startswith("sponsor"):
            w, e = validate_sponsors(items, key_label=key)
        else:
            w, e = [], []
        warnings_all += w; errors_all += e
    data_out = {}; data_out.update(program_out); data_out.update(other_out)
    return PreviewResponse(data=data_out, warnings=warnings_all, errors=errors_all)

@app.post("/api/build")
async def build(config: BuildConfig):
    prev = await preview(config)
    if isinstance(prev, PreviewResponse):
        content = prev.model_dump()
    else:
        return prev
    if content["errors"]:
        return JSONResponse({"errors": content["errors"], "warnings": content["warnings"]}, status_code=400)
    out_path = os.path.join(tempfile.gettempdir(), "program.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(content["data"], f, ensure_ascii=False, indent=2)
    return FileResponse(out_path, media_type="application/json", filename="program.json")

@app.post("/api/reset")
def reset():
    path = _STATE.get("path")
    if path and os.path.isfile(path):
        try: os.remove(path)
        except Exception: pass
    _STATE["path"] = None
    _STATE["sheets"] = {}
    return {"status": "ok"}

@app.get("/api/program")
def proxy_program(src: str):
    try:
        r = requests.get(src, timeout=30)
        r.raise_for_status()
        try:
            data = r.json()
        except ValueError:
            data = json.loads(r.text)
        return JSONResponse(content=data, headers={"Cache-Control": "no-store"})
    except Exception as e:
        return JSONResponse({"error": f"Fetch failed: {e}"}, status_code=502)

@app.get("/favicon.ico", include_in_schema=False)
def favicon():
    return Response(status_code=204)

app.mount("/", StaticFiles(directory=FRONT_DIR, html=True), name="static")
EOF

cat > frontend/index.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Interactive Program Builder v2.2.1</title>
  <script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-slate-50 text-slate-900">
  <div class="max-w-6xl mx-auto p-6">
    <h1 class="text-3xl font-bold mb-4">Interactive Program Builder</h1>
    <p class="mb-6 text-slate-600">Upload an <b>XLSX/CSV</b> or paste a <b>Google Sheets share link</b>, map columns per sheet (program/faculty/sponsors), preview, validate, and export JSON.</p>

    <div class="grid md:grid-cols-2 gap-4 mb-6">
      <div class="bg-white rounded-xl shadow p-4">
        <h2 class="font-semibold mb-2">Upload file</h2>
        <form id="upload-form" class="flex items-center gap-4">
          <input id="file" name="file" type="file" class="block w-full text-sm text-slate-700" accept=".xlsx,.xls,.csv" required />
          <button class="px-4 py-2 rounded bg-blue-600 text-white hover:bg-blue-500">Upload</button>
          <button id="reset" type="button" class="px-4 py-2 rounded border border-slate-300 hover:bg-slate-100">Reset</button>
        </form>
        <div id="upload-msg" class="text-sm text-slate-600 mt-2"></div>
      </div>

      <div class="bg-white rounded-xl shadow p-4">
        <h2 class="font-semibold mb-2">Google Sheets link</h2>
        <div class="flex gap-2">
          <input id="gs-url" type="url" placeholder="Paste Google Sheets share link (anyone with the link → viewer)" class="flex-1 px-3 py-2 border rounded text-sm" />
          <button id="fetch-gs" class="px-4 py-2 rounded bg-emerald-600 text-white hover:bg-emerald-500">Fetch</button>
        </div>
        <p class="text-xs text-slate-500 mt-2">Tip: In Google Sheets → Share → General access: <b>Anyone with the link</b> (Viewer), or File → <b>Publish to the web</b>.</p>
        <div id="gs-msg" class="text-sm text-slate-600 mt-2"></div>
      </div>
    </div>

    <div id="mapping" class="bg-white rounded-xl shadow p-4 mb-6 hidden">
      <h2 class="text-xl font-semibold mb-3">Sheets</h2>
      <div id="sheets"></div>
      <div id="empty-hint" class="text-sm text-amber-700 mt-2 hidden">No sheets detected yet. Upload an XLSX/CSV or paste a Google Sheets link.</div>
    </div>

    <div id="actions" class="flex items-center gap-3 hidden">
      <button id="preview" class="px-4 py-2 rounded bg-emerald-600 text-white hover:bg-emerald-500">Preview & Validate</button>
      <button id="build" class="px-4 py-2 rounded bg-violet-600 text-white hover:bg-violet-500">Build JSON</button>
    </div>

    <div id="results" class="mt-6 hidden">
      <div class="bg-white rounded-xl shadow p-4">
        <h3 class="font-semibold mb-2">Preview JSON</h3>
        <pre id="preview-json" class="text-xs overflow-auto max-h-96 bg-slate-50 p-3 rounded"></pre>
      </div>
      <div class="grid md:grid-cols-2 gap-6 mt-6">
        <div class="bg-white rounded-xl shadow p-4">
          <h3 class="font-semibold mb-2">Warnings</h3>
          <ul id="warnings" class="text-amber-700 list-disc list-inside text-sm"></ul>
        </div>
        <div class="bg-white rounded-xl shadow p-4">
          <h3 class="font-semibold mb-2">Errors</h3>
          <ul id="errors" class="text-red-700 list-disc list-inside text-sm"></ul>
        </div>
      </div>
    </div>
  </div>

  <script>
    const PROGRAM_FIELDS  = [
      "time","title","speaker","chair","track","type","room","notes",
      "sponsor","sponsor_name","sponsored_by","sponsor_id","sponsor_logo"
    ];
    const FACULTY_FIELDS  = ["name","role","institution","country","bio","photo","website","email"];
    const SPONSOR_FIELDS  = ["name","level","logo","url","blurb","id"];

    const HEURISTICS = {
      faculty: {
        name: ["name","speaker","ponente"],
        role: ["role","rol","position","posición","cargo","title"],
        institution: ["institution","institución","affiliation","afiliación","hospital","university","universidad"],
        country: ["country","país","pais"],
        bio: ["bio","biography","biografía","resumen"],
        photo: ["photo","foto","image","imagen","headshot","picture","pic"],
        website: ["website","url","site","web","pagina","página"],
        email: ["email","e-mail","mail","correo"]
      },
      sponsors: {
        id: ["id","code","sponsor id","sponsor_id"],
        name: ["name","sponsor","company","empresa"],
        level: ["level","tier","categoria","categoría","category"],
        logo: ["logo","image","imagen","picture","pic","logo url","logo_url"],
        url: ["url","website","site","web","link"],
        blurb: ["blurb","desc","description","descripción","about","acerca"]
      }
    };

    function autoGuessForType(columns, type) {
      const colsLower = columns.map(c => ({raw:c, key:String(c).trim().toLowerCase()}));
      const out = {};
      const dict = HEURISTICS[type] || {};
      Object.entries(dict).forEach(([field, candidates]) => {
        const hit = colsLower.find(col => candidates.includes(col.key));
        if (hit) out[field] = hit.raw;
      });
      return out;
    }

    function fieldsForType(t) {
      if (t === 'faculty')  return FACULTY_FIELDS;
      if (t === 'sponsors') return SPONSOR_FIELDS;
      return PROGRAM_FIELDS;
    }

    function setupSheets(sheets) {
      const wrap = document.querySelector("#sheets");
      wrap.innerHTML = "";
      const mapping = document.querySelector("#mapping");
      const actions = document.querySelector("#actions");
      const hint = document.querySelector("#empty-hint");

      if (!sheets || sheets.length === 0) {
        mapping.classList.remove("hidden");
        actions.classList.add("hidden");
        hint.classList.remove("hidden");
        return;
      }
      hint.classList.add("hidden");
      mapping.classList.remove("hidden");
      actions.classList.remove("hidden");

      sheets.forEach(s => wrap.appendChild(createSheetCard(s)));
    }

    function createSheetCard(s) {
      const card = document.createElement('div');
      card.className = "mb-4 border border-slate-200 rounded-lg";

      const header = document.createElement('div');
      header.className = "px-4 py-2 bg-slate-100 rounded-t-lg flex items-center justify-between";
      header.innerHTML = `<div class='font-medium'>${s.name}</div>`;
      card.appendChild(header);

      const body = document.createElement('div');
      body.className = "p-4 space-y-3";

      const meta = document.createElement('div');
      meta.className = "grid md:grid-cols-3 gap-3";
      meta.innerHTML = `
        <div><label class='text-xs'>Key</label><input class='key block w-full border rounded px-2 py-1' value='${s.name.toLowerCase().replace(/[^a-z0-9]+/g,'_')}'></div>
        <div><label class='text-xs'>Slug</label><input class='slug block w-full border rounded px-2 py-1' value='${s.name.toLowerCase().replace(/[^a-z0-9]+/g,'-')}'></div>
        <div><label class='text-xs'>Date Label</label><input class='date_label block w-full border rounded px-2 py-1' placeholder='e.g., Thursday, October 16'></div>
      `;
      body.appendChild(meta);

      const typeRow = document.createElement('div');
      typeRow.className = "grid md:grid-cols-3 gap-3 items-end";
      typeRow.innerHTML = `
        <div>
          <label class='text-xs'>Sheet Type</label>
          <select class='sheet_type block w-full border rounded px-2 py-1'>
            <option value='program' selected>program</option>
            <option value='faculty'>faculty</option>
            <option value='sponsors'>sponsors</option>
          </select>
        </div>
        <div>
          <label class='text-xs'>ID Strategy</label>
          <select class='id_strategy block w-full border rounded px-2 py-1'>
            <option value='slug-index' selected>slug-index</option>
            <option value='uid-column'>uid-column</option>
          </select>
        </div>
        <div>
          <label class='text-xs'>UID Column (if uid-column)</label>
          <select class='uid_column block w-full border rounded px-2 py-1'>
            <option value=''>-- select column --</option>
            ${s.columns.map(c => `<option>${c}</option>`).join('')}
          </select>
        </div>
      `;
      body.appendChild(typeRow);

      const mapWrap = document.createElement('div');
      mapWrap.innerHTML = `<div class='font-medium mb-1'>Column Mapping</div>`;
      const table = document.createElement('table');
      table.className = "w-full text-sm border";
      mapWrap.appendChild(table);
      body.appendChild(mapWrap);

      const opts = document.createElement('div');
      opts.className = "grid md:grid-cols-3 gap-3";
      opts.innerHTML = `
        <div><label class='text-xs'>Chair from Speaker</label><select class='opt-chair block w-full border rounded px-2 py-1'><option value='1' selected>Yes</option><option value='0'>No</option></select></div>
        <div><label class='text-xs'>Chair Prefix Regex</label><input class='opt-chairrx block w-full border rounded px-2 py-1' value='^\\s*chair:?:?\\s*'></div>
        <div><label class='text-xs'>Split Speakers By</label><input class='opt-split block w-full border rounded px-2 py-1' placeholder='e.g., ;'></div>
      `;
      body.appendChild(opts);

      const renderMappingRows = (auto=false) => {
        const t = body.querySelector('.sheet_type').value;
        const FIELDS = (t==='faculty') ? FACULTY_FIELDS : (t==='sponsors') ? SPONSOR_FIELDS : PROGRAM_FIELDS;
        opts.style.display = (t === 'program') ? '' : 'none';

        const autoGuess = (t !== 'program' && auto) ? autoGuessForType(s.columns, t) : {};
        table.innerHTML = `
          <thead class='bg-slate-50'>
            <tr>
              <th class='text-left p-2 border'>Target Field</th>
              <th class='text-left p-2 border'>Source Column</th>
            </tr>
          </thead>
            <tbody>
              ${FIELDS.map(field => {
                const pre = (t==='program') ? s.guess[field] : autoGuess[field];
                return `
                  <tr>
                    <td class='p-2 border'>${field}</td>
                    <td class='p-2 border'>
                      <select class='map map-${field} block w-full border rounded px-2 py-1'>
                        <option value=''>-- none --</option>
                        ${s.columns.map(c => `<option ${pre===c ? 'selected':''}>${c}</option>`).join('')}
                      </select>
                    </td>
                  </tr>
                `;
              }).join('')}
            </tbody>
        `;
      };

      renderMappingRows(true);
      body.querySelector('.sheet_type').addEventListener('change', () => renderMappingRows(true));

      card.appendChild(body);
      return card;
    }

    document.querySelector("#upload-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const form = new FormData(e.target);
      const res = await fetch("/api/upload", { method: "POST", body: form });
      const data = await res.json();
      if (!data.sheets) {
        document.querySelector("#upload-msg").textContent = "Upload failed.";
        setupSheets([]);
        return;
      }
      document.querySelector("#upload-msg").textContent = "File uploaded. Sheets detected.";
      setupSheets(data.sheets);
      document.querySelector("#gs-msg").textContent = "";
    });

    document.querySelector("#fetch-gs").addEventListener("click", async () => {
      const url = document.querySelector("#gs-url").value.trim();
      if (!url) {
        document.querySelector("#gs-msg").textContent = "Please paste a Google Sheets share link.";
        return;
      }
      const res = await fetch("/api/fetch_google", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ url })
      });
      const data = await res.json();
      if (res.status !== 200) {
        document.querySelector("#gs-msg").textContent = (data.error || "Failed to fetch spreadsheet.");
        setupSheets([]);
        return;
      }
      document.querySelector("#gs-msg").textContent = `Loaded sheet ${data.sheet_id}.`;
      setupSheets(data.sheets);
      document.querySelector("#upload-msg").textContent = "";
    });

    document.querySelector("#reset").addEventListener("click", async () => {
      await fetch("/api/reset", { method: "POST"});
      document.querySelector("#upload-msg").textContent = "State reset.";
      document.querySelector("#gs-msg").textContent = "";
      setupSheets([]);
      document.querySelector("#results").classList.add("hidden");
    });

    document.querySelector("#preview").addEventListener("click", async () => {
      const cfg = getConfigFromUI();
      const res = await fetch("/api/preview", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(cfg)
      });
      const data = await res.json();
      document.querySelector("#results").classList.remove("hidden");
      document.querySelector("#errors").innerHTML = (data.errors || []).map(e => `<li>${e}</li>`).join("");
      document.querySelector("#warnings").innerHTML = (data.warnings || []).map(w => `<li>${w}</li>`).join("");
      document.querySelector("#preview-json").textContent = JSON.stringify(data.data || {}, null, 2);
    });

    document.querySelector("#build").addEventListener("click", async () => {
      const cfg = getConfigFromUI();
      const res = await fetch("/api/build", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(cfg)
      });
      if (res.status !== 200) {
        const err = await res.json();
        alert("Fix errors first: " + (err.errors || []).join("; "));
        return;
      }
      const blob = await res.blob();
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = "program.json";
      a.click();
      URL.revokeObjectURL(url);
    });

    function getConfigFromUI() {
      const sheetsWrap = document.querySelector("#sheets");
      const cards = [...sheetsWrap.children];
      const sheets = cards.map(card => {
        const name = card.querySelector('.font-medium').textContent;
        const key = card.querySelector('.key').value.trim();
        const slug = card.querySelector('.slug').value.trim();
        const date_label = card.querySelector('.date_label').value.trim();
        const sheet_type = card.querySelector('.sheet_type').value;
        const id_strategy = card.querySelector('.id_strategy').value;
        const uid_column = card.querySelector('.uid_column').value || null;

        const fields = sheet_type === 'faculty' ? FACULTY_FIELDS
                      : sheet_type === 'sponsors' ? SPONSOR_FIELDS
                      : PROGRAM_FIELDS;

        const mapping = {};
        fields.forEach(t => {
          const v = card.querySelector(`.map-${t}`).value;
          mapping[t] = v || null;
        });

        const options = {
          chair_from_speaker: (sheet_type === 'program') ? (card.querySelector('.opt-chair').value === '1') : false,
          chair_prefix_regex: (sheet_type === 'program') ? (card.querySelector('.opt-chairrx').value || '^\\s*chair:?\\s*') : '^\\s*chair:?\\s*',
          split_speakers_by: (sheet_type === 'program') ? (card.querySelector('.opt-split').value || null) : null
        };

        return { name, key, slug, date_label, sheet_type, id_strategy, uid_column, mapping, options };
      });
      return { sheets };
    }
  </script>
</body>
</html>
EOF

cat > tests/test_sponsor_enrichment.py <<'EOF'
from backend.app import _enrich_sessions_with_sponsor_logos

def test_enrich_by_id():
    program = { "oct_16": [ {"id":"x-1","title":"Talk A","time":"10:00","sponsor_id":"sp01"}, {"id":"x-2","title":"Talk B","time":"11:00"} ] }
    other = { "sponsors": [ {"id":"sp01","name":"ACME","logo":"https://cdn/logo-acme.png"}, {"id":"sp02","name":"Globex","logo":"https://cdn/logo-globex.png"} ] }
    _enrich_sessions_with_sponsor_logos(program, other)
    assert program["oct_16"][0]["sponsor_logo"] == "https://cdn/logo-acme.png"
    assert "sponsor_logo" not in program["oct_16"][1]

def test_enrich_by_name():
    program = { "oct_16": [ {"id":"x-1","title":"Talk A","time":"10:00","sponsor":"Globex"} ] }
    other = { "sponsors": [ {"id":"sp01","name":"ACME","logo":"https://cdn/logo-acme.png"}, {"id":"sp02","name":"Globex","logo":"https://cdn/logo-globex.png"} ] }
    _enrich_sessions_with_sponsor_logos(program, other)
    assert program["oct_16"][0]["sponsor_logo"] == "https://cdn/logo-globex.png"
EOF

cat > README.md <<'EOF'
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
