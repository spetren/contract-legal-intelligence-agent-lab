#!/usr/bin/env python3
"""
Ingest SharePoint files into Azure AI Search using Microsoft Graph and Azure AI Document Intelligence.
 
The script keeps credentials out of source code. It supports interactive MSAL authentication
for Microsoft Graph and uses the active Azure CLI session to:
  - read Azure AI Search and Document Intelligence endpoints/keys
  - pull SharePoint files from a document-library folder
  - OCR/extract content with Document Intelligence
  - chunk and push content into Azure AI Search
"""
 
from __future__ import annotations
 
import argparse
import base64
import http.client
import json
import mimetypes
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from dataclasses import dataclass
from io import BytesIO
from typing import Any
from xml.etree import ElementTree

import msal
 
 
SEARCH_API_VERSION = "2024-07-01"
DOC_INTEL_API_VERSION = "2023-07-31"
SUPPORTED_EXTENSIONS = {".pdf", ".png", ".jpg", ".jpeg", ".tif", ".tiff", ".docx"}
WORD_NS = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
 
 
@dataclass
class SourceFile:
    item_id: str
    name: str
    web_url: str
    size: int
    last_modified: str | None
    mime_type: str
 
 
def run_az(args: list[str]) -> str:
    command = ["az", *args]
    if os.name == "nt":
        command = [os.environ.get("ComSpec", "cmd.exe"), "/d", "/c", "az", *args]
 
    completed = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"az {' '.join(args)} failed with exit code {completed.returncode}:\n"
            f"{completed.stderr.strip() or completed.stdout.strip()}"
        )
    return completed.stdout.strip()
 
 
def get_cli_token(resource: str) -> str:
    return run_az(
        [
            "account",
            "get-access-token",
            "--resource",
            resource,
            "--query",
            "accessToken",
            "-o",
            "tsv",
        ]
    )


def get_interactive_graph_token(tenant_id: str, client_id: str, scopes: list[str]) -> str:
    authority = f"https://login.microsoftonline.com/{tenant_id}"
    app = msal.PublicClientApplication(client_id=client_id, authority=authority)
    accounts = app.get_accounts()
    result = app.acquire_token_silent(scopes, account=accounts[0]) if accounts else None

    if not result:
        flow = app.initiate_device_flow(scopes=scopes)
        if "user_code" not in flow:
            raise RuntimeError(
                "Could not start Microsoft Graph device-code authentication: "
                + json.dumps(flow, indent=2)
            )
        print(flow["message"])
        result = app.acquire_token_by_device_flow(flow)

    access_token = result.get("access_token") if result else None
    if not access_token:
        error = result.get("error_description") or result.get("error") or "Unknown authentication error"
        raise RuntimeError(f"Microsoft Graph authentication failed: {error}")
    return access_token
 
 
def request(
    method: str,
    url: str,
    headers: dict[str, str] | None = None,
    body: bytes | None = None,
    expect_json: bool = True,
    timeout: int = 120,
) -> Any:
    for attempt in range(6):
        req = urllib.request.Request(url, data=body, headers=headers or {}, method=method)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as response:
                data = response.read()
                if not expect_json:
                    return data, response.headers
                if not data:
                    return None
                return json.loads(data.decode("utf-8"))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            if exc.code in {429, 500, 502, 503, 504} and attempt < 5:
                retry_after = exc.headers.get("Retry-After")
                delay = int(retry_after) if retry_after and retry_after.isdigit() else 2**attempt
                time.sleep(min(delay, 30))
                continue
            raise RuntimeError(f"{method} {url} failed: HTTP {exc.code}\n{detail}") from exc
        except (urllib.error.URLError, TimeoutError, http.client.RemoteDisconnected) as exc:
            if attempt < 5:
                time.sleep(min(2**attempt, 30))
                continue
            raise RuntimeError(f"{method} {url} failed after retries: {exc}") from exc
 
 
