import sys
from typing import Optional

try:
    import tiktoken
except ImportError:
    tiktoken = None

from .base_service import BaseChatService
from ..Models.ollama_models import OllamaChatRequest, AddDocumentRequest, AddDocumentResponse
from ..Models.common_models import GeneralChatResponse, Alert, Suggestion, Action
from ..Utils.conversation_storage_manager import conversation_storage_manager, format_conversation_history_for_prompt
from ..Utils.vectorstore_client import vector_store_manager
# Assuming a refactored langchain_components that can be configured or is generic enough
from ..Utils.langchain_components import langchain_pipeline_manager


class OllamaService(BaseChatService):
    """
    Service for handling chat interactions with local Ollama models.
    This includes RAG and conversation history management.
    """

    def __init__(self):
        self.tokenizer = None
        if tiktoken:
            try:
                self.tokenizer = tiktoken.get_encoding("cl100k_base")
            except Exception as e:
                print(f"Could not initialize tiktoken tokenizer: {e}", file=sys.stderr)

    def _build_suggestion_payload(self) -> Suggestion:
        actions = [
            Action(type="new_chat_with_summary", displayText="Start New Chat with Summary"),
            Action(type="upgrade_llm", displayText="Upgrade LLM for Larger Context")
        ]
        return Suggestion(actions=actions, suggested_models=["llama3:70b"])

    async def process_chat_interaction(self, request_payload: OllamaChatRequest) -> GeneralChatResponse:
        conversation_id = request_payload.conversation_id
        user_prompt = request_payload.prompt

        # NOTE: The langchain_pipeline_manager may need refactoring to dynamically accept llm_settings
        # For now, we assume it uses a default or is configured elsewhere.

        # The logic for RAG and history is encapsulated within the langchain_pipeline now.
        # We just need to invoke it with the user's prompt and conversation ID.
        ai_response = await langchain_pipeline_manager.invoke_chain(
            user_prompt=user_prompt,
            conversation_id=conversation_id
        )

        # Persist conversation
        conversation_storage_manager.add_message(data=user_prompt, user_id=conversation_id, role="user")
        conversation_storage_manager.add_message(data=ai_response, user_id=conversation_id, role="ai")

        return GeneralChatResponse(
            response=ai_response,
            conversation_id=conversation_id
        )

    def add_document_to_vectorstore(self, request_payload: AddDocumentRequest) -> AddDocumentResponse:
        """Adds a document to the ChromaDB vector store."""
        if not vector_store_manager.vectorstore:
            raise RuntimeError("Vector store (ChromaDB) is not available.")

        doc_metadata = {"source": request_payload.source}
        if request_payload.metadata:
            doc_metadata.update(request_payload.metadata)

        success, doc_ids = vector_store_manager.add_documents(
            texts=[request_payload.text],
            metadatas=[doc_metadata]
        )

        if success:
            doc_id = doc_ids[0] if doc_ids else None
            return AddDocumentResponse(
                message="Document added successfully to ChromaDB.",
                document_id=doc_id,
                text_preview=request_payload.text[:100] + "...",
                metadata=doc_metadata
            )
        else:
            raise RuntimeError("Failed to add document to ChromaDB.")


ollama_service = OllamaService()
