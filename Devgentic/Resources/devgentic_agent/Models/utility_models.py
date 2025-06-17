# filename: Models/utility_models.py
from pydantic import BaseModel, Field
from typing import List, Optional, Dict, Any, Literal

class ModelDetail(BaseModel):
    """Represents a single available model from a provider."""
    id: str
    owned_by: Optional[str] = None
    display_name: Optional[str] = None

class ServiceStatus(BaseModel):
    """Represents the status of a single backend service."""
    service: str
    status: Literal["ok", "degraded", "error"]
    message: Optional[str] = None

class HealthCheckResponse(BaseModel):
    """Response model for the system-wide health check."""
    overall_status: Literal["ok", "degraded", "error"]
    services: List[ServiceStatus]

