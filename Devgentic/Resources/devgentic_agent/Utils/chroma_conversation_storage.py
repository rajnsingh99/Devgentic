import sys
from typing import Optional, List, Dict, Any, Tuple
from datetime import datetime

from .conversation_storage_interface import ConversationStorage
from .vectorstore_client import vector_store_manager


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
        """
        if self.initialization_error:
            print(f"ChromaDB conversation storage not available: {self.initialization_error}", file=sys.stderr)
            return False

        message_metadata = {
            "conversation_id": user_id,
            "role": role,
            "timestamp": datetime.now().isoformat(),
            "type": "chat_message",
        }
        if metadata:
            message_metadata.update(metadata)

        success, doc_ids = self.vector_store_manager.add_documents(
            texts=[data],
            metadatas=[message_metadata]
        )
        if success:
            print(
                f"Added chat message to ChromaDB for user_id: {user_id}, role: {role}. Doc ID: {doc_ids[0] if doc_ids else 'N/A'}")
        else:
            print(f"Error adding chat message to ChromaDB for user_id {user_id}.", file=sys.stderr)
        return success

    def get_history(self, user_id: str, limit: int = 10) -> List[Any]:
        """
        Retrieves chat messages from ChromaDB for a given conversation ID using a metadata filter.
        """
        if self.initialization_error or not self.vector_store_manager.vectorstore:
            print(f"ChromaDB conversation storage not available: {self.initialization_error}", file=sys.stderr)
            return []

        print(f"\n--- Retrieving history for conversation_id: {user_id} (limit: {limit}) ---", file=sys.stdout)
        try:
            # Use a direct metadata filter to get all documents for a conversation_id.
            results = self.vector_store_manager.vectorstore.get(
                where={"conversation_id": user_id},
                include=["metadatas", "documents"]
            )

            raw_doc_count = len(results.get('documents', []))
            print(f"Step 1: Found {raw_doc_count} raw documents in ChromaDB for this conversation_id.", file=sys.stdout)

            if not results or not results.get('documents'):
                print("--- History retrieval finished: No documents found. ---\n", file=sys.stdout)
                return []

            # Combine the retrieved metadata and documents into a single list of objects
            combined_docs = []
            for i, doc_content in enumerate(results['documents']):
                meta = results['metadatas'][i]
                # We can add a secondary check here if other document types might share a conversation_id
                if meta.get("type") == "chat_message":
                    combined_docs.append({
                        "role": meta.get("role", "unknown"),
                        "text": doc_content,
                        "timestamp": meta.get("timestamp"),
                        "metadata": meta
                    })

            print(f"Step 2: Assembled {len(combined_docs)} messages of type 'chat_message'.", file=sys.stdout)

            # Sort chronologically by timestamp
            combined_docs.sort(key=lambda x: x.get("timestamp", ""))
            print(f"Step 3: Sorted {len(combined_docs)} messages chronologically.", file=sys.stdout)

            # Apply the limit to get the most recent messages
            final_history = combined_docs[-limit:]
            print(f"Step 4: Returning the last {len(final_history)} messages due to limit.", file=sys.stdout)
            print(f"--- History retrieval finished for conversation_id: {user_id} ---\n", file=sys.stdout)

            return final_history

        except Exception as e:
            print(f"Error retrieving chat history directly from ChromaDB for user_id {user_id}: {e}", file=sys.stderr)
            return []

    def is_available(self) -> Tuple[str, str | None]:
        """
        Checks the availability of the ChromaDB conversation storage.
        """
        status, msg = self.vector_store_manager.get_status()
        if self.initialization_error:
            return "error", self.initialization_error

        if status == "ok":
            return "ok", "ChromaDB conversation storage is available."
        elif status == "degraded":
            return "degraded", f"ChromaDB conversation storage degraded: {msg}"
        return "error", f"ChromaDB conversation storage error: {msg}"
