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