def encode_sharepoint_path(path: str) -> str:
    return "/".join(urllib.parse.quote(part, safe="") for part in path.strip("/").split("/"))
 
 
def list_graph_folder_files(drive_id: str, folder_path: str, graph_token: str) -> list[SourceFile]:
    encoded_path = encode_sharepoint_path(folder_path)
    select = "id,name,size,webUrl,lastModifiedDateTime,file,folder"
    url = (
        f"https://graph.microsoft.com/v1.0/drives/{drive_id}/root:/{encoded_path}:/children"
        f"?%24select={urllib.parse.quote(select)}&%24top=200"
    )
    headers = {"Authorization": f"Bearer {graph_token}"}
    files: list[SourceFile] = []
 
    while url:
        payload = request("GET", url, headers=headers)
        for item in payload.get("value", []):
            if "folder" in item:
                continue
            name = item["name"]
            ext = os.path.splitext(name)[1].lower()
            if ext not in SUPPORTED_EXTENSIONS:
                continue
            mime_type = item.get("file", {}).get("mimeType") or mimetypes.guess_type(name)[0]
            files.append(
                SourceFile(
                    item_id=item["id"],
                    name=name,
                    web_url=item.get("webUrl", ""),
                    size=int(item.get("size") or 0),
                    last_modified=item.get("lastModifiedDateTime"),
                    mime_type=mime_type or "application/octet-stream",
                )
            )
        url = payload.get("@odata.nextLink")
 
    return sorted(files, key=lambda f: f.name)
 
 
def download_graph_file(drive_id: str, source_file: SourceFile, graph_token: str) -> bytes:
    metadata_url = (
        f"https://graph.microsoft.com/v1.0/drives/{drive_id}/items/{source_file.item_id}"
        "?%24select=%40microsoft.graph.downloadUrl"
    )
    metadata = request(
        "GET",
        metadata_url,
        headers={"Authorization": f"Bearer {graph_token}"},
    )
    download_url = metadata.get("@microsoft.graph.downloadUrl")
    if not download_url:
        raise RuntimeError(
            f"Microsoft Graph did not return a download URL for '{source_file.name}'."
        )
    body, _headers = request(
        "GET",
        download_url,
        expect_json=False,
        timeout=600,
    )
    return body
 
 
def analyze_with_document_intelligence(endpoint: str, credential: str, content: bytes, mime_type: str) -> dict[str, Any]:
    analyze_url = (
        f"{endpoint.rstrip('/')}/formrecognizer/documentModels/prebuilt-layout:analyze"
        f"?api-version={DOC_INTEL_API_VERSION}"
    )
    headers = document_intelligence_headers(credential, mime_type)
 
    req = urllib.request.Request(analyze_url, data=content, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=120) as response:
            operation_location = response.headers.get("Operation-Location")
            if not operation_location:
                raise RuntimeError("Document Intelligence did not return an Operation-Location header.")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Document Intelligence analyze failed: HTTP {exc.code}\n{detail}") from exc
 
    poll_headers = document_intelligence_headers(credential)
    deadline = time.time() + 900
    while time.time() < deadline:
        result = request("GET", operation_location, headers=poll_headers, timeout=120)
        status = result.get("status")
        if status == "succeeded":
            return result.get("analyzeResult", {})
        if status == "failed":
            raise RuntimeError(json.dumps(result.get("error", result), indent=2))
        time.sleep(3)
 
    raise TimeoutError("Timed out waiting for Document Intelligence analysis.")
 
 
def document_intelligence_headers(credential: str, mime_type: str | None = None) -> dict[str, str]:
    scheme, value = credential.split(":", 1)
    headers: dict[str, str]
    if scheme == "aad":
        headers = {"Authorization": f"Bearer {value}"}
    elif scheme == "key":
        headers = {"Ocp-Apim-Subscription-Key": value}
    else:
        raise ValueError(f"Unsupported Document Intelligence credential scheme: {scheme}")
    if mime_type:
        headers["Content-Type"] = mime_type
    return headers


