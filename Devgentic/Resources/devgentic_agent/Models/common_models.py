from pydantic import BaseModel, Field
from typing import Optional, List, Literal

class Alert(BaseModel):
    """Model for a critical alert to be shown to the user."""
    level: Literal["warning", "critical"]
    title: str
    message: str

class Action(BaseModel):
    """Model for a single suggested action the user can take."""
    type: Literal["new_chat_with_summary", "upgrade_llm"]
    displayText: str

class Suggestion(BaseModel):
    """Model for providing actionable suggestions to the user."""
    actions: List[Action]
    suggested_models: Optional[List[str]] = Field(None, description="A list of suggested model names for upgrade.")

class GeneralChatResponse(BaseModel):
    """A general response structure that can be used across different providers."""
    response: str
    conversation_id: str
    alert: Optional[Alert] = None
    suggestion: Optional[Suggestion] = None

