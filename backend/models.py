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
