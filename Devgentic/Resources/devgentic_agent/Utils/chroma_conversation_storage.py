import sys
from typing import Optional, List, Dict, Any, Tuple
from datetime import datetime
from langchain_chroma import Chroma
from langchain_ollama import OllamaEmbeddings

# FIX: Import the new specific history collection name and other necessary configs
from ..config import (
    CHROMA_PERSIST_DIRECTORY,
    OLLAMA_BASE_URL,
    EMBEDDING_MODEL_NAME,
    HISTORY_COLLECTION_NAME
)
from .conversation_storage_interface import ConversationStorage


class ChromaConversationStorage(ConversationStorage):
    """
    Manages conversation history using a dedicated ChromaDB collection.
    """

    def __init__(self):
        self.vectorstore: Optional[Chroma] = None
        self.initialization_error: Optional[str] = None

        try:
            # FIX: This class now initializes its own Chroma instance for history
            embeddings = OllamaEmbeddings(
                model=EMBEDDING_MODEL_NAME,
                base_url=OLLAMA_BASE_URL
            )
            self.vectorstore = Chroma(
                collection_name=HISTORY_COLLECTION_NAME,
                embedding_function=embeddings,
                persist_directory=CHROMA_PERSIST_DIRECTORY,
            )
            print(f"ChromaDB History storage initialized. Collection: '{HISTORY_COLLECTION_NAME}'")
        except Exception as e:
            self.initialization_error = f"Error initializing History ChromaDB: {e}"
            print(self.initialization_error, file=sys.stderr)

    def add_message(self, data: str, user_id: str, role: str, metadata: Optional[Dict] = None) -> bool:
        if not self.vectorstore: return False

        message_metadata = {"conversation_id": user_id, "role": role, "timestamp": datetime.now().isoformat()}
        if metadata: message_metadata.update(metadata)

        try:
            self.vectorstore.add_texts(texts=[data], metadatas=[message_metadata])
            return True
        except Exception as e:
            print(f"Error adding chat message to history store: {e}", file=sys.stderr)
            return False

    def get_history(self, user_id: str, limit: int = 10) -> List[Any]:
        if not self.vectorstore: return []
        try:
            results = self.vectorstore.get(
                where={"conversation_id": user_id},
                include=["metadatas", "documents"]
            )

            if not results or not results.get('documents'): return []

            combined_docs = [{
                "role": meta.get("role", "unknown"),
                "text": doc_content,
                "timestamp": meta.get("timestamp"),
            } for doc_content, meta in zip(results['documents'], results['metadatas'])]

            combined_docs.sort(key=lambda x: x.get("timestamp", ""))
            return combined_docs[-limit:]
        except Exception as e:
            print(f"Error retrieving chat history from store for user_id {user_id}: {e}", file=sys.stderr)
            return []

    def is_available(self) -> Tuple[str, str | None]:
        if self.initialization_error: return "error", self.initialization_error
        if not self.vectorstore: return "error", "History ChromaDB not initialized."
        try:
            self.vectorstore._collection.count()
            return "ok", "History ChromaDB is operational."
        except Exception as e:
            return "degraded", f"History ChromaDB health check failed: {e}"
