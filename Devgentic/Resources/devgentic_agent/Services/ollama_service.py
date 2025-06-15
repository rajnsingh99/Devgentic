# filename: Services/ollama_service.py
import sys
from typing import Optional, Dict

from .base_service import BaseChatService
from ..Models.ollama_models import OllamaChatRequest, AddDocumentRequest, AddDocumentResponse, LLMSettings
from ..Models.common_models import GeneralChatResponse
from ..Utils.conversation_storage_manager import conversation_storage_manager, format_conversation_history_for_prompt
from ..Utils.vectorstore_client import vector_store_manager, format_chroma_context_for_prompt
from ..Utils.langchain_components import langchain_pipeline_manager
from ..Utils.context_manager import context_manager


class OllamaService(BaseChatService):
    """
    Service for handling chat interactions with local Ollama models.
    MODIFIED: System prompt is now more implicit to prevent meta-commentary from the LLM.
    """

    def __init__(self):
        self._last_llm_config_store: Dict[str, LLMSettings] = {}

    def _has_llm_config_changed(self, conversation_id: str, new_config: LLMSettings) -> bool:
        """Compares the new LLM config with the last known config for the conversation."""
        last_config = self._last_llm_config_store.get(conversation_id)
        return last_config != new_config

    async def process_chat_interaction(self, request_payload: OllamaChatRequest) -> GeneralChatResponse:
        """
        Processes a chat request with a cleaner, more implicit prompt.
        """
        conversation_id = request_payload.conversation_id
        user_prompt = request_payload.prompt
        llm_settings = request_payload.llm_settings

        if self._has_llm_config_changed(conversation_id, llm_settings):
            print(f"[OllamaService] LLM config changed for '{conversation_id}'. Updating to: {llm_settings.model_name}",
                  file=sys.stdout)
            langchain_pipeline_manager.update_llm_and_rebuild_chain(
                new_ollama_url=str(llm_settings.base_url),
                new_model_name=llm_settings.model_name
            )
            self._last_llm_config_store[conversation_id] = llm_settings

        # 1. Retrieve history and RAG context.
        history_messages = conversation_storage_manager.get_history(user_id=conversation_id, limit=50)
        history_prompt_content = format_conversation_history_for_prompt(history_messages)

        rag_docs = vector_store_manager.retrieve_documents(query=user_prompt)
        rag_context_content = format_chroma_context_for_prompt(rag_docs)

        # 2. FIXED: Build a more implicit and direct system prompt.
        # We present history and context as facts, not as instructions.
        system_prompt_parts = ["You are a helpful and concise AI assistant."]

        if rag_context_content:
            system_prompt_parts.append(f"--- Context ---\n{rag_context_content}")

        if history_prompt_content:
            system_prompt_parts.append(f"--- Chat History ---\n{history_prompt_content}")

        system_prompt = "\n\n".join(system_prompt_parts)

        # 3. Use the ContextManager for token evaluation.
        full_prompt_for_tokens = f"{system_prompt}\n\nUser: {user_prompt}"

        _, alert, suggestion = context_manager.manage_context(
            full_prompt_text=full_prompt_for_tokens,
            user_prompt=user_prompt,
            context_window_size=llm_settings.context_window_size
        )

        if alert:
            # If context is truncated, use a simple prompt.
            system_prompt = "You are a helpful and concise AI assistant. The prior conversation history was too long and has been omitted."

        # 4. Invoke the pipeline.
        ai_response = await langchain_pipeline_manager.invoke_chain(
            user_prompt=user_prompt,
            system_prompt=system_prompt,
        )

        # 5. Persist the conversation turn.
        conversation_storage_manager.add_message(data=user_prompt, user_id=conversation_id, role="user")
        if ai_response:
            conversation_storage_manager.add_message(data=ai_response, user_id=conversation_id, role="ai")

        # 6. Return the full response object.
        return GeneralChatResponse(
            response=ai_response or "Sorry, I could not generate a response.",
            conversation_id=conversation_id,
            alert=alert,
            suggestion=suggestion
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
