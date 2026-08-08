"""Grounded retrieval-augmented generation for BHT Insight Phase 1A."""

from dataclasses import dataclass
from typing import Any

from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from azure.search.documents import SearchClient
from azure.search.documents.models import VectorizedQuery
from openai import AzureOpenAI

from bht_insight.settings import Settings


@dataclass(frozen=True)
class SourceChunk:
    """A retrievable source chunk returned with an answer."""

    id: str
    document_id: str | None
    file_name: str | None
    title: str | None
    content: str
    page_number: int | None
    chunk_number: int | None
    source_uri: str | None
    classification: str | None


class RagService:
    """Perform keyless hybrid retrieval and grounded answer generation."""

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._credential = DefaultAzureCredential()
        self._search = SearchClient(
            endpoint=settings.azure_search_endpoint,
            index_name=settings.azure_search_index,
            credential=self._credential,
        )
        token_provider = get_bearer_token_provider(
            self._credential, "https://cognitiveservices.azure.com/.default"
        )
        self._openai = AzureOpenAI(
            azure_endpoint=settings.azure_openai_endpoint,
            azure_ad_token_provider=token_provider,
            api_version=settings.azure_openai_api_version,
        )

    def ask(self, question: str) -> tuple[str, list[SourceChunk]]:
        """Answer a question using only retrieved approved knowledge chunks."""

        embedding_response = self._openai.embeddings.create(
            model=self._settings.azure_openai_embedding_deployment,
            input=question,
            dimensions=1536,
        )
        vector = embedding_response.data[0].embedding

        vector_query = VectorizedQuery(
            vector=vector,
            k_nearest_neighbors=self._settings.retrieval_top_k,
            fields="content_vector",
        )

        results = self._search.search(
            search_text=question,
            vector_queries=[vector_query],
            query_type="semantic",
            semantic_configuration_name="bht-semantic",
            top=self._settings.retrieval_top_k,
            select=[
                "id",
                "document_id",
                "file_name",
                "title",
                "content",
                "page_number",
                "chunk_number",
                "source_uri",
                "classification",
            ],
        )

        sources = [self._to_source(dict(result)) for result in results]
        if not sources:
            return (
                "I could not find enough approved source material to answer that question.",
                [],
            )

        context = self._build_context(sources)
        completion = self._openai.chat.completions.create(
            model=self._settings.azure_openai_chat_deployment,
            temperature=0.1,
            messages=[
                {
                    "role": "system",
                    "content": (
                        "You are BHT Insight. Answer only from the supplied approved context. "
                        "Do not invent facts. If the context is insufficient, say so. "
                        "Cite supporting chunks inline using [S1], [S2], and so on."
                    ),
                },
                {
                    "role": "user",
                    "content": f"Question:\n{question}\n\nApproved context:\n{context}",
                },
            ],
        )

        answer = completion.choices[0].message.content
        if not answer:
            answer = "The model returned no answer."

        return answer, sources

    @staticmethod
    def _to_source(result: dict[str, Any]) -> SourceChunk:
        return SourceChunk(
            id=str(result.get("id", "")),
            document_id=_optional_str(result.get("document_id")),
            file_name=_optional_str(result.get("file_name")),
            title=_optional_str(result.get("title")),
            content=str(result.get("content", "")),
            page_number=_optional_int(result.get("page_number")),
            chunk_number=_optional_int(result.get("chunk_number")),
            source_uri=_optional_str(result.get("source_uri")),
            classification=_optional_str(result.get("classification")),
        )

    @staticmethod
    def _build_context(sources: list[SourceChunk]) -> str:
        blocks: list[str] = []
        for index, source in enumerate(sources, start=1):
            label = f"S{index}"
            metadata = (
                f"file={source.file_name or 'unknown'}; "
                f"page={source.page_number if source.page_number is not None else 'n/a'}; "
                f"chunk={source.chunk_number if source.chunk_number is not None else 'n/a'}"
            )
            blocks.append(f"[{label}] {metadata}\n{source.content}")
        return "\n\n".join(blocks)


def _optional_str(value: Any) -> str | None:
    return None if value is None else str(value)


def _optional_int(value: Any) -> int | None:
    if value is None:
        return None
    return int(value)
