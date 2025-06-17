# filename: Models/remote_models.py
from pydantic import BaseModel, Field, field_validator
from typing import Optional, List, Literal

# --- File Object Model ---
# This can be a common model, but we define it here for clarity.
class FileObject(BaseModel):
    """Represents a file to be processed."""
    uri: str = Field(..., description="The local URI of the file.")
    name: Optional[str] = None

    @field_validator('uri')
    @classmethod
    def uri_must_be_valid(cls, v: str) -> str:
        if not v.strip():
            raise ValueError('File URI must not be empty.')
        # A more robust validation could check for file existence or scheme.
        return v

# --- Models for Remote Providers ---

class RemoteLLMSettings(BaseModel):
    """
    Configuration for remote LLM providers like OpenAI, Google, etc.
    """
    model_config = {"populate_by_name": True}

    provider: Literal["openai", "google", "anthropic"] = Field(
        ...,
        alias="provider",
        description="The name of the remote provider."
    )
    model_name: str = Field(
        ...,
        alias="modelName",
        description="The specific model name for the chosen provider (e.g., 'gpt-4o-mini', 'gemini-1.5-flash-latest')."
    )
    api_key: str = Field(
        ...,
        alias="apiKey",
        description="The API key for the remote service."
    )
    context_window_size: Optional[int] = Field(
        default=None,
        ge=0,
        alias='contextWindowSize',
        description="The context window size for the model, used for token management."
    )

    @field_validator('api_key', 'model_name')
    @classmethod
    def not_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError('Field must not be empty or consist only of whitespace.')
        return v


class RemoteChatRequest(BaseModel):
    """
    Request model for the /remote/chat endpoint.
    MODIFIED: Now includes a list of files.
    """
    model_config = {"populate_by_name": True}

    conversation_id: str = Field(..., alias="conversationId")
    prompt: str
    # ADDED: files field to accept a list of file objects
    files: Optional[List[FileObject]] = Field(default_factory=list, description="A list of files to be included as context.")
    llm_settings: RemoteLLMSettings = Field(..., alias="llmSettings")
    metadata: Optional[dict] = None

    @field_validator('conversation_id', 'prompt')
    @classmethod
    def not_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError('Field must not be empty or consist only of whitespace.')
        return v
