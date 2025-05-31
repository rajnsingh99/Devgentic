# devgentic_agent/models/api_models.py
from pydantic import BaseModel, Field, field_validator, HttpUrl
from typing import Optional, List, Dict, Any

# --- New Nested Models for ChatRequest ---
class MessageContent(BaseModel):
    """
    Content of the user's message, including prompt and any associated files.
    """
    prompt: str
    files: List[str] = Field(default_factory=list) # Files are optional, default to empty list

class AgentConfigItem(BaseModel):
    """
    Configuration for a specific agent to be used for processing the request.
    """
    ollama_url: HttpUrl # Use HttpUrl for automatic validation
    model: str
    tools: List[str] = Field(default_factory=list) # Tools are optional, default to empty list

class RequestMetadata(BaseModel):
    """
    Metadata associated with the chat request, e.g., to indicate model changes.
    """
    modelChanged: bool

# --- Updated ChatRequest Model ---
class ChatRequest(BaseModel):
    """
    Request model for the /chat endpoint, reflecting the new detailed schema.
    """
    conversationId: str # Now mandatory
    messageContent: MessageContent
    agentConfig: List[AgentConfigItem] # A list of agent configurations
    metadata: RequestMetadata

    @field_validator('conversationId')
    @classmethod
    def conversation_id_must_not_be_empty(cls, v: str) -> str:
        """Ensures conversationId is not an empty or whitespace-only string."""
        if not v.strip():
            raise ValueError('conversationId must not be empty or consist only of whitespace.')
        return v

    @field_validator('agentConfig')
    @classmethod
    def agent_config_must_not_be_empty(cls, v: List[AgentConfigItem]) -> List[AgentConfigItem]:
        """Ensures the agentConfig list contains at least one configuration item."""
        if not v:
            raise ValueError('agentConfig list must not be empty. At least one agent configuration is required.')
        return v
    
    @field_validator('messageContent')
    @classmethod
    def prompt_in_message_content_must_not_be_empty(cls, v: MessageContent) -> MessageContent:
        """Ensures the prompt within messageContent is not empty."""
        if not v.prompt.strip():
            raise ValueError('Prompt in messageContent must not be empty or consist only of whitespace.')
        return v

# --- Existing Models (may need review or updates based on new ChatRequest handling) ---
class ChatResponse(BaseModel):
    """
    Response model for the /chat endpoint.
    """
    response: str
    conversation_id: str 
    notification: Optional[str] = None # Added field for client notifications (e.g., model change issues)

class AddDocumentRequest(BaseModel):
    """
    Request model for the /add_document endpoint.
    """
    text: str
    source: Optional[str] = "default_source" 
    metadata: Optional[Dict[str, Any]] = None

class AddDocumentResponse(BaseModel):
    """
    Response model for the /add_document endpoint.
    """
    message: str
    document_id: Optional[str] = None 
    text_preview: str 
    metadata: Dict[str, Any]

# --- Health Check Models ---
class ServiceStatus(BaseModel):
    """
    Model for reporting status of individual services in health check.
    """
    service: str
    status: str 
    message: Optional[str] = None

class HealthCheckResponse(BaseModel):
    """
    Response model for the /health endpoint.
    """
    overall_status: str 
    chat_model: Optional[str] = None 
    embedding_model: str
    pid: int
    services: List[ServiceStatus]
