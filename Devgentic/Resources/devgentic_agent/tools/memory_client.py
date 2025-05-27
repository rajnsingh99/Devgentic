# devgentic_agent/tools/memory_client.py
from mem0 import Mem0
from typing import Optional, List
from mem0.types import Memory as Mem0MemoryType # For type hinting

from ..config import MEM0_API_KEY # Relative import from config

class MemoryManager:
    """
    Manages interactions with the Mem0 client.
    """
    def __init__(self, api_key: Optional[str]):
        self.client: Optional[Mem0] = None
        self.initialization_error: Optional[str] = None
        self.is_configured: bool = bool(api_key)

        if api_key:
            try:
                self.client = Mem0(api_key=api_key)
                print("Mem0 client initialized successfully.")
            except Exception as e:
                self.initialization_error = f"Error initializing Mem0 client: {e}"
                print(self.initialization_error, file=sys.stderr)
        else:
            self.initialization_error = "MEM0_API_KEY not provided. Mem0 features will be disabled."
            print(self.initialization_error, file=sys.stdout)

    def add_memory(self, data: str, user_id: str, role: str, metadata: Optional[dict] = None) -> bool:
        """Adds a memory to Mem0."""
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

    def get_all_memories(self, user_id: str, limit: int = 10) -> List[Mem0MemoryType]:
        """Retrieves all memories for a user from Mem0."""
        if not self.client:
            print("Mem0 client not available, cannot retrieve memories.", file=sys.stderr)
            return []
        try:
            memories = self.client.get_all(user_id=user_id, limit=limit)
            return memories if memories else []
        except Exception as e:
            print(f"Error retrieving memories from Mem0 for user_id {user_id}: {e}", file=sys.stderr)
            return []

    def get_status(self) -> tuple[str, str | None]:
        """Returns the status of the Mem0 client ('ok', 'error', 'disabled') and an error message if any."""
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


# Initialize a global instance (or manage through dependency injection in FastAPI)
# For simplicity in this refactor, a global instance is created.
# In a larger app, you might use FastAPI's dependency injection.
memory_manager = MemoryManager(api_key=MEM0_API_KEY)

# Helper function to be used by Langchain chain
def format_mem0_history_for_prompt(history_entries: List[Mem0MemoryType]) -> str:
    """Formats Mem0 history objects into a readable string for the LLM prompt."""
    if not history_entries:
        return "No chat history found for this conversation."
    
    formatted_history = []
    for entry in history_entries: # Assuming get_all_memories already returns in desired order or is reversed before calling
        role = getattr(entry, 'role', 'user')
        content = getattr(entry, 'text', '')

        if role and role.lower() in ["ai", "assistant", "llm"]:
            formatted_history.append(f"AI: {content}")
        else:
            formatted_history.append(f"User: {content}")
    return "\n".join(formatted_history)