def get_document_intelligence_credential(resource_group: str, account_name: str) -> str:
    local_auth_disabled = run_az(
        [
            "cognitiveservices",
            "account",
            "show",
            "--resource-group",
            resource_group,
            "--name",
            account_name,
            "--query",
            "properties.disableLocalAuth",
            "-o",
            "tsv",
        ]
    ).lower() == "true"
    if local_auth_disabled:
        print("Document Intelligence local key auth is disabled; using Microsoft Entra auth.")
        return "aad:" + get_cli_token("https://cognitiveservices.azure.com")

    try:
        key = run_az(
            [
                "cognitiveservices",
                "account",
                "keys",
                "list",
                "--resource-group",
                resource_group,
                "--name",
                account_name,
                "--query",
                "key1",
                "-o",
                "tsv",
            ]
        )
        if key:
            return "key:" + key
    except RuntimeError:
        pass

    print("Document Intelligence local key auth is unavailable; using Microsoft Entra auth.")
    return "aad:" + get_cli_token("https://cognitiveservices.azure.com")
 
 
def extract_docx_text(content: bytes) -> str:
    paragraphs: list[str] = []
    with zipfile.ZipFile(BytesIO(content)) as package:
        xml_parts = [
            name
            for name in package.namelist()
            if name == "word/document.xml"
            or name.startswith("word/header")
            or name.startswith("word/footer")
        ]
        for part in xml_parts:
            root = ElementTree.fromstring(package.read(part))
            for paragraph in root.iter(f"{WORD_NS}p"):
                text = "".join(node.text or "" for node in paragraph.iter(f"{WORD_NS}t")).strip()
                if text:
                    paragraphs.append(text)
    return "\n".join(paragraphs)
 
 
def page_texts_from_analysis(analysis: dict[str, Any]) -> list[tuple[int, str]]:
    full_text = analysis.get("content") or ""
    pages = analysis.get("pages") or []
    page_texts: list[tuple[int, str]] = []
 
    for fallback_page_number, page in enumerate(pages, start=1):
        page_number = int(page.get("pageNumber") or fallback_page_number)
        spans = page.get("spans") or []
        fragments = []
        for span in spans:
            offset = int(span.get("offset", 0))
            length = int(span.get("length", 0))
            fragments.append(full_text[offset : offset + length])
        text = "\n".join(fragment for fragment in fragments if fragment).strip()
        if text:
            page_texts.append((page_number, text))
 
    if not page_texts and full_text.strip():
        page_texts.append((1, full_text.strip()))
 
    return page_texts
 
 
def chunk_text(text: str, max_chars: int = 3500, overlap: int = 300) -> list[str]:
    normalized = "\n".join(line.rstrip() for line in text.splitlines()).strip()
    if not normalized:
        return []
 
    chunks: list[str] = []
    start = 0
    length = len(normalized)
 
    while start < length:
        end = min(start + max_chars, length)
        if end < length:
            paragraph_break = normalized.rfind("\n\n", start, end)
            sentence_break = normalized.rfind(". ", start, end)
            best_break = max(paragraph_break, sentence_break)
            if best_break > start + int(max_chars * 0.55):
                end = best_break + (2 if best_break == paragraph_break else 1)
        chunk = normalized[start:end].strip()
        if chunk:
            chunks.append(chunk)
        if end >= length:
            break
        start = max(0, end - overlap)
 
    return chunks
 
 
def search_headers(search_key: str) -> dict[str, str]:
    return {
        "api-key": search_key,
        "Content-Type": "application/json",
    }
 
 
