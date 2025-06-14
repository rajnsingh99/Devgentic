from abc import ABC, abstractmethod
from ..Models.common_models import GeneralChatResponse

class BaseChatService(ABC):
    """
    Abstract Base Class for chat services. Defines the common interface
    that all provider-specific services (Ollama, Remote, Agent) must implement.
    """
    @abstractmethod
    async def process_chat_interaction(self, request_payload: any) -> GeneralChatResponse:
        """
        Processes a chat request payload and returns a standardized chat response.

        Args:
            request_payload (any): The provider-specific request model.

        Returns:
            GeneralChatResponse: A standardized response object.
        """
        pass
