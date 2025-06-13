# devgentic_agent/tools/chroma_conversation_storage.py
import sys
from typing import Optional, List, Dict, Any, Tuple
from datetime import datetime

# Importing the new interface
from .conversation_storage_interface import ConversationStorage
from .vectorstore_client import vector_store_manager # Reusing the existing ChromaDB manager

class ChromaConversationStorage(ConversationStorage):
    """
    Manages conversation history using ChromaDB, implementing the ConversationStorage interface.
    Stores chat messages as documents in ChromaDB with specific metadata.
    """

    def __init__(self):
        self.vector_store_manager = vector_store_manager
        self.initialization_error: Optional[str] = None
        self._check_initialization()
        print("ChromaConversationStorage initialized.")

    def _check_initialization(self):
        """Internal helper to check if vector store is ready."""
        status, msg = self.vector_store_manager.get_status()
        if status == "error":
            self.initialization_error = f"ChromaDB backend not available: {msg}"
            print(f"ChromaConversationStorage initialization error: {self.initialization_error}", file=sys.stderr)
        else:
            self.initialization_error = None

    def add_message(self, data: str, user_id: str, role: str, metadata: Optional[Dict] = None) -> bool:
        """
        Adds a single chat message to ChromaDB.
        Messages are stored as documents with metadata to identify them as chat history.
        """
        if self.initialization_error:
            print(f"ChromaDB conversation storage not available: {self.initialization_error}", file=sys.stderr)
            return False

        message_metadata = {
            "conversation_id": user_id,
            "role": role,
            "timestamp": datetime.now().isoformat(), # Store timestamp for ordering
            "type": "chat_message", # Custom type to distinguish from other RAG documents
        }
        if metadata:
            message_metadata.update(metadata)

        success, doc_ids = self.vector_store_manager.add_documents(
            texts=[data],
            metadatas=[message_metadata]
        )
        if success:
            print(f"Added chat message to ChromaDB for user_id: {user_id}, role: {role}. Doc ID: {doc_ids[0] if doc_ids else 'N/A'}")
        else:
            print(f"Error adding chat message to ChromaDB for user_id {user_id}.", file=sys.stderr)
        return success

    def get_history(self, user_id: str, limit: int = 10) -> List[Any]:
        """
        Retrieves chat messages from ChromaDB for a given conversation ID.
        This attempts to retrieve documents tagged as 'chat_message' for the specific conversation ID.
        """
        if self.initialization_error:
            print(f"ChromaDB conversation storage not available: {self.initialization_error}", file=sys.stderr)
            return []

        # ChromaDB's retriever primarily uses semantic similarity.
        # To get chronological history, we might need to retrieve broadly and then filter/sort.
        # A direct metadata filter for get_history functionality is generally more robust
        # but the retriever's invoke method focuses on semantic search.
        # For a true chronological retrieval, directly querying the collection with WHERE clauses
        # would be better, but we are using the simpler retriever abstraction here.
        # We will retrieve based on a general query to ensure we get *all* chat messages for the user.
        # The 'query' here is generic to ensure it hits relevant documents,
        # but the primary filtering will be on metadata after retrieval.

        # A more robust solution for getting exact history might involve:
        # 1. Extending vectorstore_client.py to expose direct Chroma collection querying.
        # 2. Or, for simplicity, using a broad query and filtering results.
        # For now, we'll use a broad query and filter by metadata.
        # Note: This approach might not be perfectly efficient for very large histories
        # as it still relies on semantic search for initial retrieval.

        # Query that encourages retrieval of conversation messages.
        # This is a heuristic; direct metadata filtering (if exposed by vectorstore_client) is better.
        query_text = f"Show me the conversation history for user {user_id}"

        # Retrieve documents using the existing retriever
        # We assume the retriever might return more than just chat messages,
        # so we filter post-retrieval.
        try:
            docs = self.vector_store_manager.retrieve_documents(query=query_text)
            
            # Filter and sort by timestamp
            conversation_messages = []
            for doc in docs:
                # Ensure it's a chat message for this conversation_id
                if (doc.metadata.get("type") == "chat_message" and
                    doc.metadata.get("conversation_id") == user_id):
                    conversation_messages.append({
                        "role": doc.metadata.get("role", "unknown"),
                        "text": doc.page_content,
                        "timestamp": doc.metadata.get("timestamp"),
                        "metadata": doc.metadata # Include all metadata if useful
                    })
            
            # Sort chronologically
            conversation_messages.sort(key=lambda x: x.get("timestamp", ""))
            
            # Apply limit
            return conversation_messages[-limit:] if limit else conversation_messages

        except Exception as e:
            print(f"Error retrieving chat history from ChromaDB for user_id {user_id}: {e}", file=sys.stderr)
            return []

    def is_available(self) -> Tuple[str, str | None]:
        """
        Checks the availability of the ChromaDB conversation storage.
        Delegates to the underlying vector_store_manager's status.
        """
        status, msg = self.vector_store_manager.get_status()
        if self.initialization_error:
            return "error", self.initialization_error
        # Translate vector store status to conversation storage status
        if status == "ok":
            return "ok", "ChromaDB conversation storage is available."
        elif status == "degraded":
            return "degraded", f"ChromaDB conversation storage degraded: {msg}"
        return "error", f"ChromaDB conversation storage error: {msg}"

