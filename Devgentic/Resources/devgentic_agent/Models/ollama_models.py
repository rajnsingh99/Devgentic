# filename: Models/ollama_models.py
from pydantic import BaseModel, Field, HttpUrl, field_validator
from typing import Optional, Dict, Any, Literal


class LLMSettings(BaseModel):
    """Configuration specific to the Language Model provider."""
    model_config = {"populate_by_name": True}

    # FIXED: The provider field must be a Literal for the discriminator to work.
    provider: Literal["ollama"] = "ollama"

    base_url: HttpUrl = Field(..., alias='base_url')
    model_name: str = Field(..., alias='model_name')
    context_window_size: Optional[int] = Field(default=None, ge=0, alias='context_window_size')


class OllamaChatRequest(BaseModel):
    """Request model for the /ollama/chat endpoint."""
    model_config = {"populate_by_name": True}
    conversation_id: str = Field(..., alias='conversationId')
    prompt: str
    llm_settings: LLMSettings = Field(..., alias='llmSettings')
    metadata: Optional[dict] = None

    @field_validator('conversation_id', 'prompt')
    @classmethod
    def not_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError('Field must not be empty or consist only of whitespace.')
        return v


class AddDocumentRequest(BaseModel):
    """Request model for the /add_document endpoint."""
    text: str
    source: Optional[str] = "default_source"
    metadata: Optional[Dict[str, Any]] = None


class AddDocumentResponse(BaseModel):
    """Response model for the /add_document endpoint."""
    message: str
    document_id: Optional[str] = None
    text_preview: str
    metadata: Dict[str, Any]
