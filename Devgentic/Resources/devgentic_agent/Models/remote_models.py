"""
This file will define the Pydantic models for chat requests to remote LLM providers
like OpenAI (ChatGPT), Google (Gemini), or Anthropic (Claude).

Future Implementation Details:
- A `RemoteChatRequest` model will be created.
- It will include a 'provider' field (e.g., "openai", "google") to specify the target service.
- It will need a mechanism to handle API keys, likely passed in a secure header or
  as part of the request body for the service to use.
- The `LLMSettings` within this request will differ from the Ollama model, as it will
  need to support provider-specific parameters (e.g., 'model' for GPT-4 vs. Gemini-Pro).
- This will allow the Swift app to send a single request format to the `/remote/chat`
  endpoint, with the backend handling the logic of routing to the correct provider.
"""

from pydantic import BaseModel, Field, HttpUrl
from typing import Optional, List, Literal

# --- Placeholder for Future Remote LLMSettings ---
class RemoteLLMSettings(BaseModel):
    """
    (Template) Configuration for remote LLM providers.
    This will be expanded to include provider-specific options.
    """
    model_config = {"populate_by_name": True}
    # The provider will be crucial for the factory pattern in the remote_service
    provider: Literal["openai", "google", "anthropic"] = Field(..., alias="provider")
    model_name: str = Field(..., alias="modelName")
    # API Key management will be a key consideration here.
    # It might be handled via environment variables on the server or passed per request.
    api_key: Optional[str] = Field(None, alias="apiKey")


# --- Placeholder for Future Remote Chat Request ---
class RemoteChatRequest(BaseModel):
    """
    (Template) Request model for the /remote/chat endpoint.
    This will serve as the contract for all interactions with external LLM providers.
    """
    model_config = {"populate_by_name": True}
    conversation_id: str = Field(..., alias="conversationId")
    prompt: str
    llm_settings: RemoteLLMSettings = Field(..., alias="llmSettings")
    metadata: Optional[dict] = None

