"""Azure Functions entry point for the BHT Insight FastAPI application."""

import sys
from pathlib import Path

import azure.functions as func

SRC = Path(__file__).resolve().parent / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from bht_insight.main import app as fastapi_app  # noqa: E402

app = func.AsgiFunctionApp(app=fastapi_app, http_auth_level=func.AuthLevel.ANONYMOUS)
