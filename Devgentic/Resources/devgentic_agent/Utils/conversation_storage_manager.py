
import sys
from typing import Optional, List, Dict, Any, Tuple

from .conversation_storage_interface import ConversationStorage
from .chroma_conversation_storage import ChromaConversationStorage

def format_conversation_history_for_prompt(history_entries: List[Any]) -> str:
    """
    Formats history objects (from ChromaDB) into a readable string for the LLM prompt.
    This function is now defined here and adapted for dictionary-based history entries.
    """
    if not history_entries:
        return "No chat history found for this conversation."
    
    formatted_history = []
    # Adapted to use dictionary access .get() instead of getattr()
    for entry in history_entries:
        role = entry.get('role', 'user')
        content = entry.get('text', '')

        if role and role.lower() in ["ai", "assistant", "llm"]:
            formatted_history.append(f"AI: {content}")
        else:
            formatted_history.append(f"User: {content}")
    return "\n".join(formatted_history)

class ConversationStorageManager:
    """
    Manages the conversation history storage backend, now exclusively using ChromaDB.
    """
    def __init__(self):
        self._active_storage: ConversationStorage
        self.active_backend_name: str
        self.initialization_error: Optional[str] = None

        # Removed conditional logic for Mem0. Always use ChromaDB.
        self._active_storage = ChromaConversationStorage()
        self.active_backend_name = "ChromaDB"
        print("ConversationStorageManager: Using ChromaDB for conversation history.")

        # Check the status of the backend immediately
        status, msg = self._active_storage.is_available()
        if status == "error":
            self.initialization_error = f"Conversation storage backend ({self.active_backend_name}) initialized with errors: {msg}"
            print(self.initialization_error, file=sys.stderr)
        elif status == "degraded":
            print(f"Conversation storage backend ({self.active_backend_name}) is in a degraded state: {msg}", file=sys.stdout)
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