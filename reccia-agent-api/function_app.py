import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

import azure.functions as func


SEARCH_API_VERSION = "2024-07-01"
DEFAULT_OPENAI_API_VERSION = "2024-10-21"
MAX_EVIDENCE_CHARS = 1800

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)


class AppError(Exception):
    def __init__(self, message: str, status_code: int = 500):
        super().__init__(message)
        self.status_code = status_code


def json_response(payload: dict[str, Any], status_code: int = 200) -> func.HttpResponse:
    return func.HttpResponse(
        json.dumps(payload, ensure_ascii=False),
        status_code=status_code,
        mimetype="application/json",
    )


def required_setting(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise AppError(f"Missing required app setting: {name}")
    return value


def http_json(
    method: str,
    url: str,
    headers: dict[str, str] | None = None,
    payload: dict[str, Any] | None = None,
    timeout: int = 120,
) -> dict[str, Any]:
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=body, headers=headers or {}, method=method)
    for attempt in range(5):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                data = response.read()
                if not data:
                    return {}
                return json.loads(data.decode("utf-8"))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            if exc.code in {429, 500, 502, 503, 504} and attempt < 4:
                retry_after = exc.headers.get("Retry-After")
                delay = int(retry_after) if retry_after and retry_after.isdigit() else 2**attempt
                time.sleep(min(delay, 20))
                continue
            raise AppError(f"{method} {url} failed: HTTP {exc.code}: {detail}", exc.code) from exc
        except urllib.error.URLError as exc:
            if attempt < 4:
                time.sleep(2**attempt)
                continue
            raise AppError(f"{method} {url} failed: {exc}") from exc
    raise AppError(f"{method} {url} failed after retries")


def truncate(value: str | None, max_chars: int = MAX_EVIDENCE_CHARS) -> str:
    text = (value or "").strip()
    if len(text) <= max_chars:
        return text
    return text[: max_chars - 3].rstrip() + "..."


def normalize_answer_links(answer: str) -> str:
    return re.sub(r"!\[([^\]]*)\]\(([^)]+)\)", r"[\1](\2)", answer)


def search_index(index_name: str, question: str, select: str, top: int) -> list[dict[str, Any]]:
    endpoint = required_setting("SEARCH_ENDPOINT").rstrip("/")
    key = required_setting("SEARCH_QUERY_KEY")
    url = f"{endpoint}/indexes/{index_name}/docs/search?api-version={SEARCH_API_VERSION}"
    payload = {
        "search": question,
        "top": top,
        "select": select,
        "queryType": "simple",
    }
    response = http_json(
        "POST",
        url,
        headers={"api-key": key, "Content-Type": "application/json"},
        payload=payload,
    )
    return response.get("value", [])


def collect_evidence(question: str, top_documents: int, top_images: int) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    document_index = os.environ.get("DOCUMENT_INDEX", "reccia-documents")
    image_index = os.environ.get("IMAGE_INDEX", "reccia-images")

    document_hits = search_index(
        document_index,
        question,
        "documentName,sourceUrl,pageNumber,chunkIndex,content,lastModifiedDateTime",
        top_documents,
    )
    image_hits = search_index(
        image_index,
        question,
        (
            "sourceDocumentName,sourceUrl,imageUrl,imageKind,pageNumber,occurrenceIndex,"
            "caption,captionConfidence,ocrText,tags,visionStatus,indexedAt"
        ),
        top_images,
    )

    documents = []
    for hit in document_hits:
        documents.append(
            {
                "type": "document",
                "title": hit.get("documentName"),
                "url": hit.get("sourceUrl"),
                "pageNumber": hit.get("pageNumber"),
                "chunkIndex": hit.get("chunkIndex"),
                "score": hit.get("@search.score"),
                "snippet": truncate(hit.get("content")),
                "lastModifiedDateTime": hit.get("lastModifiedDateTime"),
            }
        )

    images = []
    for hit in image_hits:
        images.append(
            {
                "type": "image",
                "title": hit.get("sourceDocumentName"),
                "sourceUrl": hit.get("sourceUrl"),
                "imageUrl": hit.get("imageUrl"),
                "imageKind": hit.get("imageKind"),
                "pageNumber": hit.get("pageNumber"),
                "occurrenceIndex": hit.get("occurrenceIndex"),
                "score": hit.get("@search.score"),
                "caption": truncate(hit.get("caption"), 500),
                "ocrText": truncate(hit.get("ocrText")),
                "tags": hit.get("tags") or [],
                "visionStatus": hit.get("visionStatus"),
            }
        )
    return documents, images


def get_managed_identity_token(resource: str) -> str:
    identity_endpoint = os.environ.get("IDENTITY_ENDPOINT")
    identity_header = os.environ.get("IDENTITY_HEADER")
    if identity_endpoint and identity_header:
        query = urllib.parse.urlencode({"resource": resource, "api-version": "2019-08-01"})
        request = urllib.request.Request(
            f"{identity_endpoint}?{query}",
            headers={"X-IDENTITY-HEADER": identity_header},
        )
    else:
        query = urllib.parse.urlencode({"resource": resource, "api-version": "2018-02-01"})
        request = urllib.request.Request(
            f"http://169.254.169.254/metadata/identity/oauth2/token?{query}",
            headers={"Metadata": "true"},
        )
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = json.loads(response.read().decode("utf-8"))
    token = payload.get("access_token")
    if not token:
        raise AppError("Managed identity token response did not include access_token")
    return token


