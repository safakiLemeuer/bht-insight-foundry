"""Application entry point for BHT Insight.

This module intentionally contains only a health endpoint during repository
bootstrap. Business functionality will be added through small, reviewed changes.
"""

from fastapi import FastAPI

app = FastAPI(
    title="BHT Insight Foundry",
    description="Secure enterprise knowledge assistant built with Azure AI Foundry.",
    version="0.1.0",
)


@app.get("/health", tags=["operations"])
async def health() -> dict[str, str]:
    """Return service health for local and deployment smoke tests.

    Returns:
        A minimal status payload that does not expose environment details,
        resource identifiers, dependency versions, or secrets.
    """
    return {"status": "healthy"}
