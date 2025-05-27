# devgentic_agent/models/api_models.py
from pydantic import BaseModel
from typing import Optional, Dict, Any, List

class ChatRequest(BaseModel):
    """
    Request model for the /chat endpoint.
    """
    user_prompt: str
    conversation_id: Optional[str] = None
    # metadata: Optional[Dict[str, Any]] = None # Future use for Mem0 or other metadata

class ChatResponse(BaseModel):
    """
    Response model for the /chat endpoint.
    """
    response: str
    conversation_id: Optional[str] = None
    # retrieved_context_sources: Optional[List[str]] = None # Future: if you want to return sources

class AddDocumentRequest(BaseModel):
    """
    Request model for the /add_document endpoint.
    """
    text: str
    source: Optional[str] = "default_source" # Default source if not provided
    metadata: Optional[Dict[str, Any]] = None

class AddDocumentResponse(BaseModel):
    """
    Response model for the /add_document endpoint.
    """
    message: str
    document_id: Optional[str] = None # ChromaDB might return IDs for added docs
    text_preview: str # A preview of the added text
    metadata: Dict[str, Any]

# --- Health Check Models ---
class ServiceStatus(BaseModel):
    """
    Model for reporting status of individual services in health check.
    """
    service: str
    status: str # e.g., "ok", "error", "degraded", "disabled"
    message: Optional[str] = None

class HealthCheckResponse(BaseModel):
    """
    Response model for the /health endpoint.
    """
    overall_status: str # e.g., "ok", "error", "degraded"
    chat_model: str
    embedding_model: str
    pid: int
    services: List[ServiceStatus]

# You can add more Pydantic models here as your API evolves.
