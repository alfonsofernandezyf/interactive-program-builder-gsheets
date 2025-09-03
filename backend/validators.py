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
