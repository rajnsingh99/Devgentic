# devgentic_agent/tools/vectorstore_client.py
import sys
from typing import Optional, List, Dict, Any
from langchain_community.vectorstores import Chroma
from langchain_community.embeddings import OllamaEmbeddings
from langchain_core.vectorstores import VectorStoreRetriever

from ..config import (
    CHROMA_PERSIST_DIRECTORY,
    OLLAMA_BASE_URL,
    EMBEDDING_MODEL_NAME,
    CHROMA_COLLECTION_NAME
)

class VectorStoreManager:
    """
    Manages interactions with the ChromaDB vector store and embeddings.
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
            print(f"OllamaEmbeddings initialized with model: {EMBEDDING_MODEL_NAME}, base_url: {OLLAMA_BASE_URL}")

            self.vectorstore = Chroma(
                collection_name=CHROMA_COLLECTION_NAME,
                embedding_function=self.embeddings,
                persist_directory=CHROMA_PERSIST_DIRECTORY,
            )
            self.retriever = self.vectorstore.as_retriever(
                search_type="similarity",
                search_kwargs={"k": 3} # Retrieve top 3 relevant docs
            )
            print(f"ChromaDB vectorstore initialized. Collection: '{CHROMA_COLLECTION_NAME}', Persist Dir: '{CHROMA_PERSIST_DIRECTORY}'")
        except Exception as e:
            self.initialization_error = f"Error initializing ChromaDB or Embeddings: {e}"
            print(self.initialization_error, file=sys.stderr)

    def add_documents(self, texts: List[str], metadatas: Optional[List[Dict[str, Any]]] = None) -> tuple[bool, Optional[List[str]]]:
        """Adds documents to ChromaDB."""
        if not self.vectorstore:
            print("ChromaDB vectorstore not available, cannot add documents.", file=sys.stderr)
            return False, None
        try:
            # Chroma's add_texts can return a list of IDs for the added documents
            doc_ids = self.vectorstore.add_texts(texts=texts, metadatas=metadatas)
            # Ensure persistence if not automatically handled by the client version/config
            # self.vectorstore.persist() # May not be needed depending on Chroma client behavior
            print(f"Successfully added {len(texts)} documents to ChromaDB. IDs: {doc_ids}")
            return True, doc_ids
        except Exception as e:
            print(f"Error adding documents to ChromaDB: {e}", file=sys.stderr)
            return False, None

    def retrieve_documents(self, query: str) -> List[Any]: # langchain.schema.document.Document
        """Retrieves relevant documents from ChromaDB based on a query."""
        if not self.retriever:
            print("ChromaDB retriever not available, cannot retrieve documents.", file=sys.stderr)
            return []
        try:
            docs = self.retriever.invoke(query)
            return docs if docs else []
        except Exception as e:
            print(f"Error retrieving documents from ChromaDB for query '{query}': {e}", file=sys.stderr)
            return []

    def get_status(self) -> tuple[str, str | None]:
        """Returns the status of the VectorStore ('ok', 'error') and an error message if any."""
        if self.initialization_error:
            return "error", self.initialization_error
        if self.vectorstore and self.retriever and self.embeddings:
            try:
                # Perform a lightweight check, e.g., count items in collection
                count = self.vectorstore._collection.count()
                return "ok", f"ChromaDB initialized. Collection has {count} items."
            except Exception as e:
                return "degraded", f"ChromaDB initialized but health check failed: {e}"
        return "error", "VectorStore components not fully initialized."

# Initialize a global instance
vector_store_manager = VectorStoreManager()

# Helper function for Langchain chain
def format_chroma_context_for_prompt(docs: List[Any]) -> str: # Any is langchain.schema.document.Document
    """Formats retrieved ChromaDB documents into a readable string for the LLM prompt."""
    if not docs:
        return "No relevant context found in documents."
    return "\n---\n".join([
        f"Source: {doc.metadata.get('source', 'N/A')}\nContent: {doc.page_content}"
        for doc in docs
    ]) if docs else "No relevant context found in documents."

