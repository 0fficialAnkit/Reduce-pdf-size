# PDF Compressor

A small Flask web application that accepts a PDF, compresses it with Ghostscript, and provides the compressed file for download.

## Features

- Upload a PDF through a browser form.
- Compress the PDF using Ghostscript's `/screen` preset.
- Download the compressed PDF from the browser.
- Works with Ghostscript on macOS/Linux (`gs`) and Windows (`gswin64c`).

## Project Structure

```text
.
├── app.py                 # Flask server and PDF-processing routes
├── requirements.txt       # Python dependencies
├── templates/
│   └── index.html         # Upload page
└── static/
	├── script.js          # Browser upload and download logic
	└── style.css           # Page styling
```

The `uploads/` and `compressed/` directories are created automatically when the app starts. They contain temporary user files and are ignored by Git.

## Requirements

- Python 3.10 or newer
- Ghostscript
- A web browser

### Install Ghostscript

macOS with Homebrew:

```bash
brew install ghostscript
```

Ubuntu/Debian:

```bash
sudo apt-get update
sudo apt-get install ghostscript
```

Windows:

1. Install Ghostscript from its official website.
2. Add the folder containing `gswin64c.exe` to `PATH`.

The application searches for `gs` first and then `gswin64c`, so the same Python code can run on all three platforms.

## Run Locally

From the project directory:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python3 app.py
```

On Windows PowerShell, activate the environment with:

```powershell
.venv\Scripts\Activate.ps1
```

Open <http://127.0.0.1:5000> in a browser. Stop the development server with `Ctrl+C`.

## How the Application Works

### 1. The page is loaded

The browser requests `GET /`. Flask's `index()` route renders `templates/index.html`. That page loads `static/style.css` for presentation and `static/script.js` for behavior.

### 2. A PDF is selected

The HTML form contains a file input named `pdf`. The `accept=".pdf"` attribute guides the browser to show PDF files, and the `required` attribute prevents an empty submission in normal browser use.

### 3. The browser uploads the file

The submit handler in `static/script.js` prevents a normal page reload, creates a `FormData` object, and sends the selected file with `POST /compress` as the `pdf` multipart form field.

### 4. Flask validates and stores the upload

The `compress()` route checks that `pdf` exists in `request.files`. It sanitizes the original filename with Werkzeug's `secure_filename()` and saves the file in the absolute `uploads/` directory.

The application builds paths from `BASE_DIR`, which is the directory containing `app.py`. This means the app does not depend on the directory from which the command was started.

### 5. Ghostscript compresses the PDF

The route uses `shutil.which()` to locate Ghostscript. It then calls Ghostscript with `subprocess.run()`:

```text
-sDEVICE=pdfwrite          Write a new PDF
-dCompatibilityLevel=1.4   Use PDF compatibility level 1.4
-dPDFSETTINGS=/screen       Favor a smaller file size
-dNOPAUSE -dBATCH           Run without interactive prompts
-dQUIET                     Reduce command-line output
-sOutputFile=...            Write to compressed/
```

The original upload remains in `uploads/`, while the result is written to `compressed/` using the same sanitized filename.

### 6. The server returns a download URL

After Ghostscript exits successfully, Flask verifies that the output exists and returns JSON similar to:

```json
{"download_url": "/download/example.pdf"}
```

If Ghostscript is missing, exits with an error, or does not create the output file, the route returns an HTTP 500 response.

### 7. The browser downloads the result

The JavaScript reads `download_url` and displays a link. Clicking the link sends `GET /download/<filename>`. The `download()` route confirms that the output exists and uses Flask's `send_from_directory()` with `as_attachment=True` so the browser downloads the PDF.

## Flask Routes

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/` | Render the upload page |
| `POST` | `/compress` | Save and compress the uploaded PDF |
| `GET` | `/download/<filename>` | Download a compressed PDF |

## Compression Quality

The `/screen` Ghostscript preset creates smaller files by reducing image quality and resolution. This is useful for screen viewing but may not be suitable for printing. Other common presets are `/ebook` for a balance between size and quality and `/printer` for higher quality and larger files.

## Important Deployment Notes

- GitHub Pages cannot run this Flask backend; it only hosts static files. GitHub can store the source code, while a service such as Render can run the Flask app.
- A production server should run `gunicorn app:app` instead of Flask's development server.
- The deployed environment must have Ghostscript installed as a system package as well as the Python packages in `requirements.txt`.
- The current folders use local disk storage. Uploaded and compressed files are temporary and may disappear when a hosting service restarts or redeploys.
- Add authentication, file-size limits, file-type validation, cleanup, and rate limiting before exposing the app publicly.

## Troubleshooting

### `FileNotFoundError: gswin64c`

This means the app is using an old Windows-only command. The current version searches for `gs` on macOS/Linux and `gswin64c` on Windows. Confirm Ghostscript is installed with:

```bash
which gs
```

### `Ghostscript is not installed`

Install Ghostscript and ensure its executable is available on `PATH`, then restart Flask.

### Port 5000 is already in use

Run the app on another port by changing the final line in `app.py` to:

```python
app.run(debug=True, port=5001)
```
# Compression_pdf


## http://localhost:5000/
