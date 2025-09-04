# 🎯 Interactive Program Builder

[![Python](https://img.shields.io/badge/Python-3.8+-blue.svg)](https://python.org)
[![FastAPI](https://img.shields.io/badge/FastAPI-0.100+-green.svg)](https://fastapi.tiangolo.com)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Version](https://img.shields.io/badge/Version-2.2.1-orange.svg)](https://github.com/alfonsofernandezyf/interactive-program-builder-gsheets/releases)

> **Build and validate conference program JSON from Excel/CSV or Google Sheets with intelligent column mapping, automatic time normalization, and sponsor enrichment.**

---

## ✨ Features

- 🔄 **Flexible Column Mapping** - Map any columns to program fields
- 📊 **Google Sheets Integration** - Import directly from share links
- 🎨 **Sponsor Enrichment** - Automatic logo assignment and branding
- ⏰ **Smart Time Normalization** - Fixes common time format typos
- ✅ **Comprehensive Validation** - Detects duplicates, malformed data, and missing fields
- 🎭 **Multi-Sheet Support** - Handle Program, Faculty, and Sponsors separately
- 🌐 **WordPress Ready** - Includes embed widget for easy integration

---

## 🚀 Quick Start

### Prerequisites
- Python 3.8+
- pip or poetry

### Installation

```bash
# Clone the repository
git clone https://github.com/alfonsofernandezyf/interactive-program-builder-gsheets.git
cd interactive-program-builder-gsheets

# Backend setup
cd backend
python3 -m venv .venv
source .venv/bin/activate  # On Windows: .venv\Scripts\activate
pip install -r requirements.txt

# Start the API server
uvicorn app:app --reload
```

The API will be available at `http://127.0.0.1:8000/`

### Frontend

```bash
# Open the mapping UI
open frontend/index.html
# Or serve with a simple HTTP server
python3 -m http.server 8001
```

---

## 🏗️ Project Structure

```
interactive-program-builder/
├── 📁 backend/                 # FastAPI service
│   ├── 🐍 app.py              # Main API endpoints
│   ├── 🔧 processors.py       # Data processing logic
│   ├── ✅ validators.py       # Validation rules
│   └── 📋 requirements.txt    # Python dependencies
├── 🎨 frontend/               # Mapping UI (HTML/JS)
│   └── 📄 index.html         # Column mapping interface
├── 🔌 embed/                  # WordPress embed widget
│   └── 🌐 lasid-program-embed.html
├── 📚 docs/                   # Documentation
│   └── 📖 json-schema.md     # API schema reference
├── 🧪 tests/                  # Test suite
└── 🚀 bootstrap_v221.sh      # Quick setup script
```

---

## 🔧 Configuration

### Environment Variables

Create `backend/.env` to customize settings:

```env
ALLOWED_ORIGINS=http://127.0.0.1:5500,http://localhost:5173
MAX_UPLOAD_MB=10
```

### CORS Setup

The backend automatically configures CORS based on your `ALLOWED_ORIGINS` setting.

---

## 📖 Usage Guide

### 1. Upload Your Data

**Option A: File Upload**
- Upload Excel (.xlsx) or CSV files via the UI
- Supports multiple sheets in a single file

**Option B: Google Sheets**
- Paste a share link (preferably "Publish to web")
- Format: `https://docs.google.com/spreadsheets/d/<SHEET_ID>/edit...`

### 2. Map Your Columns

For each sheet, specify:
- **Sheet Type**: `program`, `faculty`, or `sponsors`
- **Field Mapping**: Map your columns to standard fields
- **Day Assignment**: Set the day key for program sheets

### 3. Preview & Validate

- Review normalized JSON output
- Check for warnings and errors
- Fix any mapping issues

### 4. Build Final JSON

- Export the validated program structure
- Ready for use in your application

---

## 🎯 Field Mapping Reference

### Program Sheet (`type: "program"`)

| Field | Required | Description |
|-------|----------|-------------|
| `id` | ✅ | Unique session identifier |
| `time` | ✅ | Session time (auto-normalized) |
| `title` | ✅ | Session title |
| `speaker` | ⚠️ | Speaker name(s) |
| `chair` | ❌ | Session moderator |
| `track` | ❌ | Session track/category |
| `room` | ❌ | Session location |
| `type` | ❌ | Session type (keynote, workshop, etc.) |
| `notes` | ❌ | Additional information |

**Sponsor Fields** (any combination):
- `sponsor_id` - Links to sponsors sheet
- `sponsor_name` - Direct sponsor name
- `sponsor_logo` - Direct logo URL

### Sponsors Sheet (`type: "sponsors"`)

| Field | Required | Description |
|-------|----------|-------------|
| `id` | ✅ | Unique sponsor identifier |
| `name` | ✅ | Sponsor company name |
| `logo` | ❌ | Logo image URL |

### Faculty Sheet (`type: "faculty"`)

| Field | Required | Description |
|-------|----------|-------------|
| `id` | ✅ | Unique faculty identifier |
| `name` | ✅ | Faculty member name |
| `bio` | ❌ | Professional biography |
| `photo` | ❌ | Profile photo URL |
| `affiliation` | ❌ | Company/organization |
| `email` | ❌ | Contact email |

---

## 🔌 API Reference

### Endpoints

#### `POST /api/upload`
Upload Excel/CSV files for processing.

**Request**: `multipart/form-data` with `file` field

**Response**:
```json
{
  "sheets": [
    {
      "name": "october_16",
      "columns": ["Time", "Title", "Speaker", "Chair", "Room"],
      "guess": {
        "time": "Time",
        "title": "Title",
        "speaker": "Speaker"
      }
    }
  ]
}
```

#### `POST /api/fetch_google`
Fetch data from Google Sheets.

**Request**:
```json
{
  "url": "https://docs.google.com/spreadsheets/d/XXXX/edit?usp=sharing"
}
```

#### `POST /api/preview`
Preview normalized JSON without saving.

**Request**:
```json
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
        "speaker": "Speaker(s)"
      }
    }
  ]
}
```

#### `POST /api/build`
Generate final JSON output.

---

## 📊 Output Format

```json
{
  "educational_day": [
    {
      "id": "ed-101",
      "time": "09:00 - 09:30",
      "title": "Welcome & Opening",
      "speaker": ["Dr. Smith", "Prof. Johnson"],
      "chair": "Dr. Williams",
      "track": "Main Hall",
      "room": "Auditorium",
      "type": "Keynote",
      "sponsor_logo": "https://example.com/logo.png"
    }
  ],
  "october_16": [ /* sessions */ ],
  "october_17": [ /* sessions */ ],
  "faculty": [ /* faculty members */ ],
  "sponsors": [ /* sponsor info */ ]
}
```

---

## 🎨 WordPress Integration

### Embed Widget

Use the included embed widget in WordPress:

1. Copy `embed/lasid-program-embed.html`
2. Paste into a Custom HTML block
3. Update the JSON URL:
   ```javascript
   const JSON_URL = "https://your-site.com/path/to/program.json";
   ```

### Features
- **Shadow DOM** - Isolated styling
- **Responsive Design** - Mobile-friendly layout
- **Favorites System** - Local storage persistence
- **Sponsor Logos** - Automatic display on sponsored sessions

---

## 🧪 Testing

Run the test suite:

```bash
cd tests
python -m pytest test_sponsor_enrichment.py -v
```

---

## 🐛 Troubleshooting

### Common Issues

| Problem | Solution |
|---------|----------|
| **405 Method Not Allowed** | Use POST with `multipart/form-data` |
| **CORS Errors** | Add frontend origin to `ALLOWED_ORIGINS` |
| **Google Sheets 403** | Use "Publish to web" or download as XLSX |
| **Time Format Warnings** | Check for typos like `11-30` vs `11:30` |
| **Empty Preview** | Ensure program sheet has title/time and day assignment |

### Debug Mode

Enable detailed logging in the backend for troubleshooting.

---

## 📈 Roadmap

- [ ] **WordPress Plugin** - Admin settings and style customization
- [ ] **Service Account Auth** - Secure Google Sheets access
- [ ] **CLI Tool** - Batch processing from command line
- [ ] **Internationalization** - Multi-language support
- [ ] **Real-time Sync** - Auto-refresh from Google Sheets
- [ ] **Advanced Analytics** - Session statistics and insights

---

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## 🙏 Acknowledgments

- Built with [FastAPI](https://fastapi.tiangolo.com/) for robust API development
- Designed for seamless Google Sheets integration
- Optimized for conference and event management workflows

---

## 📞 Support

- **Issues**: [GitHub Issues](https://github.com/alfonsofernandezyf/interactive-program-builder-gsheets/issues)
- **Documentation**: [Wiki](https://github.com/alfonsofernandezyf/interactive-program-builder-gsheets/wiki)
- **Releases**: [GitHub Releases](https://github.com/alfonsofernandezyf/interactive-program-builder-gsheets/releases)

---

<div align="center">

**Made with ❤️ for the conference community**

[⭐ Star this repo](https://github.com/alfonsofernandezyf/interactive-program-builder-gsheets) | [🐛 Report issues](https://github.com/alfonsofernandezyf/interactive-program-builder-gsheets/issues) | [📖 View docs](https://github.com/alfonsofernandezyf/interactive-program-builder-gsheets#readme)

</div>
