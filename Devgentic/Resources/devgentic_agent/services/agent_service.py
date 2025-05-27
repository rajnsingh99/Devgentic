# devgentic_agent/services/agent_service.py
import sys
from typing import Optional, Dict, Any, Tuple, List

from ..models.api_models import ChatRequest, AddDocumentRequest, ChatResponse, AddDocumentResponse
# Import managers from the tools package
from ..tools.memory_client import memory_manager
from ..tools.vectorstore_client import vector_store_manager
from ..tools.langchain_components import langchain_pipeline_manager

class AgentService:
    """
    Service layer containing the core business logic for the agent.
    """
    def __init__(self):
        # Check if essential components are initialized
        # This service relies on the global instances from the tools modules
        self.is_ready = (
            memory_manager is not None and
            vector_store_manager is not None and
            langchain_pipeline_manager is not None and
            langchain_pipeline_manager.chain is not None # Crucial check
        )
        if not self.is_ready:
            print("AgentService initialized, but one or more underlying tools (memory, vectorstore, langchain pipeline) might not be fully ready. Check logs.", file=sys.stderr)
        else:
            print("AgentService initialized and ready.")


    async def process_chat_interaction(self, request_payload: ChatRequest) -> ChatResponse:
        """
        Processes a chat request, interacts with Mem0, Langchain pipeline, and returns a response.
        """
        user_prompt = request_payload.user_prompt
        conversation_id = request_payload.conversation_id

        if not langchain_pipeline_manager.chain: # Or check langchain_pipeline_manager.get_status()
            raise RuntimeError("Langchain processing chain is not available. Cannot process chat.")

        # 1. Add user message to Mem0 (if configured and conversation_id is present)
        if memory_manager.client and conversation_id:
            memory_manager.add_memory(
                data=user_prompt,
                user_id=conversation_id,
                role="user"
            )
            # No need to print here, memory_manager.add_memory already prints

        # 2. Invoke the Langchain pipeline
        # The pipeline itself handles fetching history from Mem0 and context from ChromaDB
        try:
            ai_response_content = await langchain_pipeline_manager.invoke_chain(
                user_prompt=user_prompt,
                conversation_id=conversation_id
            )
        except Exception as e:
            print(f"Error during Langchain pipeline invocation: {e}", file=sys.stderr)
            # Re-raise or handle more gracefully, perhaps returning a specific error response
            raise RuntimeError(f"Error processing chat with LLM: {e}")


        # 3. Add AI response to Mem0 (if configured and conversation_id is present)
        if memory_manager.client and conversation_id and ai_response_content:
            memory_manager.add_memory(
                data=ai_response_content,
                user_id=conversation_id,
                role="ai" # Or "assistant" / "llm" depending on Mem0 conventions
            )

        return ChatResponse(response=ai_response_content, conversation_id=conversation_id)

    def add_document_to_vectorstore(self, request_payload: AddDocumentRequest) -> AddDocumentResponse:
        """
        Adds a document to the ChromaDB vector store.
        """
        if not vector_store_manager.vectorstore:
            raise RuntimeError("Vector store (ChromaDB) is not available. Cannot add document.")

        doc_metadata = {"source": request_payload.source}
        if request_payload.metadata:
            doc_metadata.update(request_payload.metadata)
        
        success, doc_ids = vector_store_manager.add_documents(
            texts=[request_payload.text],
            metadatas=[doc_metadata]
        )

        if success:
            # ChromaDB's add_texts can return a list of IDs.
            # We are adding one text, so we expect one ID if returned.
            doc_id = doc_ids[0] if doc_ids and len(doc_ids) > 0 else None
            return AddDocumentResponse(
                message="Document added successfully to ChromaDB.",
                document_id=doc_id,
                text_preview=request_payload.text[:100] + "..." if len(request_payload.text) > 100 else request_payload.text,
                metadata=doc_metadata
            )
        else:
            # The error is already printed by vector_store_manager
            raise RuntimeError("Failed to add document to ChromaDB.")

# Global instance of the service
agent_service = AgentService()
