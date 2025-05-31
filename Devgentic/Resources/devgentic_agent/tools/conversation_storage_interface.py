# devgentic_agent/tools/conversation_storage_interface.py
from abc import ABC, abstractmethod
from typing import Optional, List, Dict, Any, Tuple

class ConversationStorage(ABC):
    """
    Abstract Base Class (ABC) for conversation history storage backends.
    Defines the interface that all concrete conversation storage implementations must follow.
    """

    @abstractmethod
    def __init__(self, **kwargs):
        """
        Initializes the conversation storage backend.
        Specific implementations will handle their own initialization parameters.
        """
        pass

    @abstractmethod
    def add_message(self, data: str, user_id: str, role: str, metadata: Optional[Dict] = None) -> bool:
        """
        Adds a single chat message (user or AI) to the conversation history.

        Args:
            data (str): The content of the message.
            user_id (str): The ID of the conversation/user.
            role (str): The role of the sender (e.g., "user", "ai").
            metadata (Optional[Dict]): Additional metadata for the message.

        Returns:
            bool: True if the message was added successfully, False otherwise.
        """
        pass

    @abstractmethod
    def get_history(self, user_id: str, limit: int = 10) -> List[Any]:
        """
        Retrieves a list of past messages for a given user/conversation ID.

        Args:
            user_id (str): The ID of the conversation/user.
            limit (int): The maximum number of messages to retrieve.

        Returns:
            List[Any]: A list of message objects/dictionaries, preferably sorted chronologically.
                       The structure of the objects/dictionaries should ideally be consistent
                       across implementations (e.g., each item having 'role' and 'text' attributes/keys).
        """
        pass

    @abstractmethod
    def is_available(self) -> Tuple[str, str | None]:
        """
        Checks the availability and health of the conversation storage backend.

        Returns:
            Tuple[str, Optional[str]]: A tuple containing:
                - status (str): "ok", "error", "disabled", "degraded"
                - message (Optional[str]): A descriptive message about the status.
        """
        pass

