# from flask import Flask, request, send_from_directory, render_template
# import os
# import subprocess
# from werkzeug.utils import secure_filename

# app = Flask(__name__)
# UPLOAD_FOLDER = 'uploads'
# COMPRESSED_FOLDER = 'compressed'

# os.makedirs(UPLOAD_FOLDER, exist_ok=True)
# os.makedirs(COMPRESSED_FOLDER, exist_ok=True)

# @app.route('/')
# def index():
#     return render_template('index.html')

# # @app.route('/compress', methods=['POST'])
# # def compress():
# #     if 'pdf' not in request.files:
# #         return 'No file uploaded', 400

# #     file = request.files['pdf']
# #     filename = secure_filename(file.filename)
# #     input_path = os.path.join(UPLOAD_FOLDER, filename)
# #     output_path = os.path.join(COMPRESSED_FOLDER, filename)

# #     file.save(input_path)

# #     try:
# #         subprocess.run([
# #             'gswin64c', 
# #             '-sDEVICE=pdfwrite',
# #             '-dCompatibilityLevel=1.4',
# #             '-dPDFSETTINGS=/screen',
# #             '-dNOPAUSE',
# #             '-dQUIET',
# #             '-dBATCH',
# #             f'-sOutputFile={output_path}',
# #             input_path
# #         ], check=True)
# #         return {'download_url': f'/download/{filename}'}
# #     except subprocess.CalledProcessError:
# #         return 'Compression failed', 500






# @app.route('/compress', methods=['POST'])
# def compress():
#     if 'pdf' not in request.files:
#         return 'No file uploaded', 400

#     file = request.files['pdf']
#     filename = secure_filename(file.filename)
#     print(f"[INFO] Received file: {filename}")

#     input_path = os.path.join(UPLOAD_FOLDER, filename)
#     output_path = os.path.join(COMPRESSED_FOLDER, filename)
#     print(f"[INFO] Input path: {input_path}")
#     print(f"[INFO] Output path: {output_path}")

#     file.save(input_path)

#     try:
#         subprocess.run([
#             'gswin64c',
#             '-sDEVICE=pdfwrite',
#             '-dCompatibilityLevel=1.4',
#             '-dPDFSETTINGS=/screen',
#             '-dNOPAUSE',
#             '-dQUIET',
#             '-dBATCH',
#             f'-sOutputFile={output_path}',
#             input_path
#         ], check=True)
#         print("[INFO] Compression successful.")
#         return {'download_url': f'/download/{filename}'}
#     except subprocess.CalledProcessError as e:
#         print(f"[ERROR] Compression failed: {e}")
#         return 'Compression failed', 500










# @app.route('/download/<filename>')
# def download(filename):
#     return send_from_directory(COMPRESSED_FOLDER, filename, as_attachment=True)

# if __name__ == '__main__':
#     app.run(debug=True)




























from flask import Flask, request, send_from_directory, render_template, abort
import os
import subprocess
from werkzeug.utils import secure_filename

app = Flask(__name__)

# Folder setup
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
UPLOAD_FOLDER = os.path.join(BASE_DIR, 'uploads')
COMPRESSED_FOLDER = os.path.join(BASE_DIR, 'compressed')

os.makedirs(UPLOAD_FOLDER, exist_ok=True)
os.makedirs(COMPRESSED_FOLDER, exist_ok=True)

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/compress', methods=['POST'])
def compress():
    if 'pdf' not in request.files:
        return 'No file uploaded', 400

    file = request.files['pdf']
    filename = secure_filename(file.filename)
    print(f"[INFO] Received file: {filename}")

    input_path = os.path.join(UPLOAD_FOLDER, filename)
    output_path = os.path.join(COMPRESSED_FOLDER, filename)
    print(f"[INFO] Input path: {input_path}")
    print(f"[INFO] Output path: {output_path}")

    file.save(input_path)

    try:
        subprocess.run([
            'gswin64c',
            '-sDEVICE=pdfwrite',
            '-dCompatibilityLevel=1.4',
            '-dPDFSETTINGS=/screen',
            '-dNOPAUSE',
            '-dQUIET',
            '-dBATCH',
            f'-sOutputFile={output_path}',
            input_path
        ], check=True)

        if os.path.exists(output_path):
            print("[INFO] Compression successful.")
            return {'download_url': f'/download/{filename}'}
        else:
            print("[ERROR] Output file not found after compression.")
            return 'Compression failed', 500

    except subprocess.CalledProcessError as e:
        print(f"[ERROR] Compression failed: {e}")
        return 'Compression failed', 500

@app.route('/download/<filename>')
def download(filename):
    output_path = os.path.join(COMPRESSED_FOLDER, filename)
    print(f"[INFO] Download requested for: {filename}")
    print(f"[INFO] Full path: {output_path}")

    if not os.path.exists(output_path):
        print("[ERROR] File not found for download.")
        return abort(404)

    return send_from_directory(COMPRESSED_FOLDER, filename, as_attachment=True)

if __name__ == '__main__':
    app.run(debug=True)

