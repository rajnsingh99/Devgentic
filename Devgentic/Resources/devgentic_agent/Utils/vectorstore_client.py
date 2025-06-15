# filename: Utils/vectorstore_client.py
import sys
from typing import Optional, List, Dict, Any
from langchain_chroma import Chroma
from langchain_ollama import OllamaEmbeddings
from langchain_core.vectorstores import VectorStoreRetriever

# FIX: Import the new specific collection name
from ..config import (
    CHROMA_PERSIST_DIRECTORY,
    OLLAMA_BASE_URL,
    EMBEDDING_MODEL_NAME,
    RAG_COLLECTION_NAME
)


class VectorStoreManager:
    """
    Manages interactions with the ChromaDB vector store for RAG documents.
    """

    def __init__(self):
        self.embeddings: Optional[OllamaEmbeddings] = None
        self.vectorstore: Optional[Chroma] = None
        self.retriever: Optional[VectorStoreRetriever] = None
        self.initialization_error: Optional[str] = None

        try:
            self.embeddings = OllamaEmbeddings(
                model=EMBEDDING_MODEL_NAME,
                base_url=OLLAMA_BASE_URL
            )

            # FIX: Use the dedicated RAG collection name
            self.vectorstore = Chroma(
                collection_name=RAG_COLLECTION_NAME,
                embedding_function=self.embeddings,
                persist_directory=CHROMA_PERSIST_DIRECTORY,
            )
            print(f"ChromaDB RAG vectorstore initialized. Collection: '{RAG_COLLECTION_NAME}'")

            self.retriever = self.vectorstore.as_retriever(
                search_type="similarity",
                search_kwargs={"k": 3}
            )
        except Exception as e:
            self.initialization_error = f"Error initializing RAG VectorStore: {e}"
            print(self.initialization_error, file=sys.stderr)

    def add_documents(self, texts: List[str], metadatas: Optional[List[Dict[str, Any]]] = None) -> tuple[
        bool, Optional[List[str]]]:
        if not self.vectorstore: return False, None
        try:
            return True, self.vectorstore.add_texts(texts=texts, metadatas=metadatas)
        except Exception as e:
            print(f"Error adding documents to RAG store: {e}", file=sys.stderr)
            return False, None

    def retrieve_documents(self, query: str) -> List[Any]:
        if not self.retriever: return []
        try:
            return self.retriever.invoke(query)
        except Exception as e:
            print(f"Error retrieving documents from RAG store for query '{query}': {e}", file=sys.stderr)
            return []

    def get_status(self) -> tuple[str, str | None]:
        if self.initialization_error: return "error", self.initialization_error
        if not all([self.vectorstore, self.retriever, self.embeddings]):
            return "error", "RAG VectorStore components not fully initialized."
        try:
            self.vectorstore._collection.count()
            return "ok", "RAG ChromaDB is operational."
        except Exception as e:
            return "degraded", f"RAG ChromaDB health check failed: {e}"


vector_store_manager = VectorStoreManager()


def format_chroma_context_for_prompt(docs: List[Any]) -> str:
    """
    Formats ChromaDB documents into a readable string for the LLM prompt.
    FIXED: Returns an empty string if docs list is empty.
    """
    if not docs:
        # Return an empty string instead of a descriptive message.
        return ""
    return "\n---\n".join([
        f"Source: {doc.metadata.get('source', 'N/A')}\nContent: {doc.page_content}"
        for doc in docs
    ])
