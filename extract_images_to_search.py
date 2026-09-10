#!/usr/bin/env python3
"""
Extract images from SharePoint source documents, store them in SharePoint, and index them in Azure AI Search.

Outputs:
  - SharePoint: Extracted Images/<source-document-name>/*
  - Azure AI Search: one image record per extracted embedded image or rendered PDF page

The script extracts:
  - PDF embedded raster images
  - PDF page renders, to capture scanned pages and vector diagrams that are not embedded images
  - DOCX/PPTX package media files

Credentials are resolved at runtime through the active Azure CLI session.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import mimetypes
import os
import re
import sys
import time
import urllib.parse
import zipfile
from dataclasses import dataclass
from datetime import datetime, timezone
from io import BytesIO
from typing import Any, Iterable

try:
    import pymupdf as fitz
except ImportError:  # pragma: no cover - older PyMuPDF namespace
    import fitz  # type: ignore

from PIL import Image

from ingest_sharepoint_to_search import (
    SourceFile,
    get_cli_token,
    request,
    run_az,
    search_headers,
    upload_search_documents,
)


SEARCH_API_VERSION = "2024-07-01"
VISION_API_VERSION = "2024-02-01"
IMAGE_SOURCE_EXTENSIONS = {".pdf", ".docx", ".pptx"}
SUPPORTED_PACKAGE_EXTENSIONS = {".docx": "word/media/", ".pptx": "ppt/media/"}
VISION_SUPPORTED_MIME_TYPES = {
    "image/bmp",
    "image/gif",
    "image/jpeg",
    "image/png",
    "image/tiff",
    "image/webp",
}


@dataclass
class ImageAsset:
    source_file: SourceFile
    kind: str
    file_name: str
    content: bytes
    mime_type: str
    page_number: int | None
    occurrence_index: int
    width: int | None
    height: int | None
    source_ref: str

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.content).hexdigest()


def safe_segment(value: str, max_length: int = 90) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._ -]+", "-", value).strip(" .-")
    cleaned = re.sub(r"\s+", " ", cleaned)
    if not cleaned:
        cleaned = "item"
    return cleaned[:max_length].rstrip(" .-")


def encode_path(path: str) -> str:
    return "/".join(urllib.parse.quote(part, safe="") for part in path.strip("/").split("/"))


def list_image_source_files(drive_id: str, folder_path: str, graph_token: str) -> list[SourceFile]:
    encoded_path = encode_path(folder_path)
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
            if ext not in IMAGE_SOURCE_EXTENSIONS:
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


def graph_json_headers(graph_token: str) -> dict[str, str]:
    return {
        "Authorization": f"Bearer {graph_token}",
        "Content-Type": "application/json",
    }


def ensure_graph_folder(drive_id: str, folder_path: str, graph_token: str) -> dict[str, Any]:
    segments = [safe_segment(segment) for segment in folder_path.strip("/").split("/") if segment.strip()]
    if not segments:
        raise ValueError("folder_path must not be empty")

    current = ""
    current_item: dict[str, Any] | None = None
    headers = {"Authorization": f"Bearer {graph_token}"}

    for segment in segments:
        target = f"{current}/{segment}".strip("/")
        get_url = f"https://graph.microsoft.com/v1.0/drives/{drive_id}/root:/{encode_path(target)}"
        try:
            current_item = request("GET", get_url, headers=headers)
            current = target
            continue
        except RuntimeError as exc:
            if "HTTP 404" not in str(exc):
                raise

        body = {
            "name": segment,
            "folder": {},
            "@microsoft.graph.conflictBehavior": "fail",
        }
        if current:
            children_url = (
                f"https://graph.microsoft.com/v1.0/drives/{drive_id}/root:/{encode_path(current)}:/children"
            )
        else:
            children_url = f"https://graph.microsoft.com/v1.0/drives/{drive_id}/root/children"
        current_item = request(
            "POST",
            children_url,
            headers=graph_json_headers(graph_token),
            body=json.dumps(body).encode("utf-8"),
        )
        current = target

    if current_item is None:
        raise RuntimeError(f"Could not resolve or create SharePoint folder: {folder_path}")
    return current_item


def upload_graph_content(
    drive_id: str,
    file_path: str,
    content: bytes,
    mime_type: str,
    graph_token: str,
) -> dict[str, Any]:
    url = f"https://graph.microsoft.com/v1.0/drives/{drive_id}/root:/{encode_path(file_path)}:/content"
    return request(
        "PUT",
        url,
        headers={
            "Authorization": f"Bearer {graph_token}",
            "Content-Type": mime_type,
        },
        body=content,
        timeout=600,
    )


def get_cognitive_credential(resource_group: str, account_name: str) -> str:
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
        return f"key:{key}"
    except RuntimeError:
        return "aad:" + get_cli_token("https://cognitiveservices.azure.com")


def cognitive_headers(credential: str, mime_type: str | None = None) -> dict[str, str]:
    scheme, value = credential.split(":", 1)
    if scheme == "key":
        headers = {"Ocp-Apim-Subscription-Key": value}
    elif scheme == "aad":
        headers = {"Authorization": f"Bearer {value}"}
    else:
        raise ValueError(f"Unsupported credential scheme: {scheme}")
    if mime_type:
        headers["Content-Type"] = mime_type
    return headers


def get_image_dimensions(content: bytes) -> tuple[int | None, int | None]:
    try:
        with Image.open(BytesIO(content)) as image:
            return image.size
    except Exception:
        return None, None


def analyze_image(
    vision_endpoint: str,
    vision_credential: str,
    content: bytes,
    mime_type: str,
    width: int | None,
    height: int | None,
) -> dict[str, Any]:
    if mime_type not in VISION_SUPPORTED_MIME_TYPES:
        return {
            "visionStatus": f"skipped unsupported MIME type {mime_type}",
            "caption": "",
            "captionConfidence": None,
            "ocrText": "",
            "tags": [],
        }
    if width is not None and height is not None and (width < 50 or height < 50):
        return {
            "visionStatus": "skipped image below Azure AI Vision minimum size",
            "caption": "",
            "captionConfidence": None,
            "ocrText": "",
            "tags": [],
        }

    query = urllib.parse.urlencode(
        {
            "api-version": VISION_API_VERSION,
            "features": "caption,read,tags",
            "language": "en",
        }
    )
    url = f"{vision_endpoint.rstrip('/')}/computervision/imageanalysis:analyze?{query}"
    try:
        payload = request(
            "POST",
            url,
            headers=cognitive_headers(vision_credential, mime_type),
            body=content,
            timeout=180,
        )
    except Exception as exc:
        return {
            "visionStatus": f"failed: {exc}",
            "caption": "",
            "captionConfidence": None,
            "ocrText": "",
            "tags": [],
        }

    caption_result = payload.get("captionResult") or {}
    tags_result = payload.get("tagsResult") or {}
    read_result = payload.get("readResult") or {}
    lines: list[str] = []
    for block in read_result.get("blocks", []):
        for line in block.get("lines", []):
            text = (line.get("text") or "").strip()
            if text:
                lines.append(text)

    return {
        "visionStatus": "succeeded",
        "caption": caption_result.get("text") or "",
        "captionConfidence": caption_result.get("confidence"),
        "ocrText": "\n".join(lines),
        "tags": [tag.get("name") for tag in tags_result.get("values", []) if tag.get("name")],
    }


def create_or_update_image_index(search_endpoint: str, search_key: str, index_name: str) -> None:
    index = {
        "name": index_name,
        "fields": [
            {"name": "id", "type": "Edm.String", "key": True, "filterable": True},
            {"name": "sourceDocumentId", "type": "Edm.String", "filterable": True},
            {
                "name": "sourceDocumentName",
                "type": "Edm.String",
                "searchable": True,
                "filterable": True,
                "sortable": True,
            },
            {"name": "sourceFileType", "type": "Edm.String", "filterable": True, "facetable": True},
            {"name": "sourceUrl", "type": "Edm.String"},
            {"name": "imageUrl", "type": "Edm.String"},
            {"name": "imageKind", "type": "Edm.String", "filterable": True, "facetable": True},
            {"name": "pageNumber", "type": "Edm.Int32", "filterable": True, "sortable": True},
            {"name": "occurrenceIndex", "type": "Edm.Int32", "filterable": True, "sortable": True},
            {"name": "imageWidth", "type": "Edm.Int32", "filterable": True, "sortable": True},
            {"name": "imageHeight", "type": "Edm.Int32", "filterable": True, "sortable": True},
            {"name": "imageByteSize", "type": "Edm.Int32", "filterable": True, "sortable": True},
            {"name": "sha256", "type": "Edm.String", "filterable": True},
            {
                "name": "caption",
                "type": "Edm.String",
                "searchable": True,
                "analyzer": "en.microsoft",
            },
            {"name": "captionConfidence", "type": "Edm.Double", "filterable": True, "sortable": True},
            {
                "name": "ocrText",
                "type": "Edm.String",
                "searchable": True,
                "analyzer": "en.microsoft",
            },
            {
                "name": "tags",
                "type": "Collection(Edm.String)",
                "searchable": True,
                "filterable": True,
                "facetable": True,
            },
            {
                "name": "content",
                "type": "Edm.String",
                "searchable": True,
                "analyzer": "en.microsoft",
            },
            {"name": "visionStatus", "type": "Edm.String", "filterable": True, "facetable": True},
            {"name": "indexedAt", "type": "Edm.DateTimeOffset", "filterable": True, "sortable": True},
            {"name": "lastModifiedDateTime", "type": "Edm.DateTimeOffset", "filterable": True, "sortable": True},
        ],
    }
    url = f"{search_endpoint.rstrip('/')}/indexes/{index_name}?api-version={SEARCH_API_VERSION}"
    request("PUT", url, headers=search_headers(search_key), body=json.dumps(index).encode("utf-8"))


def make_image_id(asset: ImageAsset) -> str:
    raw = (
        f"{asset.source_file.item_id}:{asset.kind}:{asset.page_number}:"
        f"{asset.occurrence_index}:{asset.source_ref}:{asset.sha256[:16]}"
    ).encode("utf-8")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def load_existing_search_ids(search_endpoint: str, search_key: str, index_name: str) -> set[str]:
    existing_ids: set[str] = set()
    page_size = 1000
    skip = 0
    while True:
        query = urllib.parse.urlencode(
            {
                "api-version": SEARCH_API_VERSION,
                "search": "*",
                "$select": "id",
                "$top": str(page_size),
                "$skip": str(skip),
            }
        )
        response = request(
            "GET",
            f"{search_endpoint.rstrip('/')}/indexes/{index_name}/docs?{query}",
            headers={"api-key": search_key},
        )
        values = response.get("value", [])
        existing_ids.update(record["id"] for record in values if record.get("id"))
        if len(values) < page_size:
            return existing_ids
        skip += page_size


def image_record(asset: ImageAsset, uploaded_item: dict[str, Any], vision: dict[str, Any]) -> dict[str, Any]:
    source_ext = os.path.splitext(asset.source_file.name)[1].lower().lstrip(".")
    tags = vision.get("tags") or []
    caption = vision.get("caption") or ""
    ocr_text = vision.get("ocrText") or ""
    content_parts = [
        asset.source_file.name,
        asset.kind,
        caption,
        ocr_text,
        " ".join(tags),
    ]
    return {
        "id": make_image_id(asset),
        "sourceDocumentId": asset.source_file.item_id,
        "sourceDocumentName": asset.source_file.name,
        "sourceFileType": source_ext,
        "sourceUrl": asset.source_file.web_url,
        "imageUrl": uploaded_item.get("webUrl", ""),
        "imageKind": asset.kind,
        "pageNumber": asset.page_number,
        "occurrenceIndex": asset.occurrence_index,
        "imageWidth": asset.width,
        "imageHeight": asset.height,
        "imageByteSize": len(asset.content),
        "sha256": asset.sha256,
        "caption": caption,
        "captionConfidence": vision.get("captionConfidence"),
        "ocrText": ocr_text,
        "tags": tags,
        "content": "\n".join(part for part in content_parts if part),
        "visionStatus": vision.get("visionStatus", ""),
        "indexedAt": datetime.now(timezone.utc).isoformat(),
        "lastModifiedDateTime": asset.source_file.last_modified,
    }


def pixmap_to_png(doc: fitz.Document, xref: int) -> tuple[bytes, int, int]:
    pixmap = fitz.Pixmap(doc, xref)
    if pixmap.n - pixmap.alpha > 3:
        pixmap = fitz.Pixmap(fitz.csRGB, pixmap)
    data = pixmap.tobytes("png")
    return data, pixmap.width, pixmap.height


def pixmap_to_jpeg(pixmap: fitz.Pixmap, quality: int) -> bytes:
    mode = "RGBA" if pixmap.alpha else "RGB"
    image = Image.frombytes(mode, (pixmap.width, pixmap.height), pixmap.samples)
    if image.mode != "RGB":
        image = image.convert("RGB")
    output = BytesIO()
    image.save(output, format="JPEG", quality=quality, optimize=True)
    return output.getvalue()


def iter_pdf_images(
    source_file: SourceFile,
    content: bytes,
    render_pages: bool,
    dpi: int,
    jpeg_quality: int,
    min_embedded_pixels: int,
) -> Iterable[ImageAsset]:
    with fitz.open(stream=content, filetype="pdf") as document:
        matrix = fitz.Matrix(dpi / 72, dpi / 72)
        for page_index in range(document.page_count):
            page_number = page_index + 1
            page = document[page_index]
            embedded_images = page.get_images(full=True)
            for occurrence_index, image_info in enumerate(embedded_images, start=1):
                xref = int(image_info[0])
                try:
                    image_bytes, width, height = pixmap_to_png(document, xref)
                    image_ext = "png"
                    mime_type = "image/png"
                except Exception:
                    extracted = document.extract_image(xref)
                    image_bytes = extracted["image"]
                    image_ext = extracted.get("ext") or "bin"
                    mime_type = mimetypes.guess_type(f"image.{image_ext}")[0] or "application/octet-stream"
                    width = int(extracted.get("width") or 0) or None
                    height = int(extracted.get("height") or 0) or None
                    if width is None or height is None:
                        width, height = get_image_dimensions(image_bytes)

                if width and height and width * height < min_embedded_pixels:
                    continue

                yield ImageAsset(
                    source_file=source_file,
                    kind="pdf-embedded-image",
                    file_name=f"p{page_number:04d}_embedded_{occurrence_index:03d}_xref{xref}.{image_ext}",
                    content=image_bytes,
                    mime_type=mime_type,
                    page_number=page_number,
                    occurrence_index=occurrence_index,
                    width=width,
                    height=height,
                    source_ref=f"xref:{xref}",
                )

            if render_pages:
                pixmap = page.get_pixmap(matrix=matrix, alpha=False)
                image_bytes = pixmap_to_jpeg(pixmap, jpeg_quality)
                yield ImageAsset(
                    source_file=source_file,
                    kind="pdf-rendered-page",
                    file_name=f"p{page_number:04d}_rendered_page.jpg",
                    content=image_bytes,
                    mime_type="image/jpeg",
                    page_number=page_number,
                    occurrence_index=page_number,
                    width=pixmap.width,
                    height=pixmap.height,
                    source_ref=f"page:{page_number}",
                )


def iter_package_images(source_file: SourceFile, content: bytes, package_prefix: str) -> Iterable[ImageAsset]:
    with zipfile.ZipFile(BytesIO(content)) as package:
        media_files = sorted(path for path in package.namelist() if path.startswith(package_prefix))
        for occurrence_index, media_path in enumerate(media_files, start=1):
            image_bytes = package.read(media_path)
            original_name = os.path.basename(media_path)
            ext = os.path.splitext(original_name)[1].lower()
            mime_type = mimetypes.guess_type(original_name)[0] or "application/octet-stream"
            width, height = get_image_dimensions(image_bytes)
            yield ImageAsset(
                source_file=source_file,
                kind=f"{os.path.splitext(source_file.name)[1].lower().lstrip('.')}-embedded-image",
                file_name=f"media_{occurrence_index:03d}_{safe_segment(original_name, 60)}{ext if not original_name.lower().endswith(ext) else ''}",
                content=image_bytes,
                mime_type=mime_type,
                page_number=None,
                occurrence_index=occurrence_index,
                width=width,
                height=height,
                source_ref=media_path,
            )


def iter_source_images(
    source_file: SourceFile,
    content: bytes,
    render_pages: bool,
    dpi: int,
    jpeg_quality: int,
    min_embedded_pixels: int,
) -> Iterable[ImageAsset]:
    ext = os.path.splitext(source_file.name)[1].lower()
    if ext == ".pdf":
        yield from iter_pdf_images(source_file, content, render_pages, dpi, jpeg_quality, min_embedded_pixels)
    elif ext in SUPPORTED_PACKAGE_EXTENSIONS:
        yield from iter_package_images(source_file, content, SUPPORTED_PACKAGE_EXTENSIONS[ext])


def download_graph_file(drive_id: str, item_id: str, graph_token: str) -> bytes:
    url = f"https://graph.microsoft.com/v1.0/drives/{drive_id}/items/{item_id}/content"
    body, _headers = request(
        "GET",
        url,
        headers={"Authorization": f"Bearer {graph_token}"},
        expect_json=False,
        timeout=600,
    )
    return body


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--subscription", required=True)
    parser.add_argument("--resource-group", required=True)
    parser.add_argument("--search-service", required=True)
    parser.add_argument("--vision-account", required=True)
    parser.add_argument("--drive-id", required=True)
    parser.add_argument("--source-folder", default="Source Documents")
    parser.add_argument("--images-folder", default="Extracted Images")
    parser.add_argument("--index-name", default="reccia-images")
    parser.add_argument("--render-pages", action="store_true")
    parser.add_argument("--dpi", type=int, default=120)
    parser.add_argument("--jpeg-quality", type=int, default=72)
    parser.add_argument("--min-embedded-pixels", type=int, default=1)
    parser.add_argument("--disable-vision", action="store_true")
    parser.add_argument("--batch-size", type=int, default=100)
    parser.add_argument("--max-source-files", type=int)
    parser.add_argument("--max-assets", type=int)
    parser.add_argument("--skip-existing-indexed", action="store_true")
    args = parser.parse_args()

    run_az(["account", "set", "--subscription", args.subscription])
    graph_token = get_cli_token("https://graph.microsoft.com")
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
    search_endpoint = f"https://{args.search_service}.search.windows.net"
    vision_endpoint = run_az(
        [
            "cognitiveservices",
            "account",
            "show",
            "--resource-group",
            args.resource_group,
            "--name",
            args.vision_account,
            "--query",
            "properties.endpoint",
            "-o",
            "tsv",
        ]
    )
    vision_credential = "" if args.disable_vision else get_cognitive_credential(args.resource_group, args.vision_account)

    print(f"Creating/updating Azure AI Search image index: {args.index_name}")
    create_or_update_image_index(search_endpoint, search_key, args.index_name)
    existing_ids = (
        load_existing_search_ids(search_endpoint, search_key, args.index_name)
        if args.skip_existing_indexed
        else set()
    )
    if args.skip_existing_indexed:
        print(f"Resume mode: skipping {len(existing_ids)} already indexed image records.")

    ensure_graph_folder(args.drive_id, args.images_folder, graph_token)
    source_files = list_image_source_files(args.drive_id, args.source_folder, graph_token)
    if args.max_source_files:
        source_files = source_files[: args.max_source_files]
    if not source_files:
        raise RuntimeError(f"No PDF/DOCX/PPTX files found in SharePoint folder '{args.source_folder}'.")

    records_batch: list[dict[str, Any]] = []
    total_extracted = 0
    total_indexed = 0
    total_vision_succeeded = 0
    total_skipped_existing = 0
    per_document: list[dict[str, Any]] = []

    for source_position, source_file in enumerate(source_files, start=1):
        if args.max_assets is not None and total_extracted >= args.max_assets:
            break
        document_folder = f"{args.images_folder}/{safe_segment(os.path.splitext(source_file.name)[0])}"
        ensure_graph_folder(args.drive_id, document_folder, graph_token)
        print(f"[{source_position}/{len(source_files)}] Processing {source_file.name}...")
        content = download_graph_file(args.drive_id, source_file.item_id, graph_token)
        doc_count = 0
        doc_vision_count = 0
        doc_skipped_existing = 0

        for asset in iter_source_images(
            source_file,
            content,
            args.render_pages,
            args.dpi,
            args.jpeg_quality,
            args.min_embedded_pixels,
        ):
            if args.max_assets is not None and total_extracted >= args.max_assets:
                break
            asset_id = make_image_id(asset)
            if asset_id in existing_ids:
                total_skipped_existing += 1
                doc_skipped_existing += 1
                continue
            target_path = f"{document_folder}/{safe_segment(asset.file_name, 120)}"
            uploaded = upload_graph_content(args.drive_id, target_path, asset.content, asset.mime_type, graph_token)
            if args.disable_vision:
                vision = {
                    "visionStatus": "disabled",
                    "caption": "",
                    "captionConfidence": None,
                    "ocrText": "",
                    "tags": [],
                }
            else:
                vision = analyze_image(
                    vision_endpoint,
                    vision_credential,
                    asset.content,
                    asset.mime_type,
                    asset.width,
                    asset.height,
                )
            if vision.get("visionStatus") == "succeeded":
                total_vision_succeeded += 1
                doc_vision_count += 1

            records_batch.append(image_record(asset, uploaded, vision))
            total_extracted += 1
            doc_count += 1

            if len(records_batch) >= args.batch_size:
                total_indexed += upload_search_documents(
                    search_endpoint,
                    search_key,
                    args.index_name,
                    records_batch,
                    batch_size=args.batch_size,
                )
                existing_ids.update(record["id"] for record in records_batch if record.get("id"))
                records_batch.clear()

        print(
            f"  Extracted {doc_count} images/page renders; "
            f"skipped {doc_skipped_existing} already indexed; "
            f"Vision succeeded for {doc_vision_count}."
        )
        per_document.append(
            {
                "sourceDocumentName": source_file.name,
                "extractedImages": doc_count,
                "skippedExistingIndexed": doc_skipped_existing,
                "visionSucceeded": doc_vision_count,
                "sharePointFolder": document_folder,
            }
        )

    if records_batch:
        total_indexed += upload_search_documents(
            search_endpoint,
            search_key,
            args.index_name,
            records_batch,
            batch_size=args.batch_size,
        )
        existing_ids.update(record["id"] for record in records_batch if record.get("id"))

    summary = {
        "sourceDocuments": len(source_files),
        "extractedImagesAndPageRenders": total_extracted,
        "indexedRecords": total_indexed,
        "skippedExistingIndexed": total_skipped_existing,
        "visionSucceeded": total_vision_succeeded,
        "sharePointImagesFolder": args.images_folder,
        "searchIndex": args.index_name,
        "perDocument": per_document,
    }
    print(json.dumps(summary, indent=2))

    sample_query = urllib.parse.urlencode(
        {
            "api-version": SEARCH_API_VERSION,
            "search": "solar diagram permit",
            "$top": "5",
            "$select": "sourceDocumentName,imageKind,pageNumber,caption,ocrText,imageUrl",
        }
    )
    sample = request(
        "GET",
        f"{search_endpoint.rstrip('/')}/indexes/{args.index_name}/docs?{sample_query}",
        headers={"api-key": search_key},
    )
    print(f"Image search smoke test returned {len(sample.get('value', []))} results.")
    for result in sample.get("value", [])[:3]:
        snippet = (result.get("caption") or result.get("ocrText") or "").replace("\n", " ")
        print(f"- {result.get('sourceDocumentName')} {result.get('imageKind')} p{result.get('pageNumber')}: {snippet[:180]}...")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
