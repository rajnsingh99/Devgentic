# devgentic_agent/tools/mem0_conversation_storage.py
from mem0 import Memory
import sys
from typing import Optional, List, Any, Dict, Tuple # Added Dict, Tuple for full type hinting

# Importing the new interface
from .conversation_storage_interface import ConversationStorage

from ..config import MEM0_API_KEY # Relative import from config

# Removed the direct alias as per previous discussions;
# the interface's get_history returns List[Any] which is handled by format_mem0_history_for_prompt
# Mem0MemoryType = Any

class Mem0ConversationStorage(ConversationStorage): # Inherit from ConversationStorage
    """
    Manages interactions with the Mem0 client for conversation history,
    implementing the ConversationStorage interface.
    """
    def __init__(self, api_key: Optional[str]):
        self.client: Optional[Memory] = None
        self.initialization_error: Optional[str] = None
        self.is_configured: bool = bool(api_key)

        if api_key:
            try:
                self.client = Memory(api_key=api_key)
                print("Mem0 client initialized successfully.")
            except Exception as e:
                self.initialization_error = f"Error initializing Mem0 client: {e}"
                print(self.initialization_error, file=sys.stderr)
        else:
            self.initialization_error = "MEM0_API_KEY not provided. Mem0 features will be disabled."
            print(self.initialization_error, file=sys.stdout)

    def add_message(self, data: str, user_id: str, role: str, metadata: Optional[Dict] = None) -> bool:
        """Adds a message to Mem0, implementing the add_message interface method."""
        if not self.client:
            print("Mem0 client not available, cannot add memory.", file=sys.stderr)
            return False
        try:
            self.client.add(data=data, user_id=user_id, role=role, metadata=metadata)
            print(f"Added memory to Mem0 for user_id: {user_id}, role: {role}")
            return True
        except Exception as e:
            print(f"Error adding memory to Mem0 for user_id {user_id}: {e}", file=sys.stderr)
            return False

    def get_history(self, user_id: str, limit: int = 10) -> List[Any]:
        """Retrieves memories from Mem0, implementing the get_history interface method."""
        if not self.client:
            print("Mem0 client not available, cannot retrieve memories.", file=sys.stderr)
            return []
        try:
            # Mem0's get_all returns a list of its internal Memory objects,
            # which are compatible with what format_mem0_history_for_prompt expects.
            memories = self.client.get_all(user_id=user_id, limit=limit)
            return memories if memories else []
        except Exception as e:
            print(f"Error retrieving memories from Mem0 for user_id {user_id}: {e}", file=sys.stderr)
            return []

    def is_available(self) -> Tuple[str, str | None]:
        """Returns the status of the Mem0 client, implementing the is_available interface method."""
        if not self.is_configured:
            return "disabled", self.initialization_error
        if self.initialization_error:
            return "error", self.initialization_error
        if self.client:
            try:
                # Perform a lightweight check, e.g., try to access a property or a simple call
                # For now, if initialized without error, assume ok. A more robust check could be added.
                # Example: self.client.list_users(limit=1) # This might be too heavy for a simple status
                return "ok", "Mem0 client initialized and appears responsive."
            except Exception as e:
                return "degraded", f"Mem0 client initialized but health check failed: {e}"
        return "error", "Mem0 client is None despite being configured."


# The format_mem0_history_for_prompt is a helper function specific to Mem0's output
# but will be used by Langchain components. It's kept here for locality.
def format_mem0_history_for_prompt(history_entries: List[Any]) -> str:
    """Formats Mem0 history objects into a readable string for the LLM prompt."""
    if not history_entries:
        return "No chat history found for this conversation."
    
    formatted_history = []
    # Assuming each entry in history_entries has 'role' and 'text' attributes/keys
    for entry in history_entries:
        role = getattr(entry, 'role', 'user') # Use getattr for flexibility
        content = getattr(entry, 'text', '') # Use getattr for flexibility

        if role and role.lower() in ["ai", "assistant", "llm"]:
            formatted_history.append(f"AI: {content}")
        else:
            formatted_history.append(f"User: {content}")
    return "\n".join(formatted_history)

