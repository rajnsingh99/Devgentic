# filename: Utils/file_processor.py
import os
import sys
import urllib.parse
from typing import List, Dict


def read_files_from_uris(files: List[Dict]) -> str:
    """
    Reads content from a list of file URI dictionaries and formats it for a prompt.
    This is a shared utility that can be used by any service.

    Args:
        files: A list of file objects, each represented as a dictionary
               (e.g., from `model.model_dump()`). Expected keys are 'uri' and 'name'.

    Returns:
        A formatted string containing the content of all files, or an empty string.
    """
    if not files:
        return ""

    all_file_content = []
    for f in files:
        uri_string = f.get('uri')
        file_name = f.get('name')
        if not uri_string:
            continue

        try:
            parsed_uri = urllib.parse.urlparse(uri_string)
            # Basic security: only allow local file schemes
            if parsed_uri.scheme not in ['file', '']:
                all_file_content.append(f"File: {file_name or uri_string} (Error: Cannot read non-local files.)")
                continue

            file_path = urllib.parse.unquote(parsed_uri.path)

            # Handle Windows paths (e.g., file:///C:/Users/...)
            if sys.platform == "win32" and file_path.startswith('/'):
                file_path = file_path[1:]

            if os.path.exists(file_path) and os.path.isfile(file_path):
                with open(file_path, 'r', encoding='utf-8', errors='ignore') as file:
                    content = file.read()

                header = f"File: {file_name or os.path.basename(file_path)}"
                file_info = f"{header}\n```\n{content}\n```"
                all_file_content.append(file_info)
            else:
                all_file_content.append(
                    f"File: {file_name or os.path.basename(file_path)} (Error: Not found at path {file_path})")

        except Exception as e:
            all_file_content.append(
                f"File: {file_name or 'N/A'} (Error: Could not read file at {uri_string}. Reason: {e})"
            )

    if not all_file_content:
        return ""

    # Combine all file contents under a single header
    return "---\nAttached Files:\n\n" + "\n\n".join(all_file_content) + "\n---"