def create_or_update_search_index(search_endpoint: str, search_key: str, index_name: str) -> None:
    url = f"{search_endpoint.rstrip('/')}/indexes/{index_name}?api-version={SEARCH_API_VERSION}"
    index = {
        "name": index_name,
        "fields": [
            {"name": "id", "type": "Edm.String", "key": True, "filterable": True},
            {"name": "documentId", "type": "Edm.String", "filterable": True},
            {
                "name": "documentName",
                "type": "Edm.String",
                "searchable": True,
                "filterable": True,
                "sortable": True,
            },
            {"name": "fileType", "type": "Edm.String", "filterable": True, "facetable": True},
            {"name": "sourceUrl", "type": "Edm.String"},
            {"name": "pageNumber", "type": "Edm.Int32", "filterable": True, "sortable": True},
            {"name": "chunkIndex", "type": "Edm.Int32", "filterable": True, "sortable": True},
            {
                "name": "content",
                "type": "Edm.String",
                "searchable": True,
                "analyzer": "en.microsoft",
            },
            {"name": "ocrEngine", "type": "Edm.String", "filterable": True},
            {
                "name": "lastModifiedDateTime",
                "type": "Edm.DateTimeOffset",
                "filterable": True,
                "sortable": True,
            },
        ],
    }
    request(
        "PUT",
        url,
        headers=search_headers(search_key),
        body=json.dumps(index).encode("utf-8"),
    )
 
 
def make_document_id(source_file: SourceFile, page_number: int, chunk_index: int) -> str:
    raw = f"{source_file.item_id}:{page_number}:{chunk_index}".encode("utf-8")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")
 
 
def upload_search_documents(
    search_endpoint: str,
    search_key: str,
    index_name: str,
    documents: list[dict[str, Any]],
    batch_size: int = 500,
) -> int:
    url = f"{search_endpoint.rstrip('/')}/indexes/{index_name}/docs/index?api-version={SEARCH_API_VERSION}"
    uploaded = 0
    for start in range(0, len(documents), batch_size):
        batch = documents[start : start + batch_size]
        payload = {"value": [{"@search.action": "mergeOrUpload", **doc} for doc in batch]}
        response = request(
            "POST",
            url,
            headers=search_headers(search_key),
            body=json.dumps(payload).encode("utf-8"),
        )
        failed = [item for item in response.get("value", []) if not item.get("status")]
        if failed:
            raise RuntimeError(f"Azure AI Search rejected {len(failed)} documents: {failed[:3]}")
        uploaded += len(batch)
    return uploaded
 
 
def build_search_documents(
    source_file: SourceFile,
    file_content: bytes,
    doc_intel_endpoint: str,
    doc_intel_credential: str,
) -> list[dict[str, Any]]:
    ext = os.path.splitext(source_file.name)[1].lower()
    ocr_engine = "document-intelligence-layout"
 
    if ext == ".docx":
        try:
            analysis = analyze_with_document_intelligence(
                doc_intel_endpoint,
                doc_intel_credential,
                file_content,
                source_file.mime_type,
            )
            page_texts = page_texts_from_analysis(analysis)
        except Exception:
            ocr_engine = "docx-xml-text-fallback"
            page_texts = [(1, extract_docx_text(file_content))]
    else:
        analysis = analyze_with_document_intelligence(
            doc_intel_endpoint,
            doc_intel_credential,
            file_content,
            source_file.mime_type,
        )
        page_texts = page_texts_from_analysis(analysis)
 
    search_docs: list[dict[str, Any]] = []
    chunk_index = 0
    for page_number, page_text in page_texts:
        for chunk in chunk_text(page_text):
            chunk_index += 1
            search_docs.append(
                {
                    "id": make_document_id(source_file, page_number, chunk_index),
                    "documentId": source_file.item_id,
                    "documentName": source_file.name,
                    "fileType": ext.lstrip("."),
                    "sourceUrl": source_file.web_url,
                    "pageNumber": page_number,
                    "chunkIndex": chunk_index,
                    "content": chunk,
                    "ocrEngine": ocr_engine,
                    "lastModifiedDateTime": source_file.last_modified,
                }
            )
 
    return search_docs
 
 
