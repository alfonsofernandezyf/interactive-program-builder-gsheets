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
