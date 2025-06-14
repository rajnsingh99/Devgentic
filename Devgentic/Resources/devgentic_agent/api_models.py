# from pydantic import BaseModel, Field, field_validator, HttpUrl, ConfigDict
# from typing import Optional, List, Dict, Any, Literal
#
# # --- Nested Models for ChatRequest ---
# class FileObject(BaseModel):
#     """Represents a file associated with the message."""
#     model_config = ConfigDict(populate_by_name=True)
#     uri: str
#     name: Optional[str] = None
#     mime_type: Optional[str] = Field(None, alias='mime_type')
#     size_bytes: Optional[int] = Field(default=None, ge=0, alias='size_bytes')
#     language: Optional[str] = None
#
#     @field_validator('uri')
#     @classmethod
#     def uri_must_not_be_empty(cls, v: str) -> str:
#         if not v.strip():
#             raise ValueError('FileObject uri must not be empty.')
#         return v
#
# class MessageContent(BaseModel):
#     """Content of the user's message, including prompt and any associated files."""
#     prompt: str
#     files: List[FileObject] = Field(default_factory=list)
#
# class LLMSettings(BaseModel):
#     """Configuration specific to the Language Model provider."""
#     model_config = ConfigDict(populate_by_name=True)
#     provider: str = Field("ollama", pattern="^(ollama|openai|anthropic|custom)$")
#     base_url: HttpUrl = Field(..., alias='base_url')
#     model_name: str = Field(..., alias='model_name')
#     temperature: Optional[float] = Field(default=None, ge=0.0, le=2.0)
#     top_k: Optional[int] = Field(default=None, ge=0, alias='top_k')
#     top_p: Optional[float] = Field(default=None, ge=0.0, le=1.0, alias='top_p')
#     repeat_penalty: Optional[float] = Field(default=None, ge=0.0, alias='repeat_penalty')
#     context_window_size: Optional[int] = Field(default=None, ge=0, alias='context_window_size')
#     gpu_layers: Optional[int] = Field(default=None, ge=-1, alias='gpu_layers')
#
#     @field_validator('model_name')
#     @classmethod
#     def model_name_must_not_be_empty(cls, v: str) -> str:
#         if not v.strip():
#             raise ValueError('LLMSettings model_name must not be empty.')
#         return v
#
# class ChatConfigItem(BaseModel): # Renamed from AgentConfigItem
#     """Configuration for a specific chat session to be used for processing the request."""
#     model_config = ConfigDict(populate_by_name=True)
#     id: str
#     role: Optional[str] = None
#     tools: List[str] = Field(default_factory=list) # Kept for potential future use
#     llm_settings: LLMSettings = Field(..., alias='llm_settings')
#
#     @field_validator('id')
#     @classmethod
#     def id_must_not_be_empty(cls, v: str) -> str:
#         if not v.strip():
#             raise ValueError('ChatConfigItem id must not be empty.')
#         return v
#
# class RequestMetadata(BaseModel):
#     """Metadata associated with the chat request."""
#     model_config = ConfigDict(populate_by_name=True)
#     client_request_id: Optional[str] = Field(None, alias='clientRequestId')
#
# # --- Main ChatRequest Model ---
# class ChatRequest(BaseModel):
#     """Request model for the /chat endpoint, reflecting the new detailed schema."""
#     model_config = ConfigDict(populate_by_name=True)
#     conversation_id: str = Field(..., alias='conversationId')
#     message_content: MessageContent = Field(..., alias='messageContent')
#     chat_config: List[ChatConfigItem] = Field(..., alias='chatConfig') # Renamed from agentConfig
#     metadata: RequestMetadata
#
#     @field_validator('conversation_id')
#     @classmethod
#     def conversation_id_must_not_be_empty(cls, v: str) -> str:
#         if not v.strip():
#             raise ValueError('conversationId must not be empty or consist only of whitespace.')
#         return v
#
#     @field_validator('chat_config') # Updated validator
#     @classmethod
#     def chat_config_must_not_be_empty(cls, v: List[ChatConfigItem]) -> List[ChatConfigItem]:
#         if not v:
#             raise ValueError('chatConfig list must not be empty. At least one chat configuration is required.')
#         return v
#
#     @field_validator('message_content')
#     @classmethod
#     def prompt_in_message_content_must_not_be_empty(cls, v: MessageContent) -> MessageContent:
#         if not v.prompt.strip():
#             raise ValueError('Prompt in messageContent must not be empty or consist only of whitespace.')
#         return v
#
# # --- Models for Richer Client-Side Interactions ---
#
# class Alert(BaseModel):
#     level: Literal["warning", "critical"]
#     title: str
#     message: str
#
# class Action(BaseModel):
#     type: Literal["new_chat_with_summary", "upgrade_llm"]
#     displayText: str
#
# class Suggestion(BaseModel):
#     actions: List[Action]
#     suggested_models: Optional[List[str]] = Field(None, description="A list of suggested model names for upgrade.")
#
# # --- Updated Response and Other Models ---
#
# class ChatResponse(BaseModel):
#     response: str
#     conversation_id: str
#     alert: Optional[Alert] = None
#     suggestion: Optional[Suggestion] = None
#
# class AddDocumentRequest(BaseModel):
#     text: str
#     source: Optional[str] = "default_source"
#     metadata: Optional[Dict[str, Any]] = None
#
# class AddDocumentResponse(BaseModel):
#     message: str
#     document_id: Optional[str] = None
#     text_preview: str
#     metadata: Dict[str, Any]
#
# # --- Models for Summarization Endpoint ---
#
# class SummarizeRequest(BaseModel):
#     model_config = ConfigDict(populate_by_name=True)
#     conversation_id: str = Field(..., alias='conversationId')
#
#     @field_validator('conversation_id')
#     @classmethod
#     def conversation_id_must_not_be_empty(cls, v: str) -> str:
#         if not v.strip():
#             raise ValueError('conversationId must not be empty or consist only of whitespace.')
#         return v
#
# class SummarizeResponse(BaseModel):
#     summary: str
#
# # --- Health Check Models ---
# class ServiceStatus(BaseModel):
#     service: str
#     status: str
#     message: Optional[str] = None
#
# class HealthCheckResponse(BaseModel):
#     overall_status: str
#     chat_model: Optional[str] = None
#     embedding_model: str
#     pid: int
#     services: List[ServiceStatus]