def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--subscription", required=True)
    parser.add_argument("--tenant-id", required=True)
    parser.add_argument("--graph-client-id", required=True)
    parser.add_argument("--resource-group", required=True)
    parser.add_argument("--search-service", required=True)
    parser.add_argument("--doc-intel-account", required=True)
    parser.add_argument("--drive-id", required=True)
    parser.add_argument("--folder", default="Source Documents")
    parser.add_argument("--index-name", default="reccia-documents")
    parser.add_argument("--max-source-files", type=int)
    args = parser.parse_args()
 
    run_az(["account", "set", "--subscription", args.subscription])
 
    graph_token = get_interactive_graph_token(
        args.tenant_id,
        args.graph_client_id,
        scopes=["Files.Read.All"],
    )
    search_endpoint = f"https://{args.search_service}.search.windows.net"
    search_key = run_az(
        [
            "search",
            "admin-key",
            "show",
            "--resource-group",
            args.resource_group,
            "--service-name",
            args.search_service,
            "--query",
            "primaryKey",
            "-o",
            "tsv",
        ]
    )
    doc_intel_endpoint = run_az(
        [
            "cognitiveservices",
            "account",
            "show",
            "--resource-group",
            args.resource_group,
            "--name",
            args.doc_intel_account,
            "--query",
            "properties.endpoint",
            "-o",
            "tsv",
        ]
    )
    doc_intel_credential = get_document_intelligence_credential(
        args.resource_group, args.doc_intel_account
    )
 
    print(f"Creating/updating Azure AI Search index: {args.index_name}")
    create_or_update_search_index(search_endpoint, search_key, args.index_name)
 
    files = list_graph_folder_files(args.drive_id, args.folder, graph_token)
    if args.max_source_files:
        files = files[: args.max_source_files]
    if not files:
        raise RuntimeError(f"No supported files found in SharePoint folder '{args.folder}'.")
 
    print(f"Found {len(files)} supported SharePoint files.")
    all_documents: list[dict[str, Any]] = []
    failures: list[str] = []
 
    for position, source_file in enumerate(files, start=1):
        print(f"[{position}/{len(files)}] Downloading and OCRing {source_file.name}...")
        try:
            file_content = download_graph_file(args.drive_id, source_file, graph_token)
            docs = build_search_documents(source_file, file_content, doc_intel_endpoint, doc_intel_credential)
            if not docs:
                raise RuntimeError("No searchable text was extracted.")
            print(f"  Extracted {len(docs)} chunks.")
            all_documents.extend(docs)
        except Exception as exc:
            failures.append(f"{source_file.name}: {exc}")
            print(f"  FAILED: {exc}", file=sys.stderr)
 
    if all_documents:
        uploaded = upload_search_documents(search_endpoint, search_key, args.index_name, all_documents)
        print(f"Uploaded {uploaded} chunks to Azure AI Search.")
 
    if failures:
        print("\nFailures:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
 
    sample_query = urllib.parse.urlencode(
        {
            "api-version": SEARCH_API_VERSION,
            "search": "interconnection permit contract",
            "$top": "5",
            "$select": "documentName,pageNumber,chunkIndex,content,sourceUrl",
        }
    )
    sample = request(
        "GET",
        f"{search_endpoint.rstrip('/')}/indexes/{args.index_name}/docs?{sample_query}",
        headers={"api-key": search_key},
    )
    print(f"Search smoke test returned {len(sample.get('value', []))} results.")
    for result in sample.get("value", [])[:3]:
        content = (result.get("content") or "").replace("\n", " ")
        print(f"- {result.get('documentName')} p{result.get('pageNumber')}: {content[:180]}...")
 
    return 0
 
 
if __name__ == "__main__":
    raise SystemExit(main())