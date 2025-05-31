# devgentic_agent/services/agent_service.py
import sys
from typing import Optional, Dict, Any, Tuple, List

# Updated ChatRequest model
from ..models.api_models import ChatRequest, AddDocumentRequest, ChatResponse, AddDocumentResponse
# Updated import to use the new centralized conversation storage manager
from ..tools.conversation_storage_manager import conversation_storage_manager, format_conversation_history_for_prompt
from ..tools.vectorstore_client import vector_store_manager
# Import the manager instance directly
from ..tools.langchain_components import langchain_pipeline_manager
from langchain_ollama.chat_models import ChatOllama # Needed for type hinting llm_instance
from langchain_core.prompts import ChatPromptTemplate # For summarization prompt
from langchain_core.output_parsers import StrOutputParser # For summarization output

class AgentService:
    """
    Service layer containing the core business logic for the agent.
    """
    def __init__(self):
        # Initial readiness check based on langchain_pipeline_manager's status
        lc_status, lc_msg = langchain_pipeline_manager.get_status()
        self.is_ready = lc_status in ["ok", "degraded"] # Consider degraded as initially ready for some operations

        if not self.is_ready:
            print(f"AgentService initialized, but LangchainPipelineManager reported an error: {lc_msg}. Check logs.", file=sys.stderr)
        elif lc_status == "degraded":
            print(f"AgentService initialized, but LangchainPipelineManager reported a degraded state: {lc_msg}. Some operations might be affected.", file=sys.stdout)
        else:
            print("AgentService initialized and ready.", file=sys.stdout)

    async def _get_llm_conversation_summary(
        self,
        conversation_id: str,
        llm_instance: Optional[ChatOllama], # LLM instance can be None if pipeline is broken
        history_limit: int = 20
    ) -> str:
        """
        Generates a conversation summary using the provided LLM instance.
        """
        if not llm_instance:
            print("LLM instance not provided for summarization, cannot generate summary.", file=sys.stderr)
            return ""
        
        # Use the new conversation_storage_manager
        storage_status, _ = conversation_storage_manager.is_available()
        if storage_status in ["error", "disabled"]:
            print(f"Conversation storage not available ({storage_status}), cannot generate summary.", file=sys.stderr)
            return ""

        try:
            # Get history from the active conversation storage backend
            history_memories: List[Any] = conversation_storage_manager.get_history(user_id=conversation_id, limit=history_limit)
            if not history_memories:
                print(f"No conversation history found for {conversation_id} to summarize.", file=sys.stdout)
                return ""

            # history_memories is already sorted chronologically by get_history,
            # but format_conversation_history_for_prompt expects reverse for display
            # (most recent last), so we reverse it here for the prompt.
            history_memories.reverse()
            formatted_history = format_conversation_history_for_prompt(history_memories)

            summarization_prompt_text = (
                "You are an expert summarizer. Please provide a concise summary of the following conversation. "
                "The summary will be used as context for a new query to an AI assistant. "
                "Focus on key topics, decisions made, important entities mentioned, and any unresolved questions. "
                "Keep the summary brief and informative.\n\n"
                "Conversation History:\n"
                f"{formatted_history}\n\n"
                "Concise Summary:"
            )

            prompt_template = ChatPromptTemplate.from_messages([("human", summarization_prompt_text)])
            summarization_chain = prompt_template | llm_instance | StrOutputParser()

            print(f"Requesting LLM summary for conversation_id: {conversation_id} using model {llm_instance.model}", file=sys.stdout)
            summary = await summarization_chain.ainvoke({})

            print(f"LLM summary received for conversation_id: {conversation_id}", file=sys.stdout)
            return summary.strip()

        except Exception as e:
            print(f"Error during LLM conversation summarization for {conversation_id}: {e}", file=sys.stderr)
            return ""

    async def _handle_model_change_and_get_summary(
        self,
        new_ollama_url: str,
        new_model_name: str,
        conversation_id: str,
        current_prompt: str
    ) -> Tuple[str, Optional[str]]: # Returns (effective_prompt, error_message_for_client)
        """
        Handles LLM re-initialization, generates summary, and returns effective prompt.
        Also returns an optional error message if the requested model change failed but agent is still operational.
        """
        print(f"Model change requested. New Ollama URL: {new_ollama_url}, New Model: {new_model_name}", file=sys.stdout)

        requested_update_succeeded, operational_status_ok = langchain_pipeline_manager.update_llm_and_rebuild_chain(
            new_ollama_url=new_ollama_url,
            new_model_name=new_model_name
        )

        client_error_message: Optional[str] = None

        if not operational_status_ok:
            # This means both the new model and any revert attempt failed. Agent is likely unusable.
            error_detail = langchain_pipeline_manager.initialization_error or f"Critical failure during LLM update to {new_model_name}, and revert also failed."
            raise RuntimeError(error_detail) # This will be a 500 error for the client

        if not requested_update_succeeded and operational_status_ok:
            # New model failed, but reverted to old one successfully.
            client_error_message = (
                f"Failed to switch to model '{new_model_name}'. "
                f"Continuing with the previous model ({langchain_pipeline_manager.current_model_name or 'default'}). "
                f"Details: {langchain_pipeline_manager.initialization_error or 'Unknown reason.'}"
            )
            print(client_error_message, file=sys.stdout) # Log this clearly

        # Proceed with summarization using the currently active LLM (new or reverted old)
        current_llm_for_summary = langchain_pipeline_manager.llm
        summary_prompt_prefix = ""

        storage_status, _ = conversation_storage_manager.is_available()

        if not current_llm_for_summary or storage_status in ["error", "disabled"]:
            print("LLM instance not available or conversation storage unavailable after update attempt. Cannot generate summary. Falling back to simple history.", file=sys.stderr)
            # Fallback to simple history if LLM for summary is not available or storage is disabled/errored
            if storage_status == "ok" or storage_status == "degraded": # Only try if storage is at least degraded
                try:
                    history_memories: List[Any] = conversation_storage_manager.get_history(user_id=conversation_id, limit=5)
                    if history_memories:
                        history_memories.reverse() # Reverse for prompt display
                        formatted_fallback_history = format_conversation_history_for_prompt(history_memories)
                        summary_prompt_prefix = (
                            f"--- Start of Recent Conversation History (Fallback) ---\n"
                            f"{formatted_fallback_history}\n"
                            f"--- End of Recent Conversation History ---\n\n"
                            f"Now, please respond to the following user prompt, keeping this context in mind:\n"
                        )
                        print(f"Using fallback recent history for conversation_id: {conversation_id} due to unavailable summary LLM or storage.", file=sys.stdout)
                except Exception as e_fallback:
                    print(f"Error retrieving fallback history for {conversation_id}: {e_fallback}", file=sys.stderr)
        else:
            llm_summary = await self._get_llm_conversation_summary(conversation_id, current_llm_for_summary)
            if llm_summary:
                summary_prompt_prefix = (
                    f"--- Start of Conversation Context (Summarized by AI using model {current_llm_for_summary.model}) ---\n"
                    f"{llm_summary}\n"
                    f"--- End of Conversation Context ---\n\n"
                    f"Now, please respond to the following user prompt, keeping this context in mind:\n"
                )
                print(f"Using LLM-generated summary for conversation_id: {conversation_id}", file=sys.stdout)
            else:
                print(f"LLM summary generation failed for {conversation_id}. Falling back to recent history.", file=sys.stdout)
                # Fallback to simple history if LLM summary failed
                if storage_status == "ok" or storage_status == "degraded": # Only try if storage is at least degraded
                    try:
                        history_memories: List[Any] = conversation_storage_manager.get_history(user_id=conversation_id, limit=5)
                        if history_memories:
                            history_memories.reverse() # Reverse for prompt display
                            formatted_fallback_history = format_conversation_history_for_prompt(history_memories)
                            summary_prompt_prefix = (
                                f"--- Start of Recent Conversation History (Fallback due to Summary Failure) ---\n"
                                f"{formatted_fallback_history}\n"
                                f"--- End of Recent Conversation History ---\n\n"
                                f"Now, please respond to the following user prompt, keeping this context in mind:\n"
                            )
                            print(f"Using fallback recent history for conversation_id: {conversation_id}", file=sys.stdout)
                        else:
                            print(f"No fallback history found for {conversation_id}.", file=sys.stdout)
                    except Exception as e_fallback:
                        print(f"Error retrieving fallback history for {conversation_id}: {e_fallback}", file=sys.stderr)

        return f"{summary_prompt_prefix}{current_prompt}", client_error_message


    async def process_chat_interaction(self, request_payload: ChatRequest) -> ChatResponse:
        conversation_id = request_payload.conversationId
        user_prompt = request_payload.messageContent.prompt

        if not request_payload.agentConfig:
            raise ValueError("Agent configuration is missing.")

        active_agent_config = request_payload.agentConfig[0]
        new_ollama_url = str(active_agent_config.ollama_url)
        new_model_name = active_agent_config.model

        model_changed = request_payload.metadata.modelChanged
        effective_prompt = user_prompt
        client_notification_message: Optional[str] = None

        if model_changed:
            try:
                effective_prompt, client_notification_message = await self._handle_model_change_and_get_summary(
                    new_ollama_url=new_ollama_url,
                    new_model_name=new_model_name,
                    conversation_id=conversation_id,
                    current_prompt=user_prompt
                )
            except RuntimeError as e: # Raised if agent becomes non-operational
                print(f"Critical error during model change handling: {e}", file=sys.stderr)
                # This error will be caught by the controller and returned as 500
                # We might want to include more specific info in ChatResponse if possible
                raise

        # Check overall pipeline status before proceeding
        lc_status, lc_msg = langchain_pipeline_manager.get_status()
        if lc_status == "error": # Not "ok" or "degraded"
            error_detail = lc_msg or "Langchain processing chain is not available."
            print(f"Cannot process chat: {error_detail}", file=sys.stderr)
            # This implies a critical failure, likely caught above if due to model change.
            # If it's some other persistent error, this will catch it.
            raise RuntimeError(f"Agent is not operational: {error_detail}")

        # Add user message to the active conversation storage backend
        storage_status, _ = conversation_storage_manager.is_available()
        if storage_status == "ok" or storage_status == "degraded":
            conversation_storage_manager.add_message(
                data=user_prompt,
                user_id=conversation_id,
                role="user"
            )
        else:
            print(f"Conversation storage backend is not available ({storage_status}). User message will not be persisted.", file=sys.stderr)


        try:
            print(f"Invoking Langchain pipeline with effective prompt for conversation_id: {conversation_id} using model {langchain_pipeline_manager.current_model_name or 'unknown'}", file=sys.stdout)
            ai_response_content = await langchain_pipeline_manager.invoke_chain(
                user_prompt=effective_prompt,
                conversation_id=conversation_id
            )
        except Exception as e:
            print(f"Error during Langchain pipeline invocation: {e}", file=sys.stderr)
            raise RuntimeError(f"Error processing chat with LLM: {e}")

        # Add AI response to the active conversation storage backend
        if ai_response_content and (storage_status == "ok" or storage_status == "degraded"):
            conversation_storage_manager.add_message(
                data=ai_response_content,
                user_id=conversation_id,
                role="ai"
            )
        elif not ai_response_content:
            print("AI response is empty, not persisting.", file=sys.stdout)
        else:
            print(f"Conversation storage backend is not available ({storage_status}). AI response will not be persisted.", file=sys.stderr)


        if client_notification_message:
            print(f"Client notification from model change: {client_notification_message}", file=sys.stdout)

        return ChatResponse(response=ai_response_content, conversation_id=conversation_id)

    def add_document_to_vectorstore(self, request_payload: AddDocumentRequest) -> AddDocumentResponse:
        if not vector_store_manager.vectorstore:
            print("Vector store (ChromaDB) is not available. Cannot add document.", file=sys.stderr)
            raise RuntimeError("Vector store (ChromaDB) is not available. Cannot add document.")

        doc_metadata = {"source": request_payload.source}
        if request_payload.metadata:
            doc_metadata.update(request_payload.metadata)

        success, doc_ids = vector_store_manager.add_documents(
            texts=[request_payload.text],
            metadatas=[doc_metadata]
        )

        if success:
            doc_id = doc_ids[0] if doc_ids and len(doc_ids) > 0 else None
            return AddDocumentResponse(
                message="Document added successfully to ChromaDB.",
                document_id=doc_id,
                text_preview=request_payload.text[:100] + "..." if len(request_payload.text) > 100 else request_payload.text,
                metadata=doc_metadata
            )
        else:
            raise RuntimeError("Failed to add document to ChromaDB.")

agent_service = AgentService()
