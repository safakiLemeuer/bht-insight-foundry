"""FastAPI entry point for the BHT Insight Phase 1A RAG service."""

from functools import lru_cache

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from bht_insight.rag import RagService, SourceChunk
from bht_insight.settings import get_settings

app = FastAPI(
    title="BHT Insight Foundry",
    description="Secure enterprise knowledge assistant built with Microsoft Foundry.",
    version="0.2.0",
)


class AskRequest(BaseModel):
    """Question payload accepted by the RAG endpoint."""

    question: str = Field(min_length=3, max_length=4000)


class SourceResponse(BaseModel):
    """Source metadata returned with a grounded answer."""

    id: str
    document_id: str | None
    file_name: str | None
    title: str | None
    page_number: int | None
    chunk_number: int | None
    source_uri: str | None
    classification: str | None


class AskResponse(BaseModel):
    """Grounded answer and the source chunks used to generate it."""

    answer: str
    sources: list[SourceResponse]


@lru_cache
def get_rag_service() -> RagService:
    """Create one reusable RAG client set per worker process."""

    return RagService(get_settings())


@app.get("/health", tags=["operations"])
def health() -> dict[str, str]:
    """Return minimal service health without exposing environment details."""

    return {"status": "healthy"}


@app.post("/ask", response_model=AskResponse, tags=["rag"])
def ask(request: AskRequest) -> AskResponse:
    """Answer a question from approved indexed sources only."""

    try:
        answer, sources = get_rag_service().ask(request.question)
    except Exception as exc:
        # Do not echo cloud SDK exceptions, endpoints, tokens, or resource details to callers.
        raise HTTPException(status_code=503, detail="RAG dependencies are temporarily unavailable.") from exc

    return AskResponse(
        answer=answer,
        sources=[_source_response(source) for source in sources],
    )


def _source_response(source: SourceChunk) -> SourceResponse:
    return SourceResponse(
        id=source.id,
        document_id=source.document_id,
        file_name=source.file_name,
        title=source.title,
        page_number=source.page_number,
        chunk_number=source.chunk_number,
        source_uri=source.source_uri,
        classification=source.classification,
    )
