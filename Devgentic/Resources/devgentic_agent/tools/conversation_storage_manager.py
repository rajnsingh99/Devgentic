# devgentic_agent/tools/conversation_storage_manager.py
import sys
from typing import Optional, List, Dict, Any, Tuple

from ..config import MEM0_API_KEY
from .conversation_storage_interface import ConversationStorage
from .mem0_conversation_storage import Mem0ConversationStorage, format_mem0_history_for_prompt
from .chroma_conversation_storage import ChromaConversationStorage

class ConversationStorageManager:
    """
    Manages the active conversation history storage backend.
    Selects between Mem0 and ChromaDB based on MEM0_API_KEY availability.
    Provides a unified interface for adding and retrieving conversation messages.
    """
    def __init__(self):
        self._active_storage: ConversationStorage
        self.active_backend_name: str
        self.initialization_error: Optional[str] = None

        if MEM0_API_KEY:
            self._active_storage = Mem0ConversationStorage(api_key=MEM0_API_KEY)
            self.active_backend_name = "Mem0"
            print("ConversationStorageManager: Using Mem0 backend for conversation history.")
        else:
            self._active_storage = ChromaConversationStorage()
            self.active_backend_name = "ChromaDB"
            print("ConversationStorageManager: MEM0_API_KEY not provided. Falling back to ChromaDB for conversation history.")

        # Check the status of the selected backend immediately
        status, msg = self._active_storage.is_available()
        if status == "error":
            self.initialization_error = f"Selected conversation storage backend ({self.active_backend_name}) initialized with errors: {msg}"
            print(self.initialization_error, file=sys.stderr)
        elif status == "degraded":
            print(f"Selected conversation storage backend ({self.active_backend_name}) is in a degraded state: {msg}", file=sys.stdout)
        elif status == "disabled":
            # This case primarily applies to Mem0 if key is missing, already handled by fallback logic
            print(f"Selected conversation storage backend ({self.active_backend_name}) is disabled: {msg}", file=sys.stdout)
        else:
            print(f"ConversationStorageManager: Active backend '{self.active_backend_name}' is ready.")


    def add_message(self, data: str, user_id: str, role: str, metadata: Optional[Dict] = None) -> bool:
        """Proxies the add_message call to the active storage backend."""
        return self._active_storage.add_message(data, user_id, role, metadata)

    def get_history(self, user_id: str, limit: int = 10) -> List[Any]:
        """Proxies the get_history call to the active storage backend."""
        return self._active_storage.get_history(user_id, limit)

    def is_available(self) -> Tuple[str, str | None]:
        """Proxies the is_available call to the active storage backend."""
        return self._active_storage.is_available()

# Initialize a global instance
conversation_storage_manager = ConversationStorageManager()

# Re-export format_mem0_history_for_prompt for Langchain components
# This function is designed to work with the generic List[Any] output
# from get_history, so it's compatible with both Mem0 and ChromaDB outputs
# as long as they provide 'role' and 'text' attributes/keys.
# It's kept here for convenience of import for Langchain components.
format_conversation_history_for_prompt = format_mem0_history_for_prompt