def openai_headers() -> dict[str, str]:
    api_key = os.environ.get("AZURE_OPENAI_API_KEY")
    if api_key:
        return {"api-key": api_key, "Content-Type": "application/json"}
    token = get_managed_identity_token("https://cognitiveservices.azure.com")
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


def reason_with_foundry(question: str, documents: list[dict[str, Any]], images: list[dict[str, Any]]) -> str | None:
    endpoint = os.environ.get("AZURE_OPENAI_ENDPOINT")
    deployment = os.environ.get("AZURE_OPENAI_DEPLOYMENT")
    if not endpoint or not deployment:
        return None

    api_version = os.environ.get("AZURE_OPENAI_API_VERSION", DEFAULT_OPENAI_API_VERSION)
    url = (
        f"{endpoint.rstrip('/')}/openai/deployments/{urllib.parse.quote(deployment)}/"
        f"chat/completions?api-version={urllib.parse.quote(api_version)}"
    )
    evidence = {
        "textEvidence": documents,
        "visualEvidence": images,
    }
    system_prompt = (
        "You are a renewable energy permitting and compliance assistant. "
        "Answer only from the provided evidence. Use visual evidence from extracted image captions, "
        "OCR text, tags, page numbers, and image links. If the evidence is insufficient, say what is missing. "
        "Include concise citations with document names, page numbers, and image links when relevant. "
        "Never use Markdown image syntax like ![View diagram](url). The chat cannot render authenticated "
        "SharePoint images inline. Always use normal Markdown links like [View diagram](url)."
    )
    user_prompt = (
        f"Question: {question}\n\n"
        f"Evidence JSON:\n{json.dumps(evidence, ensure_ascii=False)}\n\n"
        "Return a concise answer followed by cited evidence bullets. For visual citations, use this exact style: "
        "Visual: [View diagram](imageUrl)."
    )
    payload = {
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "temperature": 0.2,
        "max_tokens": 1400,
    }
    response = http_json("POST", url, headers=openai_headers(), payload=payload, timeout=180)
    choices = response.get("choices") or []
    if not choices:
        raise AppError("Azure OpenAI response did not include choices")
    return normalize_answer_links(choices[0].get("message", {}).get("content", ""))


def search_only_answer(question: str, documents: list[dict[str, Any]], images: list[dict[str, Any]]) -> str:
    lines = [
        f"I found {len(documents)} text matches and {len(images)} visual matches for: {question}",
        "",
    ]
    if documents:
        lines.append("Top text evidence:")
        for item in documents[:3]:
            page = f" p{item.get('pageNumber')}" if item.get("pageNumber") else ""
            lines.append(f"- {item.get('title')}{page}: {truncate(item.get('snippet'), 220)}")
    if images:
        lines.append("")
        lines.append("Top visual evidence:")
        for item in images[:3]:
            page = f" p{item.get('pageNumber')}" if item.get("pageNumber") else ""
            summary = item.get("caption") or item.get("ocrText") or ", ".join(item.get("tags") or [])
            image_url = item.get("imageUrl")
            image_link = f" [View diagram]({image_url})" if image_url else ""
            lines.append(f"- {item.get('title')}{page} ({item.get('imageKind')}): {truncate(summary, 220)}{image_link}")
    return "\n".join(lines).strip()


@app.route(route="health", methods=["GET"])
def health(req: func.HttpRequest) -> func.HttpResponse:
    return json_response({"status": "ok"})


@app.route(route="askRenewableCompliance", methods=["POST"])
def ask_renewable_compliance(req: func.HttpRequest) -> func.HttpResponse:
    try:
        body = req.get_json()
        question = (body.get("question") or "").strip()
        if not question:
            raise AppError("Request body must include a non-empty 'question'.", 400)
        top_documents = min(max(int(body.get("topDocuments", 6)), 1), 20)
        top_images = min(max(int(body.get("topImages", 6)), 1), 20)

        documents, images = collect_evidence(question, top_documents, top_images)
        answer = reason_with_foundry(question, documents, images)
        mode = "foundry" if answer is not None else "search-only"
        if answer is None:
            answer = search_only_answer(question, documents, images)

        return json_response(
            {
                "answer": answer,
                "reasoningMode": mode,
                "citations": [*documents, *images],
                "summary": {
                    "textMatches": len(documents),
                    "visualMatches": len(images),
                    "usesVisualEvidence": bool(images),
                },
            }
        )
    except AppError as exc:
        return json_response({"error": str(exc)}, exc.status_code)
    except ValueError as exc:
        return json_response({"error": f"Invalid request body: {exc}"}, 400)
    except Exception as exc:
        return json_response({"error": str(exc)}, 500)
